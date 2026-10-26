

#include "root.h"
#include "SchemaBindings.h"

#include "JavaScriptCore/Error.h"
#include "JavaScriptCore/JSBigInt.h"
#include <JavaScriptCore/JSBigIntInlines.h>
#include "JavaScriptCore/Structure.h"
#include "JavaScriptCore/ThrowScope.h"

#include "JavaScriptCore/JSArray.h"
#include "JavaScriptCore/ExceptionScope.h"
#include "JavaScriptCore/JSArrayBufferView.h"
#include "JavaScriptCore/JSType.h"

#include "JSSQLStatement.h"
#include "BunClientData.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSObjectInlines.h>
#include <algorithm>
#include <array>
#include <cstring>
#include <functional>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <utility>
#include <wtf/Ref.h>
#include <wtf/Scope.h>

#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/TypedArrayInlines.h>
#include "JSBuffer.h"
#include <JavaScriptCore/ObjectPrototype.h>
#include "BunBuiltinNames.h"
#include "sqlite3_error_codes.h"
#include "wtf/Vector.h"
#include <atomic>
#include "wtf/text/StringToIntegerConversion.h"
#include <wtf/text/CString.h>
#include <JavaScriptCore/InternalFieldTuple.h>
static constexpr int32_t kSafeIntegersFlag = 1 << 1;
static constexpr int32_t kStrictFlag = 1 << 2;

#if LAZY_LOAD_SQLITE
#include "SQLiteLibrary.h"
#endif

#if !USE(SYSTEM_MALLOC)
#include <bmalloc/BPlatform.h>
#define ENABLE_SQLITE_FAST_MALLOC (BENABLE(MALLOC_SIZE) && BENABLE(MALLOC_GOOD_SIZE))
#endif

static std::atomic<int64_t> sqlite_malloc_amount = 0;

static void enableFastMallocForSQLite()
{
#if ENABLE(SQLITE_FAST_MALLOC) && !LAZY_LOAD_SQLITE
    int returnCode = sqlite3_config(SQLITE_CONFIG_LOOKASIDE, 0, 0);
    ASSERT_WITH_MESSAGE(returnCode == SQLITE_OK, "Unable to reduce lookaside buffer size");

    static sqlite3_mem_methods fastMallocMethods = {
        [](int n) -> void* {
            void* ret;
            if (n <= 0 || !tryFastMalloc(static_cast<size_t>(n)).getValue(ret))
                return nullptr;
            sqlite_malloc_amount += fastMallocSize(ret);
            return ret;
        },
        [](void* p) {
            if (p) {
                sqlite_malloc_amount -= fastMallocSize(p);
                fastFree(p);
            }
        },
        [](void* p, int n) -> void* {
            size_t oldSize = p ? fastMallocSize(p) : 0;
            if (n <= 0) {
                sqlite_malloc_amount -= oldSize;
                fastFree(p);
                return nullptr;
            }
            void* out;
            if (!tryFastRealloc(p, static_cast<size_t>(n)).getValue(out))
                return nullptr;
            sqlite_malloc_amount += static_cast<int64_t>(fastMallocSize(out)) - static_cast<int64_t>(oldSize);
            return out;
        },
        [](void* p) { return static_cast<int>(fastMallocSize(p)); },
        [](int n) {
            if (n <= 0)
                return 0;
            size_t size = fastMallocGoodSize(static_cast<size_t>(n));
            return size <= static_cast<size_t>(std::numeric_limits<int>::max()) ? static_cast<int>(size) : 0;
        },
        [](void*) { return SQLITE_OK; },
        [](void*) {},
        nullptr
    };

    returnCode = sqlite3_config(SQLITE_CONFIG_MALLOC, &fastMallocMethods);
    ASSERT_WITH_MESSAGE(returnCode == SQLITE_OK, "Unable to replace SQLite malloc");

#endif
}

class AutoDestructingSQLiteStatement {
    WTF_MAKE_NONCOPYABLE(AutoDestructingSQLiteStatement);
public:
    AutoDestructingSQLiteStatement() = default;
    sqlite3_stmt* stmt { nullptr };

    ~AutoDestructingSQLiteStatement()
    {
        sqlite3_finalize(stmt);
    }
};

static bool initializeSQLite(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope, const char* customPath = nullptr)
{
#if LAZY_LOAD_SQLITE
    auto loaded = lazyLoadSQLite(customPath);
    RETURN_IF_EXCEPTION(scope, false);
    switch (loaded.status) {
    case SQLiteLibraryLoadResult::Status::loaded:
        break;
    case SQLiteLibraryLoadResult::Status::alreadyLoaded:
        JSC::throwException(globalObject, scope, JSC::createError(globalObject, "SQLite is already loaded; select a custom library before opening a database"_s));
        return false;
    case SQLiteLibraryLoadResult::Status::loading:
        JSC::throwException(globalObject, scope, JSC::createError(globalObject, "Cannot use SQLite while its library is being initialized"_s));
        return false;
    case SQLiteLibraryLoadResult::Status::outOfMemory:
        JSC::throwOutOfMemoryError(globalObject, scope);
        return false;
    case SQLiteLibraryLoadResult::Status::missingSymbol: {
        auto message = loaded.message.isNull() ? String { } : tryMakeString("SQLite library is missing required symbol "_s, loaded.message);
        if (message.isNull())
            JSC::throwOutOfMemoryError(globalObject, scope);
        else
            JSC::throwException(globalObject, scope, JSC::createError(globalObject, message));
        return false;
    }
    case SQLiteLibraryLoadResult::Status::loadFailed:
#if OS(WINDOWS)
    {
        auto message = tryMakeString("Unable to load SQLite library (Windows error "_s, loaded.systemError, ")"_s);
        if (message.isNull())
            JSC::throwOutOfMemoryError(globalObject, scope);
        else
            JSC::throwException(globalObject, scope, JSC::createError(globalObject, message));
    }
#else
        if (loaded.message.isNull())
            JSC::throwOutOfMemoryError(globalObject, scope);
        else
            JSC::throwException(globalObject, scope, JSC::createError(globalObject, loaded.message));
#endif
        return false;
    }
#else
    if (customPath) {
        JSC::throwException(globalObject, scope, JSC::createError(globalObject, "This build uses the bundled SQLite library"_s));
        return false;
    }
#endif
    static std::once_flag onceFlag;
    std::call_once(onceFlag, [] {
        enableFastMallocForSQLite();
    });
    return true;
}

static void releaseSQLiteBytes(void*, uint8_t* bytes, size_t)
{
    sqlite3_free(bytes);
}

static constexpr int DEFAULT_SQLITE_FLAGS = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE;
static constexpr unsigned int DEFAULT_SQLITE_PREPARE_FLAGS = SQLITE_PREPARE_PERSISTENT;
static constexpr int MAX_SQLITE_PREPARE_FLAG = SQLITE_PREPARE_PERSISTENT | SQLITE_PREPARE_NORMALIZE | SQLITE_PREPARE_NO_VTAB;

static inline JSC::JSValue jsNumberFromSQLite(sqlite3_stmt* stmt, unsigned int i)
{
    int64_t num = sqlite3_column_int64(stmt, i);
    return JSC::jsNumber(num);
}

static inline JSC::JSValue jsBigIntFromSQLite(JSC::JSGlobalObject* globalObject, sqlite3_stmt* stmt, unsigned int i)
{
    int64_t num = sqlite3_column_int64(stmt, i);
    return JSC::JSBigInt::createFrom(globalObject, num);
}

#define CHECK_THIS                              \
    RETURN_IF_EXCEPTION(scope, {});             \
    RELEASE_ASSERT(castedThis);

#define CHECK_PREPARED                                              \
    if (!castedThis->checkOpen(lexicalGlobalObject, scope))           \
        return {};                                                 \
    SQLiteDatabaseOperation operation(*castedThis->database);

namespace WebCore {
using namespace JSC;

static std::optional<CString> sqliteUTF8(JSGlobalObject* globalObject, const String& input, ThrowScope& scope, bool rejectNul = false)
{
    if (rejectNul && input.contains('\0')) {
        throwTypeError(globalObject, scope, "SQLite strings cannot contain NUL bytes"_s);
        return std::nullopt;
    }
    auto utf8 = input.tryGetUTF8();
    if (!utf8) {
        throwOutOfMemoryError(globalObject, scope);
        return std::nullopt;
    }
    return WTF::move(utf8.value());
}

class SQLiteDatabaseOperation;

class SQLiteDatabaseData {
    WTF_MAKE_NONCOPYABLE(SQLiteDatabaseData);
public:
    SQLiteDatabaseData(sqlite3* db, JSVMClientData& owner)
        : db(db)
        , m_owner(&owner)
    {
        RELEASE_ASSERT(db && !owner.sqliteClosing);
        m_next = owner.sqliteDatabaseHead;
        if (m_next)
            m_next->m_previous = this;
        owner.sqliteDatabaseHead = this;
    }
    sqlite3* db;

    void ref()
    {
        RELEASE_ASSERT(m_references && m_references < std::numeric_limits<size_t>::max());
        ++m_references;
    }

    void deref()
    {
        RELEASE_ASSERT(m_references);
        if (!--m_references)
            delete this;
    }

    void unlink()
    {
        if (!m_owner)
            return;
        if (m_previous)
            m_previous->m_next = m_next;
        else
            m_owner->sqliteDatabaseHead = m_next;
        if (m_next)
            m_next->m_previous = m_previous;
        m_owner = nullptr;
        m_previous = nullptr;
        m_next = nullptr;
    }

    bool checkIdle(JSGlobalObject* globalObject, ThrowScope& scope) const
    {
        if (!m_busy)
            return true;
        throwException(globalObject, scope, createError(globalObject, "Database is busy with an active operation or native pointer borrow"_s));
        return false;
    }

    bool checkOpen(JSGlobalObject* globalObject, ThrowScope& scope) const
    {
        if (!db || m_closing) {
            throwException(globalObject, scope, createError(globalObject, "Database has closed"_s));
            return false;
        }
        return checkIdle(globalObject, scope);
    }

    void closeForTermination();
    void releaseStatement(SQLiteStatementData*);

private:
    friend class SQLiteDatabaseOperation;

    ~SQLiteDatabaseData()
    {
        RELEASE_ASSERT(!m_busy && !m_pendingStatements);
        unlink();
        if (auto* connection = std::exchange(db, nullptr))
            sqlite3_close_v2(connection);
    }

    void endOperation();

    JSVMClientData* m_owner;
    SQLiteDatabaseData* m_previous { nullptr };
    SQLiteDatabaseData* m_next { nullptr };
    SQLiteStatementData* m_pendingStatements { nullptr };
    size_t m_references { 1 };
    bool m_busy { false };
    bool m_closing { false };
};

class SQLiteDatabaseOperation {
    WTF_MAKE_NONCOPYABLE(SQLiteDatabaseOperation);
public:
    explicit SQLiteDatabaseOperation(SQLiteDatabaseData& database)
        : m_database(&database)
    {
        RELEASE_ASSERT(!database.m_busy);
        database.m_busy = true;
    }

    SQLiteDatabaseOperation(SQLiteDatabaseOperation&& other)
        : m_database(WTF::move(other.m_database))
    {
    }

    ~SQLiteDatabaseOperation()
    {
        if (m_database)
            m_database->endOperation();
    }

private:
    RefPtr<SQLiteDatabaseData> m_database;
};

void SQLiteDatabaseData::closeForTermination()
{
    m_closing = true;
    if (!m_busy) {
        SQLiteDatabaseOperation operation(*this);
    }
}

static std::optional<int32_t> nextDatabaseIdentifier(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope)
{
    auto& owner = *downcast<JSVMClientData>(globalObject->vm().clientData);
    if (owner.sqliteClosing) {
        throwException(globalObject, scope, createError(globalObject, "Cannot open a database while the VM is shutting down"_s));
        return std::nullopt;
    }
    static std::atomic<uint64_t> next { 0 };
    auto identifier = next.load(std::memory_order_relaxed);
    do {
        if (identifier > static_cast<uint64_t>(std::numeric_limits<int32_t>::max())) {
            throwException(globalObject, scope, createRangeError(globalObject, "Too many databases"_s));
            return std::nullopt;
        }
    } while (!next.compare_exchange_weak(identifier, identifier + 1, std::memory_order_relaxed));
    return static_cast<int32_t>(identifier);
}

void closeSQLiteDatabasesForVM(JSVMClientData& owner)
{
    owner.sqliteClosing = true;
    while (auto* data = owner.sqliteDatabaseHead) {
        Ref<SQLiteDatabaseData> keepAlive(*data);
        data->unlink();
        data->closeForTermination();
    }
}

static SQLiteDatabaseData* databaseData(BunBindgen_SQLiteNative_Database_Native* owner)
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_SQLiteNative_databaseData(owner);
}

