#pragma once

#include "root.h"
#include "sqlite3_local.h"
#include <cstring>
#include <mutex>
#include <span>
#include <wtf/NeverDestroyed.h>
#include <wtf/Scope.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

#if OS(WINDOWS)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#define FOR_EACH_SQLITE_LIBRARY_FUNCTION(M) \
    M(bind_blob)                          \
    M(bind_double)                        \
    M(bind_int64)                         \
    M(bind_null)                          \
    M(bind_parameter_count)               \
    M(bind_parameter_name)                \
    M(bind_text)                          \
    M(bind_text16)                        \
    M(changes)                            \
    M(clear_bindings)                     \
    M(close)                              \
    M(close_v2)                           \
    M(column_blob)                        \
    M(column_bytes)                       \
    M(column_count)                       \
    M(column_decltype)                    \
    M(column_double)                      \
    M(column_int64)                       \
    M(column_name)                        \
    M(column_text)                        \
    M(column_type)                        \
    M(compileoption_used)                 \
    M(db_config)                          \
    M(errmsg)                             \
    M(errstr)                             \
    M(expanded_sql)                       \
    M(extended_errcode)                    \
    M(extended_result_codes)              \
    M(file_control)                       \
    M(finalize)                           \
    M(free)                               \
    M(get_autocommit)                     \
    M(last_insert_rowid)                   \
    M(malloc64)                           \
    M(open_v2)                            \
    M(prepare_v3)                         \
    M(reset)                              \
    M(step)                               \
    M(stmt_busy)                          \
    M(stmt_readonly)                      \
    M(total_changes)

struct SQLiteLibraryAPI {
#define DECLARE_SQLITE_FUNCTION(name) decltype(&::sqlite3_##name) name { nullptr };
    FOR_EACH_SQLITE_LIBRARY_FUNCTION(DECLARE_SQLITE_FUNCTION)
#undef DECLARE_SQLITE_FUNCTION
    decltype(&::sqlite3_deserialize) deserialize { nullptr };
    decltype(&::sqlite3_error_offset) error_offset { nullptr };
    decltype(&::sqlite3_load_extension) load_extension { nullptr };
    decltype(&::sqlite3_serialize) serialize { nullptr };
};

struct SQLiteLibraryState {
    std::recursive_mutex mutex;
    SQLiteLibraryAPI api;
#if OS(WINDOWS)
    HMODULE handle { nullptr };
#else
    void* handle { nullptr };
#endif
    bool loading { false };
};

static SQLiteLibraryState& sqliteLibraryState()
{
    // Owned buffers and connections can need SQLite after their originating VM exits.
    static WTF::NeverDestroyed<SQLiteLibraryState> state;
    return state.get();
}

struct SQLiteLibraryLoadResult {
    enum class Status : uint8_t { loaded, alreadyLoaded, loading, loadFailed, missingSymbol, outOfMemory };
    Status status { Status::loaded };
    WTF::String message {};
    unsigned long systemError { 0 };
};

static SQLiteLibraryLoadResult lazyLoadSQLite(const char* customPath = nullptr)
{
    auto& state = sqliteLibraryState();
    std::lock_guard lock(state.mutex);
    if (state.handle)
        return { customPath ? SQLiteLibraryLoadResult::Status::alreadyLoaded : SQLiteLibraryLoadResult::Status::loaded };
    if (state.loading)
        return { SQLiteLibraryLoadResult::Status::loading };
    state.loading = true;
    auto finishLoading = WTF::makeScopeExit([&] { state.loading = false; });

#if OS(WINDOWS)
    const char* path = customPath ? customPath : "sqlite3.dll";
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, nullptr, 0);
    if (!length)
        return { SQLiteLibraryLoadResult::Status::loadFailed, {}, GetLastError() };
    WTF::Vector<wchar_t> widePath;
    if (!widePath.tryGrow(static_cast<size_t>(length)))
        return { SQLiteLibraryLoadResult::Status::outOfMemory };
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, widePath.data(), length))
        return { SQLiteLibraryLoadResult::Status::loadFailed, {}, GetLastError() };
    auto handle = LoadLibraryW(widePath.data());
#elif OS(DARWIN)
    auto handle = dlopen(customPath ? customPath : "libsqlite3.dylib", RTLD_NOW | RTLD_LOCAL);
#else
    auto handle = dlopen(customPath ? customPath : "libsqlite3.so.0", RTLD_NOW | RTLD_LOCAL);
#endif
    if (!handle) {
#if OS(WINDOWS)
        return { SQLiteLibraryLoadResult::Status::loadFailed, {}, GetLastError() };
#else
        const char* message = dlerror();
        if (!message)
            message = "Unable to load SQLite library";
        return { SQLiteLibraryLoadResult::Status::loadFailed, WTF::String::fromUTF8ReplacingInvalidSequences(std::span<const char8_t> { reinterpret_cast<const char8_t*>(message), strlen(message) }) };
#endif
    }
    auto closeOnFailure = WTF::makeScopeExit([&] {
#if OS(WINDOWS)
        FreeLibrary(handle);
#else
        dlclose(handle);
#endif
    });

    SQLiteLibraryAPI candidate;
