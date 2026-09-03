```@meta
CurrentModule = RDF
```

# AI & GraphRAG

RDF.jl provides first-class primitives for the modern knowledge-graph + LLM
loop: **store LLM-extracted facts with their extraction metadata**, and
**ground LLM prompts in focused, token-budgeted subgraphs** (GraphRAG).

## Storing extracted knowledge — RDF-star annotations

When an LLM extracts triples from text, the facts are only half the story —
you also need the confidence score, the source document, the model that
produced them.  RDF.jl attaches this metadata to *individual triples* using
the standard RDF 1.2 reification pattern, which serializes losslessly to every
RDF 1.2 format (this is a capability rdflib does not have):

```@docs
annotate!
annotations
anno
```

```julia
using RDF
ex = Namespace("http://example.org/")

g = Graph()

# An extraction pipeline storing a fact with its metadata
t = Triple(ex.alice, ex.employer, ex.acme)
annotate!(g, t; confidence = 0.92,
                source     = ex.doc42,
                model      = Literal("claude-fable-5"),
                extracted  = Literal(Dates.now()))

# Reading it back
annotations(g, t)                    # all (predicate => object) pairs
annotations(g, t, anno.confidence)   # [Literal(0.92)]

# The guardrail filter: keep only high-confidence facts
trusted = Graph()
for fact in match(g; predicate=ex.employer)
    confs = annotations(g, fact, anno.confidence)
    any(value(Float64, c) >= 0.9 for c in confs) && push!(trusted, fact)
end
```

Under the hood `annotate!` asserts the triple and creates a *reifier* blank
node per statement (`_:r rdf:reifies <<( s p o )>>`), hanging the annotations
off the reifier.  Repeated `annotate!` calls on the same triple reuse its
reifier; multiple reifiers (e.g. two extraction runs annotating the same fact)
are aggregated by `annotations`.

## Grounding prompts — subgraph extraction

The core GraphRAG retrieval step: resolve a query to seed entities, pull a
focused subgraph around them, and render it into the prompt.

```@docs
cbd
ego_graph
to_context
```

### The pipeline

```julia
# 1. Seeds — from entity linking, a vector search, or user input
seeds = [ex.julia, ex.bezanson]

# 2. Expand: the 2-hop neighbourhood around the seeds
sub = ego_graph(g, seeds; hops=2)

# 3. Render into a token budget with compact prefixes
ctx = to_context(sub; budget=2000,
                 prefixes=Dict("ex" => "http://example.org/"))

prompt = """
Answer using only the facts below.

$ctx

Question: Who created Julia?
"""
```

`ego_graph` deliberately does **not** expand through class nodes reached via
`rdf:type` — classes are schema-level hubs, and expanding through them would
pull every co-typed instance into the context (pass `through_types=true` if
you want that).  Literals and predicates are never expanded through.

When the rendered graph exceeds the budget, `to_context` keeps whole subject
blocks greedily, most-connected subjects first, and guarantees the output
stays within `4 × budget` bytes (≈ tokens at 4 bytes/token).

### Entity profiles — Concise Bounded Description

`cbd` answers "tell me everything about X": all triples with subject `X`,
recursing through blank-node values (addresses, structured values), and —
by default — including the RDF-star annotations of every included fact, so
confidence and provenance travel with the profile:

```julia
profile = cbd(g, ex.alice)               # facts + their annotations
println(to_context(profile))
```

## Semantic retrieval — from a query vector to context

`ego_graph` and `cbd` start from seed entities, but in a real GraphRAG system the
first step is *semantic*: a user question is embedded, and the nearest entities
become the seeds. An [`EmbeddingIndex`](@ref) supplies that entry point — it maps
terms to embedding vectors and finds the nearest ones to a query vector — and
[`retrieve`](@ref) chains the whole loop (nearest entities → subgraph → context)
into one call.

```@docs
EmbeddingIndex
index!
knn
retrieve
```

The index stores and searches vectors only; producing the embeddings is your
model's job, exactly as remote contexts and Graphs.jl edge weights are
caller-supplied. Search is exact brute-force cosine similarity, which is the
right cut for the in-memory working sets this package targets.

```julia
using RDF
ex = Namespace("http://example.org/")

# embed() is your embedding model — any function term/text -> Vector{Float32}
idx = EmbeddingIndex(384)
index!(idx, ex.alice, embed("Alice Smith, engineer at Acme"))
index!(idx, ex.acme,  embed("Acme Corporation"))
index!(idx, ex.bob,   embed("Bob Jones"))

# Nearest entities to a question, with cosine scores
knn(idx, embed("who works at Acme?"); k=3)
#  ex.acme  => 0.83
#  ex.alice => 0.79
#  ex.bob   => 0.41

# Or the whole retrieval step in one call
context = retrieve(g, idx, embed("who works at Acme?");
                   k=5, hops=2, budget=2000,
                   prefixes=Dict("ex" => "http://example.org/"))

prompt = """
Answer using only these facts:

$context

Question: Who works at Acme?
"""
```

