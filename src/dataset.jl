mutable struct Dataset
    default_graph::Graph
    named_graphs::Dict{GraphName, Graph}
end

Dataset(; default_graph::Graph = Graph()) = Dataset(default_graph, Dict{GraphName, Graph}())

# ── Dict-like interface for named graphs ──────────────────────────────────────

Base.getindex(ds::Dataset, name::GraphName) = ds.named_graphs[name]
function Base.setindex!(ds::Dataset, g::Graph, name::GraphName)
    ds.named_graphs[name] = g
    ds
end
Base.delete!(ds::Dataset, name::GraphName) = (delete!(ds.named_graphs, name); ds)
Base.haskey(ds::Dataset, name::GraphName) = haskey(ds.named_graphs, name)
Base.get(ds::Dataset, name::GraphName, default) = get(ds.named_graphs, name, default)

# ── Iteration — yields (name, graph) pairs ────────────────────────────────────

Base.iterate(ds::Dataset, state...) = iterate(ds.named_graphs, state...)
Base.keys(ds::Dataset) = keys(ds.named_graphs)
Base.values(ds::Dataset) = values(ds.named_graphs)
Base.length(ds::Dataset) = length(ds.named_graphs)

# ── Utilities ─────────────────────────────────────────────────────────────────

function ntriples(ds::Dataset)
    total = length(ds.default_graph)
    for g in values(ds.named_graphs)
        total += length(g)
    end
    total
end

function quads(ds::Dataset)
    _DatasetQuadIterator(ds)
end

struct _DatasetQuadIterator
    ds::Dataset
end

function Base.iterate(it::_DatasetQuadIterator, state=nothing)
    ds = it.ds
    if state === nothing
        # Start with default graph
        gstate = iterate(ds.default_graph)
        gstate === nothing || return (Quad(gstate[1], nothing), (:default, gstate[2]))
        # Fall through to named graphs
        state = (:default, nothing)
    end
    graph_key, inner = state
    if graph_key === :default
        if inner !== nothing
            gstate = iterate(ds.default_graph, inner)
            gstate !== nothing && return (Quad(gstate[1], nothing), (:default, gstate[2]))
        end
        # Move to first named graph
        kstate = iterate(keys(ds.named_graphs))
        kstate === nothing && return nothing
        k, ks = kstate
        g = ds.named_graphs[k]
        gs = iterate(g)
        while gs === nothing
            kstate = iterate(keys(ds.named_graphs), ks)
            kstate === nothing && return nothing
            k, ks = kstate
            g = ds.named_graphs[k]
            gs = iterate(g)
        end
        return (Quad(gs[1], k), (k, ks, gs[2]))
    else
        k, ks, inner = graph_key, state[2], state[3]
        g = ds.named_graphs[k]
        gs = iterate(g, inner)
        if gs !== nothing
            return (Quad(gs[1], k), (k, ks, gs[2]))
        end
        # Advance named graph iterator
        kstate = iterate(keys(ds.named_graphs), ks)
        while kstate !== nothing
            k2, ks2 = kstate
            g2 = ds.named_graphs[k2]
            gs2 = iterate(g2)
            if gs2 !== nothing
                return (Quad(gs2[1], k2), (k2, ks2, gs2[2]))
            end
            kstate = iterate(keys(ds.named_graphs), ks2)
        end
        return nothing
    end
end

Base.eltype(::Type{_DatasetQuadIterator}) = Quad
Base.IteratorSize(::Type{_DatasetQuadIterator}) = Base.SizeUnknown()

# ── Blank node minting ────────────────────────────────────────────────────────

function blank!(ds::Dataset)::BlankNode
    bn = _mint_blank_node()
    push!(ds.default_graph.blank_nodes, bn.id)
    bn
end

# ── Isomorphism ───────────────────────────────────────────────────────────────

function isomorphic(ds1::Dataset, ds2::Dataset)
    isomorphic(ds1.default_graph, ds2.default_graph) || return false
    Set(keys(ds1.named_graphs)) == Set(keys(ds2.named_graphs)) || return false
    for name in keys(ds1.named_graphs)
        isomorphic(ds1.named_graphs[name], ds2.named_graphs[name]) || return false
    end
    true
end

≅(ds1::Dataset, ds2::Dataset) = isomorphic(ds1, ds2)
