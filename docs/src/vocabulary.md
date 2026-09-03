```@meta
CurrentModule = RDF
```

# Vocabulary API

RDF.jl ships [built-in constants](terms.md#Built-in-vocabulary-modules) for the
core W3C namespaces (`rdf`, `rdfs`, `xsd`, `owl`, `skos`, `dc`, `dcterms`,
`foaf`, `schema`).  For everything else — domain-specific ontologies,
frequently-updated vocabularies, or any namespace you want to introspect —
`Vocabulary` and `load_vocabulary` provide a unified API.

```@docs
Vocabulary
load_vocabulary
terms
label
comment
```

---

## Quick start

```julia
using RDF, HTTP

# Load CTDL (Credential Transparency Description Language)
ctdl = load_vocabulary("https://credreg.net/ctdl/schema/encoding/turtle";
                        base="http://purl.org/ctdl/terms/")

# Term access — dot notation
ctdl.BachelorDegree    # => IRI("http://purl.org/ctdl/terms/BachelorDegree")
ctdl.Course            # => IRI("http://purl.org/ctdl/terms/Course")
ctdl.estimatedCost     # => IRI("http://purl.org/ctdl/terms/estimatedCost")

# Metadata
label(ctdl, ctdl.Course)     # => "Course"
comment(ctdl, ctdl.Course)   # => "Single structured sequence..."

# Enumerate all indexed terms
for iri in terms(ctdl)
    lbl = label(ctdl, iri)
    println(lbl !== nothing ? lbl : iri)
end
```

---

## Construction

### From a file or URL

```julia
# Turtle file (extension auto-detected)
go = load_vocabulary("go.ttl"; base="http://purl.obolibrary.org/obo/")

# N-Triples
dc = load_vocabulary("dublin_core.nt")

# JSON-LD (all named graphs are merged)
schema_vocab = load_vocabulary("schemaorg.jsonld";
                                base="https://schema.org/")

# Remote URL — requires HTTP.jl
using HTTP
ctdl = load_vocabulary("https://credreg.net/ctdl/schema/encoding/turtle";
                        base="http://purl.org/ctdl/terms/")

# Explicit format override
v = load_vocabulary("vocab_data"; format=:ttl)
```

### From an existing Graph

If you already have a `Graph` (from `rdf_read`, SPARQL CONSTRUCT, inference, etc.)
you can wrap it directly:

```julia
g = rdf_read("my_ontology.ttl")
v = Vocabulary(g; base="http://example.org/onto/")
```

---

## The `base` keyword

`base` serves two roles:

1. **Filter** — only IRIs starting with `base` are indexed.
2. **Fallback** — `vocab.TermName` constructs `IRI(base * "TermName")` even for
   terms not present as subjects in the graph (e.g. terms added after the
   vocabulary snapshot was taken).

Without `base`, every subject IRI is indexed by its local name (the fragment
after the last `#` or `/`).  This works well for single-namespace vocabularies;
for multi-namespace graphs, local name collisions are silently resolved by
keeping the first occurrence — use `base` or the `vocab["http://..."]`
passthrough form instead.

```julia
# With base — scoped to one namespace, with fallback construction
ctdl = load_vocabulary("ctdl.ttl"; base="http://purl.org/ctdl/terms/")
ctdl.NewTerm   # => IRI("http://purl.org/ctdl/terms/NewTerm") even if absent

# Without base — all subject IRIs indexed by local name
v = load_vocabulary("mixed.ttl")
v["http://a.org/Foo"]   # => IRI("http://a.org/Foo")  (full IRI passthrough)
```

---

## Term access

| Syntax | Behaviour |
|--------|-----------|
| `vocab.TermName` | Local-name lookup; falls back to `base * "TermName"` if `base` is set; raises `KeyError` otherwise |
| `vocab["TermName"]` | Same as dot notation |
| `vocab["http://full/iri"]` | Full IRI passthrough — no lookup, just wraps in `IRI(...)` |

```julia
# All three are equivalent when the term exists
ctdl.BachelorDegree
ctdl["BachelorDegree"]
ctdl["http://purl.org/ctdl/terms/BachelorDegree"]
```

---

## Using vocabulary terms in queries

Vocabulary terms are plain `IRI` values, so they work anywhere an `IRI` is
expected — including SPARQL queries via string interpolation:

```julia
result = sparql(ds, """
  PREFIX ctdl: <http://purl.org/ctdl/terms/>
  SELECT ?cred ?name WHERE {
    ?cred a        <$(ctdl.BachelorDegree)> ;
          ctdl:name ?name .
  }
""")
```

Or build the triple pattern directly:

```julia
for t in match(g; predicate=rdf.type, object=ctdl.BachelorDegree)
    println(t.subject)
end
```

---

## Scientific domain vocabularies

The `Vocabulary` API is designed for the rich ecosystem of scientific ontologies:

| Domain | Vocabulary | URL |
|--------|-----------|-----|
| Biology | Gene Ontology (GO) | `http://purl.obolibrary.org/obo/go.owl` |
| Chemistry | ChEBI | `http://purl.obolibrary.org/obo/chebi.owl` |
| Ecology | Darwin Core | `https://dwc.tdwg.org/rdf/dwcterms.rdf` |
| Genomics | Sequence Ontology | `http://purl.obolibrary.org/obo/so.owl` |
| Phenotypes | Human Phenotype Ontology | `http://purl.obolibrary.org/obo/hp.owl` |
| Provenance | PROV-O | `http://www.w3.org/ns/prov-o` |
| Credentials | CTDL | `https://credreg.net/ctdl/schema/encoding/turtle` |

```julia
using RDF, HTTP

# Darwin Core
dwc = load_vocabulary("https://dwc.tdwg.org/rdf/dwcterms.rdf";
                       base="http://rs.tdwg.org/dwc/terms/")

dwc.scientificName    # => IRI("http://rs.tdwg.org/dwc/terms/scientificName")
dwc.decimalLatitude   # => IRI("http://rs.tdwg.org/dwc/terms/decimalLatitude")
```

!!! note "Large ontologies"
    OBO ontologies like GO and ChEBI contain tens of thousands of terms and can
    take a few seconds to parse and index.  Consider caching the resulting
    `Vocabulary` object for reuse within a session.
