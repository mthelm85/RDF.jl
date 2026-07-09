```@meta
CurrentModule = RDF
```

# RDF.jl

A full-featured **RDF 1.2** library for Julia with a conformant **SPARQL 1.1 and
1.2** engine (657/657 SPARQL 1.1 and 263/263 SPARQL 1.2 W3C tests passing),
including full RDF-star support — triple terms, reified triples, annotation
syntax, and directional language tags.

Graphs are backed by a **hexastore index** — six sorted arrays covering every
(s, p, o) permutation — giving O(log n) pattern matching on any combination of
subject, predicate, and object.

## Features

- **SPARQL 1.1 + 1.2** — SELECT, CONSTRUCT, ASK, DESCRIBE; full update language
  (INSERT, DELETE, LOAD, COPY, …); subqueries, aggregates, property paths,
  BIND, VALUES, EXISTS/NOT EXISTS, OPTIONAL, UNION, MINUS, GRAPH, FROM/FROM NAMED,
  SERVICE; plus RDF-star triple terms, reified triples, and annotation blocks
- **Cost-based query optimization** — basic graph patterns are reordered
  automatically using exact O(log n) hexastore cardinalities
- **Remote SPARQL endpoints** — `sparql(url, query)`, `SERVICE` federation, and
  `RemoteGraph` when HTTP.jl is loaded
- **Turtle 1.2 / N-Triples / N-Quads** — parsers and serializers
- **JSON-LD 1.1** — parser and serializer, inline and remote contexts
- **SPARQL result formats** — SPARQL/JSON, SPARQL/XML, CSV, TSV serialization
- **AI / GraphRAG primitives** — RDF-star fact annotation (`annotate!` /
  `annotations`), subgraph extraction (`cbd` / `ego_graph`), token-budgeted LLM
  context (`to_context`), and schema introspection for text-to-SPARQL
  (`describe_schema` / `to_prompt`)
- **Semantic retrieval** — an `EmbeddingIndex` maps terms to embedding vectors
  and finds the nearest to a query vector (`knn`); `retrieve` runs the whole
  GraphRAG loop — query vector → nearest entities → subgraph → context — in one call
- **SHACL Core validation** — `validate_shapes` / `conforms`; doubles as an
  LLM-extraction guardrail (`conforming` keeps only valid facts)
- **Named graphs / Datasets** — full SPARQL dataset semantics
- **RDFS inference** — forward-chaining closure, entailment check
- **Graph isomorphism** — blank-node bijection
- **Graphs.jl integration** — convert to `SimpleDiGraph`,
  `SimpleWeightedDiGraph`, or `RDFDiGraph` and run PageRank, centrality,
  shortest paths, community detection, and any other Graphs.jl algorithm
- **Tables.jl integration** — match results and `SolutionSet` work directly
  with DataFrames and any Tables.jl consumer
- **Vocabulary API** — load any external ontology or namespace as a
  `Vocabulary` with dot-notation term access (`vocab.BachelorDegree`),
  `rdfs:label` / `rdfs:comment` metadata, and HTTP loading via HTTP.jl
- Built-in vocabulary modules: `rdf`, `rdfs`, `xsd`, `owl`, `skos`, `dc`,
  `dcterms`, `foaf`, `schema`

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
push!(g, Triple(ex.alice, foaf.name, Literal("Alice")))
push!(g, Triple(ex.alice, foaf.age,  Literal(30)))
push!(g, Triple(ex.bob,   rdf.type,  ex.Person))
push!(g, Triple(ex.bob,   foaf.name, Literal("Bob")))

# Pattern matching — any combination of subject/predicate/object
for t in match(g; predicate=rdf.type, object=ex.Person)
    println(t.subject)
end

# Coerce a literal to a Julia value
age_lit = first(match(g; subject=ex.alice, predicate=foaf.age)).object
value(Int64, age_lit)  # => 30
```

### SPARQL queries

```julia
result = sparql(Dataset(; default_graph=g), """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  SELECT ?name ?age WHERE {
    ?person foaf:name ?name ;
            foaf:age  ?age .
    FILTER(?age > 26)
  } ORDER BY ?name
""")

for row in result
    println(row[:name], " — age ", row[:age])
