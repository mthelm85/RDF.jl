```@meta
CurrentModule = RDF
```

# Serialization

RDF.jl uses Julia's standard `Base.read` / `Base.write` API with MIME types to
dispatch between formats. All parsers and serializers work with `IO` streams;
`rdf_read` and `rdf_write` add file-extension–based dispatch.

## Supported formats

| Format | MIME type | Extension | Read | Write |
|---|---|---|---|---|
| N-Triples 1.2 | `application/n-triples` | `.nt` | ✅ | ✅ |
| N-Quads 1.2 | `application/n-quads` | `.nq` | ✅ | ✅ |
| Turtle 1.2 | `text/turtle` | `.ttl` | ✅ | ✅ |
| JSON-LD 1.1 | `application/ld+json` | `.jsonld` | ✅ | ✅ |

The N-Triples, N-Quads, and Turtle parsers support RDF 1.2 / RDF-star: triple
terms `<<( s p o )>>`, reified triples `<< s p o >>` with optional reifiers
(`~`), annotation blocks (`{| … |}`, Turtle), directional language tags
(`"x"@en--ltr`), and the `@version` / `VERSION` directive. All RDF 1.2 W3C
N-Triples, N-Quads, and Turtle test suites pass.

## N-Triples

```julia
# Write a Graph to N-Triples
write(io, MIME"application/n-triples"(), g)

# Read a Graph from N-Triples
g = read(io, MIME"application/n-triples"(), Graph)

# Streaming parse (low allocation)
parse_triples(io, MIME"application/n-triples"()) do triple
    process(triple)
end
```

## N-Quads

```julia
# Write a Dataset to N-Quads
write(io, MIME"application/n-quads"(), ds)

# Read a Dataset from N-Quads
ds = read(io, MIME"application/n-quads"(), Dataset)
```

## Turtle

```julia
# Write a Graph to Turtle (with optional namespace prefixes)
write(io, MIME"text/turtle"(), g)

# Read a Graph from Turtle
g = read(io, MIME"text/turtle"(), Graph)

# Read with an explicit base IRI for resolving relative IRIs
g = read(io, MIME"text/turtle"(), Graph, "http://example.org/base/")

# File path overload
g = read("data.ttl", MIME"text/turtle"(), Graph)
```

Turtle output groups triples by subject and uses predicate lists with `;` for
compact output. Common namespaces are abbreviated automatically.

## JSON-LD

JSON-LD is the dominant format for linked data on the web. It uses JSON with a
`@context` to map compact terms to full IRIs.

```julia
# Read a Graph from JSON-LD
g = read(io, MIME"application/ld+json"(), Graph)

# Read a Dataset (for documents with @graph / named graphs)
ds = read(io, MIME"application/ld+json"(), Dataset)

# Write a Graph to JSON-LD (expanded form)
write(io, MIME"application/ld+json"(), g)

# Write with a context object for compact output
write(io, MIME"application/ld+json"(), g; context=Dict(
    "@vocab" => "http://schema.org/",
    "name"   => "http://schema.org/name",
))
```

### JSON-LD example

```julia
jsonld = """
{
  "@context": {
    "ex":   "http://example.org/",
    "foaf": "http://xmlns.com/foaf/0.1/",
    "name": "foaf:name",
    "age":  {"@id": "foaf:age", "@type": "xsd:integer"},
    "xsd":  "http://www.w3.org/2001/XMLSchema#"
  },
  "@id": "ex:alice",
  "@type": "ex:Person",
  "name": "Alice",
  "age": 30,
  "foaf:knows": {"@id": "ex:bob"}
}
"""

g = read(IOBuffer(jsonld), MIME"application/ld+json"(), Graph)
# => Graph with triples:
#   ex:alice rdf:type ex:Person
#   ex:alice foaf:name "Alice"
#   ex:alice foaf:age "30"^^xsd:integer
#   ex:alice foaf:knows ex:bob
```

!!! note "Remote contexts"
    Remote context loading (`@context: "https://..."`) is not supported.
    Only inline contexts are processed. For remote contexts, fetch them
    manually and merge into the inline context.

## File-extension dispatch

`rdf_read` and `rdf_write` choose the format based on the file extension:

```@docs
rdf_read
rdf_write
```

```julia
g  = rdf_read("data.nt")    # N-Triples
g  = rdf_read("data.ttl")   # Turtle
ds = rdf_read("data.nq")    # N-Quads → Dataset
g  = rdf_read("data.jsonld") # JSON-LD

rdf_write("out.nt", g)
rdf_write("out.ttl", g)
rdf_write("out.nq", ds)
rdf_write("out.jsonld", g)
```

## Streaming parse

For very large files, use the callback form of `parse_triples` to avoid
materializing the entire graph in memory:

```@docs
parse_triples
```

```julia
# Count triples without building a Graph
n = Ref(0)
parse_triples(io, MIME"application/n-triples"()) do t
    n[] += 1
end
println(n[])  # number of triples
```
