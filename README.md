# RDF [![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://mthelm85.github.io/RDF.jl/stable/) [![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://mthelm85.github.io/RDF.jl/dev/) [![Build Status](https://github.com/mthelm85/RDF.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/mthelm85/RDF.jl/actions/workflows/CI.yml?query=branch%3Amain) [![Coverage](https://codecov.io/gh/mthelm85/RDF.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/mthelm85/RDF.jl)

A full-featured RDF 1.2 library for Julia with a **conformant SPARQL 1.1 and 1.2 engine** (657/657 SPARQL 1.1 and 263/263 SPARQL 1.2 W3C tests passing), including full RDF-star / RDF 1.2 support — triple terms, reified triples, annotation syntax, and directional language tags — across Turtle, N-Triples, N-Quads, and SPARQL.

Graphs are backed by a hexastore index — six sorted arrays covering every (s, p, o) permutation — giving O(log n) pattern matching on any combination of subject, predicate, and object.

## Features

- **SPARQL 1.1 + 1.2** — SELECT, CONSTRUCT, ASK, DESCRIBE; full update language (INSERT, DELETE, LOAD, COPY, …); subqueries, aggregates, property paths, BIND, VALUES, EXISTS/NOT EXISTS, OPTIONAL, UNION, MINUS, GRAPH, FROM/FROM NAMED, SERVICE; plus RDF-star — triple terms, reified triples, annotation blocks, `TRIPLE`/`isTRIPLE`/`SUBJECT`/`PREDICATE`/`OBJECT`, and directional-language-tag builtins
- **Cost-based query optimization** — basic graph patterns are automatically reordered using exact O(log n) hexastore cardinalities, so pattern order in your query never matters for performance
- **Remote SPARQL endpoints** — `sparql(url, query)` queries any SPARQL 1.1 endpoint (Wikidata, UniProt, DBpedia, …) when HTTP.jl is loaded; `SERVICE` federates local and remote data in one query; `RemoteGraph` wraps an endpoint in the Graph API
- **SPARQL result formats** — serialize `SolutionSet` to SPARQL/JSON, SPARQL/XML, CSV, or TSV (with RDF-star triple-term bindings) for HTTP API integration
- **Turtle 1.2** parser and serializer — including triple terms, reified triples, reifiers, annotation blocks, and directional language tags
- **N-Triples / N-Quads 1.2** parser and serializer
- **JSON-LD 1.1** parser and serializer — inline and remote contexts (caller-supplied `contexts=` map, or `load_remote_contexts=true` to fetch over HTTP), prefix expansion, language-tagged literals, typed literals, named graphs, RDF list encoding
- **AI / GraphRAG primitives** — annotate individual triples with confidence/provenance via RDF-star (`annotate!`/`annotations`), extract focused subgraphs (`cbd`, `ego_graph`), render them as token-budgeted LLM context (`to_context`), and summarize a graph's schema for text-to-SPARQL prompting (`describe_schema`/`to_prompt`)
- **SHACL Core validation** — validate a data graph against shapes (`validate_shapes`/`conforms`); doubles as an LLM-extraction guardrail (`conforming` keeps only valid facts; `to_prompt(report)` renders violations for model self-correction)
- **Named graphs / Datasets** with full SPARQL dataset semantics
- **RDFS inference** (forward-chaining closure, entailment check)
- **Graph isomorphism** (blank-node bijection)
- **Graphs.jl integration** — convert any RDF graph to a `SimpleDiGraph`, `SimpleWeightedDiGraph`, or full `RDFDiGraph <: AbstractGraph`; run PageRank, betweenness centrality, shortest paths, community detection, and any other Graphs.jl algorithm directly on RDF data
- **Tables.jl integration** — match results and `SolutionSet` work directly with DataFrames and any Tables consumer
- **Vocabulary API** — load any external ontology as a `Vocabulary` with dot-notation term access, `rdfs:label`/`rdfs:comment` metadata, and HTTP loading via HTTP.jl
- Built-in vocabulary modules: `rdf`, `rdfs`, `xsd`, `owl`, `skos`, `dc`, `dcterms`, `foaf`, `schema`

## Installation