end
# "Alice" — age 30
```

### Named graphs / Datasets

```julia
ds = Dataset()
ds[IRI("http://example.org/graph1")] = g

result = sparql(ds, """
  SELECT ?g ?s WHERE { GRAPH ?g { ?s a <http://example.org/Person> } }
""")
```

### Serialization

```julia
# Turtle (parse + write)
g = read("data.ttl", MIME"text/turtle"(), Graph)
write(io, MIME"text/turtle"(), g)

# JSON-LD (parse + write)
g = read("data.jsonld", MIME"application/ld+json"(), Graph)
write(io, MIME"application/ld+json"(), g)

# N-Triples / N-Quads
write(io, MIME"application/n-triples"(), g)
write(io, MIME"application/n-quads"(), ds)

# Convenience: dispatch on file extension (.ttl / .nt / .nq / .jsonld)
rdf_write("data.nt", g)
g = rdf_read("data.ttl")
```

### SPARQL result serialization

```julia
result = sparql(ds, "SELECT * WHERE { ?s ?p ?o }")

# SPARQL/JSON (for HTTP APIs)
write(io, MIME"application/sparql-results+json"(), result)

# SPARQL/XML
write(io, MIME"application/sparql-results+xml"(), result)

# CSV / TSV
write(io, MIME"text/csv"(), result)
write(io, MIME"text/tab-separated-values"(), result)
```

### RDFS inference

```julia
infer_rdfs(g)   # returns a new graph with the RDFS closure
infer_rdfs!(g)  # closes g in place
entails(g, Triple(ex.alice, rdf.type, ex.Animal))
```

### Tables.jl integration

Match results and SPARQL `SolutionSet`s implement the Tables.jl interface with automatic
coercion to native Julia types:

| RDF type | Julia column type |
|---|---|
| `IRI` | `String` (full URI) |
| `BlankNode` | `String` (`"_:b{id}"`) |
| `xsd:integer` and sub-types | `Int64` |
| `xsd:double` / `xsd:float` / `xsd:decimal` | `Float64` |
| `xsd:boolean` | `Bool` |
| `xsd:date` | `Dates.Date` |
| `xsd:dateTime` | `Dates.DateTime` |
| `xsd:string`, `rdf:langString`, other literals | `String` (lexical form) |
| Unbound OPTIONAL variable | `missing` |
| Heterogeneous column | `String` |

```julia
using DataFrames

# match → DataFrame
df = DataFrame(match(g; predicate=rdf.type))
# subject, predicate, object columns are all String

# SPARQL SELECT → DataFrame with typed columns
df = DataFrame(sparql(ds, """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  SELECT ?name ?age WHERE { ?s foaf:name ?name ; foaf:age ?age }
"""))
# name::String, age::Int64 — ready for analysis
```

### Vocabulary API

Load any external ontology or namespace and access its terms by name:

```julia
using RDF, HTTP

# Load CTDL from Credential Engine (any Turtle / N-Triples / JSON-LD URL works)
ctdl = load_vocabulary("https://credreg.net/ctdl/schema/encoding/turtle";
                        base="http://purl.org/ctdl/terms/")

ctdl.BachelorDegree              # => IRI("http://purl.org/ctdl/terms/BachelorDegree")
label(ctdl, ctdl.Course)         # => "Course"
comment(ctdl, ctdl.estimatedCost)

# Use directly in a SPARQL query
sparql(ds, """
  SELECT ?cred WHERE { ?cred a <$(ctdl.BachelorDegree)> . }
""")

# From a local file
go = load_vocabulary("go.ttl"; base="http://purl.obolibrary.org/obo/")
```

See the [Vocabulary API](vocabulary.md) page for the full reference.

## Built-in vocabularies

```julia
rdf.type          # IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
rdfs.subClassOf   # IRI("http://www.w3.org/2000/01/rdf-schema#subClassOf")
xsd.integer       # IRI("http://www.w3.org/2001/XMLSchema#integer")
owl.sameAs        # IRI("http://www.w3.org/2002/07/owl#sameAs")
foaf.name         # IRI("http://xmlns.com/foaf/0.1/name")
schema.Person     # IRI("https://schema.org/Person")
```
