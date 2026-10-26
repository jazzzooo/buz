#pragma once

#include "root.h"

#include "JavaScriptCore/JSCInlines.h"
#include "BunClientData.h"
#include <JavaScriptCore/JSInternalFieldObjectImpl.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/Strong.h>
#include <optional>

namespace Bun {
using namespace JSC;

class JSNextTickQueue : public JSC::JSInternalFieldObjectImpl<4> {
public:
    using Base = JSC::JSInternalFieldObjectImpl<4>;

    class PreparedTask {
        WTF_MAKE_NONCOPYABLE(PreparedTask);

    public:
        PreparedTask() = default;
        PreparedTask(PreparedTask&&) noexcept;
        void commit();

    private:
        friend class JSNextTickQueue;
        PreparedTask(VM&, JSNextTickQueue&, JSArray&);
        Strong<JSNextTickQueue> m_queue;
        Strong<JSArray> m_task;
        bool m_consumed { false };
    };

    template<typename, JSC::SubspaceAccess mode> static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm);

    JS_EXPORT_PRIVATE static JSNextTickQueue* create(VM&, Structure*);
    static JSNextTickQueue* create(JSC::JSGlobalObject* globalObject);
    static Structure* createStructure(VM&, JSGlobalObject*, JSValue);

    static std::array<JSValue, numberOfInternalFields> initialValues()
    {
        return { {
            jsNumber(0),
            jsNull(),
            jsUndefined(),
            jsNull(),
        } };
    }

    DECLARE_EXPORT_INFO;
    DECLARE_VISIT_CHILDREN;

    JSNextTickQueue(JSC::VM&, JSC::Structure*);
    void finishCreation(JSC::VM&);

    bool isEmpty();
    std::optional<PreparedTask> prepareTask(JSGlobalObject&, JSValue callback, JSArray* arguments, JSValue receiver = jsUndefined());
    JSArray* takeTask(VM&);
    void drain(JSC::VM& vm, JSC::JSGlobalObject* globalObject);

private:
    void appendTask(VM&, JSArray&);
};
}
