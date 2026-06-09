```@meta
CurrentModule = RDF
```

# Graphs & Datasets

## Graph

A `Graph` is an in-memory collection of RDF triples backed by a **hexastore
index** — six sorted arrays covering every (s, p, o) permutation. This gives
O(log n) pattern matching on any combination of bound and unbound positions
without needing a full table scan.

```@docs
Graph
```

### Adding and removing triples

```julia
g = Graph()
push!(g, Triple(ex.alice, rdf.type, ex.Person))
push!(g, Triple(ex.alice, foaf.name, Literal("Alice")))
delete!(g, Triple(ex.alice, rdf.type, ex.Person))

length(g)    # number of triples
isempty(g)   # true if the graph has no triples

Triple(ex.alice, foaf.name, Literal("Alice")) in g   # membership test
```

The `do`-block constructor lets you build a graph in one expression:

```julia
g = Graph() do g
    push!(g, Triple(ex.alice, rdf.type, ex.Person))
    push!(g, Triple(ex.alice, foaf.name, Literal("Alice")))
    push!(g, Triple(ex.bob, rdf.type, ex.Person))
end
```

### Bulk loading

```@docs
bulk_load!
```

```julia
# Much faster than push! in a loop for large collections
bulk_load!(g, triples)
```

### Pattern matching

```@docs
match
```

`match` accepts any combination of `subject`, `predicate`, and `object`
keyword arguments. Omitting an argument means "wildcard".

```julia
# All triples (full scan)
for t in match(g)
    println(t)
end

# All subjects of type Person
for t in match(g; predicate=rdf.type, object=ex.Person)
    println(t.subject)
end

# All predicates for alice
for t in match(g; subject=ex.alice)
    println(t.predicate, " => ", t.object)
end

# Single specific triple (O(log n) lookup)
results = collect(match(g; subject=ex.alice, predicate=foaf.name, object=Literal("Alice")))
```

The iterator implements the `Tables.jl` interface so match results can be
converted to a `DataFrame` directly:

```julia
using DataFrames
df = DataFrame(match(g; predicate=rdf.type))
```

### Projection helpers

```@docs
subjects
predicates
objects
```

```julia
subjects(g)    # Set{SubjectTerm}  — all distinct subjects
predicates(g)  # Set{IRI}          — all distinct predicates
objects(g)     # Set{ObjectTerm}   — all distinct objects
```

### Raw-ID iteration

For performance-critical code that needs to iterate large graphs without
constructing `Triple` structs, RDF.jl exposes two zero-allocation alternatives:

```@docs
eachid
match_ids
resolve_term
term_id
```

Both `eachid` and `match_ids` yield `NTuple{3,UInt32}` tuples of interned term
IDs.  Use [`resolve_term`](@ref) to convert an ID back to an `RDFTerm`, and
[`term_id`](@ref) to look up the ID for a term you already have.

```julia
# Iterate without allocating Triple structs
for (s_id, p_id, o_id) in eachid(g)
    println(resolve_term(s_id), " -- ", resolve_term(p_id), " --> ", resolve_term(o_id))
end

# Pattern-filtered raw-ID iteration
p_id = term_id(foaf.knows)
for (s, p, o) in match_ids(g; predicate=p_id)
    println(resolve_term(s), " knows ", resolve_term(o))
end
```

### Set operations

Standard set operations return new graphs without modifying their arguments:

```julia
g3 = union(g1, g2)      # triples in either g1 or g2
g4 = intersect(g1, g2)  # triples in both g1 and g2
g5 = setdiff(g1, g2)    # triples in g1 but not g2
issubgraph(g1, g2)       # true if every triple in g1 is also in g2
```

### Merging and skolemization

```@docs
merge!
issubgraph
skolemize
deskolemize
```

```julia
merge!(g1, g2)    # add all triples from g2 into g1 (in place)

# Replace blank nodes with IRIs scoped to a base
g_skolem = skolemize(g, "http://example.org/.well-known/genid/")
```

### Graph isomorphism

```@docs
isomorphic
```

Two graphs are isomorphic if there exists a bijection on blank nodes that makes
them identical:

```julia
isomorphic(g1, g2)   # true / false
g1 ≅ g2              # infix alias
```

### Blank nodes

