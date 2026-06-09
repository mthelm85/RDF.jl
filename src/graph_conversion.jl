using SimpleWeightedGraphs: SimpleWeightedDiGraph

# ── to_digraph ────────────────────────────────────────────────────────────────
#
# Project an RDF Graph onto a Graphs.jl SimpleDiGraph, with an accompanying
# `terms` vector that maps each vertex index back to the interned term ID.
# Two overloads:
#   to_digraph(g)        — all-predicates projection (lossy: predicate labels dropped)
#   to_digraph(g, pred)  — single-predicate projection (lossless for that edge type)

"""
    to_digraph(g::Graph) -> (graph::SimpleDiGraph, terms::Vector{UInt32})

Project every triple in `g` onto a `SimpleDiGraph`.  Each unique subject or
object term becomes a vertex; each unique `(subject, object)` pair becomes a
directed edge.  Predicate labels are dropped (textbook *Projection* strategy).
Multiple predicates between the same two terms collapse to a single edge.

Returns a named tuple with:
- `graph`  — the `Graphs.SimpleDiGraph`
- `terms`  — `Vector{UInt32}` mapping vertex index → interned term ID.
  Use `resolve_term(terms[v])` to recover the `RDFTerm` for vertex `v`.

```julia
result = to_digraph(g)
pr = pagerank(result.graph)   # PageRank over all entities
top = sortperm(pr; rev=true)
println("Most central: ", resolve_term(result.terms[top[1]]))
```

See also: [`to_digraph(g, pred)`](@ref), [`to_weighted_digraph`](@ref),
[`RDFDiGraph`](@ref).
"""
function to_digraph(g::Graph)
    id_to_vtx = Dict{UInt32,Int}()
    vtx_to_id = UInt32[]
    edges_set = Set{Tuple{Int,Int}}()

    for (s_id, _p_id, o_id) in eachid(g)
        # Assign vertex indices on first encounter
        for id in (s_id, o_id)
            if !haskey(id_to_vtx, id)
                push!(vtx_to_id, id)
                id_to_vtx[id] = length(vtx_to_id)
            end
        end
        push!(edges_set, (id_to_vtx[s_id], id_to_vtx[o_id]))
    end

    n  = length(vtx_to_id)
    dg = SimpleDiGraph(n)
    for (u, v) in edges_set
        add_edge!(dg, u, v)
    end
    (graph=dg, terms=vtx_to_id)
end

"""
    to_digraph(g::Graph, pred::IRI) -> (graph::SimpleDiGraph, terms::Vector{UInt32})

Project the subset of triples in `g` whose predicate is `pred` onto a
`SimpleDiGraph`.  Only terms that appear as subjects or objects of a `pred`
triple are included as vertices.  This is a *lossless* projection for the
connectivity of that single edge type — the resulting graph records exactly
the same reachability as the original RDF triples with that predicate.

Returns the same named tuple as [`to_digraph(g)`](@ref).

```julia
# Social-network analysis using foaf:knows connectivity
result  = to_digraph(g, foaf.knows)
pr      = pagerank(result.graph)
top     = argmax(pr)
println("Most central person: ", resolve_term(result.terms[top]))
```
"""
function to_digraph(g::Graph, pred::IRI)
    p_id = get(_IRI_STR_TO_ID, pred.value, UInt32(0))
    p_id == 0 && return (graph=SimpleDiGraph(0), terms=UInt32[])

    id_to_vtx = Dict{UInt32,Int}()
    vtx_to_id = UInt32[]
    edge_pairs = Tuple{Int,Int}[]

    for (s_id, _p2, o_id) in _match_ids(g, nothing, p_id, nothing)
        for id in (s_id, o_id)
            if !haskey(id_to_vtx, id)
                push!(vtx_to_id, id)
                id_to_vtx[id] = length(vtx_to_id)
            end
        end
        push!(edge_pairs, (id_to_vtx[s_id], id_to_vtx[o_id]))
    end

    n  = length(vtx_to_id)
    dg = SimpleDiGraph(n)
    for (u, v) in edge_pairs
        add_edge!(dg, u, v)
    end
    (graph=dg, terms=vtx_to_id)
end

# ── to_weighted_digraph ───────────────────────────────────────────────────────

