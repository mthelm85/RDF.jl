using Test
using RDF
import RDF: Graph

# ── Subgraph extraction + LLM context rendering ────────────────────────────────
#
# TDD spec.  Contract under test:
#
#   • cbd(g, node; include_annotations=true) -> Graph
#       Concise Bounded Description: every triple whose subject is `node`,
#       plus (recursively) the CBD of every blank node appearing in object
#       position of an included triple.  When include_annotations=true, the
#       RDF 1.2 annotations of every included triple (reifier + its
#       properties) are included as well.
#
#   • ego_graph(g, seeds; hops=1, through_types=false) -> Graph
#       The k-hop neighbourhood subgraph: all triples incident (as subject or
#       object) to the seed nodes; each additional hop expands the frontier
#       through IRI / blank-node neighbours.  Literals and predicates are not
#       expanded.  Class nodes reached as the object of rdf:type are included
#       but not expanded through (they are schema-level hubs that would pull
#       in every co-typed instance) unless through_types=true.  `seeds` is a
#       single term or a collection.
#
#   • to_context(g; budget=nothing, prefixes=Dict()) -> String
#       Renders the graph as compact, subject-grouped text for an LLM context
#       window.  `budget` is an approximate token budget (4 chars ≈ 1 token);
#       when set, whole subject blocks are included greedily, most-connected
#       subjects first, without exceeding the budget.

const _cx = Namespace("http://ctx-test.example.org/")