```julia
pkg> add RDF
```

## Quick start

### Building a graph

```julia
using RDF

ex = Namespace("http://example.org/")

g = Graph()
push!(g, Triple(ex.alice, rdf.type,  ex.Person))
push!(g, Triple(ex.alice, ex.name,   Literal("Alice")))
push!(g, Triple(ex.alice, ex.age,    Literal(30)))
push!(g, Triple(ex.bob,   rdf.type,  ex.Person))
push!(g, Triple(ex.bob,   ex.name,   Literal("Bob")))

# Pattern matching — any combination of subject/predicate/object
for t in match(g; predicate=rdf.type, object=ex.Person)
    println(t.subject)
end

# Coerce a literal to a Julia value
age_lit = first(match(g; subject=ex.alice, predicate=ex.age)).object
value(age_lit)           # => 30  (Int64 — inferred from xsd:integer)
value(Int64,   age_lit)  # => 30
value(Float64, age_lit)  # => 30.0  (numeric widening via convert)
tryvalue(Float64, age_lit)  # => 30.0  (returns nothing instead of throwing)

# Set operations
g2 = Graph()
push!(g2, Triple(ex.carol, rdf.type, ex.Person))
union(g, g2)
intersect(g, g2)
setdiff(g, g2)
```

### SPARQL queries

```julia
using RDF

ttl = """
  PREFIX ex: <http://example.org/>
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>

  ex:alice foaf:name "Alice" ; foaf:age 30 ; foaf:knows ex:bob .
  ex:bob   foaf:name "Bob"   ; foaf:age 25 .
"""

ds = Dataset(; default_graph=read(IOBuffer(ttl), MIME"text/turtle"(), Graph))

# SELECT
result = sparql(ds, """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  SELECT ?name ?age WHERE {
    ?person foaf:name ?name ;
            foaf:age  ?age .
    FILTER(?age > 26)
  } ORDER BY ?name
""")

for row in result
    println(row[:name], " is ", row[:age])
end
# "Alice" is 30

# ASK
sparql(ds, "PREFIX foaf: <http://xmlns.com/foaf/0.1/> ASK { ?s foaf:age 30 }")
# => true

# CONSTRUCT
g2 = sparql(ds, """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  CONSTRUCT { ?s foaf:name ?n } WHERE { ?s foaf:name ?n }
""")
```

### SPARQL aggregates, subqueries, and property paths

```julia
# Aggregate: count people per age group
result = sparql(ds, """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  SELECT ?age (COUNT(?person) AS ?n) WHERE {
    ?person foaf:age ?age
  } GROUP BY ?age ORDER BY DESC(?n)
""")

# Property path: find everyone reachable via foaf:knows*
result = sparql(ds, """
  PREFIX ex:   <http://example.org/>
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  SELECT ?friend WHERE { ex:alice foaf:knows* ?friend }
""")

# Subquery with LIMIT
result = sparql(ds, """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  SELECT ?name WHERE {
    { SELECT ?person WHERE { ?person a foaf:Person } ORDER BY ?person LIMIT 5 }
    ?person foaf:name ?name
  }
""")
```

### Remote SPARQL endpoints

Load HTTP.jl and the same `sparql` function queries any remote SPARQL 1.1 endpoint:

```julia
using RDF, HTTP

# Pull chemical elements from Wikidata
results = sparql("https://query.wikidata.org/sparql", """
  PREFIX wd:   <http://www.wikidata.org/entity/>
  PREFIX wdt:  <http://www.wikidata.org/prop/direct/>
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
  SELECT ?element ?name WHERE {
    ?element wdt:P31 wd:Q11344 ;
             rdfs:label ?name .
    FILTER(LANG(?name) = "en")
  } ORDER BY ?name LIMIT 20
""")

# Directly into a DataFrame
using DataFrames
df = DataFrame(results)

# UniProt proteins for a given taxon
sparql("https://sparql.uniprot.org/sparql", """
  PREFIX up:  <http://purl.uniprot.org/core/>
  PREFIX taxon: <http://purl.uniprot.org/taxonomy/>
  SELECT ?protein ?name WHERE {
    ?protein a up:Protein ;
             up:organism taxon:9606 ;
             up:recommendedName/up:fullName ?name .
  } LIMIT 50
""")

# Auth, timeouts, and retry are all keyword arguments
sparql("https://private.endpoint.example/sparql", query;
       auth    = ("user", "pass"),   # or auth="bearer-token"
       timeout = 120,
       retries = 3)
```