static JSValue adoptDatabase(JSGlobalObject* globalObject, sqlite3* db, int32_t identifier, ThrowScope& scope)
{
    auto& owner = *downcast<JSVMClientData>(globalObject->vm().clientData);
    if (scope.exception()) {
        sqlite3_close_v2(db);
        return {};
    }
    if (owner.sqliteClosing) {
        sqlite3_close_v2(db);
        throwException(globalObject, scope, createError(globalObject, "Cannot open a database while the VM is shutting down"_s));
        return {};
    }
    auto* data = new (std::nothrow) SQLiteDatabaseData(db, owner);
    if (!data) {
        sqlite3_close_v2(db);
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    return Bun::Bindgen::ZigExports::bunBindgenZig_SQLiteNative_adoptDatabase(globalObject, data, identifier, sizeof(SQLiteDatabaseData));
}

static JSValue createSQLiteError(JSC::JSGlobalObject* globalObject, sqlite3* db)
{
    auto& vm = JSC::getVM(globalObject);
    int code = sqlite3_extended_errcode(db);
    if ((code & 0xff) == SQLITE_NOMEM)
        return JSC::createOutOfMemoryError(globalObject);
    int byteOffset = sqlite3_error_offset(db);

    const char* msg = sqlite3_errmsg(db);
    WTF::String str = msg ? WTF::String::fromUTF8ReplacingInvalidSequences(std::span<const char8_t> { reinterpret_cast<const char8_t*>(msg), strlen(msg) }) : String("SQLite error"_s);
    if (str.isNull())
        return JSC::createOutOfMemoryError(globalObject);
    JSC::JSObject* object = JSC::createError(globalObject, str);
    auto& builtinNames = WebCore::builtinNames(vm);
    object->putDirect(vm, vm.propertyNames->name, jsString(vm, String("SQLiteError"_s)), JSC::PropertyAttribute::DontEnum | 0);

    String codeStr;

    switch (code) {
#define MACRO(SQLITE_DEF)          \
    case SQLITE_DEF: {             \
        codeStr = #SQLITE_DEF##_s; \
        break;                     \
    }
        FOR_EACH_SQLITE_ERROR(MACRO)

#undef MACRO
    }
    if (!codeStr.isEmpty())
        object->putDirect(vm, builtinNames.codePublicName(), jsString(vm, codeStr), PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly | 0);

    object->putDirect(vm, builtinNames.errnoPublicName(), jsNumber(code), PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly | 0);
    object->putDirect(vm, vm.propertyNames->byteOffset, jsNumber(byteOffset), PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly | 0);

    return object;
}

class SQLiteStatementData {
    WTF_MAKE_NONCOPYABLE(SQLiteStatementData);
public:
    struct Column {
        Identifier name;
        int index;
    };

    SQLiteStatementData(sqlite3_stmt* stmt, SQLiteDatabaseData& database, int64_t memorySizeChange)
        : stmt(stmt)
        , database(&database)
        , extraMemorySize(memorySizeChange > 0 ? static_cast<size_t>(memorySizeChange) : 0)
    {
        RELEASE_ASSERT(stmt);
    }

    std::optional<SQLiteDatabaseOperation> startExecution(JSGlobalObject*, const Bun::Bindgen::SQLiteBindingsInput*, bool continueIteration = false);
    bool checkOpen(JSGlobalObject*, ThrowScope&) const;

    enum class StepPurpose { Execute, InspectColumnTypes };

    std::optional<int> step(JSGlobalObject* globalObject, ThrowScope& scope, StepPurpose purpose = StepPurpose::Execute)
    {
        int status = sqlite3_step(stmt);
        if (status != SQLITE_ROW && status != SQLITE_DONE) {
            throwException(globalObject, scope, createSQLiteError(globalObject, database->db));
            sqlite3_reset(stmt);
            columnsLoaded = false;
            return std::nullopt;
        }
        if (purpose == StepPurpose::Execute)
            hasExecuted = true;
        return status;
    }

    ~SQLiteStatementData() { finalize(); }

    void release()
    {
        if (database)
            database->releaseStatement(this);
        else
            delete this;
    }

    void finalize()
    {
        auto keepDatabase = std::exchange(database, nullptr);
        sqlite3_finalize(std::exchange(stmt, nullptr));
        columns.clear();
        columnsLoaded = false;
        extraMemorySize = 0;
    }

    sqlite3_stmt* stmt;
    RefPtr<SQLiteDatabaseData> database;
    Vector<Column> columns;
    size_t extraMemorySize = 0;
    bool strictBindings : 1 = false;
    bool columnsLoaded : 1 = false;
    bool hasExecuted : 1 = false;
    bool useBigInt64 : 1 = false;

private:
    friend class SQLiteDatabaseData;
    SQLiteStatementData* m_nextPending { nullptr };
};

void SQLiteDatabaseData::releaseStatement(SQLiteStatementData* statement)
{
    if (m_busy) {
        statement->m_nextPending = m_pendingStatements;
        m_pendingStatements = statement;
        return;
    }
    SQLiteDatabaseOperation operation(*this);
    delete statement;
}

void SQLiteDatabaseData::endOperation()
{
    RELEASE_ASSERT(m_busy);
    // Finalizing another statement can close a journal borrowed by the active call.
    while (m_pendingStatements || (m_closing && db)) {
        while (auto* statement = m_pendingStatements) {
            m_pendingStatements = std::exchange(statement->m_nextPending, nullptr);
            delete statement;
        }
        if (m_closing) {
            if (auto* connection = std::exchange(db, nullptr))
                sqlite3_close_v2(connection);
        }
    }
    m_busy = false;
}

static SQLiteStatementData* sqlStatement(JSGlobalObject* globalObject, JSValue value)
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_SQLiteNative_statementData(globalObject, value);
}

static std::optional<std::span<const uint8_t>> sqliteColumnBytes(JSGlobalObject* globalObject, sqlite3* db, sqlite3_stmt* stmt, int index, bool text, ThrowScope& scope)
{
    const void* data = text ? sqlite3_column_text(stmt, index) : sqlite3_column_blob(stmt, index);
    if (!data && (text || (sqlite3_extended_errcode(db) & 0xff) == SQLITE_NOMEM)) {
        throwOutOfMemoryError(globalObject, scope);
        return std::nullopt;
    }
    int length = sqlite3_column_bytes(stmt, index);
    if (!length && (sqlite3_extended_errcode(db) & 0xff) == SQLITE_NOMEM) {
        throwOutOfMemoryError(globalObject, scope);
        return std::nullopt;
    }
    return std::span<const uint8_t> { static_cast<const uint8_t*>(data), static_cast<size_t>(length) };
}

static JSValue toJSAsBuffer(JSC::VM& vm, JSC::JSGlobalObject* globalObject, sqlite3* db, sqlite3_stmt* stmt, int i)
{
    auto scope = DECLARE_THROW_SCOPE(vm);

    switch (sqlite3_column_type(stmt, i)) {
    case SQLITE_INTEGER: {
        int64_t value = sqlite3_column_int64(stmt, i);
        JSC::JSUint8Array* array = JSC::JSUint8Array::createUninitialized(globalObject, globalObject->m_typedArrayUint8.get(globalObject), 8);
        RETURN_IF_EXCEPTION(scope, {});
        uint8_t* data = array->typedVector();
        for (int j = 0; j < 8; j++) {
            data[j] = (value >> (j * 8)) & 0xFF;
        }
        return array;
    }
    case SQLITE_FLOAT: {
        double value = sqlite3_column_double(stmt, i);
        JSC::JSUint8Array* array = JSC::JSUint8Array::createUninitialized(globalObject, globalObject->m_typedArrayUint8.get(globalObject), 8);
        RETURN_IF_EXCEPTION(scope, {});
        memcpy(array->typedVector(), &value, 8);
        return array;
    }
    case SQLITE3_TEXT: {
        auto bytes = sqliteColumnBytes(globalObject, db, stmt, i, true, scope);
        if (!bytes)
            return {};
        auto* array = JSC::JSUint8Array::createUninitialized(globalObject, globalObject->m_typedArrayUint8.get(globalObject), bytes->size());
        RETURN_IF_EXCEPTION(scope, {});
        if (!bytes->empty())
            memcpy(array->typedVector(), bytes->data(), bytes->size());
        return array;
    }
    case SQLITE_BLOB: {
        auto bytes = sqliteColumnBytes(globalObject, db, stmt, i, false, scope);
        if (!bytes)
            return {};
        auto* array = JSC::JSUint8Array::createUninitialized(globalObject, globalObject->m_typedArrayUint8.get(globalObject), bytes->size());
        RETURN_IF_EXCEPTION(scope, {});
        if (!bytes->empty())
            memcpy(array->typedVector(), bytes->data(), bytes->size());
        return array;
    }
    case SQLITE_NULL:
    default:
        return jsNull();
    }
}

template<bool useBigInt64>
static JSValue toJS(JSC::VM& vm, JSC::JSGlobalObject* globalObject, sqlite3* db, sqlite3_stmt* stmt, int i)
{
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    switch (sqlite3_column_type(stmt, i)) {
    case SQLITE_INTEGER: {
        if constexpr (!useBigInt64) {
            // https://github.com/oven-sh/bun/issues/1536
            return jsNumberFromSQLite(stmt, i);
        } else {
            // https://github.com/oven-sh/bun/issues/1536
            auto bint = jsBigIntFromSQLite(globalObject, stmt, i);
            RETURN_IF_EXCEPTION(throwScope, {});
            return bint;
        }
    }
    case SQLITE_FLOAT: {
        return jsNumber(sqlite3_column_double(stmt, i));
    }
    case SQLITE3_TEXT: {
        auto bytes = sqliteColumnBytes(globalObject, db, stmt, i, true, throwScope);
        if (!bytes)
            return {};
        String string = String::fromUTF8ReplacingInvalidSequences(*bytes);
        if (string.isNull()) {
            throwOutOfMemoryError(globalObject, throwScope);
            return {};
        }
        RELEASE_AND_RETURN(throwScope, jsString(vm, WTF::move(string)));
    }
    case SQLITE_BLOB: {
        auto bytes = sqliteColumnBytes(globalObject, db, stmt, i, false, throwScope);
        if (!bytes)
            return {};
        auto* array = JSC::JSUint8Array::createUninitialized(globalObject, globalObject->m_typedArrayUint8.get(globalObject), bytes->size());
        RETURN_IF_EXCEPTION(throwScope, {});
        if (!bytes->empty())
            memcpy(array->typedVector(), bytes->data(), bytes->size());
        return array;
    }
    default: {
        break;
    }
    }

    return jsNull();
}

static void initializeColumnNames(JSC::JSGlobalObject* lexicalGlobalObject, SQLiteStatementData* castedThis)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stmt = castedThis->stmt;
    int count = sqlite3_column_count(stmt);
    Vector<SQLiteStatementData::Column> columns;
    if (!columns.tryReserveInitialCapacity(count)) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return;
    }
    for (int i = 0; i < count; ++i) {
        const char* name = sqlite3_column_name(stmt, i);
        if (!name) {
            throwOutOfMemoryError(lexicalGlobalObject, scope);
            return;
        }
        String string = String::fromUTF8ReplacingInvalidSequences(std::span<const char8_t> { reinterpret_cast<const char8_t*>(name), strlen(name) });
        if (string.isNull()) {
            throwOutOfMemoryError(lexicalGlobalObject, scope);
            return;
        }
        columns.unsafeAppendWithoutCapacityCheck(SQLiteStatementData::Column { Identifier::fromString(vm, string), i });
    }
    if (!columns.isEmpty()) {
        // The last column wins when a query repeats a name.
        std::sort(columns.begin(), columns.end(), [](const auto& left, const auto& right) {
            if (left.name == right.name)
                return left.index > right.index;
            return std::less<> {}(left.name.impl(), right.name.impl());
        });
        auto end = std::unique(columns.begin(), columns.end(), [](const auto& left, const auto& right) { return left.name == right.name; });
        columns.shrink(static_cast<size_t>(end - columns.begin()));
        std::sort(columns.begin(), columns.end(), [](const auto& left, const auto& right) { return left.index < right.index; });
    }
    castedThis->columns = WTF::move(columns);
    castedThis->columnsLoaded = true;
    scope.release();
}

