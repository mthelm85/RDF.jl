# ── Graph match ───────────────────────────────────────────────────────────────

"""
    match(g::Graph; subject=nothing, predicate=nothing, object=nothing)
    match(g::Graph, pattern::TriplePattern)
    match(ds::Dataset; subject=nothing, predicate=nothing, object=nothing, graph=nothing)

Return a lazy iterator over all triples (or quads) matching the given pattern.
Any omitted keyword argument acts as a wildcard. The hexastore backing the graph
automatically selects the most efficient index for the given bound positions.

```julia
# All triples with a given predicate
for t in match(g; predicate=rdf.type)
    println(t.subject)
end

# Exact triple lookup
match(g; subject=ex.alice, predicate=rdf.type, object=ex.Person)

# Dataset: restrict to a named graph
match(ds; predicate=rdf.type, graph=IRI("http://example.org/g1"))

# Dataset: default graph only
match(ds; graph=:default)
```
"""
function match(g::Graph;
               subject::Union{SubjectTerm, Nothing}   = nothing,
               predicate::Union{PredicateTerm, Nothing} = nothing,
               object::Union{ObjectTerm, Nothing}     = nothing)
    match(g, TriplePattern(subject, predicate, object))
end

function match(g::Graph, p::TriplePattern)
    # Resolve bound terms to their IDs; return empty iterator if any bound term
    # is unknown (not yet interned → definitely not in the graph).
    s_id = p.subject   === nothing ? nothing : get(_type_map(p.subject),   p.subject,   UInt32(0))
    p_id = p.predicate === nothing ? nothing : get(_type_map(p.predicate), p.predicate, UInt32(0))
    o_id = p.object    === nothing ? nothing : get(_type_map(p.object),    p.object,    UInt32(0))

    if s_id === UInt32(0) || p_id === UInt32(0) || o_id === UInt32(0)
        return _TripleMatchIterator(g, _EMPTY_HEXAVEC,
                                   (UInt32(0), UInt32(0), UInt32(0)),
                                   (UInt32(0), UInt32(0), UInt32(0)), :spo)
    end

    index, a, b, c, order = _select_index(g.store, s_id, p_id, o_id)
    lo, hi = _range_bounds(a, b, c)
    _TripleMatchIterator(g, index, lo, hi, order)
end

# Shared sentinel vector for empty iterators — avoids allocating a new Vector per miss
const _EMPTY_HEXAVEC = NTuple{3,UInt32}[]

struct _TripleMatchIterator
    g::Graph
    index::Vector{NTuple{3,UInt32}}  # _EMPTY_HEXAVEC signals no results
    lo::NTuple{3,UInt32}             # precomputed lower bound (never changes)
    hi::NTuple{3,UInt32}             # precomputed upper bound (never changes)
    order::Symbol                    # always concrete: :spo | :sop | :pso | :pos | :osp | :ops
end

# No-state entry point: compute starting position once
function Base.iterate(it::_TripleMatchIterator)
    isempty(it.index) && return nothing
    _tmi_step(it, searchsortedfirst(it.index, it.lo))
end

# Continuation with concrete Int state — no Union{Nothing,Int} inference needed
function Base.iterate(it::_TripleMatchIterator, i::Int)
    _tmi_step(it, i)
end

@inline function _tmi_step(it::_TripleMatchIterator, i::Int)
    idx = it.index
    hi  = it.hi
    while i <= length(idx)
        tup = @inbounds idx[i]
        tup > hi && return nothing
        return (_permuted_triple(tup, it.order), i + 1)
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

# ── Zero-allocation raw-ID graph iterator ─────────────────────────────────────

"""
    eachid(g::Graph) -> iterator

Zero-allocation iterator over every triple in `g` as a raw
`(s_id, p_id, o_id)::NTuple{3,UInt32}` tuple, reading directly from the
underlying hexastore without constructing `Triple` structs or boxing
union-typed terms.

Use `RDF._resolve(id)` to convert an ID back to an `RDFTerm` when needed.
This is the preferred inner loop for bulk write operations and any code that
only needs a subset of the resolved terms per row.

```julia
# Count triples matching a condition without allocating Triple structs
_ensure_nt_cache!()
cache = RDF._NT_TERM_STRINGS
n = 0
for (s, p, o) in eachid(g)
    startswith(cache[s], "<http://example.org") && (n += 1)
end
```

See also: [`match_ids`](@ref) for pattern-filtered raw-ID iteration.
"""
eachid(g::Graph) = _RawSPOIterator(g.store.spo)

struct _RawSPOIterator
    spo::Vector{NTuple{3,UInt32}}
end

