# RDF.jl Requirements

## 1. Overview

RDF.jl is a Julia package implementing the W3C RDF 1.1 data model. It provides the
foundational types, in-memory graph store, pattern matching, N-Triples/N-Quads
serialization, RDFS inference, and standard vocabulary constants needed to build
RDF-based applications in Julia. It is the base on which separate packages —
SPARQL.jl, Turtle.jl, JSONLD.jl, RDFXML.jl, OWL.jl — are intended to build.

### 1.1 Design Principles

- **Spec-correct by default.** All normative requirements of the W3C RDF 1.1
  Concepts and Abstract Syntax specification are satisfied. Where the spec says
  MUST, the implementation enforces it. Where the spec says MUST NOT, the
  implementation prohibits it.
- **Julian API.** The package follows Julia idioms: multiple dispatch over method
  objects, operator overloading where semantics are unambiguous, the `!`
  convention for mutation, do-block construction, and the standard collection
  protocols (`iterate`, `in`, `length`, `push!`).
- **Performance-conscious design.** Internal representations are chosen for type
  stability and cache efficiency. User-facing types are concrete or small closed
  unions. The internal triple store uses integer-ID interning and sorted index
  arrays of `isbits` tuples.
- **Clean extension surface.** The package exposes stable abstract interfaces
  at the boundaries where SPARQL.jl, format packages, and OWL.jl will plug in.
  These interfaces are designed before implementation, not discovered after.

---

## 2. Scope

### 2.1 In Scope

- The complete RDF 1.1 abstract data model (IRIs, blank nodes, literals, triples,
  graphs, datasets)
- In-memory graph and dataset store with hexastore indexing
- Pattern matching with a `TriplePattern` type
- N-Triples and N-Quads parsing and serialization (the W3C test suite formats)
- RDFS inference (forward-chaining materialization)
- Standard vocabulary constants: RDF, RDFS, XSD, OWL (IRIs only), SKOS, DC,
  DCTERMS, FOAF, SCHEMA
- User-defined namespace support
- Graph isomorphism checking
- Skolemization and deskolemization
- Blank node scoping and minting
- Tables.jl integration for pattern match results
- A structured error type hierarchy
- Graph set operations (union, intersect, setdiff) with correct blank node handling

### 2.2 Explicitly Out of Scope

- SPARQL query language (separate SPARQL.jl)
- Turtle and TriG parsing/serialization (separate Turtle.jl)
- JSON-LD parsing/serialization (separate JSONLD.jl)
- RDF/XML parsing/serialization (separate RDFXML.jl)
- OWL reasoning and inconsistency detection (separate OWL.jl)
- Persistent or remote triple stores
- SPARQL endpoint client or server
- RDFa parsing
- Graphs.jl interoperability (thin adaptor package if needed)

---

## 3. Conformance with RDF 1.1

The following normative requirements are drawn directly from the W3C RDF 1.1
Concepts and Abstract Syntax specification (25 February 2014).

### 3.1 IRIs

- IRIs MUST be absolute (no relative IRIs in the abstract syntax).
- IRIs MAY contain fragment identifiers.
- IRI equality is determined by simple string comparison per RFC 3987 §5.1.
  Further normalization MUST NOT be performed when comparing IRIs for equality.
- IRI validation is performed at construction time. An `IRIError` is raised for
  malformed or relative IRIs.
- The package does not perform IRI collision detection. IRI collision is a
  social and architectural concern outside the scope of a data model library.

### 3.2 Literals

- Every literal has a lexical form (Unicode string), a datatype IRI, and
  optionally a language tag.
- A literal is a language-tagged string if and only if its datatype IRI is
  `rdf:langString`, in which case a non-empty language tag MUST be present.
- Language tags are normalized to lowercase at construction time.
- Simple literals (no explicit datatype) are equivalent to `xsd:string` literals.
  Parsers MUST perform this conversion when reading formats that allow simple
  literals.
- Literal term equality is character-by-character comparison of all three
  components: lexical form, datatype IRI, and language tag. Value equality is
  distinct from term equality and is not used for graph membership or indexing.
- Ill-typed literals (lexical form not in the lexical space of the declared
  datatype) MUST be accepted. Construction never raises an error due to an
  ill-typed literal. A `validate` function MAY emit warnings for ill-typed
  literals.