class SQLiteBindingValue {
public:
    bool capture(JSGlobalObject* globalObject, JSValue value, ThrowScope& scope, bool safeIntegers)
    {
        if (value.isUndefinedOrNull())
            return true;
        if (value.isBoolean() || value.isAnyInt()) {
            m_kind = Kind::Integer;
            m_integer = value.isBoolean() ? value.asBoolean() : value.asAnyInt();
            return true;
        }
        if (value.isNumber()) {
            m_kind = Kind::Double;
            m_double = value.asDouble();
            return true;
        }
        if (value.isString()) {
            m_text = asString(value)->value(globalObject);
            RETURN_IF_EXCEPTION(scope, false);
            if (m_text.isNull()) {
                throwOutOfMemoryError(globalObject, scope);
                return false;
            }
            if (!m_text.is8Bit()) {
                if (!checkLength(globalObject, scope, m_text.length(), sizeof(UChar)))
                    return false;
                m_kind = Kind::Text16;
            } else if (m_text.containsOnlyASCII()) {
                if (!checkLength(globalObject, scope, m_text.length()))
                    return false;
                m_kind = Kind::Text8;
            } else {
                auto utf8 = m_text.tryGetUTF8();
                if (!utf8) {
                    throwOutOfMemoryError(globalObject, scope);
                    return false;
                }
                m_utf8 = WTF::move(utf8.value());
                if (!checkLength(globalObject, scope, m_utf8.length()))
                    return false;
                m_text = {};
                m_kind = Kind::UTF8;
            }
            return true;
        }
        if (value.isBigInt()) {
            if (safeIntegers && value.isHeapBigInt()) {
                auto* bigInt = value.asHeapBigInt();
                if (JSBigInt::compare(bigInt, std::numeric_limits<int64_t>::min()) == JSBigInt::ComparisonResult::LessThan
                    || JSBigInt::compare(bigInt, std::numeric_limits<int64_t>::max()) == JSBigInt::ComparisonResult::GreaterThan) {
                    auto string = bigInt->toString(globalObject, 10);
                    RETURN_IF_EXCEPTION(scope, false);
                    auto message = tryMakeString("BigInt value '"_s, string, "' is out of range"_s);
                    if (message.isNull())
                        throwOutOfMemoryError(globalObject, scope);
                    else
                        throwRangeError(globalObject, scope, message);
                    return false;
                }
            }
            m_kind = Kind::Integer;
            m_integer = JSBigInt::toBigInt64(value);
            return true;
        }
        if (auto* buffer = dynamicDowncast<JSArrayBufferView>(value)) {
            if (buffer->isDetached() || buffer->isOutOfBounds()) {
                throwTypeError(globalObject, scope, "Cannot bind a detached or out-of-bounds TypedArray"_s);
                return false;
            }
            auto length = buffer->byteLength();
            if (!checkLength(globalObject, scope, length))
                return false;
            bool copied = m_bytes.tryAppend(std::span<const uint8_t> { static_cast<const uint8_t*>(buffer->vector()), length });
            ensureStillAliveHere(buffer);
            if (!copied) {
                throwOutOfMemoryError(globalObject, scope);
                return false;
            }
            m_kind = Kind::Blob;
            return true;
        }
        throwTypeError(globalObject, scope, "Binding expected string, TypedArray, boolean, number, bigint or null"_s);
        return false;
    }

