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

## Schema introspection for text-to-SPARQL

LLMs write good SPARQL when handed the schema.  The pieces you need are
already in the box:

```julia
# Compact schema summary for a prompt
classes    = Set(t.object    for t in match(g; predicate=rdf.type))
properties = predicates(g)

# Validate LLM-written SPARQL before executing (ParseError on failure)
sparql_parse(llm_generated_query)
```

A dedicated `describe_schema` helper (usage counts, datatype ranges, example
values) is on the roadmap.