"""
    to_weighted_digraph(g::Graph, pred::IRI; weight::Function = _ -> 1.0)
        -> (graph::SimpleWeightedDiGraph, terms::Vector{UInt32})

Project the subset of `g`'s triples with predicate `pred` onto a
`SimpleWeightedDiGraph`.  Each edge's weight is computed by calling
`weight(object_term)` on the triple's object.

The `weight` function receives the object `RDFTerm` and must return a
`Float64`.  For graphs where objects are numeric literals, a common choice is:

```julia
weight = obj -> begin
    obj isa Literal || return 1.0
    v = tryparse(Float64, obj.lexical_form)
    v === nothing ? 1.0 : v
end
```

Returns a named tuple with:
- `graph`  — a `SimpleWeightedDiGraph{Int,Float64}`
- `terms`  — `Vector{UInt32}` mapping vertex index → interned term ID

```julia
# Dijkstra's shortest path weighted by a numeric literal property
result = to_weighted_digraph(g, ex.travelTime; weight = obj -> tryvalue(obj, Float64, Inf))
src    = vertex_id_from_terms(result.terms, ex.A)
ds     = dijkstra_shortest_paths(result.graph, src)
```

See also: [`to_digraph`](@ref), [`RDFDiGraph`](@ref).
"""
function to_weighted_digraph(g::Graph, pred::IRI; weight::Function = _ -> 1.0)
    p_id = get(_IRI_STR_TO_ID, pred.value, UInt32(0))
    if p_id == 0
        return (graph=SimpleWeightedDiGraph{Int,Float64}(0), terms=UInt32[])
    end

    id_to_vtx = Dict{UInt32,Int}()
    vtx_to_id = UInt32[]
    weighted_edges = Tuple{Int,Int,Float64}[]

    for (s_id, _p2, o_id) in _match_ids(g, nothing, p_id, nothing)
        for id in (s_id, o_id)
            if !haskey(id_to_vtx, id)
                push!(vtx_to_id, id)
                id_to_vtx[id] = length(vtx_to_id)
            end
        end
        w = Float64(weight(resolve_term(o_id)))
        push!(weighted_edges, (id_to_vtx[s_id], id_to_vtx[o_id], w))
    end

    n  = length(vtx_to_id)
    dg = SimpleWeightedDiGraph{Int,Float64}(n)
    for (u, v, w) in weighted_edges
        add_edge!(dg, u, v, w)
    end
    (graph=dg, terms=vtx_to_id)
end

# ── RDFDiGraph ────────────────────────────────────────────────────────────────
#
# A Graphs.AbstractGraph{Int} wrapper around a Graph that exposes the full
# Graphs.jl algorithm interface without discarding predicate information.
#
# Vertex topology: each unique subject/object term → one integer vertex (1-based)
# Edge topology:   each unique (subject_vtx, object_vtx) pair → one directed edge
#                  Multiple predicates between the same pair remain accessible via
#                  edge_predicates(rdfdg, u, v).
#
# Construction: O(n) single pass through eachid; adjacency lists are sorted and
# deduplicated so outneighbors/inneighbors return ordered vectors.

"""
    RDFDiGraph(g::Graph) <: Graphs.AbstractGraph{Int}

A zero-copy `AbstractGraph` wrapper around an RDF `Graph`.  Every unique
subject or object term becomes an integer vertex; every unique
`(subject, object)` pair becomes a directed edge.

Predicate information is preserved: [`edge_predicates(rdfdg, u, v)`](@ref)
returns all predicates on a given edge.  Term ↔ vertex mapping is provided by
[`vertex_id`](@ref) and [`resolve_vertex`](@ref).

The full `Graphs.jl` algorithm suite — `pagerank`, `betweenness_centrality`,
`connected_components`, `dijkstra_shortest_paths`, BFS/DFS, etc. — works
directly on `RDFDiGraph` without any additional transformation.

```julia
rdfdg   = RDFDiGraph(g)
pr      = pagerank(rdfdg)
alice_v = vertex_id(rdfdg, ex.alice)
println("Alice's PageRank: ", pr[alice_v])
println("Predicates on alice→bob: ", edge_predicates(rdfdg, alice_v, vertex_id(rdfdg, ex.bob)))
```

See also: [`to_digraph`](@ref), [`to_weighted_digraph`](@ref),
[`vertex_id`](@ref), [`term_id`](@ref), [`resolve_vertex`](@ref),
[`edge_predicates`](@ref).
"""
struct RDFDiGraph <: Graphs.AbstractGraph{Int}
    # Source RDF graph (kept for edge_predicates queries)
    rdf::Graph
    # Bijective term ↔ vertex mapping
    vtx_to_id::Vector{UInt32}        # vertex index → interned term ID
    id_to_vtx::Dict{UInt32,Int}      # interned term ID → vertex index
    # Pre-built adjacency lists (sorted, unique neighbours only)
    adj_out::Vector{Vector{Int}}     # out-neighbours per vertex
    adj_in::Vector{Vector{Int}}      # in-neighbours per vertex
    n_edges::Int                     # number of unique (src, dst) pairs