    int bind(sqlite3_stmt* stmt, int index) const
    {
        switch (m_kind) {
        case Kind::Null:
            return sqlite3_bind_null(stmt, index);
        case Kind::Integer:
            return sqlite3_bind_int64(stmt, index, m_integer);
        case Kind::Double:
            return sqlite3_bind_double(stmt, index, m_double);
        case Kind::Text8:
            return sqlite3_bind_text(stmt, index, m_text.isEmpty() ? "" : reinterpret_cast<const char*>(m_text.span8().data()), static_cast<int>(m_text.length()), SQLITE_TRANSIENT);
        case Kind::Text16:
            return sqlite3_bind_text16(stmt, index, m_text.span16().data(), static_cast<int>(m_text.length() * sizeof(UChar)), SQLITE_TRANSIENT);
        case Kind::UTF8:
            return sqlite3_bind_text(stmt, index, m_utf8.data(), static_cast<int>(m_utf8.length()), SQLITE_TRANSIENT);
        case Kind::Blob:
            return sqlite3_bind_blob(stmt, index, m_bytes.isEmpty() ? static_cast<const void*>("") : m_bytes.span().data(), static_cast<int>(m_bytes.size()), SQLITE_TRANSIENT);
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

private:
    static bool checkLength(JSGlobalObject* globalObject, ThrowScope& scope, size_t length, size_t unitSize = 1)
    {
        if (length <= static_cast<size_t>(std::numeric_limits<int>::max()) / unitSize)
            return true;
        throwRangeError(globalObject, scope, "Binding exceeds SQLite's maximum value size"_s);
        return false;
    }

    enum class Kind : uint8_t { Null, Integer, Double, Text8, Text16, UTF8, Blob };
    Kind m_kind { Kind::Null };
    int64_t m_integer { 0 };
    double m_double { 0 };
    String m_text;
    CString m_utf8;
    Vector<uint8_t> m_bytes;
};

class SQLiteBindingSnapshot {
public:
    bool capture(JSGlobalObject* globalObject, JSObject* input, sqlite3_stmt* stmt, ThrowScope& scope, bool strict, bool safeIntegers)
    {
        auto& vm = getVM(globalObject);
        unsigned count = sqlite3_bind_parameter_count(stmt);
        auto* array = dynamicDowncast<JSArray>(input);
        if (array && array->length() && array->length() != count) {
            auto message = tryMakeString("SQLite query expected "_s, count, " values, received "_s, array->length());
            if (message.isNull())
                throwOutOfMemoryError(globalObject, scope);
            else
                throwException(globalObject, scope, createError(globalObject, message));
            return false;
        }
        if (!m_values.tryGrow(count)) {
            throwOutOfMemoryError(globalObject, scope);
            return false;
        }
        if (array) {
            if (!array->length())
                return true;
            for (unsigned i = 0; i < count; ++i) {
                JSValue value = array->get(globalObject, i);
                RETURN_IF_EXCEPTION(scope, false);
                if (!m_values[i].capture(globalObject, value, scope, safeIntegers))
                    return false;
            }
            return true;
        }

        struct Parameter {
            Identifier name;
            std::optional<unsigned> index;
        };
        Vector<Parameter> parameters;
        if (!parameters.tryGrow(count)) {
            throwOutOfMemoryError(globalObject, scope);
            return false;
        }
        // Getters can finalize the statement, so no SQLite-owned name survives this loop.
        for (unsigned i = 0; i < count; ++i) {
            const char* name = sqlite3_bind_parameter_name(stmt, static_cast<int>(i + 1));
            if (!name) {
                parameters[i].index = i;
                continue;
            }
            String string = String::fromUTF8(name + (strict ? 1 : 0));
            if (string.isNull()) {
                throwOutOfMemoryError(globalObject, scope);
                return false;
            }
            if (strict && !string.isEmpty() && string[0] >= '0' && string[0] <= '9') {
                if (auto integer = WTF::parseInteger<unsigned>(string, 10); integer && *integer) {
                    parameters[i].index = *integer - 1;
                    continue;
                }
            }
            parameters[i].name = Identifier::fromString(vm, string);
        }

        for (unsigned i = 0; i < count; ++i) {
            const auto& parameter = parameters[i];
            PropertySlot slot(input, PropertySlot::InternalMethodType::GetOwnProperty);
            bool found = parameter.index
                ? input->methodTable()->getOwnPropertySlotByIndex(input, globalObject, *parameter.index, slot)
                : input->methodTable()->getOwnPropertySlot(input, globalObject, parameter.name, slot);
            RETURN_IF_EXCEPTION(scope, false);
            if (!found) {
                if (!strict)
                    continue;
                auto message = parameter.index
                    ? tryMakeString("Missing parameter \""_s, *parameter.index + 1, "\""_s)
                    : tryMakeString("Missing parameter \""_s, parameter.name.string(), "\""_s);
                if (message.isNull())
                    throwOutOfMemoryError(globalObject, scope);
                else
                    throwException(globalObject, scope, createError(globalObject, message));
                return false;
            }
            JSValue value;
            if (slot.isTaintedByOpaqueObject())
                value = parameter.index ? input->get(globalObject, *parameter.index) : input->get(globalObject, parameter.name);
            else
                value = parameter.index ? slot.getValue(globalObject, *parameter.index) : slot.getValue(globalObject, parameter.name);
            RETURN_IF_EXCEPTION(scope, false);
            if (!m_values[i].capture(globalObject, value, scope, safeIntegers))
                return false;
        }
        return true;
    }

    bool bind(JSGlobalObject* globalObject, sqlite3* db, sqlite3_stmt* stmt, ThrowScope& scope) const
    {
        int status = sqlite3_clear_bindings(stmt);
        for (size_t i = 0; status == SQLITE_OK && i < m_values.size(); ++i)
            status = m_values[i].bind(stmt, static_cast<int>(i + 1));
        if (status == SQLITE_OK)
            return true;
        if ((status & 0xff) == SQLITE_NOMEM)
            throwOutOfMemoryError(globalObject, scope);
        else
            throwException(globalObject, scope, createSQLiteError(globalObject, db));
        sqlite3_clear_bindings(stmt);
        return false;
    }

private:
    Vector<SQLiteBindingValue> m_values;
};

static bool isSkippedInSQLiteQuery(const char c)
{
    return c == ' ' || c == ';' || (c >= '\t' && c <= '\r');
}

// This runs a query one-off
// without the overhead of a long-lived statement object
// does not return anything

static std::optional<CString> sqliteControlString(JSGlobalObject* globalObject, const std::optional<String>& input, ThrowScope& scope)
{
    if (!input)
        return CString();
    return sqliteUTF8(globalObject, *input, scope, true);
}

static bool sqliteControlBufferSize(JSGlobalObject* globalObject, const Bun::Bindgen::CppScopedMutableBytes* buffer, size_t size, ThrowScope& scope)
{
    if (!buffer || buffer->preparedSize() >= size)
        return true;
    throwRangeError(globalObject, scope, "SQLite file-control buffer is too small for this operation"_s);
    return false;
}

static std::optional<SQLiteDatabaseOperation> leaseSQLiteControl(Bun::Bindgen::CppCallContext& context, SQLiteDatabaseData& database, Bun::Bindgen::CppDeferredLeaseProof& proof, ThrowScope& scope)
{
    if (!database.checkOpen(&context.globalObject, scope) || !context.lease(proof))
        return std::nullopt;
    return SQLiteDatabaseOperation(database);
}

static Bun::Bindgen::SQLiteFileControlResult sqliteControlStatus(JSGlobalObject* globalObject, int status, ThrowScope& scope)
{
    if ((status & 0xff) == SQLITE_NOMEM)
        throwOutOfMemoryError(globalObject, scope);
    Bun::Bindgen::SQLiteFileControlResult result {};
    result.statusCode = status;
    result.value.set_null_value({});
    return result;
}

static String copySQLiteControlString(JSGlobalObject* globalObject, const char* text, ThrowScope& scope)
{
    String result = String::fromUTF8ReplacingInvalidSequences(std::span<const char8_t> { reinterpret_cast<const char8_t*>(text), strlen(text) });
    if (result.isNull())
        throwOutOfMemoryError(globalObject, scope);
    return result;
}

class SQLiteControlHandleData {
    WTF_MAKE_NONCOPYABLE(SQLiteControlHandleData);

public:
    SQLiteControlHandleData(SQLiteDatabaseData& database, CString databaseName, int operation)
        : database(database)
        , databaseName(WTF::move(databaseName))
        , operation(operation)
    {
    }

    Bun::Bindgen::SQLiteControlHandleKind kind() const
    {
        switch (operation) {
        case SQLITE_FCNTL_FILE_POINTER:
            return Bun::Bindgen::SQLiteControlHandleKind::database;
        case SQLITE_FCNTL_JOURNAL_POINTER:
            return Bun::Bindgen::SQLiteControlHandleKind::journal;
        case SQLITE_FCNTL_VFS_POINTER:
            return Bun::Bindgen::SQLiteControlHandleKind::vfs;
        case SQLITE_FCNTL_WIN32_GET_HANDLE:
            return Bun::Bindgen::SQLiteControlHandleKind::win32;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    int resolve(void*& pointer) const
    {
        const char* name = databaseName.isNull() ? nullptr : databaseName.data();
        switch (operation) {
        case SQLITE_FCNTL_FILE_POINTER:
        case SQLITE_FCNTL_JOURNAL_POINTER: {
            sqlite3_file* file = nullptr;
            int status = sqlite3_file_control(database->db, name, operation, &file);
            pointer = file;
            return status;
        }
        case SQLITE_FCNTL_VFS_POINTER: {
            sqlite3_vfs* vfs = nullptr;
            int status = sqlite3_file_control(database->db, name, operation, &vfs);
            pointer = vfs;
            return status;
        }
        case SQLITE_FCNTL_WIN32_GET_HANDLE:
            return sqlite3_file_control(database->db, name, operation, &pointer);
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    Ref<SQLiteDatabaseData> database;
    CString databaseName;
    int operation;
};

template<typename Arguments>
static Bun::Bindgen::SQLiteFileControlResult sqliteControlInt32(Bun::Bindgen::CppCallContext& context, const Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* database = databaseData(args.database);
    if (!database->checkOpen(globalObject, scope))
        return {};
    bool required = false;
    switch (args.operation) {
    case SQLITE_FCNTL_CHUNK_SIZE:
    case SQLITE_FCNTL_LOCK_TIMEOUT:
    case SQLITE_FCNTL_BLOCK_ON_CONNECT:
        required = true;
        break;
    case SQLITE_FCNTL_LOCKSTATE:
    case SQLITE_FCNTL_LAST_ERRNO:
    case SQLITE_FCNTL_PERSIST_WAL:
    case SQLITE_FCNTL_POWERSAFE_OVERWRITE:
    case SQLITE_FCNTL_HAS_MOVED:
    case SQLITE_FCNTL_DATA_VERSION:
    case SQLITE_FCNTL_RESERVE_BYTES:
    case SQLITE_FCNTL_EXTERNAL_READER:
        break;
    default:
        throwRangeError(globalObject, scope, "Unsupported integer file-control operation"_s);
        return {};
    }
    auto name = sqliteControlString(globalObject, args.databaseName, scope);
    if (!name)
        return {};
    Bun::Bindgen::CppDeferredLeaseProof proof;
    const auto* converted = args.argument.convertLast(proof);
    RETURN_IF_EXCEPTION(scope, {});
    if (!converted)
        return {};
    const auto& argument = *converted;
    if (!argument && required) {
        throwTypeError(globalObject, scope, "This SQLite file-control operation requires an integer argument"_s);
        return {};
    }
    int value = -1;
    const Bun::Bindgen::CppScopedMutableBytes* buffer = nullptr;
    if (argument) {
        if (argument->is_number())
            value = argument->number();
        else
            buffer = &argument->buffer();
    }
    if (!sqliteControlBufferSize(globalObject, buffer, sizeof(value), scope))
        return {};
    auto operation = leaseSQLiteControl(context, *database, proof, scope);
    if (!operation)
        return {};
    if (buffer)
        memcpy(&value, buffer->unsafePtr("The entry frame holds the control buffer lease through synchronous memcpy"_s), sizeof(value));
    const char* databaseName = name->isNull() ? nullptr : name->data();
    if (args.operation == SQLITE_FCNTL_DATA_VERSION) {
        unsigned int version = 0;
        int status = sqlite3_file_control(database->db, databaseName, args.operation, &version);
        auto result = sqliteControlStatus(globalObject, status, scope);
        RETURN_IF_EXCEPTION(scope, {});
        if (status == SQLITE_OK) {
            if (buffer)
                memcpy(buffer->unsafePtr("The entry frame holds the control buffer lease through synchronous memcpy"_s), &version, sizeof(version));
            result.value.set_number(version);
        }
        return result;
    }
    int status = sqlite3_file_control(database->db, databaseName, args.operation, &value);
    auto result = sqliteControlStatus(globalObject, status, scope);
    RETURN_IF_EXCEPTION(scope, {});
    if (status == SQLITE_OK) {
        if (buffer)
            memcpy(buffer->unsafePtr("The entry frame holds the control buffer lease through synchronous memcpy"_s), &value, sizeof(value));
        result.value.set_number(value);
    }
    return result;
}

template<typename Arguments>
static Bun::Bindgen::SQLiteFileControlResult sqliteControlInt64(Bun::Bindgen::CppCallContext& context, const Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* database = databaseData(args.database);
    if (!database->checkOpen(globalObject, scope))
        return {};
    switch (args.operation) {
    case SQLITE_FCNTL_SIZE_HINT:
    case SQLITE_FCNTL_MMAP_SIZE:
    case SQLITE_FCNTL_SIZE_LIMIT:
        break;
    default:
        throwRangeError(globalObject, scope, "Unsupported 64-bit integer file-control operation"_s);
        return {};
    }
    auto name = sqliteControlString(globalObject, args.databaseName, scope);
    if (!name)
        return {};
    Bun::Bindgen::CppDeferredLeaseProof proof;
    const auto* converted = args.argument.convertLast(proof);
    RETURN_IF_EXCEPTION(scope, {});
    if (!converted)
        return {};
    const auto& argument = *converted;
    if (!argument && args.operation == SQLITE_FCNTL_SIZE_HINT) {
        throwTypeError(globalObject, scope, "SQLITE_FCNTL_SIZE_HINT requires an integer argument"_s);
        return {};
    }
    sqlite3_int64 value = -1;
    const Bun::Bindgen::CppScopedMutableBytes* buffer = nullptr;
    if (argument) {
        if (argument->is_number())
            value = argument->number();
        else if (argument->is_bigint())
            value = argument->bigint();
        else
            buffer = &argument->buffer();
    }
    if (!sqliteControlBufferSize(globalObject, buffer, sizeof(value), scope))
        return {};
    auto operation = leaseSQLiteControl(context, *database, proof, scope);
    if (!operation)
        return {};
    if (buffer)
        memcpy(&value, buffer->unsafePtr("The entry frame holds the control buffer lease through synchronous memcpy"_s), sizeof(value));
    int status = sqlite3_file_control(database->db, name->isNull() ? nullptr : name->data(), args.operation, &value);
    auto result = sqliteControlStatus(globalObject, status, scope);
    RETURN_IF_EXCEPTION(scope, {});
    if (status == SQLITE_OK) {
        if (buffer)
            memcpy(buffer->unsafePtr("The entry frame holds the control buffer lease through synchronous memcpy"_s), &value, sizeof(value));
        result.value.set_integer(value);
    }
    return result;
}

template<typename Arguments>
static Bun::Bindgen::SQLiteFileControlResult sqliteControlRetry(Bun::Bindgen::CppCallContext& context, const Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* database = databaseData(args.database);
    if (!database->checkOpen(globalObject, scope))
        return {};
    if (args.operation != SQLITE_FCNTL_WIN32_AV_RETRY) {
        throwRangeError(globalObject, scope, "Unsupported retry file-control operation"_s);
        return {};
    }
    auto name = sqliteControlString(globalObject, args.databaseName, scope);
    if (!name)
        return {};
    Bun::Bindgen::CppDeferredLeaseProof proof;
    const auto* converted = args.argument.convertLast(proof);
    RETURN_IF_EXCEPTION(scope, {});
    if (!converted)
        return {};
    std::array<int, 2> values { -1, -1 };
    const Bun::Bindgen::CppScopedMutableBytes* buffer = nullptr;
    if (const auto& argument = *converted) {
        if (argument->is_buffer())
            buffer = &argument->buffer();
        else {
            values[0] = argument->options().retries.value_or(-1);
            values[1] = argument->options().delay.value_or(-1);
        }
    }
    if (!sqliteControlBufferSize(globalObject, buffer, sizeof(int) * values.size(), scope))
        return {};
    auto operation = leaseSQLiteControl(context, *database, proof, scope);
    if (!operation)
        return {};
    if (buffer)
        memcpy(values.data(), buffer->unsafePtr("The entry frame holds the control buffer lease through synchronous memcpy"_s), sizeof(int) * values.size());
    int status = sqlite3_file_control(database->db, name->isNull() ? nullptr : name->data(), args.operation, values.data());
    auto result = sqliteControlStatus(globalObject, status, scope);
    RETURN_IF_EXCEPTION(scope, {});
    if (status == SQLITE_OK) {
        if (buffer)
            memcpy(buffer->unsafePtr("The entry frame holds the control buffer lease through synchronous memcpy"_s), values.data(), sizeof(int) * values.size());
        result.value.set_retry({ .retries = values[0], .delay = values[1] });
    }
    return result;
}

template<typename Arguments>
static Bun::Bindgen::SQLiteFileControlResult sqliteControlText(Bun::Bindgen::CppCallContext& context, const Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* database = databaseData(args.database);
    if (!database->checkOpen(globalObject, scope))
        return {};
    if (args.operation != SQLITE_FCNTL_SET_LOCKPROXYFILE && args.operation != SQLITE_FCNTL_TRACE) {
        throwRangeError(globalObject, scope, "Unsupported string file-control operation"_s);
        return {};
    }
    auto name = sqliteControlString(globalObject, args.databaseName, scope);
    if (!name)
        return {};
    Bun::Bindgen::CppDeferredLeaseProof proof;
    const auto* converted = args.argument.convertLast(proof);
    RETURN_IF_EXCEPTION(scope, {});
    if (!converted)
        return {};
    if (!*converted && args.operation == SQLITE_FCNTL_TRACE) {
        throwTypeError(globalObject, scope, "SQLITE_FCNTL_TRACE requires a string argument"_s);
        return {};
    }
    auto text = sqliteControlString(globalObject, *converted, scope);
    if (!text)
        return {};
    auto operation = leaseSQLiteControl(context, *database, proof, scope);
    if (!operation)
        return {};
    int status = sqlite3_file_control(database->db, name->isNull() ? nullptr : name->data(), args.operation, text->isNull() ? nullptr : const_cast<char*>(text->data()));
    return sqliteControlStatus(globalObject, status, scope);
}

template<typename Arguments>
static Bun::Bindgen::SQLiteFileControlResult sqliteControlPragma(Bun::Bindgen::CppCallContext& context, const Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* database = databaseData(args.database);
    if (!database->checkOpen(globalObject, scope))
        return {};
    if (args.operation != SQLITE_FCNTL_PRAGMA) {
        throwRangeError(globalObject, scope, "Unsupported pragma file-control operation"_s);
        return {};
    }
    auto name = sqliteControlString(globalObject, args.databaseName, scope);
    if (!name)
        return {};
    Bun::Bindgen::CppDeferredLeaseProof proof;
    const auto* argument = args.argument.convertLast(proof);
    RETURN_IF_EXCEPTION(scope, {});
    if (!argument)
        return {};
    if (argument->name.isEmpty()) {
        throwTypeError(globalObject, scope, "SQLite file-control pragma requires a name"_s);
        return {};
    }
    auto pragmaName = sqliteControlString(globalObject, argument->name, scope);
    if (!pragmaName)
        return {};
    auto pragmaValue = sqliteControlString(globalObject, argument->value, scope);
    if (!pragmaValue)
        return {};
    auto operation = leaseSQLiteControl(context, *database, proof, scope);
    if (!operation)
        return {};
    std::array<char*, 3> values { nullptr, const_cast<char*>(pragmaName->data()), pragmaValue->isNull() ? nullptr : const_cast<char*>(pragmaValue->data()) };
    auto freeResult = WTF::makeScopeExit([&] { sqlite3_free(values[0]); });
    int status = sqlite3_file_control(database->db, name->isNull() ? nullptr : name->data(), args.operation, values.data());
    auto result = sqliteControlStatus(globalObject, status, scope);
    RETURN_IF_EXCEPTION(scope, {});
    if (values[0])
        result.value.set_text(copySQLiteControlString(globalObject, values[0], scope));
    return result;
}

template<typename Arguments>
static Bun::Bindgen::SQLiteFileControlResult sqliteControlQuery(Bun::Bindgen::CppCallContext& context, const Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* database = databaseData(args.database);
    if (!database->checkOpen(globalObject, scope))
        return {};
    bool handle = false;
    switch (args.operation) {
    case SQLITE_FCNTL_FILE_POINTER:
    case SQLITE_FCNTL_JOURNAL_POINTER:
    case SQLITE_FCNTL_VFS_POINTER:
    case SQLITE_FCNTL_WIN32_GET_HANDLE:
        handle = true;
        break;
    case SQLITE_FCNTL_GET_LOCKPROXYFILE:
    case SQLITE_FCNTL_VFSNAME:
    case SQLITE_FCNTL_TEMPFILENAME:
        break;
    default:
        throwRangeError(globalObject, scope, "Unsupported file-control query"_s);
        return {};
    }
    auto name = sqliteControlString(globalObject, args.databaseName, scope);
    if (!name)
        return {};
    Bun::Bindgen::CppDeferredLeaseProof proof;
    const auto* converted = args.argument.convertLast(proof);
    RETURN_IF_EXCEPTION(scope, {});
    if (!converted)
        return {};
    auto operation = leaseSQLiteControl(context, *database, proof, scope);
    if (!operation)
        return {};
    if (handle) {
        SQLiteControlHandleData view(*database, *name, args.operation);
        void* pointer = nullptr;
        int status = view.resolve(pointer);
        auto result = sqliteControlStatus(globalObject, status, scope);
        RETURN_IF_EXCEPTION(scope, {});
        if (status == SQLITE_OK && pointer) {
            auto* data = new (std::nothrow) SQLiteControlHandleData(*database, WTF::move(*name), args.operation);
            if (!data) {
                throwOutOfMemoryError(globalObject, scope);
                return {};
            }
            JSValue wrapper = Bun::Bindgen::ZigExports::bunBindgenZig_SQLiteNative_adoptControlHandle(globalObject, data, data->kind(), sizeof(SQLiteControlHandleData) + data->databaseName.length());
            RETURN_IF_EXCEPTION(scope, {});
            result.value.set_handle(wrapper);
        }
        return result;
    }
    if (args.operation == SQLITE_FCNTL_GET_LOCKPROXYFILE) {
        const char* path = nullptr;
        int status = sqlite3_file_control(database->db, name->isNull() ? nullptr : name->data(), args.operation, &path);
        auto result = sqliteControlStatus(globalObject, status, scope);
        RETURN_IF_EXCEPTION(scope, {});
        if (status == SQLITE_OK && path)
            result.value.set_text(copySQLiteControlString(globalObject, path, scope));
        return result;
    }
    char* text = nullptr;
    auto freeResult = WTF::makeScopeExit([&] { sqlite3_free(text); });
    int status = sqlite3_file_control(database->db, name->isNull() ? nullptr : name->data(), args.operation, &text);
    auto result = sqliteControlStatus(globalObject, status, scope);
    RETURN_IF_EXCEPTION(scope, {});
    if (status == SQLITE_OK && text) {
        result.value.set_text(copySQLiteControlString(globalObject, text, scope));
    }
    return result;
}

template<typename Arguments>
static Bun::Bindgen::SQLiteFileControlResult sqliteControlNotify(Bun::Bindgen::CppCallContext& context, const Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* database = databaseData(args.database);
    if (!database->checkOpen(globalObject, scope))
        return {};
    if (args.operation != SQLITE_FCNTL_RESET_CACHE) {
        throwRangeError(globalObject, scope, "Unsupported file-control notification"_s);
        return {};
    }
    auto name = sqliteControlString(globalObject, args.databaseName, scope);
    if (!name)
        return {};
    Bun::Bindgen::CppDeferredLeaseProof proof;
    const auto* converted = args.argument.convertLast(proof);
    RETURN_IF_EXCEPTION(scope, {});
    if (!converted)
        return {};
    auto operation = leaseSQLiteControl(context, *database, proof, scope);
    if (!operation)
        return {};
    int status = sqlite3_file_control(database->db, name->isNull() ? nullptr : name->data(), args.operation, nullptr);
    return sqliteControlStatus(globalObject, status, scope);
}

template<bool useBigInt64>
static inline JSC::JSValue constructResultObject(JSC::JSGlobalObject* lexicalGlobalObject, SQLiteStatementData* castedThis, JSValue receiver)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto customPrototype = Bun::Bindgen::ZigExports::bunBindgenZig_SQLiteNative_getPrototype(lexicalGlobalObject, receiver);
    RETURN_IF_EXCEPTION(scope, {});
    auto* prototype = customPrototype ? asObject(*customPrototype) : lexicalGlobalObject->objectPrototype();
    auto* result = JSC::constructEmptyObject(lexicalGlobalObject, prototype, std::min(static_cast<unsigned>(castedThis->columns.size()), JSFinalObject::maxInlineCapacity));
    RETURN_IF_EXCEPTION(scope, {});
    auto* stmt = castedThis->stmt;
    for (const auto& column : castedThis->columns) {
        auto value = toJS<useBigInt64>(vm, lexicalGlobalObject, castedThis->database->db, stmt, column.index);
        RETURN_IF_EXCEPTION(scope, {});
        result->putDirectMayBeIndex(lexicalGlobalObject, column.name, value);
        RETURN_IF_EXCEPTION(scope, {});
    }

    RELEASE_AND_RETURN(scope, result);
}

template<bool raw>
static inline JSC::JSArray* constructResultRow(JSC::VM& vm, JSC::JSGlobalObject* lexicalGlobalObject, SQLiteStatementData* castedThis, size_t columnCount)
{
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto* stmt = castedThis->stmt;
    auto* result = JSC::constructEmptyArray(lexicalGlobalObject, static_cast<ArrayAllocationProfile*>(nullptr), columnCount);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    for (size_t i = 0; i < columnCount; i++) {
        JSValue value;
        if constexpr (raw)
            value = toJSAsBuffer(vm, lexicalGlobalObject, castedThis->database->db, stmt, static_cast<int>(i));
        else
            value = castedThis->useBigInt64
                ? toJS<true>(vm, lexicalGlobalObject, castedThis->database->db, stmt, static_cast<int>(i))
                : toJS<false>(vm, lexicalGlobalObject, castedThis->database->db, stmt, static_cast<int>(i));
        RETURN_IF_EXCEPTION(throwScope, nullptr);
        result->putDirectIndex(lexicalGlobalObject, i, value);
        RETURN_IF_EXCEPTION(throwScope, nullptr);
    }

    return result;
}

bool SQLiteStatementData::checkOpen(JSGlobalObject* globalObject, ThrowScope& scope) const
{
    if (!stmt || !database) {
        throwException(globalObject, scope, createError(globalObject, "Statement has finalized"_s));
        return false;
    }
    return database->checkOpen(globalObject, scope);
}

std::optional<SQLiteDatabaseOperation> SQLiteStatementData::startExecution(JSGlobalObject* globalObject, const Bun::Bindgen::SQLiteBindingsInput* input, bool continueIteration)
{
    auto& vm = getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!checkOpen(globalObject, scope))
        return std::nullopt;

    SQLiteBindingSnapshot bindings;
    if (input) {
        if (!input->is_object()) {
            throwTypeError(globalObject, scope, "Expected object or array"_s);
            return std::nullopt;
        }
        if (!bindings.capture(globalObject, uncheckedDowncast<JSObject>(input->object()), stmt, scope, strictBindings, useBigInt64))
            return std::nullopt;
        if (!checkOpen(globalObject, scope))
            return std::nullopt;
    }

    SQLiteDatabaseOperation operation(*database);
    if (!continueIteration || input || !sqlite3_stmt_busy(stmt)) {
        int status = sqlite3_reset(stmt);
        columnsLoaded = false;
        if (status != SQLITE_OK) {
            if ((status & 0xff) == SQLITE_NOMEM)
                throwOutOfMemoryError(globalObject, scope);
            else
                throwException(globalObject, scope, createSQLiteError(globalObject, database->db));
            return std::nullopt;
        }
    }
    if (input && !bindings.bind(globalObject, database->db, stmt, scope))
        return std::nullopt;
    scope.release();
    return WTF::move(operation);
}

} // namespace WebCore

void Bun::Bindgen::Engine::releaseSQLiteDatabaseData(WebCore::SQLiteDatabaseData* data)
{
    data->deref();
}

void Bun::Bindgen::Engine::releaseSQLiteStatementData(WebCore::SQLiteStatementData* data)
{
    data->release();
}

void Bun::Bindgen::Engine::releaseSQLiteControlHandleData(WebCore::SQLiteControlHandleData* data)
{
    delete data;
}

void Bun::Bindgen::Engine::bunBindgenEngine_sqlite_termination_closeAllSQLiteDatabasesForTermination(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_sqlite_termination_closeAllSQLiteDatabasesForTermination_Arguments&)
{
    WebCore::closeSQLiteDatabasesForVM(*WTF::downcast<WebCore::JSVMClientData>(context.globalObject.vm().clientData));
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteStatementHost_createInternalFieldTuple(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_SQLiteStatementHost_createInternalFieldTuple_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    JSC::VM& vm = globalObject->vm();
    return JSC::InternalFieldTuple::create(vm, globalObject->internalFieldTupleStructure(), JSC::jsUndefined(), JSC::jsUndefined());
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteStatementHost_jsSQLStatementSetCustomSQLite(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteStatementHost_jsSQLStatementSetCustomSQLite_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.path) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "Expected 1 argument"_s));
        return false;
    }
    if (!*args.path) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "Expected SQLite path"_s));
        return false;
    }

    const String& path = **args.path;
    if (path.isEmpty() || path.contains('\0')) {
        throwTypeError(lexicalGlobalObject, scope, "Expected a nonempty SQLite library path without NUL bytes"_s);
        return false;
    }
    auto utf8 = sqliteUTF8(lexicalGlobalObject, path, scope);
    if (!utf8)
        return false;
    if (!initializeSQLite(lexicalGlobalObject, scope, utf8->data()))
        return false;

    scope.release();
    return true;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteStatementHost_jsSQLStatementDeserialize(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteStatementHost_jsSQLStatementDeserialize_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSC::JSArrayBufferView* array = args.buffer ? uncheckedDowncast<JSC::JSArrayBufferView>(*args.buffer) : nullptr;
    unsigned int deserializeFlags = SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE;
    unsigned int openFlags = DEFAULT_SQLITE_FLAGS;

    if (args.openFlags) openFlags |= *args.openFlags;
    if (args.deserializeFlags) deserializeFlags |= *args.deserializeFlags;

    if (!array) [[unlikely]] {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "Expected Uint8Array or Buffer"_s));
        return {};
    }

    if (array->isDetached()) [[unlikely]] {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "TypedArray is detached"_s));
        return {};
    }

    if (!initializeSQLite(lexicalGlobalObject, scope))
        return {};

