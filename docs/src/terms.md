```@meta
CurrentModule = RDF
```

# RDF Terms

RDF data is built from three kinds of terms. All three are subtypes of `RDFTerm`.

```@docs
RDFTerm
```

## Type hierarchy

```
RDFTerm
├── IRI
├── BlankNode
├── Literal
└── TripleTerm   (RDF 1.2 — embedded triples)
```

## IRI

An absolute IRI (RFC 3987). IRIs identify resources and are used as subjects, predicates, and objects.

```@docs
IRI
@iri_str
```

### Construction

```julia
IRI("http://example.org/Alice")    # runtime validation
iri"http://schema.org/Person"      # compile-time validation
```

Validation rules: must begin with a scheme (`http:`, `urn:`, etc.) and must not contain unencoded spaces. IRIs are interned globally — two `IRI` values with the same string are `===`.

## BlankNode

A blank node represents an unnamed resource local to a graph. Blank nodes should
be created via [`blank!`](@ref) to guarantee unique identifiers.

```@docs
BlankNode
blank!
```

```julia
g  = Graph()
b1 = blank!(g)         # mint one blank node belonging to g
b2, b3 = blank!(g, 2)  # mint two at once
```

## Literal

A typed value with a lexical form, datatype IRI, and optional language tag.

```@docs
Literal
```

### Common constructors

| Expression | Datatype |
|---|---|
| `Literal("hello")` | `xsd:string` |
| `Literal("hello"; lang="en")` | `rdf:langString` |
| `Literal("hello"; lang="ar", dir="rtl")` | `rdf:dirLangString` (RDF 1.2) |
| `Literal("hello", IRI("..."))` | explicit datatype |
| `Literal(42)` | `xsd:integer` |
| `Literal(3.14)` | `xsd:double` |
| `Literal(true)` | `xsd:boolean` |
| `Literal(Date(2024,1,1))` | `xsd:date` |
| `Literal(DateTime(2024,1,1,12,0,0))` | `xsd:dateTime` |

### Coercing a literal to a Julia value

```@docs
value
tryvalue
```

```julia
lit = Literal(42)

# One-argument: infer Julia type from the RDF datatype
value(lit)              # => 42  (Int64, because xsd:integer)

# Two-argument: convert to a requested type
value(Int64,   lit)     # => 42
value(Float64, lit)     # => 42.0   (Int64 → Float64 via convert)
value(Int64,   Literal(3.14))   # throws LiteralValueError (inexact)

# Safe variant — returns nothing instead of throwing
tryvalue(lit)                          # => 42
tryvalue(Float64, lit)                 # => 42.0
tryvalue(Int64,   Literal(3.14))       # => nothing
tryvalue(Int64,   Literal("oops", xsd.integer))  # => nothing
```

The natural Julia type for each RDF datatype:

| RDF datatype | Julia type |
|---|---|
| `xsd:string`, `rdf:langString` | `String` |
| `xsd:boolean` | `Bool` |
| `xsd:integer` and all integer subtypes | `Int64` (or `BigInt` if too large) |
| `xsd:double` | `Float64` |
| `xsd:float` | `Float32` |
| `xsd:decimal` | `BigFloat` (finite-precision approximation) |
| `xsd:date` | `Dates.Date` |
| `xsd:dateTime`, `xsd:dateTimeStamp` | `Dates.DateTime` (timezone stripped) |

The two-argument `value(T, lit)` uses Julia's `convert`, so any numeric widening
that `convert` supports works (e.g. `Int64` → `Float64`, `Float32` → `Float64`).
Abstract supertypes like `Number` or `AbstractFloat` work too.

## TripleTerm

RDF 1.2 allows an embedded triple to appear as an object via `TripleTerm`, which
enables statement-level annotations without blank-node reification.

```@docs
TripleTerm
```

```julia
tt = TripleTerm(Triple(ex.alice, ex.age, Literal(30)))
push!(g, Triple(ex.claim, rdf.reifies, tt))
```

## Triple and Quad

A `Triple` has three fields: `subject::SubjectTerm`, `predicate::IRI`, `object::ObjectTerm`.
See [`Triple`](@ref) in the Graphs & Datasets page for the full API.

A `Quad` is a named-graph extension — `(subject, predicate, object, graph)` — used
when iterating [`Dataset`](@ref) quads.

## Type aliases

| Alias | Allowed types |
|---|---|
| `SubjectTerm` | `IRI`, `BlankNode`, `TripleTerm` |
| `PredicateTerm` | `IRI` |
| `ObjectTerm` | `IRI`, `BlankNode`, `Literal`, `TripleTerm` |
| `GraphName` | `IRI`, `BlankNode` |

```@docs
SubjectTerm
PredicateTerm
ObjectTerm
GraphName
```

## Namespace helper

[`Namespace`](@ref) provides a convenient shorthand for constructing IRIs within
a common prefix.

```@docs
Namespace
```

```julia
ex   = Namespace("http://example.org/")
foaf = Namespace("http://xmlns.com/foaf/0.1/")

ex.alice            # => IRI("http://example.org/alice")
foaf.name           # => IRI("http://xmlns.com/foaf/0.1/name")
ex["with spaces"]   # => IRI("http://example.org/with%20spaces")
```

## Built-in vocabulary modules

Prefix modules expose every term from common namespaces as named constants:

```julia
rdf.type          # IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
rdfs.subClassOf   # IRI("http://www.w3.org/2000/01/rdf-schema#subClassOf")
xsd.integer       # IRI("http://www.w3.org/2001/XMLSchema#integer")
owl.sameAs        # IRI("http://www.w3.org/2002/07/owl#sameAs")
skos.prefLabel    # IRI("http://www.w3.org/2004/02/skos/core#prefLabel")
dc.title          # IRI("http://purl.org/dc/elements/1.1/title")
dcterms.creator   # IRI("http://purl.org/dc/terms/creator")
foaf.name         # IRI("http://xmlns.com/foaf/0.1/name")
schema.Person     # IRI("https://schema.org/Person")
```

Available modules: `rdf`, `rdfs`, `xsd`, `owl`, `skos`, `dc`, `dcterms`, `foaf`, `schema`.