#if OS(WINDOWS)
#define SQLITE_LIBRARY_SYMBOL(name) GetProcAddress(handle, "sqlite3_" #name)
#else
#define SQLITE_LIBRARY_SYMBOL(name) dlsym(handle, "sqlite3_" #name)
#endif
#define RESOLVE_SQLITE_FUNCTION(name)                                                                         \
    candidate.name = reinterpret_cast<decltype(candidate.name)>(SQLITE_LIBRARY_SYMBOL(name));                 \
    if (!candidate.name)                                                                                     \
        return { SQLiteLibraryLoadResult::Status::missingSymbol, WTF::String::fromUTF8("sqlite3_" #name) };
    FOR_EACH_SQLITE_LIBRARY_FUNCTION(RESOLVE_SQLITE_FUNCTION)
#undef RESOLVE_SQLITE_FUNCTION
    candidate.deserialize = reinterpret_cast<decltype(candidate.deserialize)>(SQLITE_LIBRARY_SYMBOL(deserialize));
    candidate.error_offset = reinterpret_cast<decltype(candidate.error_offset)>(SQLITE_LIBRARY_SYMBOL(error_offset));
    candidate.load_extension = reinterpret_cast<decltype(candidate.load_extension)>(SQLITE_LIBRARY_SYMBOL(load_extension));
    candidate.serialize = reinterpret_cast<decltype(candidate.serialize)>(SQLITE_LIBRARY_SYMBOL(serialize));
#undef SQLITE_LIBRARY_SYMBOL

    state.api = candidate;
    state.handle = handle;
    closeOnFailure.release();
    return {};
}

#undef FOR_EACH_SQLITE_LIBRARY_FUNCTION

static int sqliteErrorOffset(sqlite3* database)
{
    auto errorOffset = sqliteLibraryState().api.error_offset;
    return errorOffset ? errorOffset(database) : -1;
}

#define sqlite3_bind_blob sqliteLibraryState().api.bind_blob
#define sqlite3_bind_double sqliteLibraryState().api.bind_double
#define sqlite3_bind_int64 sqliteLibraryState().api.bind_int64
#define sqlite3_bind_null sqliteLibraryState().api.bind_null
#define sqlite3_bind_parameter_count sqliteLibraryState().api.bind_parameter_count
#define sqlite3_bind_parameter_name sqliteLibraryState().api.bind_parameter_name
#define sqlite3_bind_text sqliteLibraryState().api.bind_text
#define sqlite3_bind_text16 sqliteLibraryState().api.bind_text16
#define sqlite3_changes sqliteLibraryState().api.changes
#define sqlite3_clear_bindings sqliteLibraryState().api.clear_bindings
#define sqlite3_close sqliteLibraryState().api.close
#define sqlite3_close_v2 sqliteLibraryState().api.close_v2
#define sqlite3_column_blob sqliteLibraryState().api.column_blob
#define sqlite3_column_bytes sqliteLibraryState().api.column_bytes
#define sqlite3_column_count sqliteLibraryState().api.column_count
#define sqlite3_column_decltype sqliteLibraryState().api.column_decltype
#define sqlite3_column_double sqliteLibraryState().api.column_double
#define sqlite3_column_int64 sqliteLibraryState().api.column_int64
#define sqlite3_column_name sqliteLibraryState().api.column_name
#define sqlite3_column_text sqliteLibraryState().api.column_text
#define sqlite3_column_type sqliteLibraryState().api.column_type
#define sqlite3_compileoption_used sqliteLibraryState().api.compileoption_used
#define sqlite3_db_config sqliteLibraryState().api.db_config
#define sqlite3_deserialize sqliteLibraryState().api.deserialize
#define sqlite3_errmsg sqliteLibraryState().api.errmsg
#define sqlite3_error_offset sqliteErrorOffset
#define sqlite3_errstr sqliteLibraryState().api.errstr
#define sqlite3_expanded_sql sqliteLibraryState().api.expanded_sql
#define sqlite3_extended_errcode sqliteLibraryState().api.extended_errcode
#define sqlite3_extended_result_codes sqliteLibraryState().api.extended_result_codes
#define sqlite3_file_control sqliteLibraryState().api.file_control
#define sqlite3_finalize sqliteLibraryState().api.finalize
#define sqlite3_free sqliteLibraryState().api.free
#define sqlite3_get_autocommit sqliteLibraryState().api.get_autocommit
#define sqlite3_last_insert_rowid sqliteLibraryState().api.last_insert_rowid
#define sqlite3_load_extension sqliteLibraryState().api.load_extension
#define sqlite3_malloc64 sqliteLibraryState().api.malloc64
#define sqlite3_open_v2 sqliteLibraryState().api.open_v2
#define sqlite3_prepare_v3 sqliteLibraryState().api.prepare_v3
#define sqlite3_reset sqliteLibraryState().api.reset
#define sqlite3_serialize sqliteLibraryState().api.serialize
#define sqlite3_step sqliteLibraryState().api.step
#define sqlite3_stmt_busy sqliteLibraryState().api.stmt_busy
#define sqlite3_stmt_readonly sqliteLibraryState().api.stmt_readonly
#define sqlite3_total_changes sqliteLibraryState().api.total_changes