- Literals MUST NOT appear in the subject or predicate position of a standard
  RDF triple. This constraint is enforced by the Julia type system, not by
  runtime checks.

### 3.3 Blank Nodes

- Blank nodes are disjoint from IRIs and literals.
- Blank node identifiers as they appear in serialization formats are not part
  of the abstract syntax. They are scoped to a single document or parse
  operation and MUST NOT be treated as persistent identifiers.
- Blank nodes are minted by a `Graph` or `Dataset`, never constructed directly
  by users. Each minted blank node receives a globally unique `UInt64` identifier
  from an atomic counter.
- The blank node scope boundary is the `Dataset`. Blank nodes minted within a
  dataset may appear in any of its graphs.
- Graph merge operations MUST rename blank nodes to prevent collisions between
  the two graphs' blank node populations.

### 3.4 Triples

- An RDF triple consists of a subject (IRI or blank node), a predicate (IRI),
  and an object (IRI, blank node, or literal).
- The positional type constraints are enforced by the Julia type system via
  `Union` type aliases, not by runtime validation.

### 3.5 Graphs

- An RDF graph is a set of RDF triples. Duplicate triples are silently ignored.
- Graph comparison for equality is term-for-term: same subjects, predicates,
  objects including blank node identity.
- Graph isomorphism is defined by a bijection over blank nodes that preserves
  all triple structure while leaving IRIs and literals fixed. Isomorphism
  checking is a first-class operation.

### 3.6 Datasets

- An RDF dataset comprises exactly one default graph (unnamed) and zero or more
  named graphs.
- Named graphs are identified by an IRI or a blank node. This differs from
  SPARQL 1.1, which restricts graph names to IRIs. `RDF.jl` follows the data
  model specification, not the SPARQL restriction.
- Graph names are unique within a dataset.
- Blank nodes can be shared between graphs within a dataset.
- The default graph may be empty.

### 3.7 Datatypes

- All 32 RDF-compatible XSD types listed in the RDF 1.1 specification §5.1
  are recognized and have IRI constants in the `XSD` vocabulary module.
- `rdf:HTML` and `rdf:XMLLiteral` are recognized as non-normative datatypes and
  have IRI constants in the `RDF` vocabulary module. Their lexical forms are
  stored as strings; no DOM parsing is performed.
- Literals with unrecognized datatype IRIs MUST be accepted without error.
- Datatype validation (checking whether a lexical form is in the lexical space
  of its declared datatype) occurs only in the explicit `value()` and
  `validate()` functions, never silently at construction or insertion time.

### 3.8 Generalized RDF

- Generalized RDF triples (where literals or blank nodes may appear as the
  predicate) are non-normative but encountered in practice.
- A separate `GeneralizedTriple` type is provided for consumers of formats that
  produce generalized RDF. Standard `Triple` never accepts generalized triples.

---

## 4. Data Model Types

### 4.1 Term Types

```julia
abstract type RDFTerm end

struct IRI <: RDFTerm
    value::String          # validated absolute IRI string
end

struct BlankNode <: RDFTerm
    id::UInt64             # globally unique; not the serialization identifier
end

struct Literal <: RDFTerm
    lexical_form::String
    datatype::IRI
    language_tag::String   # "" when not a language-tagged string; lowercase when present
end

# Positional type aliases — Union types, not abstract types
const SubjectTerm   = Union{IRI, BlankNode}
const PredicateTerm = IRI
const ObjectTerm    = Union{IRI, BlankNode, Literal}
const GraphName     = Union{IRI, BlankNode}
```

### 4.2 Triple and Quad

```julia
struct Triple
    subject::SubjectTerm
    predicate::IRI
    object::ObjectTerm
end

struct Quad
    subject::SubjectTerm
    predicate::IRI
    object::ObjectTerm
    graph::Union{GraphName, Nothing}   # Nothing denotes the default graph
end

struct GeneralizedTriple
    subject::RDFTerm
    predicate::RDFTerm
    object::RDFTerm
end
```

### 4.3 TriplePattern

```julia
struct TriplePattern
    subject::Union{SubjectTerm, Nothing}
    predicate::Union{IRI, Nothing}
    object::Union{ObjectTerm, Nothing}
end
```