Entries are keyed by the term value, not its interned ID, so a term can be
indexed before (or without ever) being added to a graph — index a vocabulary up
front, load instances later. `retrieve` returns `""` when the index is empty or
the seeds have no triples in the graph, so it degrades cleanly.

## Schema introspection for text-to-SPARQL

LLMs write good SPARQL when handed the schema. [`describe_schema`](@ref)
introspects a graph's *actual* shape from the data — no ontology required, which
matters for the partially-typed graphs that extraction produces — and
[`to_prompt`](@ref) renders it as compact, token-budgeted text:

```@docs
describe_schema
to_prompt
SchemaSummary
ClassInfo
PredicateInfo
```

```julia
using RDF

s = describe_schema(g)            # classes, predicates, domains/ranges, examples

schema_text = to_prompt(s; budget=1500,
    prefixes=Dict("ex" => "http://example.org/",
                  "foaf" => "http://xmlns.com/foaf/0.1/"))

prompt = """
You are a SPARQL expert. Given this schema, write a query for the question.

$schema_text

Question: How old is the oldest person who works at Acme?
"""

# The model returns a query; validate it before running (ParseError on failure),
# and feed the error message back for self-correction if it fails.
query = call_your_llm(prompt)
try
    result = sparql(g, query)
catch e
    e isa ParseError && (query = call_your_llm(prompt * "\n\nThat query failed: $e"))
end
```

`to_prompt` output looks like:

```
# Classes
foaf:Person (3) — Person
ex:Organization (1)

# Properties
foaf:name (3): foaf:Person → xsd:string  e.g. "Alice", "Bob"
ex:age (3): foaf:Person → xsd:integer  [age in years]  e.g. 30, 25
foaf:knows (2, multi): foaf:Person → foaf:Person  e.g. ex:p2, ex:p3
ex:worksAt (1): foaf:Person → ex:Organization  e.g. ex:acme
```

Each property line shows its usage count, whether it is multi-valued, its
domain (subject classes) → range (object classes and/or literal datatypes),
any `rdfs:label`, and example values — everything a model needs to author a
correct query.

## Guardrailing extracted data — SHACL

[SHACL](https://www.w3.org/TR/shacl/) is the W3C standard for validating RDF
against shapes. RDF.jl ships a SHACL Core engine, which doubles as a guardrail
for LLM-extracted triples: validate before committing, and feed the report back
to the model for self-correction.

```@docs
validate_shapes
conforms
conforming
ValidationReport
ValidationResult
```

```julia
using RDF

# Shapes are themselves RDF (author them in Turtle, or build them in code)
shapes = read(IOBuffer("""
  @prefix sh:  <http://www.w3.org/ns/shacl#> .
  @prefix ex:  <http://example.org/> .
  @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
  ex:PersonShape a sh:NodeShape ;
    sh:targetClass ex:Person ;
    sh:property [ sh:path ex:age ; sh:datatype xsd:integer ; sh:minCount 1 ] .
"""), :ttl, Graph)

report = validate_shapes(extracted, shapes)
if !report.conforms
    # Feed the violations back to the model and retry
    fixed = call_your_llm(prompt * "\n\nFix these problems:\n" * to_prompt(report))
end

# Or simply keep only the facts that pass and drop the rest
trusted = conforming(extracted, shapes)
```

`to_prompt(::ValidationReport)` renders the violations as terse, model-readable
text (focus node, path, offending value, reason); `conforming` returns a copy
of the data with every non-conforming focus node removed.

The engine implements SHACL Core: node and property shapes; the `targetNode`,
`targetClass` (subclass-aware), `targetSubjectsOf`, `targetObjectsOf`, and
implicit-class targets; predicate / inverse / sequence / alternative /
zeroOrMore / oneOrMore / zeroOrOne paths; and the core constraint components
(value type, cardinality, value range, string, property-pair, logical,
shape-based, `sh:closed`, `sh:hasValue`, `sh:in`, `sh:qualifiedValueShape`).
It passes 178 of the W3C SHACL Core tests; the remainder require XSD facet
validation, cross-timezone `xsd:dateTime` ordering, qualified-shape sibling
disjointness, or the SPARQL-based extension (out of scope).
