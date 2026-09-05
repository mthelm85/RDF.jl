```@meta
CurrentModule = RDF
```

# Serialization

RDF.jl uses Julia's standard `Base.read` / `Base.write` API. All parsers and
serializers work with `IO` streams; `rdf_read` and `rdf_write` add
file-extension–based dispatch.

## Supported formats

Name a format with a symbol — that is the everyday API:

| Format | `format` | MIME type | Extension | Read | Write |
|---|---|---|---|---|---|
| N-Triples 1.2 | `:nt`, `:ntriples` | `application/n-triples` | `.nt` | ✅ | ✅ |
| N-Quads 1.2 | `:nq`, `:nquads` | `application/n-quads` | `.nq` | ✅ | ✅ |
| Turtle 1.2 | `:ttl`, `:turtle` | `text/turtle` | `.ttl` | ✅ | ✅ |
| TriG 1.2 | `:trig` | `application/trig` | `.trig` | ✅ | ✅ |
| JSON-LD 1.1 | `:jsonld` | `application/ld+json` | `.jsonld` | ✅ | ✅ |
| RDF/XML | `:rdfxml`, `:xml` | `application/rdf+xml` | `.rdf` | ✅ (with EzXML.jl) | ❌ |

An unrecognized symbol raises an `ArgumentError` listing the valid names.

### Symbols and MIME types

Every entry point that takes `:ttl` also takes `MIME"text/turtle"()`, and the
MIME form is what actually dispatches. That matters in two places:

  * **Extensibility** — a third-party package can add a format by defining
    `Base.read(io, ::MIME"application/rdf+xml", ::Type{Graph})`, with no change
    to RDF.jl. The bundled `RDFXMLExt` extension does exactly that.
  * **Content negotiation** — an HTTP `Content-Type` or `Accept` header is
    already a MIME string, so it can be handed straight to `read`/`write`
    without a lookup table.

Symbols are the friendlier surface for code you write by hand. Use whichever
fits the call site.

The N-Triples, N-Quads, and Turtle parsers support RDF 1.2 / RDF-star: triple
terms `<<( s p o )>>`, reified triples `<< s p o >>` with optional reifiers
(`~`), annotation blocks (`{| … |}`, Turtle), directional language tags
(`"x"@en--ltr`), and the `@version` / `VERSION` directive. All RDF 1.2 W3C
N-Triples, N-Quads, and Turtle test suites pass.

## N-Triples

```julia
# Write a Graph to N-Triples
write(io, :nt, g)

# Read a Graph from N-Triples
g = read(io, :nt, Graph)

# Streaming parse (low allocation)
parse_triples(io, :nt) do triple
    process(triple)
end
```

## N-Quads

```julia
# Write a Dataset to N-Quads
write(io, :nq, ds)

# Read a Dataset from N-Quads
ds = read(io, :nq, Dataset)
```

## TriG

TriG is Turtle plus graph blocks — the dataset serialization. Everything Turtle
accepts is valid inside a block, including the RDF 1.2 additions.

```julia
ds = read(io, :trig, Dataset)
write(io, :trig, ds; prefixes=Dict("ex" => "http://example.org/"))

# Reading as a Graph merges every graph, discarding the names
g = read(io, :trig, Graph)
```

```trig
@prefix ex: <http://example.org/> .

ex:a ex:p ex:b .                      # default graph
{ ex:c ex:p ex:d . }                  # also the default graph
ex:g1 { ex:s ex:p "in g1" }           # a named graph
GRAPH ex:g2 { ex:s2 ex:p2 "in g2" }   # the same, SPARQL-style
_:bg { ex:s3 ex:p3 "bnode-labelled" } # a blank node may name a graph
ex:empty {}                           # an empty named graph
```

Unlike N-Quads, TriG can represent an *empty* named graph, so a `Dataset`
round-trips through it without losing one. Blank node labels are scoped to the
document, not the graph: `_:x` in two blocks is the same node.

## Turtle

```julia
# Write a Graph to Turtle (with optional namespace prefixes)
write(io, :ttl, g)

# Read a Graph from Turtle
g = read(io, :ttl, Graph)

# Read with an explicit base IRI for resolving relative IRIs
g = read(io, :ttl, Graph, "http://example.org/base/")

# File path overload
g = read("data.ttl", :ttl, Graph)

# The MIME form is equivalent, and is what these dispatch to
g = read(io, MIME"text/turtle"(), Graph)
```

Turtle output groups triples by subject and uses predicate lists with `;` for
compact output. Common namespaces are abbreviated automatically.

## JSON-LD

JSON-LD is the dominant format for linked data on the web. It uses JSON with a
`@context` to map compact terms to full IRIs.

```julia
# Read a Graph from JSON-LD
g = read(io, :jsonld, Graph)

# Read a Dataset (for documents with @graph / named graphs)
ds = read(io, :jsonld, Dataset)

# Write a Graph to JSON-LD (expanded form)
write(io, :jsonld, g)

# Write with a context object for compact output
write(io, :jsonld, g; context=Dict(
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

g = read(IOBuffer(jsonld), :jsonld, Graph)
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

`rdf_read` and `rdf_write` choose the format based on the file extension, or
from an explicit `format` keyword:

```@docs
rdf_read
rdf_write
```

```julia
g  = rdf_read("data.nt")     # N-Triples
g  = rdf_read("data.ttl")    # Turtle
ds = rdf_read("data.nq")     # N-Quads → Dataset
g  = rdf_read("data.jsonld") # JSON-LD

rdf_write("out.nt", g)
rdf_write("out.ttl", g)
rdf_write("out.nq", ds)
rdf_write("out.jsonld", g)

# When the extension is uninformative or wrong, say so
g = rdf_read("export.txt";  format=:ttl)
rdf_write("export.txt", g;  format=:ttl)
```

An extension that names no known format — or one with no serializer for the
value being written, such as a `Dataset` to Turtle — raises an `ArgumentError`
rather than silently falling back to another format. When you want N-Triples (or
N-Quads for a `Dataset`) no matter what the file is called, use `write(path, x)`
directly.

## Streaming parse

For very large files, use the callback form of `parse_triples` to avoid
materializing the entire graph in memory:

```@docs
parse_triples
```

```julia
# Count triples without building a Graph
n = Ref(0)
parse_triples(io, :nt) do t
    n[] += 1
end
println(n[])  # number of triples
```
