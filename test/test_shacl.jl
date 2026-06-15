using Test
using RDF
import RDF: Graph

# ── SHACL core validation ──────────────────────────────────────────────────────
#
# Hand-written unit tests for the public API, plus the official W3C SHACL core
# test suite (vendored under test/w3c/fixtures/shacl/core).

const _sx = Namespace("http://shacl-test.example.org/")

@testset "SHACL — unit" begin
    @testset "datatype + minCount on a property shape" begin
        shapes = Graph()
        sh = _sx.PersonShape
        push!(shapes, Triple(sh, rdf.type, RDF._sh("NodeShape")))
        push!(shapes, Triple(sh, RDF._sh("targetClass"), _sx.Person))
        ps = blank!(shapes)
        push!(shapes, Triple(sh, RDF._sh("property"), ps))
        push!(shapes, Triple(ps, RDF._sh("path"), _sx.age))
        push!(shapes, Triple(ps, RDF._sh("datatype"), xsd.integer))
        push!(shapes, Triple(ps, RDF._sh("minCount"), Literal(1)))

        good = Graph()
        push!(good, Triple(_sx.alice, rdf.type, _sx.Person))
        push!(good, Triple(_sx.alice, _sx.age, Literal(30)))
        @test conforms(good, shapes)

        bad = Graph()
        push!(bad, Triple(_sx.bob, rdf.type, _sx.Person))
        push!(bad, Triple(_sx.bob, _sx.age, Literal("old")))   # wrong datatype
        rep = validate_shapes(bad, shapes)
        @test !rep.conforms
        @test !conforms(bad, shapes)
        @test any(r -> r.component == RDF._sh("DatatypeConstraintComponent") &&
                       r.focus_node == _sx.bob && r.path == _sx.age, rep.results)

        missing = Graph()
        push!(missing, Triple(_sx.carol, rdf.type, _sx.Person))   # no age at all
        rep2 = validate_shapes(missing, shapes)
        @test !rep2.conforms
        @test any(r -> r.component == RDF._sh("MinCountConstraintComponent"), rep2.results)
    end

    @testset "nodeKind + in on a node shape (targetNode)" begin
        shapes = Graph()
        sh = _sx.ColorShape
        push!(shapes, Triple(sh, rdf.type, RDF._sh("NodeShape")))
        push!(shapes, Triple(sh, RDF._sh("targetNode"), _sx.red))
        push!(shapes, Triple(sh, RDF._sh("targetNode"), Literal("green")))
        push!(shapes, Triple(sh, RDF._sh("nodeKind"), RDF._sh("IRI")))
        data = Graph()
        rep = validate_shapes(data, shapes)
        # the literal target violates nodeKind sh:IRI; the IRI target conforms
        @test !rep.conforms
        @test any(r -> r.focus_node == Literal("green") &&
                       r.component == RDF._sh("NodeKindConstraintComponent"), rep.results)
        @test !any(r -> r.focus_node == _sx.red, rep.results)
    end

    @testset "empty shapes graph conforms" begin
        @test conforms(Graph(), Graph())
    end

    @testset "to_prompt(::ValidationReport) for LLM self-correction" begin
        shapes = Graph()
        sh = _sx.PersonShape
        push!(shapes, Triple(sh, rdf.type, RDF._sh("NodeShape")))
        push!(shapes, Triple(sh, RDF._sh("targetClass"), _sx.Person))
        ps = blank!(shapes)
        push!(shapes, Triple(sh, RDF._sh("property"), ps))
        push!(shapes, Triple(ps, RDF._sh("path"), _sx.age))
        push!(shapes, Triple(ps, RDF._sh("datatype"), xsd.integer))

        bad = Graph()
        push!(bad, Triple(_sx.bob, rdf.type, _sx.Person))
        push!(bad, Triple(_sx.bob, _sx.age, Literal("old")))
        rep = validate_shapes(bad, shapes)

        txt = to_prompt(rep)
        @test txt isa String
        @test occursin("bob", txt)
        @test occursin("age", txt)
        # a conforming report renders a short positive message, not empty
        ok = validate_shapes(Graph(), shapes)
        @test ok.conforms
        @test occursin("conforms", lowercase(to_prompt(ok)))
    end

    @testset "keep-conforming filter (extraction guardrail)" begin
        shapes = Graph()
        sh = _sx.S
        push!(shapes, Triple(sh, rdf.type, RDF._sh("NodeShape")))
        push!(shapes, Triple(sh, RDF._sh("targetClass"), _sx.Person))
        ps = blank!(shapes)
        push!(shapes, Triple(sh, RDF._sh("property"), ps))
        push!(shapes, Triple(ps, RDF._sh("path"), _sx.age))
        push!(shapes, Triple(ps, RDF._sh("datatype"), xsd.integer))

        g = Graph()
        push!(g, Triple(_sx.a, rdf.type, _sx.Person))
        push!(g, Triple(_sx.a, _sx.age, Literal(30)))     # ok
        push!(g, Triple(_sx.b, rdf.type, _sx.Person))
        push!(g, Triple(_sx.b, _sx.age, Literal("bad")))  # violates

        kept = conforming(g, shapes)
        @test kept isa Graph
        @test conforms(kept, shapes)
        @test Triple(_sx.a, _sx.age, Literal(30)) in kept
        # the violating focus node's triples are dropped
        @test isempty(collect(match(kept; subject=_sx.b)))
    end
