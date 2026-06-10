using Test
using RDF
import RDF: Graph

# ── BGP join reordering ────────────────────────────────────────────────────────
#
# TDD spec for selectivity-based reordering of basic graph patterns.
#
# Contract under test:
#   • RDF._count_ids(g, s_id, p_id, o_id) -> Int
#       Exact number of triples matching the pattern (UInt32 ids for bound
#       positions, `nothing` for wildcards, UInt32(0) = known-absent term).
#       O(log n) — two binary searches on the hexastore.
#   • RDF._sp_reorder_bgp(triples, ctx, bound::Set{Symbol}) -> Vector{<:Any}
#       Returns a permutation of `triples` ordered for evaluation: most
#       selective first, patterns connected to already-bound variables
#       preferred over disconnected ones (Cartesian-product avoidance).
#   • sparql() results are identical regardless of the order patterns are
#       written in the query (semantics preserved).

const _jr_ex   = Namespace("http://jr-test.example.org/")
const _jr_foaf = Namespace("http://xmlns.com/foaf/0.1/")

# Extract the first SpBGP from a parsed query pattern.
function _jr_first_bgp(pat)
    pat isa RDF.SpBGP   && return pat
    pat isa RDF.SpGroup && for el in pat.elements
        b = _jr_first_bgp(el)
        b !== nothing && return b
    end
    nothing
end

function _jr_bgp_triples(query::String)
    unit = RDF.sparql_parse(query)
    bgp  = _jr_first_bgp(unit.query.pattern)
    @assert bgp !== nothing "test query has no BGP"
    bgp.triples
end

# Order-insensitive comparison of two SolutionSets over the same variables.
function _jr_rows(ss::SolutionSet)
    sort([join([repr(row[v]) for v in ss.variables], "|") for row in ss])
end

