#pragma once

#if USE(BUN_JSC_ADDITIONS)

#include "HeapAnalyzer.h"
#include <functional>
#include <optional>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
#include <wtf/Lock.h>
#include <wtf/OverflowPolicy.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/Vector.h>
#include <wtf/text/StringBuilder.h>

namespace JSC {

class JSCell;
class HeapProfiler;
class HeapSnapshot;

class JS_EXPORT_PRIVATE BunV8HeapSnapshotBuilder final : public HeapAnalyzer {
    WTF_MAKE_TZONE_ALLOCATED(BunV8HeapSnapshotBuilder);

public:
    BunV8HeapSnapshotBuilder(HeapProfiler&);
    ~BunV8HeapSnapshotBuilder() final;

    void analyzeNode(JSCell*) final;
    void analyzeEdge(JSCell* from, JSCell* to, RootMarkReason) final;
    void analyzePropertyNameEdge(JSCell* from, JSCell* to, UniquedStringImpl* propertyName) final;
    void analyzeVariableNameEdge(JSCell* from, JSCell* to, UniquedStringImpl* variableName) final;
    void analyzeIndexEdge(JSCell* from, JSCell* to, uint32_t index) final;
    void setOpaqueRootReachabilityReasonForCell(JSCell*, ASCIILiteral) final;
    void setWrappedObjectForCell(JSCell*, void*) final;
    void setLabelForCell(JSCell*, const String&) final;

    // V8 snapshot generation
    void buildSnapshot();
    String json();
    Vector<uint8_t> jsonBytes();

private:
    static constexpr unsigned kRootNodeIndex = 0;
    static constexpr unsigned kGcRootsNodeIndex = 1;
    // Synthetic-node IDs occupy 1..kSyntheticIdCount; real-object IDs are
    // identifier + kSyntheticIdCount so the spaces never collide.
    static constexpr unsigned kSyntheticIdCount = 2;

    String generateV8HeapSnapshot();
    Vector<uint8_t> generateV8HeapSnapshotBytes();
    unsigned analyzeNodeInternal(JSCell*);
    void appendSyntheticRootEdges();

    struct TraceLocation {
    public:
        unsigned scriptId { 0 };
        String scriptName;
        unsigned line { 0 };
        unsigned column { 0 };

        void sourcemap(VM& vm);
    };

    struct Node {
        JSCell* cell { nullptr };
        unsigned id { 0 };
        unsigned typeIndex { 0 };
        String name {};
        size_t selfSize { 0 };
        Vector<unsigned> edges;
        std::optional<BunV8HeapSnapshotBuilder::TraceLocation> traceLocation = std::nullopt;
        std::optional<unsigned> parentNodeId = std::nullopt;
        unsigned edgesCount { 0 };
        unsigned childrenVectorIndex { std::numeric_limits<unsigned>::max() };
    };
    struct Edge {
        unsigned fromNodeId { 0 };
        unsigned toNodeId { 0 };
        unsigned typeIndex { 0 };
        unsigned index { 0 };
        String name {};
    };

    enum class V8NodeType : uint8_t {
        Hidden,
        Array,
        String,
        Object,
        Code,
        Closure,
        RegExp,
        Number,
        Native,
        Synthetic,
        ConcatenatedString,
        SlicedString,
        Symbol,
        BigInt,
        ObjectShape,
        Count
    };

    enum class V8EdgeType : uint8_t {
        Context,
        Element,
        Property,
        Internal,
        Hidden,
        Shortcut,
        Weak,
        Count
    };

    HeapProfiler& m_profiler;
    Lock m_buildingNodeMutex;
    Lock m_buildingEdgeMutex;

    // Node and edge storage
    Vector<Node> m_nodes;
    Vector<Edge> m_edges;
    Lock m_cellToNodeIdMutex;
    HashMap<JSCell*, unsigned> m_cellToNodeId;
    Vector<unsigned> m_globalObjectNodeIndices;
    std::unique_ptr<HeapSnapshot> m_snapshot;
    HeapSnapshot* m_previousSnapshot { nullptr };

    // TODO: make this not so inefficient
    Vector<String> m_strings;
    HashMap<size_t, unsigned> m_stringsLookupTable;
    // Type mapping
    Vector<String> m_nodeTypeNames;
    Vector<String> m_edgeTypeNames;
    HashMap<String, unsigned> m_nodeTypeMap;
    HashMap<String, unsigned> m_edgeTypeMap;

    // Cell labels
    HashMap<JSCell*, String> m_cellLabels;

    // Helper methods
    unsigned getOrCreateNodeId(JSCell*);
    unsigned getNodeTypeIndex(JSCell*);
    unsigned getEdgeTypeIndex(RootMarkReason);
    unsigned getEdgeTypeIndex(const String& type);
    unsigned addString(const String&);
    void initializeTypeNames();
    String getDetailedNodeType(JSCell*);
    std::optional<TraceLocation> getTraceLocation(JSCell*);
};

} // namespace JSC

#endif // USE(BUN_JSC_ADDITIONS)