### Federated queries and RemoteGraph

The SPARQL 1.1 `SERVICE` clause joins local data with remote endpoints, and
`RemoteGraph` exposes an endpoint through the familiar Graph API — the data
never has to fit in local memory:

```julia
using RDF, HTTP

# SERVICE: join local triples with Wikidata inside one query
result = sparql(local_graph, """
  PREFIX wdt: <http://www.wikidata.org/prop/direct/>
  PREFIX ex:  <http://example.org/>
  SELECT ?city ?population WHERE {
    ?city ex:officeLocation true .              # local
    SERVICE <https://query.wikidata.org/sparql> {
      ?city wdt:P1082 ?population               # remote
    }
  }
""")

# RemoteGraph: match / in / length / sparql against a remote endpoint
wd = RemoteGraph("https://query.wikidata.org/sparql")
match(wd; subject=IRI("http://www.wikidata.org/entity/Q42"),
          predicate=IRI("http://www.wikidata.org/prop/direct/P31"))
```

### SPARQL UPDATE

```julia
sparql_update!(ds, """
  PREFIX ex:   <http://example.org/>
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  INSERT DATA { ex:carol foaf:name "Carol" ; foaf:age 28 }
""")

sparql_update!(ds, """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  DELETE { ?s foaf:age ?old }
  INSERT { ?s foaf:age ?new }
  WHERE  { ?s foaf:name "Alice" ; foaf:age ?old . BIND(?old + 1 AS ?new) }
""")
```

### Named graphs / Datasets

```julia
ds = Dataset()
ds[IRI("http://example.org/graph1")] = g

# Query across all named graphs
result = sparql(ds, """
  SELECT ?g ?s WHERE { GRAPH ?g { ?s a <http://example.org/Person> } }
""")

# Low-level pattern match across graphs
for q in match(ds; predicate=rdf.type)
    println(q.subject, " in ", q.graph)
end
```

### Serialization

```julia
# Turtle (parse + write)
g = read("data.ttl", MIME"text/turtle"(), Graph)
g = read("data.ttl", MIME"text/turtle"(), Graph, "http://base-uri.example/")
write(io, MIME"text/turtle"(), g)

# N-Triples / N-Quads
write(io, MIME"application/n-triples"(), g)
g = read(io, MIME"application/n-triples"(), Graph)
write(io, MIME"application/n-quads"(), ds)
ds = read(io, MIME"application/n-quads"(), Dataset)

# JSON-LD (parse + write)
g = read(io, MIME"application/ld+json"(), Graph)
ds = read(io, MIME"application/ld+json"(), Dataset)
write(io, MIME"application/ld+json"(), g)
write(io, MIME"application/ld+json"(), g; context=Dict("@vocab" => "http://schema.org/"))

# Convenience: dispatch on file extension (.ttl / .nt / .nq / .jsonld)
rdf_write("data.nt", g)
g = rdf_read("data.ttl")
g = rdf_read("data.jsonld")
```

### SPARQL result serialization

```julia
result = sparql(ds, "SELECT * WHERE { ?s ?p ?o }")

# W3C standard wire formats — ready for HTTP API responses
write(io, MIME"application/sparql-results+json"(), result)  # SPARQL/JSON
write(io, MIME"application/sparql-results+xml"(),  result)  # SPARQL/XML
write(io, MIME"text/csv"(),                        result)  # CSV
write(io, MIME"text/tab-separated-values"(),       result)  # TSV

# ASK results
write(io, MIME"application/sparql-results+json"(), sparql(ds, "ASK { ?s ?p ?o }"))
```

### RDFS inference

```julia
infer_rdfs(g)    # returns a new graph with the RDFS closure
infer_rdfs!(g)   # closes g in place
entails(g, Triple(ex.alice, rdf.type, ex.Animal))
```

