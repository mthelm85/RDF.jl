```@meta
CurrentModule = RDF
```

# Inference & Validation

## RDFS Inference

RDF.jl implements RDFS forward-chaining materialization — computing the full
deductive closure of a graph under the RDFS entailment rules.

```@docs
infer_rdfs
infer_rdfs!
entails
```

### Available rules

| Symbol | RDFS rule | Description |
|---|---|---|
| `:subClassOf` | rdfs9, rdfs10, rdfs11 | Transitive class hierarchy + type propagation |
| `:subPropertyOf` | rdfs5, rdfs7 | Transitive property hierarchy + triple rewriting |
| `:domain` | rdfs2 | `?x a ?C` when `?x ?p ?y` and `?p rdfs:domain ?C` |
| `:range` | rdfs3 | `?y a ?C` when `?x ?p ?y` and `?p rdfs:range ?C` |

All rules are applied by default. Pass a subset via the `rules` keyword to
restrict which rules fire:

```julia
# Only subclass inference
closed = infer_rdfs(g; rules=[:subClassOf])

# All RDFS rules (default)
closed = infer_rdfs(g)
```

### Example

```julia
using RDF

ex   = Namespace("http://example.org/")
rdfs = RDF.rdfs

g = Graph()
push!(g, Triple(ex.Cat,   rdfs.subClassOf, ex.Animal))
push!(g, Triple(ex.Tiger, rdfs.subClassOf, ex.Cat))
push!(g, Triple(ex.tigger, rdf.type,       ex.Tiger))

closed = infer_rdfs(g)

# Now derivable:
entails(closed, Triple(ex.tigger, rdf.type, ex.Cat))     # true via rdfs9
entails(closed, Triple(ex.tigger, rdf.type, ex.Animal))  # true via rdfs11+rdfs9
```

### In-place materialization

`infer_rdfs!` modifies the graph directly (no copy):

```julia
infer_rdfs!(g)  # adds all RDFS-entailed triples to g
```

### Entailment check

```@docs
entails
```

`entails` checks whether a graph entails a specific triple, optionally under
a named entailment regime:

```julia
entails(g, Triple(ex.alice, rdf.type, ex.Animal))          # :rdfs (default)
entails(g, Triple(ex.alice, rdf.type, ex.Animal); regime=:simple)  # direct membership only
```

---

## Validation

```@docs
validate
ValidationWarning
```

`validate` checks every literal in a graph against its declared datatype. It
returns a vector of `ValidationWarning` values describing any mismatches.

```julia
warnings = validate(g)
for w in warnings
    println(w.message, " at ", w.triple)
end
```

### Checked datatypes

The validator checks lexical forms for the following XSD datatypes:

- Numeric: `xsd:integer`, `xsd:long`, `xsd:int`, `xsd:short`, `xsd:byte`,
  `xsd:nonNegativeInteger`, `xsd:positiveInteger`, `xsd:nonPositiveInteger`,
  `xsd:negativeInteger`, `xsd:unsignedLong`, `xsd:unsignedInt`,
  `xsd:unsignedShort`, `xsd:unsignedByte`, `xsd:decimal`, `xsd:float`,
  `xsd:double`
- Boolean: `xsd:boolean`
- Date/time: `xsd:date`, `xsd:dateTime`, `xsd:dateTimeStamp`
- Language tags: `rdf:langString`, `rdf:dirLangString` (RDF 1.2)

A `ValidationWarning` is produced (not an exception) to allow partial processing
of real-world data that may have conformance issues.