`TriplePattern` is the programmatic query type used by SPARQL.jl. The
keyword-argument form of `match` is sugar that constructs a `TriplePattern`.

---

## 5. Internal Store Design

### 5.1 Term Interning

All terms inserted into a graph or dataset are interned into a global term table
that maps each distinct `RDFTerm` to a `UInt32` identifier. The reverse mapping
(ID to term) is a `Vector{RDFTerm}`.

Interning means:
- Term equality in the hot path is integer comparison, not string comparison.
- A triple is stored as `NTuple{3, UInt32}` — 12 bytes, fully `isbits`,
  fits in a cache line.
- Term deduplication is automatic; no triple-level deduplication logic needed.

### 5.2 Hexastore Indexing

The triple store maintains six sorted index arrays, one for each permutation of
subject (S), predicate (P), and object (O):

```
spo, sop, pso, pos, osp, ops
```

Each index is a `Vector{NTuple{3, UInt32}}` kept in sorted order. Pattern
matching selects the index whose leading positions are bound (i.e. the index
where bound positions form a prefix), then uses `searchsortedfirst` /
`searchsortedlast` for O(log n) range lookup followed by contiguous iteration.

The six-index hexastore ensures that any combination of bound and unbound
positions in a triple pattern is served by a prefix scan on at least one index.

### 5.3 Blank Node Registry

Each `Graph` and `Dataset` maintains a `Set{UInt64}` of the blank node IDs it
owns. This is used for:
- Enforcing blank node scope (a blank node minted in one dataset cannot be
  inserted into a different dataset without renaming)
- Graph isomorphism checking
- Graph merge blank node renaming

---

## 6. API Requirements

### 6.1 Term Construction

```julia
# IRI
IRI(s::String)             # validated; throws IRIError if not absolute/well-formed
iri"http://..."            # string macro; validates at parse time for string literals

# Literal — constructor dispatch by Julia type
Literal(x::Integer)        # xsd:integer
Literal(x::AbstractFloat)  # xsd:double
Literal(x::Bool)           # xsd:boolean
Literal(x::String)         # xsd:string
Literal(x::Date)           # xsd:date
Literal(x::DateTime)       # xsd:dateTime
Literal(s::String, datatype::IRI)         # explicit typed literal
Literal(s::String; lang::String)          # language-tagged string

# Literal value extraction
value(lit::Literal)                # returns Julia value; throws LiteralValueError if ill-typed
value(T::Type, lit::Literal)       # type-asserting; return type is T (type-stable)
tryvalue(lit::Literal)             # returns nothing on failure

# Blank nodes — only via graph/dataset
blank!(g::Graph)::BlankNode
blank!(g::Graph, n::Int)::Vector{BlankNode}
blank!(ds::Dataset)::BlankNode
```

### 6.2 Namespaces

```julia
struct Namespace
    base::String
end

# Property access generates IRI — mirrors Turtle prefix:name syntax
Base.getproperty(ns::Namespace, name::Symbol)::IRI
# Index access for names that are not valid Julia identifiers
Base.getindex(ns::Namespace, name::String)::IRI
Base.string(ns::Namespace)::String

# Built-in namespace constants (exported, lowercase)
# These are Julia modules containing const IRI values
rdf     # http://www.w3.org/1999/02/22-rdf-syntax-ns#
rdfs    # http://www.w3.org/2000/01/rdf-schema#
xsd     # http://www.w3.org/2001/XMLSchema#
owl     # http://www.w3.org/2002/07/owl#
skos    # http://www.w3.org/2004/02/skos/core#
dc      # http://purl.org/dc/elements/1.1/
dcterms # http://purl.org/dc/terms/
foaf    # http://xmlns.com/foaf/0.1/
schema  # https://schema.org/
```

Built-in vocabulary modules expose every term in the respective vocabulary as a
`const IRI`. For example: `rdf.type`, `rdfs.subClassOf`, `xsd.integer`,
`owl.Class`, `foaf.Person`, `schema.Person`.

### 6.3 Graphs