end

# ── W3C SHACL core test suite ──────────────────────────────────────────────────

const _SHACL_DIR = joinpath(@__DIR__, "w3c", "fixtures", "shacl", "core")

# Vocabulary used by the test manifests
const _MF_NS  = "http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#"
const _SHT_NS = "http://www.w3.org/ns/shacl-test#"
const _MF_RESULT = IRI(_MF_NS * "result")
const _MF_ACTION = IRI(_MF_NS * "action")
const _SHT_VALIDATE = IRI(_SHT_NS * "Validate")

const _SHT_DATA   = IRI(_SHT_NS * "dataGraph")
const _SHT_SHAPES = IRI(_SHT_NS * "shapesGraph")

_one(g, s, p) = (for t in match(g; subject=s, predicate=p); return t.object; end; nothing)

_sh_test_entry(g::Graph) = begin
    e = nothing
    for t in match(g; predicate=IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                      object=_SHT_VALIDATE); e = t.subject; break; end
    e
end

# Resolve a sht:dataGraph / sht:shapesGraph reference: `<>` (the test's own base)
# reuses `g`; an external file is loaded relative to the test file.
function _resolve_graph(g::Graph, base::String, testpath::String, gref)
    (gref isa IRI && gref.value == base) && return g
    gref isa IRI || return g
    fname = last(split(gref.value, '/'))
    fpath = joinpath(dirname(testpath), fname)
    b2 = "file:///" * replace(fpath, "\\" => "/")
    open(io -> read(io, MIME"text/turtle"(), Graph, b2), fpath)
end

# Parse the expected report from a test graph into comparable tuples.
function _expected(g::Graph)
    entry = _sh_test_entry(g)
    entry === nothing && return (nothing, nothing)
    rep = _one(g, entry, _MF_RESULT)
    rep === nothing && return (nothing, nothing)
    conf = _one(g, rep, RDF._sh("conforms"))
    conforms = conf isa Literal && conf.lexical_form == "true"
    tuples = Tuple[]
    for t in match(g; subject=rep, predicate=RDF._sh("result"))
        r = t.object
        push!(tuples, (
            _one(g, r, RDF._sh("focusNode")),
            _one(g, r, RDF._sh("resultPath")),     # IRI for predicate paths
            _one(g, r, RDF._sh("value")),
            _one(g, r, RDF._sh("sourceConstraintComponent")),
            _one(g, r, RDF._sh("sourceShape")),
            _one(g, r, RDF._sh("resultSeverity")),
        ))
    end
    (conforms, tuples)
end

function _actual_tuples(rep::ValidationReport)
    [(r.focus_node, r.path, r.value, r.component, r.source_shape, r.severity)
     for r in rep.results]
end