### AI / GraphRAG: annotated facts and prompt grounding

Store LLM-extracted facts with their extraction metadata (RDF-star, RDF 1.2
reification — round-trips through every serializer), then ground prompts in
focused, token-budgeted subgraphs:

```julia
# Extraction side: a fact plus its metadata
t = Triple(ex.alice, ex.employer, ex.acme)
annotate!(g, t; confidence=0.92, source=ex.doc42, model=Literal("claude-fable-5"))

# Guardrail: keep only high-confidence facts
confs = annotations(g, t, anno.confidence)
all(value(Float64, c) >= 0.9 for c in confs)   # true

# Retrieval side: seeds → subgraph → token-budgeted prompt context
sub = ego_graph(g, [ex.alice]; hops=2)         # k-hop neighbourhood
ctx = to_context(sub; budget=2000,             # ≈ tokens; most-connected first
                 prefixes=Dict("ex" => "http://example.org/"))

profile = cbd(g, ex.alice)                      # everything about one entity,
                                                # annotations included
```

### Graphs.jl integration

Convert an RDF graph to a Graphs.jl graph and run any algorithm from that ecosystem.
Three strategies, following knowledge-graph analytics conventions:

```julia
using RDF, Graphs, SimpleWeightedGraphs

ex   = Namespace("http://example.org/")
foaf = Namespace("http://xmlns.com/foaf/0.1/")

# ── Projection ─────────────────────────────────────────────────────────────
# Drop predicate labels; get a SimpleDiGraph for topology-based analytics.

result = to_digraph(g, foaf.knows)          # single-predicate (lossless)
pr     = pagerank(result.graph)
top    = argmax(pr)
println("Most influential: ", resolve_term(result.terms[top]))

result = to_digraph(g)                      # all predicates (topology only)
weakly_connected_components(result.graph)

# ── Weighting ──────────────────────────────────────────────────────────────
# Attach numeric edge weights derived from literal objects.

result = to_weighted_digraph(g, schema.distance;
             weight = obj -> tryparse(Float64, obj.lexical_form) |> something)
src    = findfirst(id -> resolve_term(id) == ex.A, result.terms)
ds     = dijkstra_shortest_paths(result.graph, src)

# ── Customisation — RDFDiGraph ─────────────────────────────────────────────
# Full AbstractGraph{Int} wrapper: all Graphs.jl algorithms work directly;
# predicate information is preserved and queryable per edge.

rdfdg   = RDFDiGraph(g)
pr      = pagerank(rdfdg)
bc      = betweenness_centrality(rdfdg)
wcc     = weakly_connected_components(rdfdg)

# Map vertex indices back to RDF terms
alice_v = vertex_id(rdfdg, ex.alice)
println("Alice's PageRank: ", pr[alice_v])
println("Alice→Bob via: ", edge_predicates(rdfdg, alice_v, vertex_id(rdfdg, ex.bob)))

# Raw-ID iteration (zero allocations — no Triple struct construction)
for (s_id, p_id, o_id) in eachid(g)
    println(resolve_term(s_id), " -- ", resolve_term(p_id), " --> ", resolve_term(o_id))
end

# Pattern-filtered raw-ID iteration
p_id = term_id(foaf.knows)
for (s, _, o) in match_ids(g; predicate=p_id)
    println(resolve_term(s), " knows ", resolve_term(o))
end
```

### Tables.jl integration

Match results and SPARQL `SolutionSet`s both implement the Tables.jl interface.
RDF terms are automatically coerced to native Julia types — no manual unwrapping needed:

| RDF type | Julia column type |
|---|---|
| `IRI` | `String` (full URI) |
| `BlankNode` | `String` (`"_:b{id}"`) |
| `xsd:integer` (and sub-types) | `Int64` |
| `xsd:double` / `xsd:float` / `xsd:decimal` | `Float64` |
| `xsd:boolean` | `Bool` |
| `xsd:date` | `Dates.Date` |
| `xsd:dateTime` | `Dates.DateTime` |
| `xsd:string`, `rdf:langString`, other literals | `String` (lexical form) |
| Unbound OPTIONAL variable | `missing` |
| Heterogeneous column | `String` (lowest common denominator) |

