```@meta
CurrentModule = RDF
```

# RDF.jl

An RDF 1.2 library for Julia. Graphs are backed by a hexastore index for fast
pattern matching on any combination of subject, predicate, and object.

## Installation

```julia
pkg> add RDF
```

## Quick start

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
for t in match(g, predicate=rdf.type, object=ex.Person)
    println(t.subject)
end

# Coerce a literal to a Julia value
age_lit = first(match(g, subject=ex.alice, predicate=ex.age)).object
value(Int64, age_lit)  # => 30
```

## Datasets (named graphs)

```julia
ds = Dataset()
ds[IRI("http://example.org/graph1")] = g

for q in match(ds, predicate=rdf.type)
    println(q.subject, " in ", q.graph)
end
```

## Serialization

```julia
# N-Triples
write(io, MIME"application/n-triples"(), g)
read(io, MIME"application/n-triples"(), Graph)

# N-Quads
write(io, MIME"application/n-quads"(), ds)
read(io, MIME"application/n-quads"(), Dataset)

# By file path
write("data.nt", g)
g = read("data.nt", Graph)
```

## RDFS inference

```julia
infer_rdfs(g)   # returns a new graph with the RDFS closure
infer_rdfs!(g)  # closes g in place
entails(g, Triple(ex.alice, rdf.type, ex.Animal))
```

## Tables.jl integration

Match results implement the Tables.jl row interface, so they work directly with
DataFrames and any other Tables.jl consumer.

```julia
using DataFrames
df = DataFrame(match(g, predicate=rdf.type))
```

## Built-in vocabularies

Prefix modules for common namespaces: `rdf`, `rdfs`, `xsd`, `owl`, `skos`,
`dc`, `dcterms`, `foaf`, `schema`.

```julia
rdf.type         # IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
xsd.integer      # IRI("http://www.w3.org/2001/XMLSchema#integer")
rdfs.subClassOf  # IRI("http://www.w3.org/2000/01/rdf-schema#subClassOf")
```