@testset "Subgraph extraction and LLM context" begin

    # ── cbd ────────────────────────────────────────────────────────────────────
    @testset "cbd — direct properties only" begin
        g = Graph()
        push!(g, Triple(_cx.alice, _cx.name, Literal("Alice")))
        push!(g, Triple(_cx.alice, _cx.age, Literal(30)))
        push!(g, Triple(_cx.bob,   _cx.name, Literal("Bob")))
        push!(g, Triple(_cx.bob,   _cx.knows, _cx.alice))   # alice as object only

        d = cbd(g, _cx.alice)
        @test d isa Graph
        @test length(d) == 2
        @test Triple(_cx.alice, _cx.name, Literal("Alice")) in d
        @test Triple(_cx.alice, _cx.age, Literal(30)) in d
        # triples about bob — even ones pointing at alice — are not in the CBD
        @test !(Triple(_cx.bob, _cx.knows, _cx.alice) in d)
    end

    @testset "cbd — recursive blank-node closure" begin
        g  = Graph()
        b1 = blank!(g)
        b2 = blank!(g)
        push!(g, Triple(_cx.alice, _cx.address, b1))
        push!(g, Triple(b1, _cx.city, Literal("Springfield")))
        push!(g, Triple(b1, _cx.geo, b2))
        push!(g, Triple(b2, _cx.lat, Literal(39.8)))
        push!(g, Triple(_cx.bob, _cx.address, b1))   # not alice's — subject differs

        d = cbd(g, _cx.alice)
        @test length(d) == 4
        @test Triple(b1, _cx.city, Literal("Springfield")) in d
        @test Triple(b2, _cx.lat, Literal(39.8)) in d
        @test !(Triple(_cx.bob, _cx.address, b1) in d)
    end

    @testset "cbd — blank-node cycles terminate" begin
        g  = Graph()
        b1 = blank!(g)
        b2 = blank!(g)
        push!(g, Triple(_cx.alice, _cx.p, b1))
        push!(g, Triple(b1, _cx.p, b2))
        push!(g, Triple(b2, _cx.p, b1))      # cycle b1 → b2 → b1
        d = cbd(g, _cx.alice)
        @test length(d) == 3
    end

    @testset "cbd — includes RDF-star annotations of included triples" begin
        g = Graph()
        t = Triple(_cx.alice, _cx.age, Literal(30))
        annotate!(g, t; confidence=0.9)
        push!(g, Triple(_cx.bob, _cx.name, Literal("Bob")))

        d = cbd(g, _cx.alice)
        @test t in d
        @test length(annotations(d, t, anno.confidence)) == 1

        d2 = cbd(g, _cx.alice; include_annotations=false)
        @test t in d2
        @test length(d2) == 1
    end

    @testset "cbd — unknown node gives an empty graph" begin
        g = Graph()
        push!(g, Triple(_cx.alice, _cx.age, Literal(30)))
        @test isempty(cbd(g, _cx.nobody))
    end

    # ── ego_graph ─────────────────────────────────────────────────────────────
    @testset "ego_graph — hop expansion along a chain" begin
        g = Graph()
        push!(g, Triple(_cx.a, _cx.p, _cx.b))
        push!(g, Triple(_cx.b, _cx.p, _cx.c))
        push!(g, Triple(_cx.c, _cx.p, _cx.d))

        @test length(ego_graph(g, _cx.a; hops=1)) == 1
        @test length(ego_graph(g, _cx.a; hops=2)) == 2
        @test length(ego_graph(g, _cx.a; hops=3)) == 3
        @test Triple(_cx.b, _cx.p, _cx.c) in ego_graph(g, _cx.a; hops=2)
    end

    @testset "ego_graph — expands through object position too" begin
        g = Graph()
        push!(g, Triple(_cx.a, _cx.p, _cx.b))
        push!(g, Triple(_cx.b, _cx.p, _cx.c))
        push!(g, Triple(_cx.c, _cx.p, _cx.d))

        e1 = ego_graph(g, _cx.c; hops=1)     # triples incident to c, both sides
        @test length(e1) == 2
        @test Triple(_cx.b, _cx.p, _cx.c) in e1
        @test Triple(_cx.c, _cx.p, _cx.d) in e1
    end

    @testset "ego_graph — literals and predicates are not expanded" begin
        g = Graph()
        push!(g, Triple(_cx.a, _cx.p, Literal("leaf")))
        push!(g, Triple(_cx.a, _cx.p, _cx.b))
        # the predicate IRI also appears as a subject elsewhere — must NOT be
        # treated as a graph neighbour of a
        push!(g, Triple(_cx.p, rdfs.label, Literal("a property")))
        push!(g, Triple(_cx.x, _cx.q, Literal("leaf")))   # shares only the literal

        e = ego_graph(g, _cx.a; hops=2)
        @test Triple(_cx.a, _cx.p, Literal("leaf")) in e
        @test Triple(_cx.a, _cx.p, _cx.b) in e
        @test !(Triple(_cx.p, rdfs.label, Literal("a property")) in e)
        @test !(Triple(_cx.x, _cx.q, Literal("leaf")) in e)
    end

    @testset "ego_graph — class hubs are not expanded through by default" begin
        g = Graph()
        push!(g, Triple(_cx.julia,  rdf.type, _cx.Language))
        push!(g, Triple(_cx.python, rdf.type, _cx.Language))
        push!(g, Triple(_cx.julia,  _cx.creator, _cx.bezanson))

        e = ego_graph(g, _cx.julia; hops=2)
        @test Triple(_cx.julia, rdf.type, _cx.Language) in e   # the type triple itself
        @test !(Triple(_cx.python, rdf.type, _cx.Language) in e)  # no hub explosion

        # opt-in: expanding through the class reaches co-typed instances
        e2 = ego_graph(g, _cx.julia; hops=2, through_types=true)
        @test Triple(_cx.python, rdf.type, _cx.Language) in e2
    end

    @testset "ego_graph — multiple seeds and absent seeds" begin
        g = Graph()
        push!(g, Triple(_cx.a, _cx.p, _cx.b))
        push!(g, Triple(_cx.x, _cx.p, _cx.y))

        e = ego_graph(g, [_cx.a, _cx.x]; hops=1)
        @test length(e) == 2

        @test isempty(ego_graph(g, _cx.nobody; hops=3))
    end

    # ── to_context ────────────────────────────────────────────────────────────
    @testset "to_context — full rendering without a budget" begin
        g = Graph()
        push!(g, Triple(_cx.hub,   _cx.name, Literal("Hub")))
        push!(g, Triple(_cx.loner, _cx.name, Literal("Loner")))

        ctx = to_context(g)
        @test ctx isa String
        @test occursin("hub", ctx)
        @test occursin("Loner", ctx)
        # deterministic
        @test ctx == to_context(g)
        # empty graph → empty context
        @test to_context(Graph()) == ""
    end

    @testset "to_context — prefixes compact the output" begin
        g = Graph()
        push!(g, Triple(_cx.alice, _cx.knows, _cx.bob))
        ctx = to_context(g; prefixes=Dict("ex" => "http://ctx-test.example.org/"))
        @test occursin("ex:alice", ctx)
        @test occursin("ex:knows", ctx)
    end

    @testset "to_context — budget keeps the most-connected subjects" begin
        g = Graph()
        # hub: 8 outgoing properties + referenced by 4 spokes → high degree
        for i in 1:8
            push!(g, Triple(_cx.hub, _cx["p$i"], Literal("value $i")))
        end
        for i in 1:4
            push!(g, Triple(_cx["spoke$i"], _cx.linksTo, _cx.hub))
            push!(g, Triple(_cx["spoke$i"], _cx.name, Literal("Spoke $i")))
        end
        # loner: a single isolated triple → strictly lowest degree
        push!(g, Triple(_cx.loner, _cx.name, Literal("Loner")))

        full = to_context(g)
        # budget (in ~tokens) that can hold the hub block but not everything
        budget = cld(ncodeunits(full), 4) - 12
        ctx = to_context(g; budget=budget)

        @test ncodeunits(ctx) <= 4 * budget       # hard budget guarantee
        @test occursin("hub", ctx)                # most central survives
        @test !occursin("loner", ctx)             # least central is cut first

        # a generous budget includes everything
        @test occursin("loner", to_context(g; budget=10 * budget))

        # a tiny budget still respects the cap (possibly empty output)
        tiny = to_context(g; budget=2)
        @test ncodeunits(tiny) <= 8
    end

    # ── The GraphRAG loop end-to-end ─────────────────────────────────────────
    @testset "seed → ego_graph → to_context pipeline" begin
        g = Graph()
        push!(g, Triple(_cx.julia, rdf.type, _cx.Language))
        push!(g, Triple(_cx.julia, _cx.creator, _cx.bezanson))
        push!(g, Triple(_cx.bezanson, _cx.name, Literal("Jeff Bezanson")))
        push!(g, Triple(_cx.python, rdf.type, _cx.Language))   # unrelated

        sub = ego_graph(g, _cx.julia; hops=2)
        ctx = to_context(sub; prefixes=Dict("ex" => "http://ctx-test.example.org/"))
        @test occursin("ex:julia", ctx)
        @test occursin("Jeff Bezanson", ctx)
        @test !occursin("python", ctx)
    end
end