# Structural equality of two SHACL property paths.  The expected report restates
# complex (blank-node) paths as fresh blank nodes, so they cannot be compared by
# identity — only by the path expression they describe.
function _sh_path_eq(g::Graph, a, b)
    a === nothing && return b === nothing
    b === nothing && return false
    a isa IRI && b isa IRI && return a == b
    (a isa IRI) != (b isa IRI) && return false
    # both blank-node path expressions: compare each construct recursively
    for kind in ("inversePath", "zeroOrMorePath", "oneOrMorePath", "zeroOrOnePath")
        pa = _one(g, a, RDF._sh(kind)); pb = _one(g, b, RDF._sh(kind))
        (pa === nothing) != (pb === nothing) && return false
        pa !== nothing && return _sh_path_eq(g, pa, pb)
    end
    aa = _one(g, a, RDF._sh("alternativePath")); ab = _one(g, b, RDF._sh("alternativePath"))
    if aa !== nothing || ab !== nothing
        (aa !== nothing && ab !== nothing) || return false
        return _sh_pathlist_eq(g, _list(g, aa), _list(g, ab))
    end
    # otherwise a sequence path (an rdf:List)
    _sh_pathlist_eq(g, _list(g, a), _list(g, b))
end

_sh_pathlist_eq(g, la, lb) =
    length(la) == length(lb) && all(i -> _sh_path_eq(g, la[i], lb[i]), eachindex(la))

function _list(g::Graph, node)
    out = RDFTerm[]; cur = node
    nil = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
    first_p = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
    rest_p  = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
    while cur isa Union{IRI,BlankNode} && cur != nil
        f = _one(g, cur, first_p); f === nothing && break
        push!(out, f); cur = _one(g, cur, rest_p); cur === nothing && break
    end
    out
end

# A result tuple matches if every field is equal, with paths compared
# structurally (slot 2).
function _tuple_eq(g::Graph, x, y)
    x[1] == y[1] && _sh_path_eq(g, x[2], y[2]) && x[3] == y[3] &&
        x[4] == y[4] && x[5] == y[5] && x[6] == y[6]
end

# Order-independent multiset equality under a graph-aware element predicate.
function _bag_equal(g::Graph, a, b)
    length(a) == length(b) || return false
    rem = collect(b)
    for x in a
        i = findfirst(y -> _tuple_eq(g, x, y), rem)
        i === nothing && return false
        deleteat!(rem, i)
    end
    true
end

# Known-unsupported core tests (the ~7% long tail), skipped with a reason:
#   - XSD facet range validation (e.g. xsd:byte out of range)
#   - xsd:dateTime partial ordering across timezones
#   - sh:qualifiedValueShapesDisjoint (sibling-shape exclusion)
#   - a few exotic property-path edge cases
#   - the recursive SHACL-of-SHACL meta validation
const _SHACL_KNOWN_UNSUPPORTED = Set{String}([
    "complex/shacl-shacl.ttl",
    "node/minInclusive-002.ttl",
    "node/minInclusive-003.ttl",
    "path/path-complex-002.ttl",
    "path/path-strange-001.ttl",
    "path/path-strange-002.ttl",
    "property/datatype-ill-formed.ttl",
    "property/qualifiedMinCountDisjoint-001.ttl",
    "property/qualifiedValueShapesDisjoint-001.ttl",
])

if isdir(_SHACL_DIR)
    test_files = String[]
    for (root, _, files) in walkdir(_SHACL_DIR), f in files
        f == "manifest.ttl" && continue
        endswith(f, ".ttl") && push!(test_files, joinpath(root, f))
    end

    @testset "W3C SHACL core" begin
        for path in sort(test_files)
            name = relpath(path, _SHACL_DIR)
            base = "file:///" * replace(path, "\\" => "/")
            g = open(io -> read(io, MIME"text/turtle"(), Graph, base), path)
            # Only files containing an sht:Validate entry are tests; the rest
            # (referenced *-data.ttl / *-shapes.ttl) are skipped silently.
            entry = _sh_test_entry(g)
            entry === nothing && continue
            @testset "$name" begin
                if replace(name, "\\" => "/") in _SHACL_KNOWN_UNSUPPORTED
                    @test_skip name
                else
                    exp_conforms, exp_tuples = _expected(g)
                    action = _one(g, entry, _MF_ACTION)
                    data   = _resolve_graph(g, base, path, _one(g, action, _SHT_DATA))
                    shapes = _resolve_graph(g, base, path, _one(g, action, _SHT_SHAPES))
                    rep = validate_shapes(data, shapes)
                    @test rep.conforms == exp_conforms
                    @test _bag_equal(g, _actual_tuples(rep), exp_tuples)
                end
            end
        end
    end
else
    error("SHACL fixtures missing at $_SHACL_DIR")
end
