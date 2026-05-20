# RDF [![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://mthelm85.github.io/RDF.jl/stable/) [![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://mthelm85.github.io/RDF.jl/dev/) [![Build Status](https://github.com/mthelm85/RDF.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/mthelm85/RDF.jl/actions/workflows/CI.yml?query=branch%3Amain) [![Coverage](https://codecov.io/gh/mthelm85/RDF.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/mthelm85/RDF.jl) [![Aqua](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/main/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

An RDF 1.1 library for Julia. Graphs are backed by a hexastore index for fast pattern matching on any combination of subject, predicate, and object.

## Installation

```julia
pkg> add RDF
```

## Usage

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

# Literal coercion
age_lit = first(match(g, subject=ex.alice, predicate=ex.age)).object
value(Int64, age_lit)  # => 30

# Set operations
g2 = Graph()
push!(g2, Triple(ex.carol, rdf.type, ex.Person))
union(g, g2)
intersect(g, g2)
setdiff(g, g2)
```

### Datasets (named graphs)

```julia
ds = Dataset()
ds[IRI("http://example.org/graph1")] = g

for q in match(ds, predicate=rdf.type)
    println(q.subject, " in ", q.graph)
end
```

### Serialization

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

### RDFS Inference

```julia
infer_rdfs(g)   # returns a new closed graph
infer_rdfs!(g)  # closes g in place
entails(g, Triple(ex.alice, rdf.type, ex.Animal))
```

### Tables.jl integration

Match results implement the Tables.jl interface, so they work directly with DataFrames and any other Tables consumer.

```julia
using DataFrames
df = DataFrame(match(g, predicate=rdf.type))
```

## Vocabularies

Built-in prefix modules: `rdf`, `rdfs`, `xsd`, `owl`, `skos`, `dc`, `dcterms`, `foaf`, `schema`.

```julia
rdf.type
xsd.integer
rdfs.subClassOf
```

## Citing

See [`CITATION.bib`](CITATION.bib) for the relevant reference(s).