```julia
using DataFrames

ex   = Namespace("http://example.org/")
foaf = Namespace("http://xmlns.com/foaf/0.1/")

g = Graph() do g
    push!(g, Triple(ex.susan, rdf.type,  ex.Person))
    push!(g, Triple(ex.susan, foaf.name, Literal("Susan")))
    push!(g, Triple(ex.susan, foaf.age,  Literal(30)))
    push!(g, Triple(ex.bill,  rdf.type,  ex.Person))
end

# match → DataFrame: all columns are plain Julia types
df = DataFrame(match(g; predicate=rdf.type))
# 2×3 DataFrame
#  subject                          predicate                                            object
#  String                           String                                               String
# ─────────────────────────────────────────────────────────────────────────────────────────────
#  "http://example.org/susan"       "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"   "http://example.org/Person"
#  "http://example.org/bill"        "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"   "http://example.org/Person"

# SPARQL SELECT → DataFrame: columns typed by their XSD datatype
ds  = Dataset(; default_graph=g)
df2 = DataFrame(sparql(ds, """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  SELECT ?name ?age WHERE { ?s foaf:name ?name ; foaf:age ?age }
"""))
# 1×2 DataFrame
#  name      age
#  String    Int64
# ──────────────
#  "Susan"   30
```

### Vocabulary API

Load any external ontology or namespace and access its terms by name:

```julia
using RDF, HTTP

# Load from a remote URL (any Turtle / N-Triples / JSON-LD endpoint)
ctdl = load_vocabulary("https://credreg.net/ctdl/schema/encoding/turtle";
                        base="http://purl.org/ctdl/terms/")

ctdl.BachelorDegree              # => IRI("http://purl.org/ctdl/terms/BachelorDegree")
label(ctdl, ctdl.Course)         # => "Course"
comment(ctdl, ctdl.estimatedCost)

# Iterate all indexed terms
for iri in terms(ctdl)
    println(label(ctdl, iri), "  =>  ", iri)
end

# Use directly in SPARQL
sparql(ds, """
  SELECT ?cred WHERE { ?cred a <$(ctdl.BachelorDegree)> . }
""")

# From a local file
go = load_vocabulary("go.ttl"; base="http://purl.obolibrary.org/obo/")

# From an existing Graph
v = Vocabulary(g; base="http://example.org/onto/")
```

## Built-in vocabularies

```julia
rdf.type          # IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
rdfs.subClassOf   # IRI("http://www.w3.org/2000/01/rdf-schema#subClassOf")
xsd.integer       # IRI("http://www.w3.org/2001/XMLSchema#integer")
owl.sameAs        # IRI("http://www.w3.org/2002/07/owl#sameAs")
foaf.name         # IRI("http://xmlns.com/foaf/0.1/name")
schema.Person     # IRI("https://schema.org/Person")
```

## Benchmarks

Run the included benchmark suite with:

```julia
julia --project=benchmarks benchmarks/benchmarks.jl
```

See `benchmarks/benchmarks.jl` for the full suite, which covers term interning, triple insertion (`push!` and `bulk_load!`), hexastore pattern matching, raw-ID iteration (`eachid`), all serialization formats (read and write, up to 100k triples), SPARQL parsing/evaluation/updates, inference, and validation.

To track regressions, save a baseline and compare against it later:

```julia
julia --project=benchmarks benchmarks/benchmarks.jl --save=baseline.json
julia --project=benchmarks benchmarks/benchmarks.jl --compare=baseline.json
```

## W3C conformance

| Test suite | Passing |
|---|---|
| W3C SPARQL 1.1 (query + update) | **657 / 657** |
| W3C Turtle 1.1 | ✓ |
| W3C N-Triples | ✓ |
| W3C N-Quads | ✓ |
| W3C RDF graph isomorphism | ✓ |
| W3C JSON-LD 1.1 (toRdf) | **412 / 459** (in progress) |
| W3C JSON-LD 1.1 (fromRdf) | **49 / 51** (round-trip) |

## Citing

See [`CITATION.bib`](CITATION.bib) for the relevant reference(s).
