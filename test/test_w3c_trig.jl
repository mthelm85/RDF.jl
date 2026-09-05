# W3C TriG conformance tests
#
# Sources: https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-trig/
#          https://w3c.github.io/rdf-tests/rdf/rdf12/rdf-trig/
#
# Test types:
#   rdft:TestTrigEval            parse the .trig, compare with the .nq reference
#                                as datasets (blank nodes matched by bijection)
#   rdft:TestTrigPositiveSyntax  must parse without error
#   rdft:TestTrigNegativeSyntax  must raise
#
# Driven from the manifests, which carry the base IRI each test resolves its
# relative IRIs against — several tests turn on exactly that.

using Test, RDF

const _TRIG_SUITES = [
    (joinpath(@__DIR__, "w3c", "fixtures", "trig"),
     "https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-trig/",
     "W3C TriG 1.1"),
    (joinpath(@__DIR__, "w3c", "fixtures", "trig12", "eval"),
     "https://w3c.github.io/rdf-tests/rdf/rdf12/rdf-trig/eval/",
     "W3C TriG 1.2 eval"),
    (joinpath(@__DIR__, "w3c", "fixtures", "trig12", "syntax"),
     "https://w3c.github.io/rdf-tests/rdf/rdf12/rdf-trig/syntax/",
     "W3C TriG 1.2 syntax"),
]

const _TRIG_MF        = "http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#"
const _TRIG_RDFT      = "http://www.w3.org/ns/rdftest#"
const _TRIG_TYPE      = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
const _TRIG_FIRST     = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
const _TRIG_REST      = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
const _TRIG_NIL       = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
const _TRIG_ENTRIES   = IRI(_TRIG_MF * "entries")
const _TRIG_NAME      = IRI(_TRIG_MF * "name")
const _TRIG_ACTION    = IRI(_TRIG_MF * "action")
const _TRIG_RESULT    = IRI(_TRIG_MF * "result")
const _TRIG_EVAL      = IRI(_TRIG_RDFT * "TestTrigEval")
const _TRIG_POS       = IRI(_TRIG_RDFT * "TestTrigPositiveSyntax")
const _TRIG_NEG       = IRI(_TRIG_RDFT * "TestTrigNegativeSyntax")

_trig_one(g, s, p) = begin
    for t in match(g; subject=s, predicate=p); return t.object; end
    nothing
end

function _trig_list(g, head)
    out = RDFTerm[]
    node = head
    while node !== nothing && node != _TRIG_NIL
        v = _trig_one(g, node, _TRIG_FIRST)
        v === nothing && break
        push!(out, v)
        node = _trig_one(g, node, _TRIG_REST)
    end
    out
end

# Compare two datasets: default graphs and every named graph must match under a
# blank-node bijection. Graph names that are blank nodes are matched by
# structure rather than by label, since labels are not preserved.
function _trig_datasets_match(a::Dataset, b::Dataset)::Bool
    (a.default_graph ≅ b.default_graph) || return false
    length(a.named_graphs) == length(b.named_graphs) || return false

    a_iri = Dict(k => v for (k, v) in a.named_graphs if k isa IRI)
    b_iri = Dict(k => v for (k, v) in b.named_graphs if k isa IRI)
    keys(a_iri) == keys(b_iri) || return false
    for (k, g) in a_iri
        (g ≅ b_iri[k]) || return false
    end

    # Blank-node-labelled graphs: pair them off by isomorphism.
    a_bn = [v for (k, v) in a.named_graphs if k isa BlankNode]
    b_bn = [v for (k, v) in b.named_graphs if k isa BlankNode]
    length(a_bn) == length(b_bn) || return false
    remaining = collect(b_bn)
    for g in a_bn
        i = findfirst(h -> g ≅ h, remaining)
        i === nothing && return false
        deleteat!(remaining, i)
    end
    return true
end

for (dir, base, label) in _TRIG_SUITES
    isdir(dir) || continue
    mpath = joinpath(dir, "manifest.ttl")
    isfile(mpath) || continue

    g = open(io -> read(io, :ttl, Graph, base), mpath)
    head = nothing
    for t in match(g; predicate=_TRIG_ENTRIES); head = t.object; break; end
    entries = head === nothing ? RDFTerm[] : _trig_list(g, head)

    @testset "$label" begin
        @test !isempty(entries)
        for entry in entries
            types = Set(t.object for t in match(g; subject=entry, predicate=_TRIG_TYPE))
            nm_l  = _trig_one(g, entry, _TRIG_NAME)
            name  = nm_l isa Literal ? nm_l.lexical_form : string(entry)
            act   = _trig_one(g, entry, _TRIG_ACTION)
            act isa IRI || continue

            action_file = joinpath(dir, basename(act.value))
            action_base = base * basename(act.value)
            isfile(action_file) || continue

            @testset "$name" begin
                if _TRIG_EVAL in types
                    res = _trig_one(g, entry, _TRIG_RESULT)
                    res isa IRI || return
                    result_file = joinpath(dir, basename(res.value))
                    isfile(result_file) || return
                    got = open(io -> read(io, :trig, Dataset, action_base), action_file)
                    want = open(io -> read(io, :nq, Dataset), result_file)
                    @test _trig_datasets_match(got, want)
                elseif _TRIG_POS in types
                    @test_nowarn open(io -> read(io, :trig, Dataset, action_base),
                                      action_file)
                elseif _TRIG_NEG in types
                    @test_throws Exception open(
                        io -> read(io, :trig, Dataset, action_base), action_file)
                end
            end
        end
    end
end