@testset "BGP join reordering" begin

    # ── Fixture graph ──────────────────────────────────────────────────────────
    # 1000 persons; everyone has a type and a name, only person_1 is named
    # "needle", only 10 persons have an age, person_i knows person_{i+1}.
    g = Graph()
    for i in 1:1000
        s = _jr_ex["person_$i"]
        push!(g, Triple(s, rdf.type, _jr_foaf.Person))
        push!(g, Triple(s, _jr_foaf.name,
                        Literal(i == 1 ? "needle" : "person $i")))
        i <= 10  && push!(g, Triple(s, _jr_foaf.age, Literal(20 + i)))
        i < 1000 && push!(g, Triple(s, _jr_foaf.knows, _jr_ex["person_$(i+1)"]))
    end

    @testset "_count_ids — exact cardinalities" begin
        sid  = term_id(_jr_ex.person_1)
        pid_type  = term_id(rdf.type)
        pid_name  = term_id(_jr_foaf.name)
        pid_age   = term_id(_jr_foaf.age)
        oid_person = term_id(_jr_foaf.Person)
        oid_needle = term_id(Literal("needle"))

        # all 8 binding combinations
        @test RDF._count_ids(g, nothing, nothing, nothing) == length(g)
        @test RDF._count_ids(g, sid, nothing, nothing) == 4      # type+name+age+knows
        @test RDF._count_ids(g, nothing, pid_type, nothing) == 1000
        @test RDF._count_ids(g, nothing, nothing, oid_person) == 1000
        @test RDF._count_ids(g, sid, pid_type, nothing) == 1
        @test RDF._count_ids(g, sid, nothing, oid_person) == 1
        @test RDF._count_ids(g, nothing, pid_name, oid_needle) == 1
        @test RDF._count_ids(g, sid, pid_type, oid_person) == 1
        @test RDF._count_ids(g, nothing, pid_age, nothing) == 10

        # absent term (UInt32(0)) and non-matching combination
        @test RDF._count_ids(g, UInt32(0), nothing, nothing) == 0
        @test RDF._count_ids(g, sid, pid_age, oid_person) == 0

        # empty graph
        @test RDF._count_ids(Graph(), nothing, nothing, nothing) == 0
    end

    @testset "reorder — most selective pattern first" begin
        triples = _jr_bgp_triples("""
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            PREFIX ex:   <http://jr-test.example.org/>
            SELECT * WHERE {
              ?s a foaf:Person .
              ?s foaf:name "needle" .
            }""")
        ctx = RDF._SpEvalCtx(g, nothing)
        ordered = RDF._sp_reorder_bgp(triples, ctx, Set{Symbol}())

        @test length(ordered) == 2
        @test Set(ordered) == Set(triples)        # permutation, nothing dropped
        # the 1-match name pattern must run before the 1000-match type pattern
        @test ordered[1] === triples[2]
    end

    @testset "reorder — connected patterns preferred over disconnected" begin
        triples = _jr_bgp_triples("""
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT * WHERE {
              ?a foaf:knows ?b .
              ?c foaf:age ?age .
              ?a foaf:name "needle" .
            }""")
        ctx = RDF._SpEvalCtx(g, nothing)
        ordered = RDF._sp_reorder_bgp(triples, ctx, Set{Symbol}())

        @test Set(ordered) == Set(triples)
        # name-needle (count 1) first; then the knows pattern (shares ?a with
        # the bound set) must come before the disconnected age pattern even
        # though age (10) is smaller than knows (999).
        @test ordered[1] === triples[3]
        @test ordered[2] === triples[1]
        @test ordered[3] === triples[2]
    end

    @testset "reorder — pre-bound variables count as connections" begin
        triples = _jr_bgp_triples("""
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT * WHERE {
              ?c foaf:age ?age .
              ?a foaf:knows ?b .
            }""")
        ctx = RDF._SpEvalCtx(g, nothing)
        # With ?a and ?b already bound (e.g. by a preceding BGP), the knows
        # pattern is connected and should be preferred over the smaller but
        # disconnected age pattern.
        ordered = RDF._sp_reorder_bgp(triples, ctx, Set{Symbol}([:a, :b]))
        @test ordered[1] === triples[2]
        @test ordered[2] === triples[1]
    end

    @testset "reorder — complex property paths deferred" begin
        triples = _jr_bgp_triples("""
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT * WHERE {
              ?a foaf:knows+ ?b .
              ?a foaf:name "needle" .
            }""")
        ctx = RDF._SpEvalCtx(g, nothing)
        ordered = RDF._sp_reorder_bgp(triples, ctx, Set{Symbol}())
        # the selective plain triple runs first so the transitive closure
        # starts from a single subject
        @test ordered[1] === triples[2]
    end

    @testset "reorder — degenerate inputs unchanged" begin
        ctx = RDF._SpEvalCtx(g, nothing)
        @test RDF._sp_reorder_bgp(RDF.SpTriple[], ctx, Set{Symbol}()) == RDF.SpTriple[]
        single = _jr_bgp_triples("SELECT * WHERE { ?s ?p ?o }")
        @test RDF._sp_reorder_bgp(single, ctx, Set{Symbol}()) == single
    end

    # ── Semantics: results must not depend on written pattern order ───────────
    @testset "equivalence — permuted pattern orders give identical results" begin
        q_good = """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?s ?age WHERE {
              ?s foaf:name "needle" .
              ?s a foaf:Person .
              OPTIONAL { ?s foaf:age ?age }
            }"""
        q_bad = """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?s ?age WHERE {
              ?s a foaf:Person .
              ?s foaf:name "needle" .
              OPTIONAL { ?s foaf:age ?age }
            }"""
        r_good = sparql(g, q_good)
        r_bad  = sparql(g, q_bad)
        @test _jr_rows(r_good) == _jr_rows(r_bad)
        @test length(r_good) == 1
        @test r_good[1][:s] == _jr_ex.person_1

        # join across knows-chain, three orderings
        base_pats = [
            "?x foaf:name \"needle\" .",
            "?x foaf:knows ?y .",
            "?y foaf:knows ?z .",
        ]
        results = map([(1,2,3), (3,2,1), (2,3,1)]) do perm
            q = """
                PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                SELECT ?x ?y ?z WHERE { $(join(base_pats[collect(perm)], "\n")) }"""
            _jr_rows(sparql(g, q))
        end
        @test results[1] == results[2] == results[3]
        @test length(results[1]) == 1
    end

    @testset "equivalence — self-join and blank-node patterns survive reorder" begin
        g2 = Graph()
        b  = blank!(g2)
        push!(g2, Triple(b, _jr_foaf.name, Literal("anon")))
        push!(g2, Triple(b, rdf.type, _jr_foaf.Person))
        push!(g2, Triple(_jr_ex.alice, _jr_foaf.knows, _jr_ex.alice))  # self-loop
        push!(g2, Triple(_jr_ex.alice, rdf.type, _jr_foaf.Person))

        # same var in subject and object position
        r = sparql(g2, """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            SELECT ?p WHERE { ?p foaf:knows ?p . ?p a foaf:Person . }""")
        @test length(r) == 1
        @test r[1][:p] == _jr_ex.alice
    end

    # ── Performance guard: Cartesian-product trap ─────────────────────────────
    # Written in the worst order: two large disconnected patterns first, the
    # selective anchors last.  Without reordering this materialises a
    # |p1| × |p2| = 36M-row intermediate (~2-4 s); with reordering it never
    # exceeds a handful of rows (~1 ms), so the 1 s bound has a wide margin
    # on both sides.
    @testset "performance — Cartesian trap completes quickly" begin
        gx = Graph()
        for i in 1:6000
            push!(gx, Triple(_jr_ex["s$i"], _jr_ex.p1, _jr_ex["o$i"]))
            push!(gx, Triple(_jr_ex["t$i"], _jr_ex.p2, _jr_ex["u$i"]))
        end
        push!(gx, Triple(_jr_ex.s1, _jr_foaf.name, Literal("anchor1")))
        push!(gx, Triple(_jr_ex.t1, _jr_foaf.name, Literal("anchor2")))

        q = """
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>
            PREFIX ex:   <http://jr-test.example.org/>
            SELECT ?a ?b ?c ?d WHERE {
              ?a ex:p1 ?b .
              ?c ex:p2 ?d .
              ?a foaf:name "anchor1" .
              ?c foaf:name "anchor2" .
            }"""
        sparql(gx, q)  # warm up compilation on the first call
        elapsed = @elapsed r = sparql(gx, q)
        @test length(r) == 1
        @test r[1][:a] == _jr_ex.s1
        @test r[1][:c] == _jr_ex.t1
        @test elapsed < 1.0
    end
end
