#pragma once

#include "MessageWithMessagePorts.h"
#include <memory>
#include <utility>
#include <variant>
#include <wtf/FastMalloc.h>

namespace WebCore {

class MessageQueue {
    WTF_MAKE_NONCOPYABLE(MessageQueue);

public:
    struct ErrorMessage {
        String text;
    };

    struct ErrorValue {
        Ref<SerializedScriptValue> value;
    };

    struct Node {
        WTF_DEPRECATED_MAKE_STRUCT_FAST_ALLOCATED(Node);

        static std::unique_ptr<Node> tryCreate()
        {
            void* allocation;
            if (!WTF::tryFastMalloc(sizeof(Node)).getValue(allocation))
                return nullptr;
            return std::unique_ptr<Node> { new (NotNull, allocation) Node };
        }

        std::variant<MessageWithMessagePorts, ErrorMessage, ErrorValue> message;

    private:
        friend class MessageQueue;
        Node* next { nullptr };
    };

    MessageQueue() = default;
    MessageQueue(MessageQueue&& other) noexcept
        : m_first(std::exchange(other.m_first, nullptr))
        , m_last(std::exchange(other.m_last, nullptr))
        , m_size(std::exchange(other.m_size, 0))
    {
    }

    MessageQueue& operator=(MessageQueue&& other) noexcept
    {
        if (this != &other) {
            clear();
            m_first = std::exchange(other.m_first, nullptr);
            m_last = std::exchange(other.m_last, nullptr);
            m_size = std::exchange(other.m_size, 0);
        }
        return *this;
    }

    ~MessageQueue() { clear(); }

    bool isEmpty() const { return !m_first; }
    size_t size() const { return m_size; }

    void append(std::unique_ptr<Node>&& node)
    {
        RELEASE_ASSERT(node && !node->next);
        if (m_last)
            m_last->next = node.get();
        else
            m_first = node.get();
        m_last = node.release();
        ++m_size;
    }

    void prepend(MessageQueue&& queue)
    {
        RELEASE_ASSERT(this != &queue);
        if (queue.isEmpty())
            return;
        queue.m_last->next = m_first;
        m_first = std::exchange(queue.m_first, nullptr);
        if (!m_last)
            m_last = queue.m_last;
        queue.m_last = nullptr;
        m_size += std::exchange(queue.m_size, 0);
    }

    std::unique_ptr<Node> takeFirst()
    {
        RELEASE_ASSERT(m_first);
        std::unique_ptr<Node> node { m_first };
        m_first = std::exchange(node->next, nullptr);
        if (!m_first)
            m_last = nullptr;
        --m_size;
        return node;
    }

private:
    void clear()
    {
        if (isEmpty())
            return;
        MessageQueue dropped;
        std::swap(m_first, dropped.m_first);
        std::swap(m_last, dropped.m_last);
        std::swap(m_size, dropped.m_size);
        while (!dropped.isEmpty())
            dropped.takeFirst();
    }

    Node* m_first { nullptr };
    Node* m_last { nullptr };
    size_t m_size { 0 };
};

}
