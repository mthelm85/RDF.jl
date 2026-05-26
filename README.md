# RDF [![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://mthelm85.github.io/RDF.jl/stable/) [![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://mthelm85.github.io/RDF.jl/dev/) [![Build Status](https://github.com/mthelm85/RDF.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/mthelm85/RDF.jl/actions/workflows/CI.yml?query=branch%3Amain) [![Coverage](https://codecov.io/gh/mthelm85/RDF.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/mthelm85/RDF.jl)

A full-featured RDF 1.1 library for Julia with a **100% conformant SPARQL 1.1 engine** (657/657 W3C tests passing).

Graphs are backed by a hexastore index — six sorted arrays covering every (s, p, o) permutation — giving O(log n) pattern matching on any combination of subject, predicate, and object.

## Features

- **SPARQL 1.1** — SELECT, CONSTRUCT, ASK, DESCRIBE; full update language (INSERT, DELETE, LOAD, COPY, …); subqueries, aggregates, property paths, BIND, VALUES, EXISTS/NOT EXISTS, OPTIONAL, UNION, MINUS, GRAPH, FROM/FROM NAMED
- **Remote SPARQL endpoints** — `sparql(url, query)` queries any SPARQL 1.1 endpoint (Wikidata, UniProt, DBpedia, …) when HTTP.jl is loaded; same API as local queries
- **SPARQL result formats** — serialize `SolutionSet` to SPARQL/JSON, SPARQL/XML, CSV, or TSV for HTTP API integration
- **Turtle 1.1** parser and serializer
- **N-Triples / N-Quads** parser and serializer
- **JSON-LD 1.1** parser and serializer — inline contexts, prefix expansion, language-tagged literals, typed literals, named graphs, RDF list encoding
- **Named graphs / Datasets** with full SPARQL dataset semantics
- **RDFS inference** (forward-chaining closure, entailment check)
- **Graph isomorphism** (blank-node bijection)
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

```powershell
julia --project=benchmarks benchmarks/benchmarks.jl
```

See `benchmarks/benchmarks.jl` for the full suite, which covers triple insertion throughput, hexastore pattern matching, Turtle/N-Triples serialization, RDFS inference, and SPARQL query execution.

## W3C conformance

| Test suite | Passing |
|---|---|
| W3C SPARQL 1.1 (query + update) | **657 / 657** |
| W3C Turtle 1.1 | ✓ |
| W3C N-Triples | ✓ |
| W3C N-Quads | ✓ |
| W3C RDF graph isomorphism | ✓ |
| W3C JSON-LD 1.1 | ✓ |

## Citing

See [`CITATION.bib`](CITATION.bib) for the relevant reference(s).