#if LAZY_LOAD_SQLITE
    if (!sqliteLibraryState().api.deserialize) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "This SQLite library does not support deserialization"_s));
        return {};
    }
#endif

    RELEASE_ASSERT(args.bytes);
    const auto* bytes = args.bytes->convert();
    RETURN_IF_EXCEPTION(scope, {});
    if (!bytes)
        return {};
    size_t byteLength = bytes->size();
    if (byteLength == 0) [[unlikely]] {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "ArrayBuffer must not be empty"_s));
        return {};
    }
    if (byteLength > static_cast<uint64_t>(std::numeric_limits<sqlite3_int64>::max())) [[unlikely]] {
        throwException(lexicalGlobalObject, scope, createRangeError(lexicalGlobalObject, "Serialized database is too large"_s));
        return {};
    }
    auto identifier = nextDatabaseIdentifier(lexicalGlobalObject, scope);
    if (!identifier)
        return {};
    void* data = sqlite3_malloc64(byteLength);
    if (data == nullptr) [[unlikely]] {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }
    auto freeDataOnFailure = WTF::makeScopeExit([&] { sqlite3_free(data); });
    memcpy(data, bytes->data(), byteLength);

    sqlite3* db = nullptr;
    auto closeDatabaseOnFailure = WTF::makeScopeExit([&] {
        if (db) sqlite3_close_v2(db);
    });
    int openStatus = sqlite3_open_v2(":memory:", &db, openFlags, nullptr);
    if (openStatus != SQLITE_OK) {
        if (openStatus == SQLITE_NOMEM)
            throwOutOfMemoryError(lexicalGlobalObject, scope);
        else
            throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "Failed to open SQLite"_s));
        return {};
    }

    int status = sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, 1, NULL);
    if (status != SQLITE_OK) {
        // TODO: log a warning here that we can't load extensions
    }
    status = sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, 1, NULL);
    if (status != SQLITE_OK) {
        // TODO: log a warning here that defensive mode is not enabled
    }

    // FREEONCLOSE makes sqlite3_deserialize consume the allocation even on failure.
    freeDataOnFailure.release();
    const auto databaseSize = static_cast<sqlite3_int64>(byteLength);
    status = sqlite3_deserialize(db, "main", reinterpret_cast<unsigned char*>(data), databaseSize, databaseSize, deserializeFlags);
    if (status == SQLITE_BUSY) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "SQLITE_BUSY"_s));
        return {};
    }

    if (status != SQLITE_OK) {
        if (status == SQLITE_NOMEM)
            throwOutOfMemoryError(lexicalGlobalObject, scope);
        else
            throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, status == SQLITE_ERROR ? "unable to deserialize database"_s : String::fromUTF8(sqlite3_errstr(status))));
        return {};
    }

    closeDatabaseOnFailure.release();
    JSValue result = adoptDatabase(lexicalGlobalObject, db, *identifier, scope);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteStatementHost_jsSQLStatementSerialize(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteStatementHost_jsSQLStatementSerialize_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* database = databaseData(args.database);
    if (!database->checkOpen(lexicalGlobalObject, scope))
        return {};

#if LAZY_LOAD_SQLITE
    if (!sqliteLibraryState().api.serialize) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "This SQLite library does not support serialization"_s));
        return {};
    }
