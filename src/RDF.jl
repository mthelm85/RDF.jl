module RDF

using Dates
using Printf
import Base: match, merge!

# ── Core types ────────────────────────────────────────────────────────────────
include("errors.jl")
include("terms.jl")
include("triple.jl")
include("store.jl")
include("graph.jl")
include("dataset.jl")
include("namespaces.jl")
include("match.jl")
include("display.jl")
include("literal_values.jl")
include("validation.jl")
include("inference.jl")

# ── Serialization ─────────────────────────────────────────────────────────────
include("serialization/ntriples.jl")
include("serialization/nquads.jl")
include("serialization/turtle.jl")

# ── Query ─────────────────────────────────────────────────────────────────────
include("sparql.jl")

# ── Vocabulary modules ────────────────────────────────────────────────────────
include("vocab/rdf_vocab.jl")
include("vocab/rdfs_vocab.jl")
include("vocab/xsd_vocab.jl")
include("vocab/owl_vocab.jl")
include("vocab/skos_vocab.jl")
include("vocab/dc_vocab.jl")
include("vocab/dcterms_vocab.jl")
include("vocab/foaf_vocab.jl")
include("vocab/schema_vocab.jl")

# ── Exports ───────────────────────────────────────────────────────────────────

export RDFTerm, IRI, BlankNode, Literal, TripleTerm
export SubjectTerm, PredicateTerm, ObjectTerm, GraphName
export Triple, Quad, GeneralizedTriple, TriplePattern
export Graph, Dataset
export Namespace
export ValidationWarning

# Error types
export RDFError, IRIError, ParseError, LiteralValueError, BlankNodeScopeError

# Term construction
export @iri_str
export value, tryvalue

# Blank node minting
export blank!

# Graph operations
export issubgraph, isomorphic, ≅, merge!, skolemize, deskolemize
export blank_nodes, subjects, predicates, objects

# Dataset operations
export ntriples, quads

# Pattern matching
export match

# Serialization
export parse_triples, rdf_read, rdf_write

# Inference
export infer_rdfs, infer_rdfs!, entails

# Validation
export validate

# SPARQL
export SolutionSet, sparql_parse, sparql, sparql_update!

# Vocabulary modules
export rdf, rdfs, xsd, owl, skos, dc, dcterms, foaf, schema

end # module RDF