end

function RDFDiGraph(g::Graph)
    id_to_vtx = Dict{UInt32,Int}()
    vtx_to_id = UInt32[]

    # Pass 1: collect unique term IDs and assign vertex indices
    for (s_id, _p_id, o_id) in eachid(g)
        for id in (s_id, o_id)
            if !haskey(id_to_vtx, id)
                push!(vtx_to_id, id)
                id_to_vtx[id] = length(vtx_to_id)
            end
        end
    end

    n        = length(vtx_to_id)
    adj_out  = [Int[] for _ in 1:n]
    adj_in   = [Int[] for _ in 1:n]
    edge_set = Set{Tuple{Int,Int}}()

    # Pass 2: build adjacency lists (deduplicated)
    for (s_id, _p_id, o_id) in eachid(g)
        u = id_to_vtx[s_id]
        v = id_to_vtx[o_id]
        if !((u, v) in edge_set)
            push!(edge_set, (u, v))
            push!(adj_out[u], v)
            push!(adj_in[v],  u)
        end
    end

    # Sort adjacency lists for deterministic iteration
    for i in 1:n
        sort!(adj_out[i])
        sort!(adj_in[i])
    end

    RDFDiGraph(g, vtx_to_id, id_to_vtx, adj_out, adj_in, length(edge_set))
end

# ── AbstractGraph interface ───────────────────────────────────────────────────

Graphs.is_directed(::Type{RDFDiGraph}) = true
Graphs.is_directed(::RDFDiGraph)       = true

Graphs.nv(g::RDFDiGraph) = length(g.vtx_to_id)
Graphs.ne(g::RDFDiGraph) = g.n_edges

Graphs.vertices(g::RDFDiGraph) = 1:nv(g)

Graphs.has_vertex(g::RDFDiGraph, v::Int) = 1 <= v <= nv(g)

function Graphs.has_edge(g::RDFDiGraph, u::Int, v::Int)
    has_vertex(g, u) || return false
    v in g.adj_out[u]
end

Graphs.outneighbors(g::RDFDiGraph, v::Int) = g.adj_out[v]
Graphs.inneighbors(g::RDFDiGraph,  v::Int) = g.adj_in[v]

function Graphs.edges(g::RDFDiGraph)
    (Graphs.SimpleEdge{Int}(u, v)
     for u in 1:nv(g)
     for v in g.adj_out[u])
end

Base.eltype(::RDFDiGraph) = Int

# ── Term ↔ vertex accessors ───────────────────────────────────────────────────

"""
    vertex_id(rdfdg::RDFDiGraph, term::RDFTerm) -> Int

Return the vertex index for `term` in `rdfdg`, or `0` if the term is not a
vertex (i.e., it does not appear as a subject or object in the underlying
RDF graph).
"""
function vertex_id(g::RDFDiGraph, term::RDFTerm)
    # Look up the interned ID first; avoid _intern! to keep this read-only
    id = get(_type_map(term), term, UInt32(0))
    id == 0 && return 0
    get(g.id_to_vtx, id, 0)
end

"""
    term_id(rdfdg::RDFDiGraph, v::Int) -> UInt32

Return the interned term ID for vertex `v`.  Use `resolve_term(term_id(rdfdg, v))`
to recover the `RDFTerm`.
"""
term_id(g::RDFDiGraph, v::Int) = @inbounds g.vtx_to_id[v]

"""
    resolve_vertex(rdfdg::RDFDiGraph, v::Int) -> RDFTerm

Return the `RDFTerm` for vertex `v`.
"""
resolve_vertex(g::RDFDiGraph, v::Int) = resolve_term(term_id(g, v))

"""
    edge_predicates(rdfdg::RDFDiGraph, u::Int, v::Int) -> Vector{IRI}

Return every predicate IRI on the directed edge from vertex `u` to vertex `v`.
Returns an empty vector if no such edge exists.

This is the mechanism for recovering predicate information that the topology
of `RDFDiGraph` (a simple directed graph) does not encode directly.
"""
function edge_predicates(g::RDFDiGraph, u::Int, v::Int)
    (has_vertex(g, u) && has_vertex(g, v)) || return IRI[]
    s_id = g.vtx_to_id[u]
    o_id = g.vtx_to_id[v]
    preds = IRI[]
    # SOP index: scan all triples with this (subject, object) pair
    for (s2, p_id, o2) in _match_ids(g.rdf, s_id, nothing, o_id)
        push!(preds, resolve_term(p_id)::IRI)
    end
    preds
end