#endif

    const auto* attachedNameInput = args.attachedName.convert();
    RETURN_IF_EXCEPTION(scope, {});
    if (!attachedNameInput)
        return {};
    const WTF::String& attachedName = *attachedNameInput;

    if (attachedName.isEmpty()) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "Expected attached database name"_s));
        return {};
    }
    auto attachedNameUTF8 = sqliteUTF8(lexicalGlobalObject, attachedName, scope, true);
    if (!attachedNameUTF8)
        return {};
    if (!database->checkOpen(lexicalGlobalObject, scope))
        return {};
    SQLiteDatabaseOperation operation(*database);
    sqlite3* db = database->db;
    sqlite3_int64 length = -1;
    unsigned char* data = sqlite3_serialize(db, attachedNameUTF8->data(), &length, 0);
    if (length < 0) [[unlikely]] {
        sqlite3_free(data);
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "Unable to serialize database"_s));
        return {};
    }
    if (data == nullptr && length != 0) [[unlikely]] {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }

    auto* owner = bun_bindgen_byte_owner_create(data, static_cast<size_t>(length), nullptr, releaseSQLiteBytes);
    if (!owner) {
        sqlite3_free(data);
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }
    auto backing = Bun::Bindgen::adoptByteOwner(owner);
    if (!backing) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }
    auto* result = WebCore::createBuffer(lexicalGlobalObject, backing.releaseNonNull());
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteStatementHost_jsSQLStatementLoadExtensionFunction(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteStatementHost_jsSQLStatementLoadExtensionFunction_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.extension) [[unlikely]] {
        throwException(lexicalGlobalObject, scope, createTypeError(lexicalGlobalObject, "Expected string"_s));
        return;
    }
    const WTF::String& extensionString = *args.extension;

    auto* database = databaseData(args.database);
    if (!database->checkOpen(lexicalGlobalObject, scope))
        return;
    SQLiteDatabaseOperation operation(*database);
    sqlite3* db = database->db;

    bool supportsExtensions = !sqlite3_compileoption_used("SQLITE_OMIT_LOAD_EXTENSION");
#if LAZY_LOAD_SQLITE
    supportsExtensions = supportsExtensions && sqliteLibraryState().api.load_extension;
#endif
    if (!supportsExtensions) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "This build of sqlite3 does not support dynamic extension loading"_s));
        return;
    }

    WTF::String entryPointStr = args.entryPoint.value_or(String());
    auto entryPointUtf8 = sqliteUTF8(lexicalGlobalObject, entryPointStr, scope, true);
    if (!entryPointUtf8)
        return;
    const char* entryPoint = entryPointStr.isEmpty() ? nullptr : entryPointUtf8->data();
    auto extensionStringUtf8 = sqliteUTF8(lexicalGlobalObject, extensionString, scope, true);
    if (!extensionStringUtf8)
        return;
    char* error = nullptr;
    int rc = sqlite3_load_extension(db, extensionStringUtf8->data(), entryPoint, &error);
    auto freeError = WTF::makeScopeExit([&] { sqlite3_free(error); });

    if (rc != SQLITE_OK) {
        if ((rc & 0xff) == SQLITE_NOMEM)
            throwOutOfMemoryError(lexicalGlobalObject, scope);
        else
            throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, String::fromUTF8(error ? error : sqlite3_errmsg(db))));
        return;
    }

    scope.release();
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteStatementHost_jsSQLStatementExecuteFunction(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteStatementHost_jsSQLStatementExecuteFunction_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.database || !args.internalFlags) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "Expected at least 2 arguments"_s));
        return;
    }

    auto* databaseOwner = databaseData(*args.database);
    if (!databaseOwner->checkOpen(lexicalGlobalObject, scope))
        return;
    sqlite3* db = databaseOwner->db;

    if (!args.sql) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "Expected SQL string"_s));
        return;
    }
    if (!*args.sql) [[unlikely]] {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "Expected SQL string"_s));
        return;
    }
    const WTF::String& sqlString = **args.sql;
    if (sqlString.isEmpty()) [[unlikely]] {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "SQL string mustn't be blank"_s));
        return;
    }

    const Bun::Bindgen::SQLiteBindingsInput* bindingsInput = args.bindings ? &*args.bindings : nullptr;

    auto utf8 = sqliteUTF8(lexicalGlobalObject, sqlString, scope);
    if (!utf8)
        return;
    if (utf8->length() > static_cast<size_t>(std::numeric_limits<int>::max())) {
        throwRangeError(lexicalGlobalObject, scope, "SQL string is too large"_s);
        return;
    }

    const char* sqlStringHead = utf8->data();
    const char* end = utf8->data() + utf8->length();

    bool didSetBindings = false;
    bool didExecuteAny = false;

    int32_t internalFlags = args.internalFlags->value_or(0);
    bool strict = (internalFlags & kStrictFlag) != 0;
    bool safeIntegers = (internalFlags & kSafeIntegersFlag) != 0;

    int total_changes_before = 0;
    std::optional<SQLiteDatabaseOperation> operation(std::in_place, *databaseOwner);

    while (sqlStringHead && sqlStringHead < end) {
        while (sqlStringHead < end && isSkippedInSQLiteQuery(*sqlStringHead))
            ++sqlStringHead;
        if (sqlStringHead == end || !*sqlStringHead)
            break;

        AutoDestructingSQLiteStatement sql;
        const char* tail = nullptr;

        int rc = sqlite3_prepare_v3(db, sqlStringHead, static_cast<int>(end - sqlStringHead), 0, &sql.stmt, &tail);
        if (rc != SQLITE_OK) {
            throwException(lexicalGlobalObject, scope, createSQLiteError(lexicalGlobalObject, db));
            return;
        }

        if (!sql.stmt) {
            // this happens for an empty statement
            sqlStringHead = tail;
            continue;
        }

        // First statement gets the bindings.
        if (!didSetBindings && bindingsInput && !bindingsInput->is_undefined_value() && !bindingsInput->is_null_value()) {
            if (bindingsInput->is_object()) {
                SQLiteBindingSnapshot bindings;
                operation.reset();
                bool captured = bindings.capture(lexicalGlobalObject, uncheckedDowncast<JSObject>(bindingsInput->object()), sql.stmt, scope, strict, safeIntegers);
                bool usable = captured && databaseOwner->checkOpen(lexicalGlobalObject, scope);
                operation.emplace(*databaseOwner);
                if (!usable)
                    return;
                if (!bindings.bind(lexicalGlobalObject, db, sql.stmt, scope))
                    return;
            } else {
                throwException(lexicalGlobalObject, scope, createTypeError(lexicalGlobalObject, "Expected bindings to be an object or array"_s));
                return;
            }
            didSetBindings = true;
        }

        if (!didExecuteAny)
            total_changes_before = sqlite3_total_changes(db);
        do {
            rc = sqlite3_step(sql.stmt);
        } while (rc == SQLITE_ROW);
        if (rc != SQLITE_DONE) {
            throwException(lexicalGlobalObject, scope, createSQLiteError(lexicalGlobalObject, db));
            return;
        }

        didExecuteAny = true;
        sqlStringHead = tail;
    }

    if (!didExecuteAny) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "Query contained no valid SQL statement; likely empty query."_s));
        return;
    }

    auto* diff = args.diff && *args.diff ? dynamicDowncast<JSC::InternalFieldTuple>(**args.diff) : nullptr;
    RELEASE_ASSERT(!args.diff || !*args.diff || diff);
    if (diff) {
        const int total_changes_after = sqlite3_total_changes(db);
        int64_t last_insert_rowid = sqlite3_last_insert_rowid(db);
        diff->putInternalField(vm, 0, JSC::jsNumber(total_changes_after - total_changes_before));
        if (safeIntegers) {
            auto* bigInt = JSBigInt::createFrom(lexicalGlobalObject, last_insert_rowid);
            if (scope.exception())
                return;
            diff->putInternalField(vm, 1, bigInt);
        } else {
            diff->putInternalField(vm, 1, JSC::jsNumber(last_insert_rowid));
        }
    }

    scope.release();
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteStatementHost_jsSQLStatementIsInTransactionFunction(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteStatementHost_jsSQLStatementIsInTransactionFunction_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* database = databaseData(args.database);
    if (!database->checkOpen(lexicalGlobalObject, scope))
        return false;
    SQLiteDatabaseOperation operation(*database);

    scope.release();
    return !sqlite3_get_autocommit(database->db);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteStatementHost_jsSQLStatementPrepareStatementFunction(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteStatementHost_jsSQLStatementPrepareStatementFunction_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.sql) {
        throwException(lexicalGlobalObject, scope, createTypeError(lexicalGlobalObject, "Expected SQL string"_s));
        return {};
    }

    auto* databaseOwner = databaseData(args.database);
    if (!databaseOwner->checkOpen(lexicalGlobalObject, scope))
        return {};
    sqlite3* db = databaseOwner->db;

    const WTF::String& sqlString = *args.sql;
    if (sqlString.isEmpty()) {
        throwException(lexicalGlobalObject, scope, createRangeError(lexicalGlobalObject, "Invalid SQL statement"_s));
        return {};
    }
    auto utf8 = sqliteUTF8(lexicalGlobalObject, sqlString, scope);
    if (!utf8)
        return {};
    if (utf8->length() > static_cast<size_t>(std::numeric_limits<int>::max())) {
        throwRangeError(lexicalGlobalObject, scope, "SQL string is too large"_s);
        return {};
    }

    unsigned int flags = DEFAULT_SQLITE_PREPARE_FLAGS;
    if (args.prepareFlags.is_number()) {
        int prepareFlags = args.prepareFlags.number();
        if (prepareFlags < 0 || prepareFlags > MAX_SQLITE_PREPARE_FLAG) {
            throwException(lexicalGlobalObject, scope, createRangeError(lexicalGlobalObject, "Invalid prepare flags"_s));
            return {};
        }
        flags = static_cast<unsigned int>(prepareFlags);
    }

    std::optional<SQLiteDatabaseOperation> operation(std::in_place, *databaseOwner);
    AutoDestructingSQLiteStatement statement;
    int64_t currentMemoryUsage = sqlite_malloc_amount;

    int rc = sqlite3_prepare_v3(db, utf8->data(), static_cast<int>(utf8->length()), flags, &statement.stmt, nullptr);

    if (rc != SQLITE_OK) {
        throwException(lexicalGlobalObject, scope, createSQLiteError(lexicalGlobalObject, db));
        return {};
    }
    if (!statement.stmt) {
        throwRangeError(lexicalGlobalObject, scope, "Invalid SQL statement"_s);
        return {};
    }

    int32_t internalFlags = args.internalFlags.value_or(0);
    bool strict = (internalFlags & kStrictFlag) != 0;
    bool safeIntegers = (internalFlags & kSafeIntegersFlag) != 0;
    if (args.bindings.is_object()) {
        SQLiteBindingSnapshot bindings;
        operation.reset();
        bool captured = bindings.capture(lexicalGlobalObject, uncheckedDowncast<JSObject>(args.bindings.object()), statement.stmt, scope, strict, safeIntegers);
        bool usable = captured && databaseOwner->checkOpen(lexicalGlobalObject, scope);
        operation.emplace(*databaseOwner);
        if (!usable)
            return {};
        if (!bindings.bind(lexicalGlobalObject, db, statement.stmt, scope))
            return {};
    }

    int64_t memoryChange = sqlite_malloc_amount - currentMemoryUsage;

    auto* sqlStatement = new (std::nothrow) SQLiteStatementData(statement.stmt, *databaseOwner, memoryChange);
    if (!sqlStatement) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }
    statement.stmt = nullptr;

    sqlStatement->strictBindings = strict;
    sqlStatement->useBigInt64 = safeIntegers;
    RELEASE_AND_RETURN(scope, Bun::Bindgen::ZigExports::bunBindgenZig_SQLiteNative_adoptStatement(lexicalGlobalObject, sqlStatement, sizeof(SQLiteStatementData) + sqlStatement->extraMemorySize));
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteStatementHost_jsSQLStatementOpenStatementFunction(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteStatementHost_jsSQLStatementOpenStatementFunction_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.path) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "Expected 1 argument"_s));
        return {};
    }

    if (!*args.path) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "Expected string"_s));
        return {};
    }

    if (!initializeSQLite(lexicalGlobalObject, scope))
        return {};

    const String& path = **args.path;
    int openFlags = DEFAULT_SQLITE_FLAGS;
    if (args.flags) {
        if (!args.flags->is_number()) {
            throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "Expected number"_s));
            return {};
        }

        openFlags = args.flags->number();
    }

    auto identifier = nextDatabaseIdentifier(lexicalGlobalObject, scope);
    if (!identifier)
        return {};

    auto pathUTF8 = sqliteUTF8(lexicalGlobalObject, path, scope, true);
    if (!pathUTF8)
        return {};
    sqlite3* db = nullptr;
    auto closeDatabaseOnFailure = WTF::makeScopeExit([&] {
        if (db) sqlite3_close_v2(db);
    });
    int statusCode = sqlite3_open_v2(pathUTF8->data(), &db, openFlags, nullptr);

    if (statusCode != SQLITE_OK) {
        if (statusCode == SQLITE_NOMEM)
            throwOutOfMemoryError(lexicalGlobalObject, scope);
        else
            throwException(lexicalGlobalObject, scope, createSQLiteError(lexicalGlobalObject, db));
        return {};
    }

    sqlite3_extended_result_codes(db, 1);

    int status = sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, 1, NULL);
    if (status != SQLITE_OK) {
        // TODO: log a warning here that extensions are unsupported.
    }

    status = sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, 1, NULL);
    if (status != SQLITE_OK) {
        // TODO: log a warning here that defensive mode is unsupported.
    }
    closeDatabaseOnFailure.release();
    JSValue result = adoptDatabase(lexicalGlobalObject, db, *identifier, scope);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteStatementHost_jsSQLStatementCloseStatementFunction(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteStatementHost_jsSQLStatementCloseStatementFunction_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;

    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    bool shouldThrowOnError = args.throwOnError;
    auto* data = databaseData(args.database);
    sqlite3* db = data->db;
    // no-op if already closed
    if (!db) {
        return;
    }
    if (!data->checkIdle(lexicalGlobalObject, scope))
        return;
    SQLiteDatabaseOperation operation(*data);

    int statusCode = shouldThrowOnError ? sqlite3_close(db) : sqlite3_close_v2(db);
    if (statusCode != SQLITE_OK) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, WTF::String::fromUTF8(sqlite3_errstr(statusCode))));
        return;
    }

    data->db = nullptr;
    scope.release();
}

