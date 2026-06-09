using RDF
using Test
using Graphs
using SimpleWeightedGraphs
# Graphs.jl also exports `Graph` — explicitly bring in RDF.Graph to resolve ambiguity
import RDF: Graph
# _resolve is an internal helper used extensively in these tests
const _resolve = RDF._resolve

# ─────────────────────────────────────────────────────────────────────────────
# Shared fixtures
# ─────────────────────────────────────────────────────────────────────────────

const _ex   = Namespace("http://example.org/")
const _foaf = Namespace("http://xmlns.com/foaf/0.1/")

# Social network: 5 triples, 4 unique terms (alice, bob, carol, Person)
#   alice --foaf:knows--> bob
#   alice --foaf:knows--> carol
#   bob   --foaf:knows--> carol
#   alice --rdf:type-->   Person
#   bob   --rdf:type-->   Person
# Unique (s,o) pairs: (alice,bob),(alice,carol),(bob,carol),(alice,Person),(bob,Person) → 5 edges
function _social_graph()
    g = Graph()
    push!(g, Triple(_ex.alice, _foaf.knows, _ex.bob))
    push!(g, Triple(_ex.alice, _foaf.knows, _ex.carol))
    push!(g, Triple(_ex.bob,   _foaf.knows, _ex.carol))
    push!(g, Triple(_ex.alice, rdf.type,    _ex.Person))
    push!(g, Triple(_ex.bob,   rdf.type,    _ex.Person))
    g
end

# Multi-predicate between the same pair:
#   alice --foaf:knows--> bob
#   alice --foaf:age-->   bob   (weird semantically, but valid for testing)
function _multi_pred_graph()
    g = Graph()
    push!(g, Triple(_ex.alice, _foaf.knows, _ex.bob))
    push!(g, Triple(_ex.alice, _foaf.age,   _ex.bob))
    g
end

# Literal objects:
#   alice --foaf:name--> "Alice"
#   alice --foaf:age-->  30
function _literal_graph()
    g = Graph()
    push!(g, Triple(_ex.alice, _foaf.name, Literal("Alice")))
    push!(g, Triple(_ex.alice, _foaf.age,  Literal(30)))
    g
end

# Self-loop:
#   alice --ex:related--> alice
function _selfloop_graph()
    g = Graph()
    push!(g, Triple(_ex.alice, _ex.related, _ex.alice))
    g
end

# Weighted: literal-valued objects for testing numeric weights
#   a --ex:cost--> 10.0
#   b --ex:cost--> 25.5
#   c --ex:cost--> 0.5
function _weight_graph()
    g = Graph()
    push!(g, Triple(_ex.a, _ex.cost, Literal(10.0)))
    push!(g, Triple(_ex.b, _ex.cost, Literal(25.5)))
    push!(g, Triple(_ex.c, _ex.cost, Literal(0.5)))
    g
end

# Chain: a → b → c → d (single predicate, useful for path algorithms)
function _chain_graph()
    g = Graph()
    push!(g, Triple(_ex.a, _ex.next, _ex.b))
    push!(g, Triple(_ex.b, _ex.next, _ex.c))
    push!(g, Triple(_ex.c, _ex.next, _ex.d))
    g
end

# Two disconnected components: {a,b} and {c,d}
function _disconnected_graph()
    g = Graph()
    push!(g, Triple(_ex.a, _ex.knows, _ex.b))
    push!(g, Triple(_ex.c, _ex.knows, _ex.d))
    g
end


