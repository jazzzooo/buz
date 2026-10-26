#pragma once

#include "MessageWithMessagePorts.h"
#include "Bindgen/NativeResult.h"
#include "ScriptExecutionContext.h"
#include <memory>
#include <wtf/FastMalloc.h>
#include <wtf/Lock.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/ThreadSafeWeakPtr.h>

namespace WebCore {

class MessagePortPipe;

class MessagePortContext final : public ThreadSafeRefCounted<MessagePortContext>, public ScriptExecutionContext::NativeLifetime {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(MessagePortContext);

public:
    static RefPtr<MessagePortContext> tryCreate(ScriptExecutionContext&);
    ~MessagePortContext();

    struct Registration {
        ThreadSafeWeakPtr<MessagePortPipe> pipe;
        uint8_t side { 0 };

    private:
        friend class MessagePortContext;
        MessagePortContext* owner { nullptr };
        Registration* previous { nullptr };
        Registration* next { nullptr };
    };

    void add(Registration&);
    void remove(Registration&);

private:
    void contextClosed() noexcept final;
    void removeLocked(Registration&) WTF_REQUIRES_LOCK(m_lock);
    WTF::Lock m_lock;
    Registration* m_head WTF_GUARDED_BY_LOCK(m_lock) { nullptr };
};

class MessagePortPipe final : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<MessagePortPipe> {
    struct MessageNode {
        WTF_DEPRECATED_MAKE_STRUCT_FAST_ALLOCATED(MessageNode);
        MessageNode* next { nullptr };
        MessageWithMessagePorts message;
    };

public:
    class PreparedSend {
        WTF_MAKE_NONCOPYABLE(PreparedSend);

    public:
        PreparedSend() = default;
        PreparedSend(PreparedSend&&) noexcept;
        ~PreparedSend();
        void commit(MessageWithMessagePorts&&);

    private:
        friend class MessagePortPipe;
        PreparedSend(Ref<MessagePortPipe>&&, uint8_t side, std::unique_ptr<MessageNode>&&);
        RefPtr<MessagePortPipe> m_pipe;
        std::unique_ptr<MessageNode> m_node;
        uint8_t m_side { 0 };
        bool m_consumed { false };
    };

    class Wakeup : public ThreadSafeRefCounted<Wakeup> {
    public:
        virtual ~Wakeup() = default;
        virtual void notify() const noexcept = 0;
    };

    static RefPtr<MessagePortPipe> tryCreate();
    ~MessagePortPipe();

    // Per-side state word layout. Low byte is flags; the queued-message count
    // lives in the upper bits so it can be bumped with fetch_add(QueuedOne).
    enum State : uint64_t {
        Closed = 1ull << 0, // close() was called on this side; drops further deliveries.
        Abandoned = 1ull << 1, // The owner was collected; discard deliveries without closing the peer.
        QueuedShift = 8,
        QueuedOne = 1ull << QueuedShift,
    };
    static constexpr uint64_t queuedCount(uint64_t s) { return s >> QueuedShift; }

    // Sender-thread operations.
    // `fromSide` is the sender's side; the message lands in the *other* side's inbox.
    Bun::Bindgen::NativeAllocationResult<PreparedSend> tryPrepareSend(uint8_t fromSide);

    // Receiver-thread synchronous pop, for node:worker_threads receiveMessageOnPort.
    std::optional<MessageWithMessagePorts> takeOne(uint8_t side);

    void attach(uint8_t side, Ref<Wakeup>&&, Ref<MessagePortContext>&&);
    void detach(uint8_t side);
    void close(uint8_t side);
    void abandon(uint8_t side);

    // Lockless snapshot for the GC visitor / hasPendingActivity.
    uint64_t state(uint8_t side) const { return m_sides[side].state.load(std::memory_order_acquire); }
    bool isOtherSideOpen(uint8_t side) const { return !(state(1 - side) & Closed); }

    // Equality is by identity; used to reject "port posted through itself".
    bool operator==(const MessagePortPipe& other) const { return this == &other; }

private:
    MessagePortPipe() = default;
    void disposeEndpoint(uint8_t side, State reason);
    void detachContext(uint8_t side);
    void finishClose(uint8_t side);

    struct Side {
        WTF::Lock lock;
        MessageNode* first WTF_GUARDED_BY_LOCK(lock) { nullptr };
        MessageNode* last WTF_GUARDED_BY_LOCK(lock) { nullptr };
        uint64_t reserved WTF_GUARDED_BY_LOCK(lock) { 0 };
        RefPtr<Wakeup> wakeup WTF_GUARDED_BY_LOCK(lock);
        RefPtr<MessagePortContext> context WTF_GUARDED_BY_LOCK(lock);
        MessagePortContext::Registration registration;
        // Packed flags + count. Written only while holding `lock`; read locklessly.
        std::atomic<uint64_t> state { 0 };
        Side* closeNext { nullptr };
        MessagePortPipe* closeOwner { nullptr };
    };
    Side m_sides[2];
};

} // namespace WebCore