Bun::Bindgen::SQLiteFileControlResult Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteControl_int32(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteControl_int32_Arguments& args)
{
    return WebCore::sqliteControlInt32(context, args);
}

Bun::Bindgen::SQLiteFileControlResult Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteControl_int64(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteControl_int64_Arguments& args)
{
    return WebCore::sqliteControlInt64(context, args);
}

Bun::Bindgen::SQLiteFileControlResult Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteControl_retry(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteControl_retry_Arguments& args)
{
    return WebCore::sqliteControlRetry(context, args);
}

Bun::Bindgen::SQLiteFileControlResult Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteControl_string(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteControl_string_Arguments& args)
{
    return WebCore::sqliteControlText(context, args);
}

Bun::Bindgen::SQLiteFileControlResult Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteControl_pragma(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteControl_pragma_Arguments& args)
{
    return WebCore::sqliteControlPragma(context, args);
}

Bun::Bindgen::SQLiteFileControlResult Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteControl_query(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteControl_query_Arguments& args)
{
    return WebCore::sqliteControlQuery(context, args);
}

Bun::Bindgen::SQLiteFileControlResult Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteControl_notify(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteControl_notify_Arguments& args)
{
    return WebCore::sqliteControlNotify(context, args);
}

std::optional<Bun::Bindgen::CppAny> Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_ControlHandle_method_withUnsafePointer(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_ControlHandle_method_withUnsafePointer_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* data = Bun::Bindgen::ZigExports::bunBindgenZig_SQLiteNative_controlHandleData(globalObject, args.bindingThis);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    RELEASE_ASSERT(data);
    if (!data->database->checkOpen(globalObject, scope))
        return std::nullopt;
    WebCore::SQLiteDatabaseOperation operation(data->database.get());
    void* pointer = nullptr;
    int status = data->resolve(pointer);
    if ((status & 0xff) == SQLITE_NOMEM) {
        JSC::throwOutOfMemoryError(globalObject, scope);
        return std::nullopt;
    }
    if (status != SQLITE_OK || !pointer) {
        auto message = tryMakeString("SQLite native resource is unavailable (status "_s, status, ")"_s);
        if (message.isNull()) {
            JSC::throwOutOfMemoryError(globalObject, scope);
            return std::nullopt;
        }
        JSC::throwException(globalObject, scope, JSC::createError(globalObject, message));
        return std::nullopt;
    }
    auto result = Bun::Bindgen::ZigExports::bunBindgenZig_SQLiteNative_invokePointerCallback(globalObject, args.callback, static_cast<uint64_t>(reinterpret_cast<uintptr_t>(pointer)));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return result;
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_method_as(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_method_as_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);
    if (scope.exception())
        return;
    RELEASE_ASSERT(castedThis);

    if (!castedThis->checkOpen(lexicalGlobalObject, scope))
        return;
    JSObject* newPrototype = nullptr;
    if (!args.prototype.is_undefined_value()) {
        if (!args.prototype.is_object()) {
            JSC::throwTypeError(lexicalGlobalObject, scope, "Expected class to be a constructor or undefined"_s);
            return;
        }

        JSC::JSValue value = args.prototype.object();
        if (value != lexicalGlobalObject->objectConstructor()) {
            auto* constructor = value.getObject();
            RELEASE_ASSERT(constructor);
            if (!constructor->isConstructor()) {
                JSC::throwTypeError(lexicalGlobalObject, scope, "Expected a constructor"_s);
                return;
            }

            JSC::JSValue prototype = constructor->getIfPropertyExists(lexicalGlobalObject, vm.propertyNames->prototype);
            RETURN_IF_EXCEPTION(scope, void());
            if (!prototype) {
                JSC::throwTypeError(lexicalGlobalObject, scope, "Expected constructor to have a prototype"_s);
                return;
            }
            if (!prototype.isObject()) {
                JSC::throwTypeError(lexicalGlobalObject, scope, "Expected a constructor prototype to be an object"_s);
                return;
            }
            newPrototype = JSC::asObject(prototype);
        }
    }

    if (!castedThis->checkOpen(lexicalGlobalObject, scope))
        return;
    RELEASE_AND_RETURN(scope, Bun::Bindgen::ZigExports::bunBindgenZig_SQLiteNative_setPrototype(lexicalGlobalObject, args.bindingThis, newPrototype ? std::optional<JSValue>(newPrototype) : std::nullopt));
}

Bun::Bindgen::SQLiteStatementObjectOrNullResult Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_method_iterate(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_method_iterate_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);

    CHECK_THIS

    auto operation = castedThis->startExecution(lexicalGlobalObject, args.bindings ? &*args.bindings : nullptr, true);
    RETURN_IF_EXCEPTION(scope, {});
    if (!operation)
        return {};
    auto* stmt = castedThis->stmt;

    auto initialStatus = castedThis->step(lexicalGlobalObject, scope);
    if (!initialStatus)
        return {};
    int status = *initialStatus;

    if (!castedThis->columnsLoaded) {
        initializeColumnNames(lexicalGlobalObject, castedThis);
        RETURN_IF_EXCEPTION(scope, {});
    }

    Bun::Bindgen::SQLiteStatementObjectOrNullResult result;
    if (status == SQLITE_ROW) {
        bool useBigInt64 = castedThis->useBigInt64;

        JSValue object = useBigInt64 ? constructResultObject<true>(lexicalGlobalObject, castedThis, args.bindingThis)
                                     : constructResultObject<false>(lexicalGlobalObject, castedThis, args.bindingThis);
        RETURN_IF_EXCEPTION(scope, {});
        result.set_object(object);
    } else {
        result.set_null_value(true);
    }

    if (status == SQLITE_DONE || status == SQLITE_OK || status == SQLITE_ROW) {
        RELEASE_AND_RETURN(scope, result);
    } else {
        throwException(lexicalGlobalObject, scope, createSQLiteError(lexicalGlobalObject, castedThis->database->db));
        sqlite3_reset(stmt);
        return {};
    }
}

Bun::Bindgen::SQLiteStatementArrayOrNumberOrUndefinedResult Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_method_all(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_method_all_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);

    CHECK_THIS

    auto operation = castedThis->startExecution(lexicalGlobalObject, args.bindings ? &*args.bindings : nullptr);
    RETURN_IF_EXCEPTION(scope, {});
    if (!operation)
        return {};
    auto* stmt = castedThis->stmt;
    int64_t currentMemoryUsage = sqlite_malloc_amount;

    auto initialStatus = castedThis->step(lexicalGlobalObject, scope);
    if (!initialStatus)
        return {};
    int status = *initialStatus;

    if (!castedThis->columnsLoaded) {
        initializeColumnNames(lexicalGlobalObject, castedThis);
        RETURN_IF_EXCEPTION(scope, {});
    }

    size_t columnCount = castedThis->columns.size();
    Bun::Bindgen::SQLiteStatementArrayOrNumberOrUndefinedResult result;
    if (status == SQLITE_ROW) {
        // this is a count from UPDATE or another query like that
        if (columnCount == 0) {
            result.set_number(sqlite3_changes(castedThis->database->db));

            while (status == SQLITE_ROW) {
                status = sqlite3_step(stmt);
            }
        } else {
            bool useBigInt64 = castedThis->useBigInt64;
            JSC::JSArray* resultArray = JSC::constructEmptyArray(lexicalGlobalObject, static_cast<ArrayAllocationProfile*>(nullptr), 0);
            RETURN_IF_EXCEPTION(scope, {});
            if (useBigInt64) {
                do {
                    JSC::JSValue result = constructResultObject<true>(lexicalGlobalObject, castedThis, args.bindingThis);
                    RETURN_IF_EXCEPTION(scope, {});
                    resultArray->putDirectIndex(lexicalGlobalObject, resultArray->length(), result);
                    RETURN_IF_EXCEPTION(scope, {});
                    status = sqlite3_step(stmt);
                } while (status == SQLITE_ROW);
            } else {
                do {
                    JSC::JSValue result = constructResultObject<false>(lexicalGlobalObject, castedThis, args.bindingThis);
                    RETURN_IF_EXCEPTION(scope, {});
                    resultArray->putDirectIndex(lexicalGlobalObject, resultArray->length(), result);
                    RETURN_IF_EXCEPTION(scope, {});
                    status = sqlite3_step(stmt);
                } while (status == SQLITE_ROW);
            }
            result.set_array(resultArray);
        }
    } else if (status == SQLITE_DONE) {
        auto* resultArray = JSC::constructEmptyArray(lexicalGlobalObject, static_cast<ArrayAllocationProfile*>(nullptr), 0);
        RETURN_IF_EXCEPTION(scope, {});
        result.set_array(resultArray);
    } else {
        result.set_undefined_value(true);
    }

    if (status != SQLITE_DONE && status != SQLITE_OK) [[unlikely]] {
        throwException(lexicalGlobalObject, scope, createSQLiteError(lexicalGlobalObject, castedThis->database->db));
        sqlite3_reset(stmt);
        return {};
    }

    int64_t memoryChange = sqlite_malloc_amount - currentMemoryUsage;
    if (memoryChange > 255) {
        vm.heap.deprecatedReportExtraMemory(memoryChange);
    }

    RELEASE_AND_RETURN(scope, result);
}

Bun::Bindgen::SQLiteStatementObjectOrNullResult Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_method_get(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_method_get_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;

    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);

    CHECK_THIS

    auto operation = castedThis->startExecution(lexicalGlobalObject, args.bindings ? &*args.bindings : nullptr);
    RETURN_IF_EXCEPTION(scope, {});
    if (!operation)
        return {};
    auto* stmt = castedThis->stmt;

    auto initialStatus = castedThis->step(lexicalGlobalObject, scope);
    if (!initialStatus)
        return {};
    int status = *initialStatus;

    if (!castedThis->columnsLoaded) {
        initializeColumnNames(lexicalGlobalObject, castedThis);
        RETURN_IF_EXCEPTION(scope, {});
    }

    Bun::Bindgen::SQLiteStatementObjectOrNullResult result;
    if (status == SQLITE_ROW) {
        bool useBigInt64 = castedThis->useBigInt64;

        JSValue object = useBigInt64 ? constructResultObject<true>(lexicalGlobalObject, castedThis, args.bindingThis)
                                     : constructResultObject<false>(lexicalGlobalObject, castedThis, args.bindingThis);
        RETURN_IF_EXCEPTION(scope, {});
        result.set_object(object);
        while (status == SQLITE_ROW) {
            status = sqlite3_step(stmt);
        }
    } else {
        result.set_null_value(true);
    }

    if (status == SQLITE_DONE || status == SQLITE_OK) {
        RELEASE_AND_RETURN(scope, result);
    } else {
        throwException(lexicalGlobalObject, scope, createSQLiteError(lexicalGlobalObject, castedThis->database->db));
        sqlite3_reset(stmt);
        return {};
    }
}