@testset "Graph Conversion (Graphs.jl integration)" begin

    # ─────────────────────────────────────────────────────────────────────────
    # 1. to_digraph(g) — all-predicates projection
    # ─────────────────────────────────────────────────────────────────────────

    @testset "to_digraph(g) — all predicates" begin

        @testset "empty graph → empty digraph" begin
            result = to_digraph(Graph())
            @test result.graph isa SimpleDiGraph
            @test nv(result.graph) == 0
            @test ne(result.graph) == 0
            @test isempty(result.terms)
        end

        @testset "single triple → 2 vertices, 1 edge" begin
            g = Graph()
            push!(g, Triple(_ex.alice, rdf.type, _ex.Person))
            result = to_digraph(g)
            @test nv(result.graph) == 2
            @test ne(result.graph) == 1
            @test length(result.terms) == 2
        end

        @testset "social graph — vertex and edge counts" begin
            result = to_digraph(_social_graph())
            # 4 unique terms: alice, bob, carol, Person
            @test nv(result.graph) == 4
            # 5 unique (s,o) pairs
            @test ne(result.graph) == 5
            @test length(result.terms) == 4
        end

        @testset "multi-predicate pair collapses to one edge" begin
            result = to_digraph(_multi_pred_graph())
            # 2 unique terms (alice, bob), but only 1 (s,o) pair
            @test nv(result.graph) == 2
            @test ne(result.graph) == 1
        end

        @testset "directionality: alice→bob edge, not bob→alice" begin
            result = to_digraph(_social_graph())
            terms = result.terms
            dg    = result.graph
            alice_v = findfirst(id -> _resolve(id) == _ex.alice, terms)
            bob_v   = findfirst(id -> _resolve(id) == _ex.bob,   terms)
            @test alice_v !== nothing
            @test bob_v   !== nothing
            @test has_edge(dg, alice_v, bob_v)
            @test !has_edge(dg, bob_v, alice_v)   # no reverse triple
        end

        @testset "literal objects included as sink vertices" begin
            result = to_digraph(_literal_graph())
            terms = result.terms
            dg    = result.graph
            # alice, "Alice", 30 → 3 vertices
            @test nv(dg) == 3
            @test ne(dg) == 2
            # literal vertices have out-degree 0
            lit_vtxs = [i for (i, id) in enumerate(terms)
                        if _resolve(id) isa Literal]
            @test length(lit_vtxs) == 2
            @test all(outdegree(dg, v) == 0 for v in lit_vtxs)
        end

        @testset "self-loop triple" begin
            result = to_digraph(_selfloop_graph())
            @test nv(result.graph) == 1
            @test ne(result.graph) == 1
            @test has_edge(result.graph, 1, 1)
        end

        @testset "terms vector maps every vertex back to an RDFTerm" begin
            result = to_digraph(_social_graph())
            @test all(result.terms[v] isa UInt32 for v in vertices(result.graph))
            resolved = _resolve.(result.terms)
            @test _ex.alice in resolved
            @test _ex.bob   in resolved
            @test _ex.carol in resolved
            @test _ex.Person in resolved
        end

        @testset "vertex indices are 1:nv" begin
            result = to_digraph(_social_graph())
            @test collect(vertices(result.graph)) == 1:nv(result.graph)
        end

        @testset "blank node subjects and objects become vertices" begin
            g = Graph()
            b = blank!(g)
            push!(g, Triple(b, rdf.type, _ex.Person))
            result = to_digraph(g)
            @test nv(result.graph) == 2
            @test ne(result.graph) == 1
            resolved = _resolve.(result.terms)
            @test any(t isa BlankNode for t in resolved)
        end

    end

    # ─────────────────────────────────────────────────────────────────────────
    # 2. to_digraph(g, pred) — single-predicate projection
    # ─────────────────────────────────────────────────────────────────────────

    @testset "to_digraph(g, pred) — single predicate" begin

        @testset "knows subgraph has only knows-connected terms" begin
            result = to_digraph(_social_graph(), _foaf.knows)
            # alice→bob, alice→carol, bob→carol: vertices = {alice,bob,carol}
            @test nv(result.graph) == 3
            @test ne(result.graph) == 3
            resolved = Set(_resolve.(result.terms))
            @test _ex.alice in resolved
            @test _ex.bob   in resolved
            @test _ex.carol in resolved
            # Person is NOT in this subgraph
            @test _ex.Person ∉ resolved
        end

        @testset "type subgraph has only type-connected terms" begin
            result = to_digraph(_social_graph(), rdf.type)
            # alice→Person, bob→Person: vertices = {alice,bob,Person}
            @test nv(result.graph) == 3
            @test ne(result.graph) == 2
            resolved = Set(_resolve.(result.terms))
            @test _ex.alice  in resolved
            @test _ex.bob    in resolved
            @test _ex.Person in resolved
            @test _ex.carol ∉ resolved
        end

        @testset "predicate not in graph → empty digraph" begin
            result = to_digraph(_social_graph(), _ex.nonexistent)
            @test nv(result.graph) == 0
            @test ne(result.graph) == 0
            @test isempty(result.terms)
        end

        @testset "single-predicate result has correct directionality" begin
            result = to_digraph(_social_graph(), _foaf.knows)
            terms = result.terms
            dg    = result.graph
            alice_v = findfirst(id -> _resolve(id) == _ex.alice, terms)
            carol_v = findfirst(id -> _resolve(id) == _ex.carol, terms)
            @test alice_v !== nothing && carol_v !== nothing
            @test has_edge(dg, alice_v, carol_v)
            @test !has_edge(dg, carol_v, alice_v)
        end

        @testset "chain subgraph has correct structure" begin
            result = to_digraph(_chain_graph(), _ex.next)
            @test nv(result.graph) == 4   # a, b, c, d
            @test ne(result.graph) == 3   # a→b, b→c, c→d
        end

        @testset "terms vector covers exactly the predicate's subjects and objects" begin
            result = to_digraph(_social_graph(), rdf.type)
            resolved = Set(_resolve.(result.terms))
            # Only terms that appear in rdf:type triples
            @test all(t in resolved for t in [_ex.alice, _ex.bob, _ex.Person])
            @test _ex.carol ∉ resolved
        end

        @testset "empty graph with any predicate → empty digraph" begin
            result = to_digraph(Graph(), _foaf.knows)
            @test nv(result.graph) == 0
            @test ne(result.graph) == 0
        end

    end

    # ─────────────────────────────────────────────────────────────────────────
    # 3. to_weighted_digraph
    # ─────────────────────────────────────────────────────────────────────────

    @testset "to_weighted_digraph" begin

        @testset "returns SimpleWeightedDiGraph" begin
            result = to_weighted_digraph(_weight_graph(), _ex.cost; weight = o -> 1.0)
            @test result.graph isa SimpleWeightedDiGraph
        end

        @testset "correct vertex and edge counts" begin
            result = to_weighted_digraph(_weight_graph(), _ex.cost; weight = o -> 1.0)
            # a→Lit(10.0), b→Lit(25.5), c→Lit(0.5): 6 unique terms, 3 edges
            @test nv(result.graph) == 6
            @test ne(result.graph) == 3
        end

        @testset "constant weight function" begin
            result = to_weighted_digraph(_weight_graph(), _ex.cost; weight = o -> 42.0)
            dg = result.graph
            # SimpleWeightedDiGraph stores weights[dst, src]; use e.weight from the edge iter
            for e in edges(dg)
                @test e.weight ≈ 42.0
            end
        end

        @testset "numeric literal weight via object value" begin
            weight_fn = obj -> begin
                obj isa Literal || return NaN
                v = tryparse(Float64, obj.lexical_form)
                v === nothing ? NaN : v
            end
            result = to_weighted_digraph(_weight_graph(), _ex.cost; weight = weight_fn)
            terms = result.terms
            dg    = result.graph
            # Find the edge from 'a' to its literal object and check weight ≈ 10.0
            a_v = findfirst(id -> _resolve(id) == _ex.a, terms)
            @test a_v !== nothing
            # SimpleWeightedDiGraph.weights is indexed [dst, src]
            weights_from_a = [dg.weights[nb, a_v] for nb in outneighbors(dg, a_v)]
            @test any(w ≈ 10.0 for w in weights_from_a)
        end

        @testset "predicate not in graph → empty weighted digraph" begin
            result = to_weighted_digraph(_weight_graph(), _ex.nonexistent; weight = o -> 1.0)
            @test nv(result.graph) == 0
            @test ne(result.graph) == 0
        end

        @testset "terms vector covers predicate's subjects and objects" begin
            result = to_weighted_digraph(_weight_graph(), _ex.cost; weight = o -> 1.0)
            resolved = Set(_resolve.(result.terms))
            @test _ex.a in resolved
            @test _ex.b in resolved
            @test _ex.c in resolved
        end

        @testset "Dijkstra's shortest path works on weighted result" begin
            # a --1.0--> b --2.0--> c, check path cost a→c = 3.0
            g = Graph()
            push!(g, Triple(_ex.a, _ex.route, _ex.b))
            push!(g, Triple(_ex.b, _ex.route, _ex.c))
            edges_weight = Dict(_ex.b => 1.0, _ex.c => 2.0)
            result = to_weighted_digraph(g, _ex.route;
                                         weight = o -> get(edges_weight, o, 1.0))
            terms = result.terms
            dg    = result.graph
            a_v   = findfirst(id -> _resolve(id) == _ex.a, terms)
            c_v   = findfirst(id -> _resolve(id) == _ex.c, terms)
            @test a_v !== nothing && c_v !== nothing
            ds = dijkstra_shortest_paths(dg, a_v)
            @test ds.dists[c_v] ≈ 3.0
        end

    end

    # ─────────────────────────────────────────────────────────────────────────
    # 4. RDFDiGraph — AbstractGraph interface
    # ─────────────────────────────────────────────────────────────────────────

    @testset "RDFDiGraph — AbstractGraph interface" begin

        @testset "is a concrete Graphs.AbstractGraph" begin
            rdfdg = RDFDiGraph(_social_graph())
            @test rdfdg isa Graphs.AbstractGraph{Int}
            @test is_directed(typeof(rdfdg))
            @test is_directed(rdfdg)
        end

        @testset "nv — number of unique terms" begin
            @test nv(RDFDiGraph(Graph()))       == 0
            @test nv(RDFDiGraph(_social_graph())) == 4   # alice,bob,carol,Person
            @test nv(RDFDiGraph(_literal_graph())) == 3  # alice,"Alice",30
            @test nv(RDFDiGraph(_selfloop_graph())) == 1 # alice
        end

        @testset "ne — number of unique (src,dst) vertex pairs" begin
            @test ne(RDFDiGraph(Graph()))         == 0
            @test ne(RDFDiGraph(_social_graph())) == 5
            # multi-predicate: 2 triples, 1 unique (s,o) pair → ne=1
            @test ne(RDFDiGraph(_multi_pred_graph())) == 1
            @test ne(RDFDiGraph(_selfloop_graph()))   == 1
        end

        @testset "vertices returns 1:nv" begin
            rdfdg = RDFDiGraph(_social_graph())
            @test collect(vertices(rdfdg)) == 1:nv(rdfdg)
        end

        @testset "has_vertex" begin
            rdfdg = RDFDiGraph(_social_graph())
            @test has_vertex(rdfdg, 1)
            @test has_vertex(rdfdg, nv(rdfdg))
            @test !has_vertex(rdfdg, 0)
            @test !has_vertex(rdfdg, nv(rdfdg) + 1)
        end

        @testset "has_edge" begin
            rdfdg = RDFDiGraph(_social_graph())
            alice_v = vertex_id(rdfdg, _ex.alice)
            bob_v   = vertex_id(rdfdg, _ex.bob)
            carol_v = vertex_id(rdfdg, _ex.carol)
            @test alice_v > 0 && bob_v > 0 && carol_v > 0
            @test has_edge(rdfdg, alice_v, bob_v)       # alice knows bob
            @test has_edge(rdfdg, alice_v, carol_v)     # alice knows carol
            @test has_edge(rdfdg, bob_v, carol_v)       # bob knows carol
            @test !has_edge(rdfdg, bob_v, alice_v)      # no reverse edge
            @test !has_edge(rdfdg, carol_v, alice_v)
            # multi-predicate: still one edge in the graph
            rdfdg2 = RDFDiGraph(_multi_pred_graph())
            a_v = vertex_id(rdfdg2, _ex.alice)
            b_v = vertex_id(rdfdg2, _ex.bob)
            @test has_edge(rdfdg2, a_v, b_v)
        end

        @testset "outneighbors" begin
            rdfdg = RDFDiGraph(_social_graph())
            alice_v = vertex_id(rdfdg, _ex.alice)
            # alice has edges to: bob, carol, Person (3 outneighbors)
            out = outneighbors(rdfdg, alice_v)
            @test length(out) == 3
            bob_v    = vertex_id(rdfdg, _ex.bob)
            carol_v  = vertex_id(rdfdg, _ex.carol)
            person_v = vertex_id(rdfdg, _ex.Person)
            @test bob_v    in out
            @test carol_v  in out
            @test person_v in out
        end

        @testset "inneighbors" begin
            rdfdg   = RDFDiGraph(_social_graph())
            carol_v = vertex_id(rdfdg, _ex.carol)
            # carol is the object of: alice knows carol, bob knows carol → 2 inneighbors
            inn = inneighbors(rdfdg, carol_v)
            @test length(inn) == 2
            alice_v = vertex_id(rdfdg, _ex.alice)
            bob_v   = vertex_id(rdfdg, _ex.bob)
            @test alice_v in inn
            @test bob_v   in inn
        end

        @testset "out-degree 0 for literal objects (sink vertices)" begin
            rdfdg = RDFDiGraph(_literal_graph())
            alice_v = vertex_id(rdfdg, _ex.alice)
            @test outdegree(rdfdg, alice_v) == 2
            # find the literal vertices and verify out-degree 0
            for v in vertices(rdfdg)
                if _resolve(term_id(rdfdg, v)) isa Literal
                    @test outdegree(rdfdg, v) == 0
                end
            end
        end

        @testset "self-loop edge" begin
            rdfdg   = RDFDiGraph(_selfloop_graph())
            alice_v = vertex_id(rdfdg, _ex.alice)
            @test has_edge(rdfdg, alice_v, alice_v)
            @test alice_v in outneighbors(rdfdg, alice_v)
            @test alice_v in inneighbors(rdfdg, alice_v)
        end

        @testset "edges iterator yields SimpleEdge{Int}" begin
            rdfdg = RDFDiGraph(_social_graph())
            es = collect(edges(rdfdg))
            @test length(es) == ne(rdfdg)
            @test all(e isa Graphs.SimpleEdge{Int} for e in es)
        end

    end

    # ─────────────────────────────────────────────────────────────────────────
    # 5. RDFDiGraph — term accessor functions
    # ─────────────────────────────────────────────────────────────────────────

    @testset "RDFDiGraph — term accessors" begin

        @testset "vertex_id(rdfdg, term) maps IRI terms to vertex indices" begin
            rdfdg = RDFDiGraph(_social_graph())
            v = vertex_id(rdfdg, _ex.alice)
            @test v isa Int
            @test 1 <= v <= nv(rdfdg)
            # All four social graph terms have valid vertex IDs
            @test vertex_id(rdfdg, _ex.alice)  > 0
            @test vertex_id(rdfdg, _ex.bob)    > 0
            @test vertex_id(rdfdg, _ex.carol)  > 0
            @test vertex_id(rdfdg, _ex.Person) > 0
        end

        @testset "vertex_id returns 0 for unknown terms" begin
            rdfdg = RDFDiGraph(_social_graph())
            @test vertex_id(rdfdg, _ex.nobody) == 0
            @test vertex_id(rdfdg, _ex.xyz)    == 0
        end

        @testset "term_id(rdfdg, v) maps vertex index to term ID" begin
            rdfdg = RDFDiGraph(_social_graph())
            for v in vertices(rdfdg)
                id = term_id(rdfdg, v)
                @test id isa UInt32
                @test id > 0
            end
        end

        @testset "vertex_id and term_id are inverses" begin
            rdfdg = RDFDiGraph(_social_graph())
            for v in vertices(rdfdg)
                id  = term_id(rdfdg, v)
                term = _resolve(id)
                @test vertex_id(rdfdg, term) == v
            end
        end

        @testset "resolve_vertex(rdfdg, v) returns the RDFTerm" begin
            rdfdg = RDFDiGraph(_social_graph())
            alice_v = vertex_id(rdfdg, _ex.alice)
            @test resolve_vertex(rdfdg, alice_v) == _ex.alice
            # Every vertex resolves to a term
            for v in vertices(rdfdg)
                @test resolve_vertex(rdfdg, v) isa RDFTerm
            end
        end

        @testset "edge_predicates returns IRIs for a given (u,v) edge" begin
            rdfdg = RDFDiGraph(_social_graph())
            alice_v = vertex_id(rdfdg, _ex.alice)
            bob_v   = vertex_id(rdfdg, _ex.bob)
            preds = edge_predicates(rdfdg, alice_v, bob_v)
            @test preds isa Vector{IRI}
            @test length(preds) == 1
            @test _foaf.knows in preds
        end

        @testset "edge_predicates returns all predicates for multi-predicate edges" begin
            rdfdg = RDFDiGraph(_multi_pred_graph())
            a_v = vertex_id(rdfdg, _ex.alice)
            b_v = vertex_id(rdfdg, _ex.bob)
            preds = edge_predicates(rdfdg, a_v, b_v)
            @test length(preds) == 2
            @test _foaf.knows in preds
            @test _foaf.age   in preds
        end

        @testset "edge_predicates returns empty for non-existent edge" begin
            rdfdg = RDFDiGraph(_social_graph())
            bob_v   = vertex_id(rdfdg, _ex.bob)
            carol_v = vertex_id(rdfdg, _ex.carol)
            # carol → bob does not exist
            @test isempty(edge_predicates(rdfdg, carol_v, bob_v))
        end

        @testset "vertex_id works with BlankNode terms" begin
            g = Graph()
            b = blank!(g)
            push!(g, Triple(b, rdf.type, _ex.Person))
            rdfdg = RDFDiGraph(g)
            v = vertex_id(rdfdg, b)
            @test v > 0
            @test resolve_vertex(rdfdg, v) == b
        end

        @testset "vertex_id works with Literal terms" begin
            rdfdg   = RDFDiGraph(_literal_graph())
            lit_age = Literal(30)
            v = vertex_id(rdfdg, lit_age)
            @test v > 0
            @test resolve_vertex(rdfdg, v) isa Literal
        end

    end

    # ─────────────────────────────────────────────────────────────────────────
    # 6. RDFDiGraph — Graphs.jl algorithm compatibility
    # ─────────────────────────────────────────────────────────────────────────

    @testset "RDFDiGraph — Graphs.jl algorithms" begin

        @testset "pagerank — returns one score per vertex, sums to ≈1" begin
            rdfdg = RDFDiGraph(_social_graph())
            pr = pagerank(rdfdg)
            @test length(pr) == nv(rdfdg)
            @test all(x >= 0.0 for x in pr)
            @test sum(pr) ≈ 1.0 atol=1e-6
        end

        @testset "pagerank on empty graph — nv=0" begin
            rdfdg = RDFDiGraph(Graph())
            @test nv(rdfdg) == 0
            # Graphs.jl's pagerank does not handle N=0 gracefully (convergence
            # check `0.0 < 0` never triggers), so we only verify the vertex count.
        end

        @testset "betweenness_centrality — correct length" begin
            rdfdg = RDFDiGraph(_social_graph())
            bc = betweenness_centrality(rdfdg)
            @test length(bc) == nv(rdfdg)
            @test all(x >= 0.0 for x in bc)
        end

        @testset "weakly_connected_components — two components in disconnected graph" begin
            rdfdg = RDFDiGraph(_disconnected_graph())
            @test nv(rdfdg) == 4  # a, b, c, d
            wcc = weakly_connected_components(rdfdg)
            @test length(wcc) == 2
            @test all(length(c) == 2 for c in wcc)
        end

        @testset "weakly_connected_components — one component in social graph" begin
            # All nodes reachable from alice in undirected sense
            rdfdg = RDFDiGraph(_social_graph())
            wcc   = weakly_connected_components(rdfdg)
            @test length(wcc) == 1
        end

        @testset "bfs_tree — reachability from alice" begin
            rdfdg   = RDFDiGraph(_chain_graph())
            a_v     = vertex_id(rdfdg, _ex.a)
            d_v     = vertex_id(rdfdg, _ex.d)
            tree    = bfs_tree(rdfdg, a_v)
            # d is reachable from a via b and c
            @test has_path(rdfdg, a_v, d_v)
        end

        @testset "strongly_connected_components — chain has no non-trivial SCCs" begin
            rdfdg = RDFDiGraph(_chain_graph())
            scc   = strongly_connected_components(rdfdg)
            # a→b→c→d: each node is its own SCC (no cycles)
            @test length(scc) == nv(rdfdg)
        end

        @testset "indegree and outdegree via Graphs interface" begin
            rdfdg   = RDFDiGraph(_social_graph())
            carol_v = vertex_id(rdfdg, _ex.carol)
            # carol is only an object (in-degree 2, out-degree 0)
            @test indegree(rdfdg, carol_v)  == 2
            @test outdegree(rdfdg, carol_v) == 0
            # alice is only a subject here
            alice_v  = vertex_id(rdfdg, _ex.alice)
            @test indegree(rdfdg, alice_v)  == 0
            @test outdegree(rdfdg, alice_v) == 3
        end

    end

    # ─────────────────────────────────────────────────────────────────────────
    # 7. eachid — zero-allocation raw-ID iterator
    # ─────────────────────────────────────────────────────────────────────────

    @testset "eachid" begin

        @testset "yields NTuple{3,UInt32}" begin
            g = _social_graph()
            for tup in eachid(g)
                @test tup isa NTuple{3,UInt32}
            end
        end

        @testset "count matches graph length" begin
            g = _social_graph()
            @test sum(1 for _ in eachid(g)) == length(g)
        end

        @testset "resolving IDs gives original terms" begin
            g = Graph()
            push!(g, Triple(_ex.alice, _foaf.knows, _ex.bob))
            for (s_id, p_id, o_id) in eachid(g)
                @test _resolve(s_id) == _ex.alice
                @test _resolve(p_id) == _foaf.knows
                @test _resolve(o_id) == _ex.bob
            end
        end

        @testset "large graph iteration works correctly" begin
            # Build a larger graph and verify eachid counts correctly
            # (zero-alloc property is verified by bench/benchmarks.jl via BenchmarkTools)
            g_large = Graph()
            for i in 1:100
                push!(g_large, Triple(_ex["s$i"], _foaf.knows, _ex["o$i"]))
            end
            @test sum(1 for _ in eachid(g_large)) == 100
        end

        @testset "empty graph yields nothing" begin
            @test isempty(collect(eachid(Graph())))
        end

        @testset "match_ids — filtered raw-ID iteration" begin
            g = _social_graph()
            p_id = RDF._intern!(_foaf.knows)
            ids  = collect(match_ids(g; predicate=p_id))
            @test length(ids) == 3  # three foaf:knows triples
            @test all(tup isa NTuple{3,UInt32} for tup in ids)
            # All returned tuples have foaf:knows as predicate
            @test all(_resolve(tup[2]) == _foaf.knows for tup in ids)
        end

        @testset "match_ids — unbound returns all triples" begin
            g = _social_graph()
            @test length(collect(match_ids(g))) == length(g)
        end

        @testset "match_ids — UInt32(0) for unknown term → empty" begin
            g = _social_graph()
            @test isempty(collect(match_ids(g; subject=UInt32(0))))
        end

    end

end