```@docs
blank_nodes
```

```julia
blank_nodes(g)  # Set{BlankNode} — all blank nodes owned by g
```

---

## Dataset

A `Dataset` is an RDF dataset: a default graph plus zero or more named graphs,
each identified by an `IRI` or `BlankNode`.

```@docs
Dataset
```

```julia
ds = Dataset()
ds = Dataset(; default_graph=g)

# Named graph access (dict-like)
ds[IRI("http://example.org/g1")] = g1
g = ds[IRI("http://example.org/g1")]
haskey(ds, IRI("http://example.org/g1"))  # true
delete!(ds, IRI("http://example.org/g1"))

# Iterate named graphs
for (name, graph) in ds
    println(name, " has ", length(graph), " triples")
end

length(ds)  # number of named graphs (not counting the default graph)
```

### Dataset pattern matching

`match` on a `Dataset` returns `Quad` values instead of `Triple` values. Each
`Quad` has fields `subject`, `predicate`, `object`, and `graph`.

```julia
# Match across all named graphs
for q in match(ds; predicate=rdf.type)
    println(q.subject, " a ", q.object, " in graph ", q.graph)
end

# Restrict to a specific named graph
for q in match(ds; graph=IRI("http://example.org/g1"), predicate=rdf.type)
    println(q.subject)
end
```

### Counting triples

```@docs
ntriples
quads
```

```julia
ntriples(ds)          # total triples across all graphs (including default)
collect(quads(ds))    # lazy iterator of all Quad values including default graph
```

---

## Graphs.jl integration

RDF.jl bridges into the [Graphs.jl](https://juliagraphs.org/) ecosystem,
letting you run graph algorithms — PageRank, betweenness centrality, shortest
paths, community detection, and more — directly on RDF data.

Three conversion strategies correspond to the *Projection*, *Weighting*, and
*Customisation* approaches described in the knowledge-graph analytics
literature:

### Projection — `to_digraph`

```@docs
to_digraph
```

Drop predicate labels and project onto a `SimpleDiGraph` for topology-based
analytics:

```julia
# All-predicates reachability graph
result  = to_digraph(g)
pr      = pagerank(result.graph)
top     = argmax(pr)
println("Most central entity: ", resolve_term(result.terms[top]))

# Single-predicate lossless projection
result  = to_digraph(g, foaf.knows)
cc      = weakly_connected_components(result.graph)
println("Social network has $(length(cc)) components")
```

### Weighting — `to_weighted_digraph`

```@docs
to_weighted_digraph
```

Attach numeric edge weights derived from literal objects:

```julia
# Weight edges by a numeric literal property on the object
result = to_weighted_digraph(g, schema.distance;
             weight = obj -> tryparse(Float64, obj.lexical_form) |> something)
src    = vertex_id(result.graph, term_id(ex.A))
ds     = dijkstra_shortest_paths(result.graph, src)
```

### Customisation — `RDFDiGraph`

```@docs
RDFDiGraph
vertex_id
resolve_vertex
edge_predicates
```

`RDFDiGraph` is a full `AbstractGraph{Int}` wrapper: every Graphs.jl algorithm
accepts it without any data copy, and predicate information is preserved and
queryable per-edge:

```julia
rdfdg   = RDFDiGraph(g)

# Standard Graphs.jl algorithms
pr  = pagerank(rdfdg)
bc  = betweenness_centrality(rdfdg)
wcc = weakly_connected_components(rdfdg)

# Map results back to RDF terms
alice_v = vertex_id(rdfdg, ex.alice)
println("Alice's PageRank: ", pr[alice_v])

# Recover predicate information on an edge
bob_v   = vertex_id(rdfdg, ex.bob)
println("Alice→Bob via: ", edge_predicates(rdfdg, alice_v, bob_v))

# Resolve a vertex back to an RDFTerm
println(resolve_vertex(rdfdg, argmax(pr)))
```

---

## Triples and Quads

```@docs
Triple
Quad
GeneralizedTriple
TriplePattern
```

A `Triple` holds `subject::SubjectTerm`, `predicate::IRI`, `object::ObjectTerm`.
A `Quad` extends this with `graph::GraphName`.

`TriplePattern` is used internally by SPARQL — it allows variables (`nothing`)
in any position.
