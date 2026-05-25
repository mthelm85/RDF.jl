```@meta
CurrentModule = RDF
```

# RDF.jl

A full-featured RDF 1.1 library for Julia.

Graphs are backed by a **hexastore index** — six sorted arrays covering every
(s, p, o) permutation — giving O(log n) pattern matching on any combination of
subject, predicate, and object. The SPARQL 1.1 engine is 100% W3C conformant
(657/657 tests passing).

## Features

- **SPARQL 1.1** — SELECT, CONSTRUCT, ASK, DESCRIBE; full update language
  (INSERT, DELETE, LOAD, COPY, …); subqueries, aggregates, property paths,
  BIND, VALUES, EXISTS/NOT EXISTS, OPTIONAL, UNION, MINUS, GRAPH, FROM/FROM NAMED
- **Turtle 1.1** — parser and serializer
- **N-Triples / N-Quads** — parser and serializer
- **JSON-LD 1.1** — parser and serializer with inline context support
- **SPARQL result formats** — SPARQL/JSON, SPARQL/XML, CSV, TSV serialization
- **Named graphs / Datasets** — full SPARQL dataset semantics
- **RDFS inference** — forward-chaining closure, entailment check
- **Graph isomorphism** — blank-node bijection
- **Tables.jl integration** — match results and `SolutionSet` work directly
  with DataFrames and any Tables.jl consumer
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

```julia
using DataFrames
df = DataFrame(match(g; predicate=rdf.type))
df = DataFrame(sparql(ds, "SELECT * WHERE { ?s ?p ?o }"))
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
