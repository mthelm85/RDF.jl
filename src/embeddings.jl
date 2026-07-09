# ── Semantic retrieval — the vector → graph entry point of the GraphRAG loop ────
#
# An EmbeddingIndex maps RDF terms to dense vectors and answers "which terms are
# nearest this query vector".  It is the missing first step of GraphRAG: embed a
# user query, find the seed entities, then hand them to the existing subgraph
# pipeline (ego_graph / cbd → to_context).
#
# Scope: the index stores and searches vectors only.  Producing the embeddings
# is the caller's job (any model), mirroring how remote contexts and Graphs.jl
# edge weights are caller-supplied.  Search is exact brute force — one pass of
# cosine similarity — which is the right cut for the in-memory AI working sets
# this package targets; approximate ANN and disk persistence are deferred.

"""
    EmbeddingIndex{T<:AbstractFloat}
    EmbeddingIndex(dim)            -> empty Float32 index of width `dim`
    EmbeddingIndex{Float64}(dim)   -> empty Float64 index
    EmbeddingIndex(pairs)          -> built from `term => vector` pairs (dim inferred)

A mapping from [`RDFTerm`](@ref)s to L2-normalized dense vectors, supporting
cosine-similarity nearest-neighbour search ([`knn`](@ref)) and one-call semantic
retrieval into prompt context ([`retrieve`](@ref)).

Entries are keyed by the term *value*, not its interned ID, so a term may be
indexed before (or without ever) being added to a graph.

```julia
idx = EmbeddingIndex(384)                     # e.g. 384-dim sentence embeddings
index!(idx, ex.alice, embed("Alice Smith"))   # embed() is your model
index!(idx, ex.acme,  embed("Acme Corp"))

knn(idx, embed("who is Alice?"); k=5)         # nearest terms + scores
retrieve(g, idx, embed("who is Alice?"))      # → prompt-ready subgraph text
```

See also [`index!`](@ref), [`knn`](@ref), [`retrieve`](@ref).
"""
struct EmbeddingIndex{T<:AbstractFloat}
    dim::Int
    terms::Vector{RDFTerm}          # terms[i] ↔ vectors[i]
    vectors::Vector{Vector{T}}      # normalized columns, aligned with `terms`
    lookup::Dict{RDFTerm,Int}       # term → position in `terms`/`vectors`
end

EmbeddingIndex{T}(dim::Integer) where {T<:AbstractFloat} =
    EmbeddingIndex{T}(Int(dim), RDFTerm[], Vector{T}[], Dict{RDFTerm,Int}())

EmbeddingIndex(dim::Integer) = EmbeddingIndex{Float32}(dim)

function EmbeddingIndex(pairs)
    ps = collect(pairs)
    isempty(ps) && throw(ArgumentError(
        "cannot infer dimension from empty pairs; use EmbeddingIndex(dim)"))
    firstvec = last(first(ps))
    T   = float(eltype(firstvec))
    dim = length(firstvec)
    idx = EmbeddingIndex{T}(dim)
    index!(idx, ps)
    idx
end

Base.length(idx::EmbeddingIndex) = length(idx.terms)
Base.haskey(idx::EmbeddingIndex, term::RDFTerm) = haskey(idx.lookup, term)
Base.in(term::RDFTerm, idx::EmbeddingIndex) = haskey(idx.lookup, term)
Base.eltype(::EmbeddingIndex{T}) where {T} = T

function Base.getindex(idx::EmbeddingIndex, term::RDFTerm)
    col = get(idx.lookup, term, 0)
    col == 0 && throw(KeyError(term))
    idx.vectors[col]
end

function Base.show(io::IO, idx::EmbeddingIndex{T}) where {T}
    print(io, "EmbeddingIndex{", T, "}(", idx.dim, "-dim, ", length(idx), " terms)")
end

