# W3C RDF 1.1 Semantics (rdf-mt) conformance tests
#
# Source: https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-mt/
#
# These are entailment tests, not syntax or query tests. Each entry gives a
# premise graph and either a conclusion graph or the literal `false`:
#
#   mf:PositiveEntailmentTest  premises entail the conclusion
#   mf:NegativeEntailmentTest  premises do NOT entail the conclusion
#   mf:result false            premises are inconsistent under the regime
#
# Conclusion blank nodes are existentials, so "entails" means there is a
# homomorphism from the conclusion into the closure of the premises — not
# literal triple containment, which is what `issubgraph` checks.

using Test, RDF

const _MT_FIXTURES = joinpath(@__DIR__, "w3c", "fixtures", "rdf-mt")

if isdir(_MT_FIXTURES)

const _MT_MF   = "http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#"
const _MT_RDFT = "http://www.w3.org/ns/rdftest#"

const _MT_TYPE       = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
const _MT_FIRST      = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
const _MT_REST       = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
const _MT_NIL        = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
const _MT_ENTRIES    = IRI(_MT_MF * "entries")
const _MT_NAME       = IRI(_MT_MF * "name")
const _MT_ACTION     = IRI(_MT_MF * "action")
const _MT_RESULT     = IRI(_MT_MF * "result")
const _MT_REGIME     = IRI(_MT_MF * "entailmentRegime")
const _MT_POSITIVE   = IRI(_MT_MF * "PositiveEntailmentTest")
const _MT_NEGATIVE   = IRI(_MT_MF * "NegativeEntailmentTest")

_mt_one(g::Graph, s, p) = begin
    for t in match(g; subject=s, predicate=p)
        return t.object
    end
    nothing
end

# Walk an rdf:List into a Vector.
function _mt_list(g::Graph, head)
    out = RDFTerm[]
    node = head
    while node !== nothing && node != _MT_NIL
        v = _mt_one(g, node, _MT_FIRST)
        v === nothing && break
        push!(out, v)
        node = _mt_one(g, node, _MT_REST)
    end
    out
end

_mt_path(iri::AbstractString) = joinpath(_MT_FIXTURES, basename(iri))

# The fixtures sit in per-test subdirectories; resolve relative to the manifest.
function _mt_resolve(iri::AbstractString)
    s = iri
    i = findfirst("rdf-mt/", s)
    rel = i === nothing ? basename(s) : s[(last(i)+1):end]
    joinpath(_MT_FIXTURES, replace(rel, '/' => Base.Filesystem.path_separator))
end

function _mt_load(path::AbstractString)::Graph
    ext = lowercase(last(splitext(path)))
    open(path) do io
        ext == ".nt" ? read(io, :nt, Graph) : read(io, :ttl, Graph)
    end
end

# ─── Entailment check ────────────────────────────────────────────────────────
#
# Conclusion blank nodes are existential: find a mapping from them to terms of
# the closure making every conclusion triple present. Backtracking search; the
# fixtures are tiny.

# Two literals match when they denote the same value, not when their lexical
# forms agree: under D-entailment with a datatype recognized, "1"^^xsd:integer
# and "01"^^xsd:integer are the same thing, as are two xsd:float lexical forms
# that round to the same single-precision value.
const _MT_XSD_FLOAT  = "http://www.w3.org/2001/XMLSchema#float"
const _MT_XSD_DOUBLE = "http://www.w3.org/2001/XMLSchema#double"

function _mt_terms_equal(a, b)
    (a isa Literal && b isa Literal) || return a == b
    RDF._sp_value_equal(a, b) || return false
    # RDF's value space keeps positive and negative zero apart, so
    # "0"^^xsd:float and "-0"^^xsd:float denote different things. SPARQL does
    # not — op:numeric-equal follows IEEE, where +0 == -0 — so the distinction
    # lives here rather than in _sp_value_equal.
    dt = a.datatype.value
    if dt == b.datatype.value && (dt == _MT_XSD_FLOAT || dt == _MT_XSD_DOUBLE)
        fa = RDF._sp_to_float(a); fb = RDF._sp_to_float(b)
        (fa == 0.0 && fb == 0.0) && return signbit(fa) == signbit(fb)
    end
    return true
end

function _mt_unify!(pat, val, b::Dict{BlankNode, RDFTerm})::Bool
    if pat isa BlankNode
        haskey(b, pat) && return _mt_terms_equal(b[pat], val)
        b[pat] = val
        return true
    end
    return _mt_terms_equal(pat, val)
end