```julia
# Construction
Graph()
Graph(f::Function)      # do-block form; f receives the graph

# Mutation
push!(g::Graph, t::Triple)
delete!(g::Graph, t::Triple)

# Set interface
in(t::Triple, g::Graph)::Bool
length(g::Graph)::Int
isempty(g::Graph)::Bool
iterate(g::Graph)           # yields Triple values

# Set operations — return new Graph; blank nodes renamed as needed
union(g1::Graph, g2::Graph)        # g1 ∪ g2
intersect(g1::Graph, g2::Graph)    # g1 ∩ g2
setdiff(g1::Graph, g2::Graph)      # g1 \ g2
merge!(g1::Graph, g2::Graph)       # mutating union into g1

# Subgraph and isomorphism
issubgraph(g1::Graph, g2::Graph)::Bool   # g1 ⊆ g2
isomorphic(g1::Graph, g2::Graph)::Bool   # g1 ≅ g2

# Skolemization
skolemize(g::Graph; base::String)::Graph
deskolemize(g::Graph; base::String)::Graph
```

Operator aliases: `∪`, `∩`, `\`, `⊆`, `≅`.

### 6.4 Datasets

```julia
# Construction
Dataset()
Dataset(; default_graph::Graph)

# Named graph access — Dict-like interface
Base.getindex(ds::Dataset, name::GraphName)::Graph
Base.setindex!(ds::Dataset, g::Graph, name::GraphName)
Base.delete!(ds::Dataset, name::GraphName)
Base.haskey(ds::Dataset, name::GraphName)::Bool

# Default graph
# Accessed via ds.default_graph field
# Replaceable via ds.default_graph = g

# Iteration — yields (name::GraphName, graph::Graph) pairs
Base.iterate(ds::Dataset)
Base.keys(ds::Dataset)      # iterator over GraphName
Base.values(ds::Dataset)    # iterator over Graph
Base.length(ds::Dataset)    # number of named graphs

# Utilities
ntriples(ds::Dataset)::Int  # total triple count across all graphs
quads(ds::Dataset)          # lazy iterator of Quad
```

### 6.5 Pattern Matching

```julia
# Keyword form — for human use
match(g::Graph;
      subject::Union{SubjectTerm, Nothing}  = nothing,
      predicate::Union{IRI, Nothing}         = nothing,
      object::Union{ObjectTerm, Nothing}     = nothing)

# TriplePattern form — for programmatic use (SPARQL.jl)
match(g::Graph, p::TriplePattern)

# Dataset match — adds graph keyword; returns iterator of Quad
match(ds::Dataset;
      subject::Union{SubjectTerm, Nothing}  = nothing,
      predicate::Union{IRI, Nothing}         = nothing,
      object::Union{ObjectTerm, Nothing}     = nothing,
      graph::Union{GraphName, Nothing}       = nothing)

# Convenience accessors — all return lazy iterators
subjects(g::Graph; kwargs...)
predicates(g::Graph; kwargs...)
objects(g::Graph; kwargs...)
```

All `match` variants return lazy iterators. No intermediate collection is
allocated unless the caller explicitly calls `collect`. Match results implement
the Tables.jl row interface with columns `:subject`, `:predicate`, `:object`
(and `:graph` for dataset matches). This enables direct use with DataFrames.jl,
CSV.jl, and any other Tables.jl consumer.

The keyword form is syntactic sugar for constructing a `TriplePattern` and
dispatching to the pattern form. Both paths reach the same internal
implementation.

### 6.6 Serialization

N-Triples and N-Quads are part of `RDF.jl`. Additional formats are separate
packages that extend the same MIME-dispatch interface.

```julia
# Write
Base.write(io::IO, ::MIME"application/n-triples", g::Graph)
Base.write(io::IO, ::MIME"application/n-quads",   ds::Dataset)

# Read
Base.read(io::IO, ::MIME"application/n-triples", ::Type{Graph})::Graph
Base.read(io::IO, ::MIME"application/n-quads",   ::Type{Dataset})::Dataset

# File convenience — format detected from extension
read(path::String)::Union{Graph, Dataset}
write(path::String, g::Graph)
write(path::String, ds::Dataset)

