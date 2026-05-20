# ── Graph match ───────────────────────────────────────────────────────────────

function match(g::Graph;
               subject::Union{SubjectTerm, Nothing}   = nothing,
               predicate::Union{PredicateTerm, Nothing} = nothing,
               object::Union{ObjectTerm, Nothing}     = nothing)
    match(g, TriplePattern(subject, predicate, object))
end

function match(g::Graph, p::TriplePattern)
    # Resolve bound terms to their IDs; return empty iterator if any bound term
    # is unknown (not yet interned → definitely not in the graph).
    s_id = p.subject   === nothing ? nothing : get(_TERM_TO_ID, p.subject,   UInt32(0))
    p_id = p.predicate === nothing ? nothing : get(_TERM_TO_ID, p.predicate, UInt32(0))
    o_id = p.object    === nothing ? nothing : get(_TERM_TO_ID, p.object,    UInt32(0))

    (s_id === UInt32(0) || p_id === UInt32(0) || o_id === UInt32(0)) &&
        return _TripleMatchIterator(g, nothing, nothing, nothing, nothing, nothing)

    index, a, b, c, order = _select_index(g.store, s_id, p_id, o_id)
    _TripleMatchIterator(g, index, a, b, c, order)
end

struct _TripleMatchIterator
    g::Graph
    index::Union{Vector{NTuple{3,UInt32}}, Nothing}
    a::Union{UInt32, Nothing}
    b::Union{UInt32, Nothing}
    c::Union{UInt32, Nothing}
    order::Union{Symbol, Nothing}  # :spo | :sop | :pso | :pos | :osp | :ops
end

function Base.iterate(it::_TripleMatchIterator, state=nothing)
    it.index === nothing && return nothing
    idx = it.index
    lo_a = it.a !== nothing ? it.a : UInt32(0)
    lo_b = it.b !== nothing ? it.b : UInt32(0)
    lo_c = it.c !== nothing ? it.c : UInt32(0)
    lo   = (lo_a, lo_b, lo_c)
    hi_a = it.a !== nothing ? it.a : typemax(UInt32)
    hi_b = it.b !== nothing ? it.b : typemax(UInt32)
    hi_c = it.c !== nothing ? it.c : typemax(UInt32)
    hi   = (hi_a, hi_b, hi_c)

    i = state === nothing ? searchsortedfirst(idx, lo) : state
    while i <= length(idx)
        tup = idx[i]
        tup > hi && break
        triple = _permuted_triple(tup, it.order)
        return (triple, i + 1)
    end
    nothing
end

# Reconstruct a Triple from a permuted index tuple
function _permuted_triple(tup::NTuple{3,UInt32}, order::Symbol)::Triple
    a, b, c = _resolve(tup[1]), _resolve(tup[2]), _resolve(tup[3])
    if order === :spo
        Triple(a::SubjectTerm, b::IRI, c)
    elseif order === :sop
        Triple(a::SubjectTerm, c::IRI, b)
    elseif order === :pso
        Triple(b::SubjectTerm, a::IRI, c)
    elseif order === :pos
        Triple(c::SubjectTerm, a::IRI, b)
    elseif order === :osp
        Triple(b::SubjectTerm, c::IRI, a)
    else  # :ops
        Triple(c::SubjectTerm, b::IRI, a)
    end
end

Base.eltype(::Type{_TripleMatchIterator}) = Triple
Base.IteratorSize(::Type{_TripleMatchIterator}) = Base.SizeUnknown()

# ── Dataset match ─────────────────────────────────────────────────────────────

function match(ds::Dataset;
               subject::Union{SubjectTerm, Nothing}   = nothing,
               predicate::Union{PredicateTerm, Nothing} = nothing,
               object::Union{ObjectTerm, Nothing}     = nothing,
               graph::Union{GraphName, Nothing, Symbol} = nothing)
    pat = TriplePattern(subject, predicate, object)
    _DatasetMatchIterator(ds, pat, graph)
end

struct _DatasetMatchIterator
    ds::Dataset
    pattern::TriplePattern
    graph_filter::Union{GraphName, Nothing, Symbol}  # nothing = all, :default = default only
end

function Base.iterate(it::_DatasetMatchIterator, state=nothing)
    ds, pat, gf = it.ds, it.pattern, it.graph_filter
    # State: (phase, inner_state) where phase ∈ {:default, :named}
    # and for :named, also (name_iter_state, current_name)
    if state === nothing
        if gf === :default || gf === nothing
            inner = iterate(match(ds.default_graph, pat))
            inner !== nothing &&
                return (Quad(inner[1], nothing), (:default, inner[2]))
            gf === :default && return nothing
        end
        # named graphs
        if gf isa GraphName
            haskey(ds, gf) || return nothing
            g = ds[gf]
            inner = iterate(match(g, pat))
            inner !== nothing && return (Quad(inner[1], gf), (gf, nothing, inner[2]))
            return nothing
        end
        # gf === nothing → all named graphs
        ks = iterate(keys(ds.named_graphs))
        ks === nothing && return nothing
        return _advance_named(it, ks[1], ks[2])
    end

    phase = state[1]
    if phase === :default
        inner = iterate(match(ds.default_graph, pat), state[2])
        inner !== nothing &&
            return (Quad(inner[1], nothing), (:default, inner[2]))
        gf === :default && return nothing
        ks = iterate(keys(ds.named_graphs))
        ks === nothing && return nothing
        return _advance_named(it, ks[1], ks[2])
    elseif phase isa GraphName
        name, ks_state, inner_state = state[1], state[2], state[3]
        g = ds.named_graphs[name]
        inner = iterate(match(g, pat), inner_state)
        if inner !== nothing
            return (Quad(inner[1], name), (name, ks_state, inner[2]))
        end
        ks_state === nothing && return nothing  # fixed graph filter, done
        ks = iterate(keys(ds.named_graphs), ks_state)
        ks === nothing && return nothing
        return _advance_named(it, ks[1], ks[2])
    end
    nothing
end

function _advance_named(it::_DatasetMatchIterator, name::GraphName, ks_state)
    ds, pat = it.ds, it.pattern
    g = ds.named_graphs[name]
    inner = iterate(match(g, pat))
    if inner !== nothing
        return (Quad(inner[1], name), (name, ks_state, inner[2]))
    end
    ks = iterate(keys(ds.named_graphs), ks_state)
    ks === nothing && return nothing
    _advance_named(it, ks[1], ks[2])
end

Base.eltype(::Type{_DatasetMatchIterator}) = Quad
Base.IteratorSize(::Type{_DatasetMatchIterator}) = Base.SizeUnknown()

# ── Convenience accessors ─────────────────────────────────────────────────────

subjects(g::Graph; kwargs...) =
    (t.subject for t in match(g; kwargs...))

predicates(g::Graph; kwargs...) =
    (t.predicate for t in match(g; kwargs...))

objects(g::Graph; kwargs...) =
    (t.object for t in match(g; kwargs...))