function _mt_match(closure::Graph, triples::Vector{Triple}, i::Int,
                   b::Dict{BlankNode, RDFTerm})::Bool
    i > length(triples) && return true
    t = triples[i]
    for ct in closure
        b2 = copy(b)
        _mt_unify!(t.subject,   ct.subject,   b2) || continue
        _mt_unify!(t.predicate, ct.predicate, b2) || continue
        _mt_unify!(t.object,    ct.object,    b2) || continue
        _mt_match(closure, triples, i + 1, b2) && return true
    end
    return false
end

_mt_entails(closure::Graph, concl::Graph)::Bool =
    _mt_match(closure, Triple[t for t in concl], 1, Dict{BlankNode, RDFTerm}())

# Closure of the premises under the declared regime. RDF-regime tests are run
# against the RDFS closure: RDFS entailment subsumes RDF entailment, so a
# positive RDF test that holds will still hold, though a negative one could in
# principle be entailed by the stronger regime.
function _mt_closure(g::Graph, regime::AbstractString, concl::Graph)::Graph
    lowercase(regime) == "simple" && return g
    # The container-membership axioms are an infinite schema, so infer_rdfs
    # instantiates them only for the rdf:_N a graph mentions. A conclusion may
    # name one the premises do not — `{} ⊨ rdf:_1 rdf:type
    # rdfs:ContainerMembershipProperty` — so seed those before closing.
    seeded = Graph()
    for t in g; push!(seeded, t); end
    for t in concl
        for term in (t.subject, t.predicate, t.object)
            if RDF._is_container_membership_iri(term)
                push!(seeded, Triple(term::IRI,
                                     IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                                     IRI("http://www.w3.org/2000/01/rdf-schema#ContainerMembershipProperty")))
            end
        end
    end
    return infer_rdfs(seeded)
end

# ─── Manifest ────────────────────────────────────────────────────────────────

struct _MTTest
    name::String
    positive::Bool
    regime::String
    action::String
    result::Union{String, Bool}
end

function _mt_load_tests()::Vector{_MTTest}
    mpath = joinpath(_MT_FIXTURES, "manifest.ttl")
    isfile(mpath) || return _MTTest[]
    base = "file:///" * replace(abspath(mpath), '\\' => '/')
    g = open(io -> read(io, :ttl, Graph, base), mpath)

    # Manifest entries list
    head = nothing
    for t in match(g; predicate=_MT_ENTRIES)
        head = t.object
        break
    end
    head === nothing && return _MTTest[]

    tests = _MTTest[]
    for entry in _mt_list(g, head)
        types = Set(t.object for t in match(g; subject=entry, predicate=_MT_TYPE))
        positive = _MT_POSITIVE in types
        (positive || _MT_NEGATIVE in types) || continue

        name_l = _mt_one(g, entry, _MT_NAME)
        name   = name_l isa Literal ? name_l.lexical_form : string(entry)

        act = _mt_one(g, entry, _MT_ACTION)
        act isa IRI || continue

        reg_l  = _mt_one(g, entry, _MT_REGIME)
        regime = reg_l isa Literal ? reg_l.lexical_form : "simple"

        res = _mt_one(g, entry, _MT_RESULT)
        result = if res isa IRI
            _mt_resolve(res.value)
        elseif res isa Literal
            lowercase(res.lexical_form) == "true"
        else
            continue
        end

        push!(tests, _MTTest(name, positive, regime, _mt_resolve(act.value), result))
    end
    tests
end

@testset "W3C RDF 1.1 Semantics (rdf-mt)" begin
    tests = _mt_load_tests()
    @test !isempty(tests)

    for t in tests
        @testset "$(t.name)" begin
            if t.result isa Bool
                # `mf:result false` asserts the premises are inconsistent under
                # the regime. RDFS forward-chaining materialisation derives new
                # triples but never detects a contradiction (a datatype clash,
                # or an ill-typed literal in a range), so this class of test is
                # out of reach of the current inference engine.
                @test_skip "inconsistency detection not implemented"
            elseif t.name == "literal-type"
                # `:a :b "42"^^xsd:integer` entails `:a :b _:x . _:x a xsd:integer`
                # by rdfD1, which types a literal — putting a literal in subject
                # position. RDF forbids that, and Graph holds Triples whose
                # subject is an IRI or blank node, so the closure cannot express
                # the premise this test turns on.
                @test_skip "rdfD1 literal typing needs a literal as subject"
            elseif !isfile(t.action) || !isfile(t.result)
                @test_skip "fixture file missing"
            else
                premises = _mt_load(t.action)
                concl    = _mt_load(t.result)
                closure  = _mt_closure(premises, t.regime, concl)
                if t.positive
                    @test _mt_entails(closure, concl)
                else
                    @test !_mt_entails(closure, concl)
                end
            end
        end
    end
end

end  # if isdir(_MT_FIXTURES)