@inline function Base.iterate(it::_RawSPOIterator, i::Int=1)
    i > length(it.spo) && return nothing
    @inbounds it.spo[i], i + 1
end

Base.eltype(::Type{_RawSPOIterator})     = NTuple{3,UInt32}
Base.IteratorSize(::Type{_RawSPOIterator}) = Base.HasLength()
Base.length(it::_RawSPOIterator)         = length(it.spo)

"""
    match_ids(g::Graph; subject=nothing, predicate=nothing, object=nothing)

Like [`match`](@ref) but yields raw `(s_id, p_id, o_id)::NTuple{3,UInt32}` tuples
rather than resolved `Triple`s.  Arguments are `UInt32` IDs (use
`RDF._intern!(term)` to get the ID for a term) or `nothing` for wildcards.
Pass `UInt32(0)` for any bound position that is definitely not in the registry
to get an immediately-empty iterator.

This is a zero-allocation alternative to `match` for code that needs pattern
filtering without the overhead of `_resolve()` and `Triple` construction.
"""
function match_ids(g::Graph;
                   subject::Union{UInt32, Nothing}   = nothing,
                   predicate::Union{UInt32, Nothing} = nothing,
                   object::Union{UInt32, Nothing}    = nothing)
    _match_ids(g, subject, predicate, object)
end

# ── ID-based match iterator ───────────────────────────────────────────────────
#
# Returns raw (s_id, p_id, o_id) NTuples directly from the hexastore.
# Arguments are UInt32 for bound positions, nothing for wildcards.
# UInt32(0) for any argument means "term not in registry" → empty iterator.
# Used internally by the columnar BGP evaluator to avoid _resolve() overhead
# and Triple struct construction during join loops.

struct _IDTripleIterator
    index::Vector{NTuple{3,UInt32}}  # _EMPTY_HEXAVEC signals no results
    lo::NTuple{3,UInt32}
    hi::NTuple{3,UInt32}
    order::Symbol
end

function _match_ids(g::Graph,
                    s_id::Union{UInt32, Nothing},
                    p_id::Union{UInt32, Nothing},
                    o_id::Union{UInt32, Nothing})
    # UInt32(0) signals "not in registry" → return empty iterator
    if s_id === UInt32(0) || p_id === UInt32(0) || o_id === UInt32(0)
        return _IDTripleIterator(_EMPTY_HEXAVEC,
                                 (UInt32(0), UInt32(0), UInt32(0)),
                                 (UInt32(0), UInt32(0), UInt32(0)), :spo)
    end
    index, a, b, c, order = _select_index(g.store, s_id, p_id, o_id)
    lo, hi = _range_bounds(a, b, c)
    _IDTripleIterator(index, lo, hi, order)
end

function Base.iterate(it::_IDTripleIterator)
    isempty(it.index) && return nothing
    _idi_step(it, searchsortedfirst(it.index, it.lo))
end

function Base.iterate(it::_IDTripleIterator, i::Int)
    _idi_step(it, i)
end

@inline function _idi_step(it::_IDTripleIterator, i::Int)
    idx = it.index
    hi  = it.hi
    while i <= length(idx)
        tup = @inbounds idx[i]
        tup > hi && return nothing
        return (_permute_to_spo(tup, it.order), i + 1)
    end
    nothing
end

# Reorder a permuted hexastore tuple to canonical (s_id, p_id, o_id) order.
@inline function _permute_to_spo(tup::NTuple{3,UInt32}, order::Symbol)::NTuple{3,UInt32}
    a, b, c = tup
    order === :spo && return (a, b, c)
    order === :sop && return (a, c, b)
    order === :pso && return (b, a, c)
    order === :pos && return (c, a, b)
    order === :osp && return (b, c, a)
    return (c, b, a)  # :ops
end

Base.eltype(::Type{_IDTripleIterator}) = NTuple{3, UInt32}
Base.IteratorSize(::Type{_IDTripleIterator}) = Base.SizeUnknown()

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

"""
    subjects(g::Graph; kwargs...) -> iterator

Lazy iterator over the subjects of all triples matching `kwargs`. Equivalent to
`(t.subject for t in match(g; kwargs...))`.
"""
subjects(g::Graph; kwargs...) =
    (t.subject for t in match(g; kwargs...))

"""
    predicates(g::Graph; kwargs...) -> iterator

Lazy iterator over the predicates of all triples matching `kwargs`.
"""
predicates(g::Graph; kwargs...) =
    (t.predicate for t in match(g; kwargs...))

"""
    objects(g::Graph; kwargs...) -> iterator

Lazy iterator over the objects of all triples matching `kwargs`.
"""
objects(g::Graph; kwargs...) =
    (t.object for t in match(g; kwargs...))
