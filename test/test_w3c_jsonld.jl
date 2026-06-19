using Test
using RDF
import RDF: Graph
import JSON3

# ── W3C JSON-LD 1.1 test suite (toRdf / fromRdf) ────────────────────────────────
#
# Vendored from https://github.com/w3c/json-ld-api/tree/main/tests
# The suite is designed to run offline: remote context/document references are
# resolved by a document loader that maps the test-suite base IRI onto the
# vendored files.

const _JLD_DIR  = joinpath(@__DIR__, "w3c", "fixtures", "jsonld")
const _JLD_BASE = "https://w3c.github.io/json-ld-api/tests/"

# Map a test-suite IRI back to a vendored local path (nothing if outside).
function _jld_local(iri::AbstractString)
    startswith(iri, _JLD_BASE) || return nothing
    joinpath(_JLD_DIR, replace(iri[ncodeunits(_JLD_BASE)+1:end], "/" => Base.Filesystem.path_separator))
end

# Document loader: given a (resolved, absolute) context IRI, return the context
# value to splice in (the remote document's top-level @context).
function _jld_loader(iri::AbstractString)
    p = _jld_local(iri)
    (p === nothing || !isfile(p)) && return nothing
    doc = JSON3.read(read(p, String))
    doc isa JSON3.Object && haskey(doc, Symbol("@context")) ? doc[Symbol("@context")] : nothing
end

# ── Dataset comparison (quad multiset under a blank-node bijection) ─────────────

_jld_quads(ds::Dataset) = collect(quads(ds))

function _jld_term_eq!(a, b, m::Dict{BlankNode,BlankNode})
    if a isa BlankNode && b isa BlankNode
        haskey(m, a) ? (m[a] == b) :
            (b in values(m) ? false : (m[a] = b; true))
    else
        a == b
    end
end

function _jld_quad_eq!(qa, qb, m)
    _jld_term_eq!(qa.subject, qb.subject, m) &&
    _jld_term_eq!(qa.predicate, qb.predicate, m) &&
    _jld_term_eq!(qa.object, qb.object, m) &&
    _jld_term_eq!(qa.graph === nothing ? RDF.IRI("urn:dg") : qa.graph,
                  qb.graph === nothing ? RDF.IRI("urn:dg") : qb.graph, m)
end

function _jld_ds_iso(a::Dataset, b::Dataset)::Bool
    qa = _jld_quads(a); qb = _jld_quads(b)
    length(qa) == length(qb) || return false
    # backtracking bijection
    function go(i, rem, m)
        i > length(qa) && return isempty(rem)
        for (j, q) in enumerate(rem)
            m2 = copy(m)
            if _jld_quad_eq!(qa[i], q, m2)
                go(i+1, [rem[k] for k in eachindex(rem) if k != j], m2) && return true
            end
        end
        false
    end
    go(1, qb, Dict{BlankNode,BlankNode}())
end

# ── Manifest runner ─────────────────────────────────────────────────────────────

_jget(o, k, default=nothing) = haskey(o, Symbol(k)) ? o[Symbol(k)] : default

function _jld_run_manifest(runner::Function, manifest_file::String, test_type::String)
    man = JSON3.read(read(joinpath(_JLD_DIR, manifest_file), String))
    for entry in man.sequence
        types = _jget(entry, "@type", String[])
        (test_type in types) || continue
        opt = _jget(entry, "option")
        # We target JSON-LD 1.1; skip 1.0-processing-mode tests.
        if opt !== nothing && _jget(opt, "processingMode", "") == "json-ld-1.0"
            continue
        end
        name = string(_jget(entry, "@id", "?"), " ", _jget(entry, "name", ""))
        @testset "$name" begin
            runner(entry, opt)
        end
    end
end

if isdir(_JLD_DIR)
    @testset "W3C JSON-LD 1.1 toRdf" begin
        _jld_run_manifest("toRdf-manifest.jsonld", "jld:ToRDFTest") do entry, opt
            input = String(_jget(entry, "input"))
            inpath = _jld_local(_JLD_BASE * input)
            iri = _JLD_BASE * input
            base = opt !== nothing && _jget(opt, "base") !== nothing ?
                   String(_jget(opt, "base")) : iri
            types = _jget(entry, "@type", String[])
            negative = "jld:NegativeEvaluationTest" in types
            if negative
                @test_throws Exception open(io -> read(io, MIME"application/ld+json"(),
                                                       Dataset; base=base), inpath)
            else
                expect = String(_jget(entry, "expect"))
                exppath = _jld_local(_JLD_BASE * expect)
                expected = open(io -> read(io, MIME"application/n-quads"(), Dataset), exppath)
                actual = open(io -> read(io, MIME"application/ld+json"(),
                                         Dataset; base=base), inpath)
                @test _jld_ds_iso(actual, expected)
            end
        end
    end
else
    error("JSON-LD fixtures missing at $_JLD_DIR")
end
