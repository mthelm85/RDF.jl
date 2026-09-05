module RDF

using Dates
using Printf
using SHA
using MD5
using DataStructures: RobinDict
using Parsers
using Bumper
using Graphs
using LRUCache
import JSON
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
include("xsd_lexical.jl")     # shared XSD lexical-space predicates
include("literal_values.jl")
include("validation.jl")
include("inference.jl")

# ── Serialization ─────────────────────────────────────────────────────────────
include("serialization/ntriples.jl")
include("serialization/nquads.jl")
include("graph_conversion.jl")
include("serialization/turtle.jl")
include("serialization/trig.jl")
include("serialization/jsonld.jl")

# ── Query ─────────────────────────────────────────────────────────────────────
include("sparql.jl")
include("remote.jl")

# Symbol format aliases (:ttl, :jsonld, …) over the MIME dispatch layer.
# Included after sparql.jl because it forwards SolutionSet writes too.
include("serialization/formats.jl")

# ── Vocabulary API ───────────────────────────────────────────────────────────
include("vocabulary.jl")

# ── AI / GraphRAG layer ───────────────────────────────────────────────────────
include("annotations.jl")
include("context.jl")
include("embeddings.jl")
include("schema.jl")
include("shacl.jl")

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
export RemoteEndpointError

# Term construction
export @iri_str
export value, tryvalue

# Blank node minting
export blank!

# Graph operations
export issubgraph, isomorphic, ≅, merge!, skolemize, deskolemize, bulk_load!
export blank_nodes, subjects, predicates, objects

# Dataset operations
export ntriples, quads

# Pattern matching
export match, eachid, match_ids

# Term ID ↔ RDFTerm bridge (used with eachid, match_ids, to_digraph results)
export resolve_term   # UInt32 ID  → RDFTerm
export term_id        # RDFTerm    → UInt32 ID  (0 if not interned)
                      # also: RDFDiGraph + vertex index → UInt32 ID (see below)

# Graphs.jl integration
export to_digraph, to_weighted_digraph
export RDFDiGraph, vertex_id, resolve_vertex, edge_predicates

# ML / knowledge-graph-embedding integration
export indexed_triples, IndexMap

# Serialization
export parse_triples, rdf_read, rdf_write

# Inference
export infer_rdfs, infer_rdfs!, entails

# Validation
export validate

# SPARQL
export SolutionSet, SolutionRow, sparql_parse, sparql, sparql_update!
export read_sparql_json, write_sparql_results

# Remote SPARQL endpoints (transport provided by the HTTP.jl extension)
export RemoteGraph

# RDF-star annotations + GraphRAG context extraction
export annotate!, annotations, anno
export cbd, ego_graph, to_context

# Semantic (vector → graph) retrieval
export EmbeddingIndex, index!, knn, retrieve

# Schema introspection (text-to-SPARQL)
export describe_schema, to_prompt, SchemaSummary, ClassInfo, PredicateInfo

# SHACL validation
export validate_shapes, conforms, conforming, ValidationReport, ValidationResult

# Vocabulary API
export Vocabulary, load_vocabulary, terms, label, comment

# Vocabulary modules
export rdf, rdfs, xsd, owl, skos, dc, dcterms, foaf, schema

# ── Precompile workload ───────────────────────────────────────────────────────
#
# Exercises the SPARQL parser/evaluator and the serialization round-trips so
# their methods are compiled into the package image.  Cuts time-to-first-query
# from ~12 s to well under a second at the cost of a longer (one-time) package
# precompile.  The terms interned here use the reserved http://precompile.invalid/
# namespace; they occupy a few registry slots in every session but are inert.
using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    _pc = Namespace("http://precompile.invalid/")
    @compile_workload begin
        # Graph construction + pattern matching
        g = Graph()
        push!(g, Triple(_pc.s1, rdf.type, _pc.C))
        push!(g, Triple(_pc.s1, _pc.name, Literal("precompile")))
        push!(g, Triple(_pc.s1, _pc.age, Literal(1)))
        push!(g, Triple(_pc.s2, _pc.knows, _pc.s1))
        bulk_load!(Graph(), [Triple(_pc.s3, _pc.p, Literal(2.5))])
        collect(match(g; predicate=rdf.type))
        for _ in eachid(g); end
        Triple(_pc.s1, rdf.type, _pc.C) in g
        value(Int64, Literal(1)); value(Literal("precompile"))

        # Serialization round-trips (N-Triples, Turtle, JSON-LD, N-Quads)
        buf = IOBuffer()
        write(buf, MIME"application/n-triples"(), g)
        read(IOBuffer(take!(buf)), MIME"application/n-triples"(), Graph)
        write(buf, MIME"text/turtle"(), g)
        read(IOBuffer(take!(buf)), MIME"text/turtle"(), Graph)
        write(buf, MIME"application/ld+json"(), g)
        read(IOBuffer(take!(buf)), MIME"application/ld+json"(), Graph)
        ds = Dataset(; default_graph=g)
        write(buf, MIME"application/n-quads"(), ds)
        read(IOBuffer(take!(buf)), MIME"application/n-quads"(), Dataset)

        # SPARQL: parse + evaluate the common query shapes
        sparql(ds, """
            SELECT ?s ?o WHERE {
              ?s <http://precompile.invalid/name> ?o .
              OPTIONAL { ?s <http://precompile.invalid/age> ?a }
              FILTER(BOUND(?s) && STRLEN(?o) > 0)
            } ORDER BY ?o LIMIT 5""")
        sparql(ds, "ASK { ?s ?p ?o }")
        sparql(ds, "CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }")
        sparql(ds, "SELECT ?p (COUNT(?s) AS ?n) WHERE { ?s ?p ?o } GROUP BY ?p")
        sparql(ds, "SELECT ?x WHERE { <http://precompile.invalid/s2> <http://precompile.invalid/knows>+ ?x }")
        sparql_update!(ds, "INSERT DATA { <http://precompile.invalid/u> <http://precompile.invalid/p> 1 }")
        sol = sparql(ds, "SELECT ?s WHERE { ?s ?p ?o } LIMIT 2")
        write(buf, MIME"application/sparql-results+json"(), sol)

        # AI / GraphRAG layer
        annotate!(g, Triple(_pc.s1, _pc.name, Literal("precompile")); confidence=0.9)
        ego_graph(g, _pc.s1; hops=2)
        to_context(g; prefixes=Dict("pc" => "http://precompile.invalid/"))
        _ei = EmbeddingIndex(3)
        index!(_ei, _pc.s1, Float32[1, 0, 0])
        knn(_ei, Float32[1, 0, 0]; k=1)
        retrieve(g, _ei, Float32[1, 0, 0]; k=1, hops=1)
        to_prompt(describe_schema(g); prefixes=Dict("pc" => "http://precompile.invalid/"))

        # indexed_triples (ML / KGE)
        _it = indexed_triples(g)
        _it.entities[_pc.s1]
        _it.entities[1]
        haskey(_it.entities, _pc.s1)

        # SHACL
        shg = Graph()
        push!(shg, Triple(_pc.Sh, rdf.type, _sh("NodeShape")))
        push!(shg, Triple(_pc.Sh, _sh("targetClass"), _pc.C))
        psh = blank!(shg)
        push!(shg, Triple(_pc.Sh, _sh("property"), psh))
        push!(shg, Triple(psh, _sh("path"), _pc.age))
        push!(shg, Triple(psh, _sh("datatype"), IRI("http://www.w3.org/2001/XMLSchema#integer")))
        to_prompt(validate_shapes(g, shg))
        conforming(g, shg)
    end
end

end # module RDF