# Streaming parser — never materializes the full graph
parse_triples(f::Function, io::IO, mime::MIME)   # do-block callback form
parse_triples(io::IO, mime::MIME)                 # returns lazy iterator
```

Format packages (Turtle.jl, JSONLD.jl, RDFXML.jl) extend this interface by
adding methods for their respective MIME types:

```
MIME"text/turtle"
MIME"application/trig"
MIME"application/ld+json"
MIME"application/rdf+xml"
```

No code in `RDF.jl` references these MIME types. The extension is purely
additive.

### 6.7 RDFS Inference

```julia
# Non-mutating — returns new graph containing g plus all entailed triples
infer_rdfs(g::Graph)::Graph
infer_rdfs(g::Graph; rules::Vector{Symbol})::Graph   # select specific rules

# Mutating — adds entailed triples directly to g
infer_rdfs!(g::Graph)
infer_rdfs!(g::Graph; rules::Vector{Symbol})

# Entailment checking
entails(g::Graph, t::Triple; regime::Symbol=:rdfs)::Bool
```

Supported RDFS rules (selectable via `rules` keyword):
`:subClassOf`, `:subPropertyOf`, `:domain`, `:range`, `:type_propagation`.

The `regime` keyword on `entails` is the extension point for OWL.jl:

```julia
# OWL.jl will add methods for:
entails(g, t; regime=:owl_rl)
entails(g, t; regime=:owl_el)
```

`RDF.jl` does not perform inconsistency detection. Inconsistency detection
requires OWL reasoning and belongs in OWL.jl.

### 6.8 Validation

```julia
struct ValidationWarning
    triple::Triple
    message::String
    code::Symbol          # e.g. :ill_typed_literal, :undefined_datatype
end

validate(g::Graph)::Vector{ValidationWarning}
validate(ds::Dataset)::Vector{ValidationWarning}
```

`validate` checks for:
- Ill-typed literals (lexical form not in the lexical space of the declared
  datatype, for recognized datatypes)
- Language tags that do not conform to BCP47

`validate` never throws. It always returns a (possibly empty) vector of warnings.
It is never called automatically — it is always an explicit user action.

### 6.9 Display

```julia
# Terms render in standard RDF serialization syntax
show(io, IRI("http://example.org/alice"))
# => <http://example.org/alice>

show(io, Literal("hello"; lang="en"))
# => "hello"@en

show(io, Literal("42", xsd.integer))
# => "42"^^<http://www.w3.org/2001/XMLSchema#integer>

show(io, Triple(ex.alice, rdf.type, ex.Person))
# => <http://example.org/alice> <...#type> <http://example.org/Person> .

# Graphs show a summary in the REPL, not all triples
show(io, g)
# => RDF.Graph with 42 triples
```

---

## 7. Error Types

```julia
abstract type RDFError <: Exception end

# Raised when an IRI string fails RFC 3987 validation or is not absolute
struct IRIError <: RDFError
    value::String
    reason::String
end

# Raised by parsers on malformed input
struct ParseError <: RDFError
    message::String
    line::Int
    column::Int
    format::MIME
end

# Raised by value() when a literal's lexical form is not in the
# lexical space of its declared datatype
struct LiteralValueError <: RDFError
    literal::Literal
    target_type::Type
end

# Raised when a blank node is used outside its scope
struct BlankNodeScopeError <: RDFError
    node::BlankNode
    message::String
