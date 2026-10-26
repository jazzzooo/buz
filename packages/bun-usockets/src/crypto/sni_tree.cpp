/*
 * Authored by Alex Hultman, 2018-2020.
 * Intellectual property of third-party.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef LIBUS_NO_SSL

#include "../libusockets.h"
#include <openssl/tls1.h>
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>
#include <string_view>
#include <type_traits>

struct sni_node;

struct sni_child {
    std::string_view label;
    sni_node *node;
};

static_assert(std::is_trivially_copyable_v<sni_child>);

struct sni_node {
    void *user = nullptr;
    sni_child *children = nullptr;
    size_t count = 0;
    size_t capacity = 0;
};

static std::string_view takeLabel(std::string_view &name) {
    const auto label = name.substr(0, name.find('.'));
    name.remove_prefix(std::min(name.size(), label.size() + 1));
    return label;
}

static size_t lowerBound(const sni_node *node, std::string_view label) {
    size_t first = 0, last = node->count;
    while (first < last) {
        const size_t middle = first + (last - first) / 2;
        if (node->children[middle].label < label) first = middle + 1;
        else last = middle;
    }
    return first;
}

static bool reserveChildren(sni_node *node, size_t count) {
    if (count <= node->capacity) return true;
    const size_t maximum = SIZE_MAX / sizeof(sni_child);
    if (count > maximum) return false;
    const size_t grown = node->capacity > maximum / 2 ? maximum : std::max(size_t(4), node->capacity * 2);
    const size_t capacity = std::max(count, grown);
    auto *children = static_cast<sni_child *>(std::realloc(node->children, capacity * sizeof(sni_child)));
    if (!children) return false;
    node->children = children;
    node->capacity = capacity;
    return true;
}

static void freeNode(sni_node *node, void (*release)(void *)) {
    if (!node) return;
    for (size_t i = 0; i < node->count; ++i) {
        std::free(const_cast<char *>(node->children[i].label.data()));
        freeNode(node->children[i].node, release);
    }
    if (node->user && release) release(node->user);
    std::free(node->children);
    delete node;
}

static void freeChild(sni_child child) {
    std::free(const_cast<char *>(child.label.data()));
    freeNode(child.node, nullptr);
}

static sni_child makeChild(std::string_view label) {
    auto *node = new (std::nothrow) sni_node;
    if (!node) return {};
    auto *bytes = static_cast<char *>(std::malloc(std::max(size_t(1), label.size())));
    if (!bytes) {
        delete node;
        return {};
    }
    std::memcpy(bytes, label.data(), label.size());
    return {std::string_view(bytes, label.size()), node};
}

static void *removeUser(sni_node *node, std::string_view name) {
    if (name.empty()) {
        void *user = node->user;
        node->user = nullptr;
        return user;
    }
    const auto label = takeLabel(name);
    const size_t index = lowerBound(node, label);
    if (index == node->count || node->children[index].label != label) return nullptr;
    const auto child = node->children[index];
    void *user = removeUser(child.node, name);
    if (!child.node->user && child.node->count == 0) {
        freeChild(child);
        std::memmove(node->children + index, node->children + index + 1, (node->count - index - 1) * sizeof(sni_child));
        --node->count;
    }
    return user;
}

static void *findUser(const sni_node *node, std::string_view name) {
    if (name.empty()) return node->user;
    const auto label = takeLabel(name);
    const size_t exact = lowerBound(node, label);
    if (exact < node->count && node->children[exact].label == label) {
        if (void *user = findUser(node->children[exact].node, name)) return user;
    }
    if (label == "*") return nullptr;
    const size_t wildcard = lowerBound(node, "*");
    if (wildcard == node->count || node->children[wildcard].label != "*") return nullptr;
    return findUser(node->children[wildcard].node, name);
}

extern "C" {

void *sni_new() {
    return new (std::nothrow) sni_node;
}

void sni_free(void *sni, void (*release)(void *)) {
    freeNode(static_cast<sni_node *>(sni), release);
}

static int setUser(void *sni, const char *hostname, void *user, bool replace, void **previous) {
    *previous = nullptr;
    std::string_view name(hostname);
    if (name.size() > TLSEXT_MAXLEN_host_name) return US_SERVER_NAME_INVALID;
    auto *node = static_cast<sni_node *>(sni);
    while (!name.empty()) {
        const auto label = takeLabel(name);
        const size_t index = lowerBound(node, label);
        if (index < node->count && node->children[index].label == label) {
            node = node->children[index].node;
            continue;
        }

        // Build the entire missing suffix before publishing its first edge.
        auto branch = makeChild(label);
        if (!branch.node) return US_SERVER_NAME_OUT_OF_MEMORY;
        auto *leaf = branch.node;
        while (!name.empty()) {
            auto child = makeChild(takeLabel(name));
            if (!child.node || !reserveChildren(leaf, 1)) {
                freeChild(child);
                freeChild(branch);
                return US_SERVER_NAME_OUT_OF_MEMORY;
            }
            leaf->children[0] = child;
            leaf->count = 1;
            leaf = child.node;
        }
        if (node->count == SIZE_MAX || !reserveChildren(node, node->count + 1)) {
            freeChild(branch);
            return US_SERVER_NAME_OUT_OF_MEMORY;
        }
        leaf->user = user;
        std::memmove(node->children + index + 1, node->children + index, (node->count - index) * sizeof(sni_child));
        node->children[index] = branch;
        ++node->count;
        return US_SERVER_NAME_OK;
    }
    if (node->user && !replace) return US_SERVER_NAME_DUPLICATE;
    *previous = node->user;
    node->user = user;
    return US_SERVER_NAME_OK;
}

int sni_add(void *sni, const char *hostname, void *user) {
    void *previous;
    return setUser(sni, hostname, user, false, &previous);
}

int sni_replace(void *sni, const char *hostname, void *user, void **previous) {
    return setUser(sni, hostname, user, true, previous);
}

void *sni_remove(void *sni, const char *hostname) {
    const std::string_view name(hostname);
    if (name.size() > TLSEXT_MAXLEN_host_name) return nullptr;
    return removeUser(static_cast<sni_node *>(sni), name);
}

void *sni_find(void *sni, const char *hostname) {
    const std::string_view name(hostname);
    if (name.size() > TLSEXT_MAXLEN_host_name) return nullptr;
    return findUser(static_cast<sni_node *>(sni), name);
}

}

#endif