# L2-normalize a fresh copy of `vec` as element type T; a zero vector is left as
# zeros (it has no direction).
function _normalized(::Type{T}, vec::AbstractVector) where {T<:AbstractFloat}
    v = Vector{T}(undef, length(vec))
    @inbounds for i in eachindex(v)
        v[i] = T(vec[i])
    end
    s = zero(T)
    @inbounds for x in v
        s += x * x
    end
    n = sqrt(s)
    if n > 0
        @inbounds for i in eachindex(v)
            v[i] /= n
        end
    end
    v
end

"""
    index!(idx, term, vec) -> idx
    index!(idx, pairs)     -> idx

Add `term` to `idx` with embedding `vec`, storing an L2-normalized copy.  Indexing
a term already present overwrites its vector (no duplicate).  The bulk form
accepts any iterable of `term => vector` pairs.  Throws `DimensionMismatch` if
`length(vec) != idx.dim`.
"""
function index!(idx::EmbeddingIndex{T}, term::RDFTerm, vec::AbstractVector) where {T}
    length(vec) == idx.dim || throw(DimensionMismatch(
        "expected a length-$(idx.dim) vector, got length $(length(vec))"))
    v   = _normalized(T, vec)
    col = get(idx.lookup, term, 0)
    if col == 0
        push!(idx.terms, term)
        push!(idx.vectors, v)
        idx.lookup[term] = length(idx.terms)
    else
        idx.vectors[col] = v
    end
    idx
end

function index!(idx::EmbeddingIndex, pairs)
    for (term, vec) in pairs
        index!(idx, term, vec)
    end
    idx
end

"""
    knn(idx, query; k=5) -> Vector{Pair{RDFTerm,Float64}}

The `k` terms in `idx` nearest `query` by cosine similarity, as `term => score`
pairs sorted by descending score (scores lie in `[-1, 1]`).  Returns all terms
when `k` exceeds the index size, and `[]` for an empty index.  Throws
`DimensionMismatch` if `length(query) != idx.dim`.
"""
function knn(idx::EmbeddingIndex, query::AbstractVector; k::Integer=5)
    length(query) == idx.dim || throw(DimensionMismatch(
        "expected a length-$(idx.dim) query, got length $(length(query))"))
    n = length(idx.terms)
    n == 0 && return Pair{RDFTerm,Float64}[]

    # Normalize the query once (in Float64) so each score is a plain dot product
    # against the already-normalized stored columns.
    q = _normalized(Float64, query)
    scores = Vector{Float64}(undef, n)
    @inbounds for j in 1:n
        v = idx.vectors[j]
        s = 0.0
        for i in 1:idx.dim
            s += q[i] * v[i]
        end
        scores[j] = s
    end

    kk    = min(Int(k), n)
    order = partialsortperm(scores, 1:kk; rev=true)
    Pair{RDFTerm,Float64}[idx.terms[j] => scores[j] for j in order]
end

"""
    retrieve(g, idx, query; k=5, hops=2, through_types=false,
             budget=2000, prefixes=Dict()) -> String

The full GraphRAG retrieval step in one call: find the `k` terms nearest `query`
([`knn`](@ref)), take the `hops`-hop neighbourhood of those seeds in `g`
([`ego_graph`](@ref)), and render it as compact, token-budgeted context
([`to_context`](@ref)).  Returns `""` when the index is empty or the seeds have
no triples in `g`.

```julia
prompt = \"\"\"
Answer using only these facts:

\$(retrieve(g, idx, embed(question); budget=1500,
            prefixes=Dict("ex" => "http://example.org/")))

Question: \$question
\"\"\"
```

See also [`knn`](@ref), [`ego_graph`](@ref), [`to_context`](@ref).
"""
function retrieve(g::Graph, idx::EmbeddingIndex, query::AbstractVector;
                  k::Integer=5, hops::Integer=2, through_types::Bool=false,
                  budget::Union{Int,Nothing}=2000,
                  prefixes::Dict{String,String}=Dict{String,String}())
    hits = knn(idx, query; k=k)
    isempty(hits) && return ""
    seeds = RDFTerm[first(h) for h in hits]
    sub   = ego_graph(g, seeds; hops=Int(hops), through_types=through_types)
    to_context(sub; budget=budget, prefixes=prefixes)
end