end
```

---

## 8. Performance Requirements

The following constraints follow directly from Julia's performance model and
must be respected throughout the implementation.

### 8.1 Type Stability

All public functions must be type-stable. The return type of every function
must be inferrable from the types of its arguments alone. Functions that
return `RDFTerm` values must use `Union{IRI, BlankNode, Literal}` rather than
the abstract `RDFTerm` type wherever the closed set is known.

### 8.2 No Abstract Fields in Hot-Path Structs

`Triple`, `Quad`, `TriplePattern`, and the internal index tuple types must have
no fields typed as abstract types. Positional constraints are expressed as
`Union` types (`Union{IRI, BlankNode}`, etc.), which Julia handles with
specialized code generation.

### 8.3 isbits Internal Representation

Internal index entries are `NTuple{3, UInt32}` — fully `isbits`, stack-
allocatable, 12 bytes per entry. Sorted `Vector{NTuple{3, UInt32}}` arrays
provide cache-friendly prefix scans.

### 8.4 Lazy Iterators

`match` and all accessor functions (`subjects`, `predicates`, `objects`,
`quads`) return lazy iterators. No intermediate `Vector` is allocated by the
library. The caller controls materialization via `collect`, `DataFrame`, etc.

### 8.5 Const Vocabulary Terms

All built-in vocabulary IRI constants (`rdf.type`, `xsd.integer`, etc.) are
Julia `const` values. They are allocated once at package load time and never
reallocated.

### 8.6 Atomic Blank Node Counter

The global blank node ID counter is a `Threads.Atomic{UInt64}` to support
concurrent blank node minting without locks.

---

## 9. Package Boundaries and Extension Interfaces

### 9.1 Extension Points for SPARQL.jl

SPARQL.jl requires the following from RDF.jl:
- `TriplePattern` type (already part of RDF.jl)
- `match(g, p::TriplePattern)` dispatch
- `match(ds; ..., graph=...)` for named graph access
- `iterate(g::Graph)` for full graph scans
- Tables.jl compatibility on match results

SPARQL.jl does not need to know about the internal store structure. It interacts
entirely through the `match` interface.

### 9.2 Extension Points for Format Packages

Format packages extend the serialization interface by adding methods to:
- `Base.read(io::IO, mime::MIME{T}, ::Type{Graph})` for new MIME types
- `Base.write(io::IO, mime::MIME{T}, g::Graph)` for new MIME types
- `parse_triples(io::IO, mime::MIME{T})` for streaming

No changes to RDF.jl are required to register a new format.

### 9.3 Extension Points for OWL.jl

OWL.jl extends the inference interface by adding methods to:
- `entails(g::Graph, t::Triple; regime::Symbol)` for `:owl_rl`, `:owl_el`, etc.

The `regime` keyword is the only coupling point. OWL.jl otherwise operates
on `Graph` and `Triple` values using the standard public API.

---

## 10. Dependencies

### 10.1 Required Dependencies

None beyond Julia's standard library. The core data model, N-Triples/N-Quads
parser/serializer, and RDFS inference have no external dependencies.

### 10.2 Optional / Weak Dependencies

- **Tables.jl** — for match result interop. Declared as a weak dependency;
  the Tables.jl integration activates only when Tables.jl is loaded.

### 10.3 Explicitly Excluded Dependencies

- **Graphs.jl** — no dependency. RDF graphs and graph-theory graphs are
  unrelated despite the shared name.
- **URIs.jl / IRIs.jl** — IRI validation is implemented directly to avoid
  taking on a dependency for a small, well-specified task.

---

## 11. Testing Requirements

### 11.1 W3C Test Suite

The package must pass the W3C RDF 1.1 test suites for:
- N-Triples (positive and negative syntax tests)
- N-Quads (positive and negative syntax tests)
- Graph isomorphism (the isomorphism test cases)

### 11.2 Unit Tests

Every public function has unit tests covering:
- Normal operation
- Edge cases defined by the spec (ill-typed literals, blank node scoping,
  language tag normalization, IRI equality without normalization)
- Error conditions (IRIError, ParseError, LiteralValueError,
  BlankNodeScopeError)

### 11.3 Performance Tests

Benchmarks using BenchmarkTools.jl covering:
- Triple insertion throughput (target: >1M triples/second on reference hardware)
- Pattern match throughput for each of the seven binding patterns
  (S__, _P_, __O, SP_, S_O, _PO, SPO)
- Graph union with blank node renaming
- N-Triples round-trip for large files

### 11.4 Type Stability Tests

`@inferred` tests for all public functions confirm that the Julia compiler can
infer return types statically.

---

## 12. Not Addressed in This Package

| Concern | Where It Belongs |
|---|---|
| SPARQL query language | SPARQL.jl |
| Turtle / TriG parsing and serialization | Turtle.jl |
| JSON-LD processing | JSONLD.jl |
| RDF/XML parsing and serialization | RDFXML.jl |
| OWL reasoning and inconsistency detection | OWL.jl |
| Persistent storage | Application layer or separate store package |
| SPARQL HTTP endpoint client | SPARQL.jl or HTTP.jl application code |
| Graph-theoretic algorithms (centrality, etc.) | Thin adaptor package using Graphs.jl |
| IRI collision detection | Outside the scope of any library |
| RDFa parsing | Separate package |