template<bool raw, typename Arguments>
static Bun::Bindgen::SQLiteStatementArrayOrNumberOrNullResult statementValues(
    Bun::Bindgen::CppCallContext& context,
    const Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;

    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);

    CHECK_THIS;

    auto operation = castedThis->startExecution(lexicalGlobalObject, args.bindings ? &*args.bindings : nullptr);
    RETURN_IF_EXCEPTION(scope, {});
    if (!operation)
        return {};
    auto* stmt = castedThis->stmt;

    auto initialStatus = castedThis->step(lexicalGlobalObject, scope);
    if (!initialStatus)
        return {};
    int status = *initialStatus;

    if (!castedThis->columnsLoaded) {
        initializeColumnNames(lexicalGlobalObject, castedThis);

        if (scope.exception()) [[unlikely]] {
            sqlite3_reset(stmt);
            RELEASE_AND_RETURN(scope, {});
        }
    }

    size_t columnCount = castedThis->columns.size();
    Bun::Bindgen::SQLiteStatementArrayOrNumberOrNullResult result;
    result.set_null_value(true);
    if (status == SQLITE_ROW) {
        // this is a count from UPDATE or another query like that
        if (columnCount == 0) {
            while (status == SQLITE_ROW) {
                status = sqlite3_step(stmt);
            }

            result.set_number(sqlite3_column_count(stmt));
        } else {
            JSC::JSArray* resultArray = JSC::constructEmptyArray(lexicalGlobalObject, static_cast<ArrayAllocationProfile*>(nullptr), 0);
            RETURN_IF_EXCEPTION(scope, {});
            size_t rowColumnCount = sqlite3_column_count(stmt);
            do {
                JSC::JSArray* row = constructResultRow<raw>(vm, lexicalGlobalObject, castedThis, rowColumnCount);
                if (!row || scope.exception()) [[unlikely]] {
                    sqlite3_reset(stmt);
                    RELEASE_AND_RETURN(scope, {});
                }
                resultArray->putDirectIndex(lexicalGlobalObject, resultArray->length(), row);
                if (scope.exception()) [[unlikely]] {
                    sqlite3_reset(stmt);
                    RELEASE_AND_RETURN(scope, {});
                }
                status = sqlite3_step(stmt);
            } while (status == SQLITE_ROW);

            result.set_array(resultArray);
        }
    } else if (status == SQLITE_DONE && columnCount != 0) {
        auto* resultArray = JSC::constructEmptyArray(lexicalGlobalObject, static_cast<ArrayAllocationProfile*>(nullptr), 0);
        RETURN_IF_EXCEPTION(scope, {});
        result.set_array(resultArray);
    }

    if (status != SQLITE_DONE && status != SQLITE_OK) [[unlikely]] {
        throwException(lexicalGlobalObject, scope, createSQLiteError(lexicalGlobalObject, castedThis->database->db));
        sqlite3_reset(stmt);
        return {};
    }

    RELEASE_AND_RETURN(scope, result);
}

Bun::Bindgen::SQLiteStatementArrayOrNumberOrNullResult Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_method_values(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_method_values_Arguments& args)
{
    return statementValues<false>(context, args);
}

Bun::Bindgen::SQLiteStatementArrayOrNumberOrNullResult Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_method_raw(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_method_raw_Arguments& args)
{
    return statementValues<true>(context, args);
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_method_run(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_method_run_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;

    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);
    if (scope.exception())
        return;
    RELEASE_ASSERT(castedThis);

    auto operation = castedThis->startExecution(lexicalGlobalObject, args.bindings ? &*args.bindings : nullptr);
    RETURN_IF_EXCEPTION(scope, );
    if (!operation)
        return;
    auto* stmt = castedThis->stmt;

    int total_changes_before = sqlite3_total_changes(castedThis->database->db);

    auto initialStatus = castedThis->step(lexicalGlobalObject, scope);
    if (!initialStatus)
        return;
    int status = *initialStatus;

    if (!castedThis->columnsLoaded) {
        initializeColumnNames(lexicalGlobalObject, castedThis);
        if (scope.exception()) [[unlikely]] {
            sqlite3_reset(stmt);
            scope.release();
            return;
        }
    }

    while (status == SQLITE_ROW) {
        status = sqlite3_step(stmt);
    }

    if (status != SQLITE_DONE && status != SQLITE_OK) [[unlikely]] {
        throwException(lexicalGlobalObject, scope, createSQLiteError(lexicalGlobalObject, castedThis->database->db));
        sqlite3_reset(stmt);
        return;
    }

    if (args.diff) {
        auto* diff = dynamicDowncast<JSC::InternalFieldTuple>(*args.diff);
        RELEASE_ASSERT(diff);
        auto* db = castedThis->database->db;
        const int total_changes_after = sqlite3_total_changes(db);
        int64_t last_insert_rowid = sqlite3_last_insert_rowid(db);
        diff->putInternalField(vm, 0, JSC::jsNumber(total_changes_after - total_changes_before));
        if (castedThis->useBigInt64) {
            JSValue lastRowIdBigInt = JSBigInt::createFrom(lexicalGlobalObject, last_insert_rowid);
            if (scope.exception())
                return;
            diff->putInternalField(vm, 1, lastRowIdBigInt);
        } else {
            diff->putInternalField(vm, 1, JSC::jsNumber(last_insert_rowid));
        }
    }

    scope.release();
}

WTF::String Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_method_toString(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_method_toString_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);
    CHECK_THIS

    if (!castedThis->stmt) {
        scope.release();
        return emptyString();
    }
    CHECK_PREPARED
    char* string = sqlite3_expanded_sql(castedThis->stmt);
    if (!string) {
        if ((sqlite3_extended_errcode(castedThis->database->db) & 0xff) == SQLITE_NOMEM) {
            throwOutOfMemoryError(lexicalGlobalObject, scope);
            return {};
        }
        scope.release();
        return emptyString();
    }
    auto freeString = WTF::makeScopeExit([&] { sqlite3_free(string); });
    size_t length = strlen(string);
    WTF::String result = WTF::String::fromUTF8ReplacingInvalidSequences(std::span<const char8_t> { reinterpret_cast<const char8_t*>(string), length });
    if (result.isNull()) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }
    scope.release();
    return result;
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_method_finalize(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_method_finalize_Arguments& args)
{
    using namespace WebCore;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);
    if (scope.exception())
        return;
    RELEASE_ASSERT(castedThis);
    if (castedThis->database) {
        if (!castedThis->database->checkIdle(lexicalGlobalObject, scope))
            return;
        SQLiteDatabaseOperation operation(*castedThis->database);
        castedThis->finalize();
    }
    RELEASE_AND_RETURN(scope, Bun::Bindgen::ZigExports::bunBindgenZig_SQLiteNative_setPrototype(lexicalGlobalObject, args.bindingThis, std::nullopt));
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_getter_isFinalized(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_getter_isFinalized_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* data = WebCore::sqlStatement(globalObject, args.bindingThis);
    RETURN_IF_EXCEPTION(scope, false);
    RELEASE_ASSERT(data);
    return !data->stmt;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_getter_columns(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_getter_columns_Arguments& args)
{
    using namespace WebCore;
    JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);
    CHECK_THIS

    CHECK_PREPARED
    if (!castedThis->columnsLoaded) {
        initializeColumnNames(lexicalGlobalObject, castedThis);
        RETURN_IF_EXCEPTION(scope, {});
    }
    auto* array = JSC::constructEmptyArray(lexicalGlobalObject, static_cast<ArrayAllocationProfile*>(nullptr), castedThis->columns.size());
    RETURN_IF_EXCEPTION(scope, {});
    unsigned index = 0;
    for (const auto& column : castedThis->columns) {
        auto* string = jsString(vm, column.name.string());
        RETURN_IF_EXCEPTION(scope, {});
        array->putDirectIndex(lexicalGlobalObject, index++, string);
        RETURN_IF_EXCEPTION(scope, {});
    }
    return array;
}

int32_t Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_getter_columnsCount(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_getter_columnsCount_Arguments& args)
{
    using namespace WebCore;
    JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);
    CHECK_THIS
    CHECK_PREPARED

    scope.release();
    return sqlite3_column_count(castedThis->stmt);
}

int32_t Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_getter_paramsCount(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_getter_paramsCount_Arguments& args)
{
    using namespace WebCore;
    JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);
    CHECK_THIS
    CHECK_PREPARED

    scope.release();
    return sqlite3_bind_parameter_count(castedThis->stmt);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_getter_columnTypes(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_getter_columnTypes_Arguments& args)
{
    using namespace WebCore;
    JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);
    CHECK_THIS
    CHECK_PREPARED

    if (!sqlite3_stmt_readonly(castedThis->stmt)) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "columnTypes is not available for non-read-only statements (INSERT, UPDATE, DELETE, etc.)"_s));
        return {};
    }

    int resetStatus = sqlite3_reset(castedThis->stmt);
    castedThis->columnsLoaded = false;
    if (resetStatus != SQLITE_OK) {
        throwException(lexicalGlobalObject, scope, createSQLiteError(lexicalGlobalObject, castedThis->database->db));
        return {};
    }

    auto resetStatement = WTF::makeScopeExit([&] { sqlite3_reset(castedThis->stmt); });
    auto stepStatus = castedThis->step(lexicalGlobalObject, scope, SQLiteStatementData::StepPurpose::InspectColumnTypes);
    if (!stepStatus)
        return {};

    int count = sqlite3_column_count(castedThis->stmt);
    auto* array = JSC::constructEmptyArray(lexicalGlobalObject, static_cast<ArrayAllocationProfile*>(nullptr), count);
    RETURN_IF_EXCEPTION(scope, {});
    for (int i = 0; i < count; ++i) {
        int columnType = *stepStatus == SQLITE_ROW ? sqlite3_column_type(castedThis->stmt, i) : SQLITE_NULL;
        JSValue typeValue;
        switch (columnType) {
        case SQLITE_INTEGER:
            typeValue = jsString(vm, String("INTEGER"_s));
            break;
        case SQLITE_FLOAT:
            typeValue = jsString(vm, String("FLOAT"_s));
            break;
        case SQLITE3_TEXT:
            typeValue = jsString(vm, String("TEXT"_s));
            break;
        case SQLITE_BLOB:
            typeValue = jsString(vm, String("BLOB"_s));
            break;
        case SQLITE_NULL:
            typeValue = jsString(vm, String("NULL"_s));
            break;
        default:
            RELEASE_ASSERT_NOT_REACHED();
        }
        RETURN_IF_EXCEPTION(scope, {});
        array->putDirectIndex(lexicalGlobalObject, i, typeValue);
        RETURN_IF_EXCEPTION(scope, {});
    }

    RELEASE_AND_RETURN(scope, array);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_getter_declaredTypes(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_getter_declaredTypes_Arguments& args)
{
    using namespace WebCore;
    JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);
    CHECK_THIS
    CHECK_PREPARED

    // Ensure the statement has been executed at least once
    if (!castedThis->hasExecuted) {
        throwException(lexicalGlobalObject, scope, createError(lexicalGlobalObject, "Statement must be executed before accessing declaredTypes"_s));
        return {};
    }

    int count = sqlite3_column_count(castedThis->stmt);
    JSC::JSArray* array = JSC::constructEmptyArray(lexicalGlobalObject, static_cast<ArrayAllocationProfile*>(nullptr), count);
    RETURN_IF_EXCEPTION(scope, {});

    // Use declared types only - return raw strings as-is, null when no declared type
    for (int i = 0; i < count; i++) {
        const char* declType = sqlite3_column_decltype(castedThis->stmt, i);
        JSC::JSValue typeValue;

        if (declType != nullptr) {
            String typeStr = String::fromUTF8ReplacingInvalidSequences(std::span<const char8_t> { reinterpret_cast<const char8_t*>(declType), strlen(declType) });
            if (typeStr.isNull()) {
                throwOutOfMemoryError(lexicalGlobalObject, scope);
                return {};
            }
            typeValue = JSC::jsString(vm, WTF::move(typeStr));
            RETURN_IF_EXCEPTION(scope, {});
        } else {
            if ((sqlite3_extended_errcode(castedThis->database->db) & 0xff) == SQLITE_NOMEM) {
                throwOutOfMemoryError(lexicalGlobalObject, scope);
                return {};
            }
            typeValue = JSC::jsNull();
        }

        array->putDirectIndex(lexicalGlobalObject, i, typeValue);
        RETURN_IF_EXCEPTION(scope, {});
    }

    RELEASE_AND_RETURN(scope, array);
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_getter_safeIntegers(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_getter_safeIntegers_Arguments& args)
{
    using namespace WebCore;
    JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);
    CHECK_THIS
    CHECK_PREPARED

    scope.release();
    return castedThis->useBigInt64;
}

void Bun::Bindgen::Cpp::bunBindgenCpp_SQLiteNative_Statement_setter_safeIntegers(
    CppCallContext& context,
    const BunBindgenCpp_SQLiteNative_Statement_setter_safeIntegers_Arguments& args)
{
    using namespace WebCore;
    JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = sqlStatement(lexicalGlobalObject, args.bindingThis);
    if (scope.exception())
        return;
    RELEASE_ASSERT(castedThis);
    if (!castedThis->checkOpen(lexicalGlobalObject, scope))
        return;

    castedThis->useBigInt64 = args.value;

    scope.release();
}
