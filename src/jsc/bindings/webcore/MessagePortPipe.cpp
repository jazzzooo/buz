#include "config.h"
#include "MessagePortPipe.h"
#include <limits>
#include <wtf/Locker.h>

namespace WebCore {

RefPtr<MessagePortContext> MessagePortContext::tryCreate(ScriptExecutionContext& context)
{
    void* allocation;
    if (!WTF::tryFastMalloc(sizeof(MessagePortContext)).getValue(allocation))
        return nullptr;
    Ref result = adoptRef(*new (NotNull, allocation) MessagePortContext);
    result->attach(context);
    return result;
}

MessagePortContext::~MessagePortContext()
{
    ASSERT(!context());
    ASSERT(!m_head);
}

void MessagePortContext::add(Registration& registration)
{
    RELEASE_ASSERT(context() && context()->isContextThread());
    Locker locker { m_lock };
    RELEASE_ASSERT(!registration.owner);
    registration.owner = this;
    registration.next = m_head;
    if (m_head)
        m_head->previous = &registration;
    m_head = &registration;
}

void MessagePortContext::removeLocked(Registration& registration)
{
    if (!registration.owner)
        return;
    RELEASE_ASSERT(registration.owner == this);
    if (registration.previous)
        registration.previous->next = registration.next;
    else
        m_head = registration.next;
    if (registration.next)
        registration.next->previous = registration.previous;
    registration.owner = nullptr;
    registration.previous = nullptr;
    registration.next = nullptr;
}

void MessagePortContext::remove(Registration& registration)
{
    Locker locker { m_lock };
    removeLocked(registration);
}

void MessagePortContext::contextClosed() noexcept
{
    while (true) {
        RefPtr<MessagePortPipe> pipe;
        uint8_t side;
        {
            Locker locker { m_lock };
            if (!m_head)
                return;
            auto& registration = *m_head;
            pipe = registration.pipe.get();
            side = registration.side;
            removeLocked(registration);
        }
        if (pipe)
            pipe->close(side);
    }
}

RefPtr<MessagePortPipe> MessagePortPipe::tryCreate()
{
    void* allocation;
    if (!WTF::tryFastMalloc(sizeof(MessagePortPipe)).getValue(allocation))
        return nullptr;
    Ref pipe = adoptRef(*new (NotNull, allocation) MessagePortPipe);
    for (uint8_t side = 0; side < 2; ++side) {
        pipe->m_sides[side].registration.pipe = pipe.get();
        pipe->m_sides[side].registration.side = side;
    }
    return pipe;
}

MessagePortPipe::~MessagePortPipe()
{
    for (uint8_t side = 0; side < 2; ++side)
        detachContext(side);
    for (auto& side : m_sides) {
        Locker locker { side.lock };
        ASSERT(!side.first && !side.last && !side.reserved);
    }
}

// Defined here (not in TransferredMessagePort.h) to break the header cycle
// MessagePortPipe.h → MessageWithMessagePorts.h → TransferredMessagePort.h.
TransferredMessagePort::~TransferredMessagePort()
{
    // If this endpoint is destroyed while still owning the pipe side (never
    // handed off to a new MessagePort via entangle()), the side is orphaned;
    // mark it Closed so the peer's hasPendingActivity() can return false.
    if (pipe)
        pipe->close(side);
}

TransferredMessagePort& TransferredMessagePort::operator=(TransferredMessagePort&& other)
{
    if (this != &other) {
        if (pipe)
            pipe->close(side);
        pipe = WTF::move(other.pipe);
        side = other.side;
    }
    return *this;
}

MessagePortPipe::PreparedSend::PreparedSend(Ref<MessagePortPipe>&& pipe, uint8_t side, std::unique_ptr<MessageNode>&& node)
    : m_pipe(WTF::move(pipe))
    , m_node(WTF::move(node))
    , m_side(side)
{
}

MessagePortPipe::PreparedSend::PreparedSend(PreparedSend&& other) noexcept
    : m_pipe(WTF::move(other.m_pipe))
    , m_node(WTF::move(other.m_node))
    , m_side(other.m_side)
    , m_consumed(std::exchange(other.m_consumed, true))
{
}

MessagePortPipe::PreparedSend::~PreparedSend()
{
    if (m_pipe) {
        auto& side = m_pipe->m_sides[m_side];
        Locker locker { side.lock };
        ASSERT(side.reserved);
        --side.reserved;
    }
}

Bun::Bindgen::NativeAllocationResult<MessagePortPipe::PreparedSend> MessagePortPipe::tryPrepareSend(uint8_t fromSide)
{
    ASSERT(fromSide < 2);
    const uint8_t destination = 1 - fromSide;
    auto& side = m_sides[destination];
    if (side.state.load(std::memory_order_acquire) & (Closed | Abandoned))
        return PreparedSend {};

    void* allocation;
    if (!WTF::tryFastMalloc(sizeof(MessageNode)).getValue(allocation))
        return Bun::Bindgen::nativeAllocationFailure();
    std::unique_ptr<MessageNode> node { new (NotNull, allocation) MessageNode };
    {
        Locker locker { side.lock };
        const uint64_t state = side.state.load(std::memory_order_relaxed);
        if (state & (Closed | Abandoned))
            return PreparedSend {};
        constexpr uint64_t maximumCount = std::numeric_limits<uint64_t>::max() >> QueuedShift;
        if (queuedCount(state) + side.reserved >= maximumCount)
            return Bun::Bindgen::nativeAllocationFailure();
        ++side.reserved;
    }
    return PreparedSend { Ref { *this }, destination, WTF::move(node) };
}

void MessagePortPipe::PreparedSend::commit(MessageWithMessagePorts&& message)
{
    RELEASE_ASSERT(!m_consumed);
    m_consumed = true;
    if (!m_pipe)
        return;

    Ref pipe = m_pipe.releaseNonNull();
    auto node = WTF::move(m_node);
    node->message = WTF::move(message);
    auto& dst = pipe->m_sides[m_side];

    RefPtr<Wakeup> wakeup;
    {
        Locker locker { dst.lock };
        ASSERT(dst.reserved);
        --dst.reserved;
        uint64_t s = dst.state.load(std::memory_order_relaxed);
        if (s & (Closed | Abandoned))
            return;

        if (dst.last)
            dst.last->next = node.get();
        else
            dst.first = node.get();
        dst.last = node.release();

        wakeup = dst.wakeup;
        dst.state.store(s + QueuedOne, std::memory_order_release);
    }

    if (wakeup)
        wakeup->notify();
}

std::optional<MessageWithMessagePorts> MessagePortPipe::takeOne(uint8_t side)
{
    ASSERT(side < 2);
    auto& s = m_sides[side];
    std::unique_ptr<MessageNode> node;
    {
        Locker locker { s.lock };
        if ((s.state.load(std::memory_order_relaxed) & (Closed | Abandoned)) || !s.first)
            return std::nullopt;
        node.reset(s.first);
        s.first = node->next;
        if (!s.first)
            s.last = nullptr;
        s.state.fetch_sub(QueuedOne, std::memory_order_acq_rel);
    }
    return WTF::move(node->message);
}

void MessagePortPipe::attach(uint8_t side, Ref<Wakeup>&& wakeup, Ref<MessagePortContext>&& context)
{
    ASSERT(side < 2);
    auto& s = m_sides[side];
    RefPtr<Wakeup> pendingWakeup;
    {
        Locker locker { s.lock };
        uint64_t st = s.state.load(std::memory_order_relaxed);
        if (st & (Closed | Abandoned))
            return;
        ASSERT(!s.wakeup);
        ASSERT(!s.context);
        context->add(s.registration);
        s.context = WTF::move(context);
        s.wakeup = WTF::move(wakeup);
        if (queuedCount(st) || !isOtherSideOpen(side))
            pendingWakeup = s.wakeup;
    }
    if (pendingWakeup)
        pendingWakeup->notify();
}

void MessagePortPipe::detach(uint8_t side)
{
    ASSERT(side < 2);
    auto& s = m_sides[side];
    RefPtr<Wakeup> wakeup;
    {
        Locker locker { s.lock };
        wakeup = std::exchange(s.wakeup, nullptr);
    }
    detachContext(side);
}

void MessagePortPipe::detachContext(uint8_t side)
{
    auto& s = m_sides[side];
    RefPtr<MessagePortContext> context;
    {
        Locker locker { s.lock };
        context = std::exchange(s.context, nullptr);
    }
    if (context)
        context->remove(s.registration);
}

void MessagePortPipe::finishClose(uint8_t side)
{
    detachContext(side);
    RefPtr<Wakeup> peerWakeup;
    auto& peer = m_sides[1 - side];
    {
        Locker locker { peer.lock };
        peerWakeup = peer.wakeup;
    }
    if (peerWakeup)
        peerWakeup->notify();
}

void MessagePortPipe::close(uint8_t side)
{
    disposeEndpoint(side, Closed);
}

void MessagePortPipe::abandon(uint8_t side)
{
    disposeEndpoint(side, Abandoned);
}

void MessagePortPipe::disposeEndpoint(uint8_t side, State reason)
{
    ASSERT(side < 2);

    // Claim each side once under its lock. Its embedded node retains the pipe
    // until cleanup consumes it, avoiding both allocation and recursive close.
    Side* worklist = nullptr;
    const auto enqueue = [&](MessagePortPipe& pipe, uint8_t sd, State reason) {
        ASSERT(sd < 2);
        auto& pending = pipe.m_sides[sd];
        bool promoted = false;
        {
            Locker locker { pending.lock };
            const auto state = pending.state.load(std::memory_order_relaxed);
            if (state & Closed)
                return;
            if (state & Abandoned) {
                if (reason == Abandoned)
                    return;
                pending.state.store(state | Closed, std::memory_order_release);
                promoted = true;
            } else {
                pipe.ref();
                pending.closeOwner = &pipe;
                pending.closeNext = worklist;
                worklist = &pending;
                pending.state.store(reason, std::memory_order_release);
            }
        }
        // Abandonment cleanup may already own the embedded worklist node.
        if (promoted)
            pipe.finishClose(sd);
    };
    enqueue(*this, side, reason);

    while (worklist) {
        auto& s = *worklist;
        worklist = std::exchange(s.closeNext, nullptr);
        Ref pipe = adoptRef(*std::exchange(s.closeOwner, nullptr));

        MessageNode* dropped;
        RefPtr<Wakeup> wakeup;
        {
            Locker locker { s.lock };
            wakeup = WTF::move(s.wakeup);
            dropped = std::exchange(s.first, nullptr);
            s.last = nullptr;
        }

        while (dropped) {
            std::unique_ptr<MessageNode> message { dropped };
            dropped = message->next;
            for (auto& tp : message->message.transferredPorts) {
                if (auto p = std::exchange(tp.pipe, nullptr))
                    enqueue(*p, tp.side, Closed);
            }
        }

        if (s.state.load(std::memory_order_acquire) & Closed) {
            pipe->finishClose(&s == &pipe->m_sides[0] ? 0 : 1);
        }
    }
}

} // namespace WebCore
