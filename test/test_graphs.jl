using RDF
using Test

@testset "Graphs" begin

    ex = Namespace("http://example.org/")

    @testset "Construction" begin
        g = Graph()
        @test g isa Graph
        @test isempty(g)
        @test length(g) == 0

        # Do-block construction
        g = Graph() do g
            push!(g, Triple(ex.alice, rdf.type, ex.Person))
            push!(g, Triple(ex.bob,   rdf.type, ex.Person))
        end
        @test length(g) == 2
        @test Triple(ex.alice, rdf.type, ex.Person) in g
        @test Triple(ex.bob,   rdf.type, ex.Person) in g
    end

    @testset "push! — adding triples" begin
        g = Graph()

        t = Triple(ex.alice, rdf.type, ex.Person)
        push!(g, t)
        @test length(g) == 1
        @test t in g

        # Duplicate triple is silently ignored (graph is a set)
        push!(g, t)
        @test length(g) == 1

        # Multiple distinct triples
        push!(g, Triple(ex.alice, ex.name, Literal("Alice")))
        push!(g, Triple(ex.bob,   rdf.type, ex.Person))
        @test length(g) == 3
    end

    @testset "delete! — removing triples" begin
        g = Graph()
        t = Triple(ex.alice, rdf.type, ex.Person)
        push!(g, t)
        @test length(g) == 1

        delete!(g, t)
        @test length(g) == 0
        @test t ∉ g

        # Deleting a non-existent triple is a no-op
        @test_nowarn delete!(g, t)
        @test length(g) == 0
    end

    @testset "in / membership" begin
        g = Graph()
        t1 = Triple(ex.alice, rdf.type, ex.Person)
        t2 = Triple(ex.bob,   rdf.type, ex.Person)

        push!(g, t1)
        @test t1 in g
        @test t2 ∉ g

        push!(g, t2)
        @test t2 in g
    end

    @testset "Iteration — yields Triple values" begin
        g = Graph()
        triples = [
            Triple(ex.alice, rdf.type, ex.Person),
            Triple(ex.alice, ex.name, Literal("Alice")),
            Triple(ex.bob,   rdf.type, ex.Person),
        ]
        for t in triples
            push!(g, t)
        end

        collected = collect(g)
        @test length(collected) == 3
        @test all(t isa Triple for t in collected)
        @test Set(collected) == Set(triples)
    end

    @testset "length and isempty" begin
        g = Graph()
        @test isempty(g)
        @test length(g) == 0

        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        @test !isempty(g)
        @test length(g) == 1

        push!(g, Triple(ex.alice, rdf.type, ex.Person))  # duplicate
        @test length(g) == 1

        push!(g, Triple(ex.bob, rdf.type, ex.Person))
        @test length(g) == 2
    end

    @testset "append! — bulk insertion" begin
        g = Graph()
        triples = [
            Triple(ex.alice, rdf.type, ex.Person),
            Triple(ex.bob,   rdf.type, ex.Person),
            Triple(ex.carol, rdf.type, ex.Person),
        ]
        append!(g, triples)
        @test length(g) == 3

        # Also works from another graph
        g2 = Graph()
        append!(g2, g)
        @test length(g2) == 3
    end

    @testset "Set operations" begin
        g1 = Graph()
        push!(g1, Triple(ex.alice, rdf.type, ex.Person))
        push!(g1, Triple(ex.bob,   rdf.type, ex.Person))

        g2 = Graph()
        push!(g2, Triple(ex.bob,   rdf.type, ex.Person))
        push!(g2, Triple(ex.carol, rdf.type, ex.Person))

        # Union
        g3 = union(g1, g2)
        @test length(g3) == 3
        @test Triple(ex.alice, rdf.type, ex.Person) in g3
        @test Triple(ex.bob,   rdf.type, ex.Person) in g3
        @test Triple(ex.carol, rdf.type, ex.Person) in g3

        # ∪ operator
        g4 = g1 ∪ g2
        @test length(g4) == 3

        # Intersection
        g5 = intersect(g1, g2)
        @test length(g5) == 1
        @test Triple(ex.bob, rdf.type, ex.Person) in g5

        # ∩ operator
        g6 = g1 ∩ g2
        @test length(g6) == 1

        # Difference
        g7 = setdiff(g1, g2)
        @test length(g7) == 1
        @test Triple(ex.alice, rdf.type, ex.Person) in g7
        @test Triple(ex.bob,   rdf.type, ex.Person) ∉ g7

        # \ operator
        g8 = g1 \ g2
        @test length(g8) == 1

        # Operations do not mutate the originals
        @test length(g1) == 2
        @test length(g2) == 2
    end

    @testset "merge! — mutating union" begin
        g1 = Graph()
        push!(g1, Triple(ex.alice, rdf.type, ex.Person))

        g2 = Graph()
        push!(g2, Triple(ex.bob, rdf.type, ex.Person))

        merge!(g1, g2)
        @test length(g1) == 2
        @test Triple(ex.alice, rdf.type, ex.Person) in g1
        @test Triple(ex.bob,   rdf.type, ex.Person) in g1

        # g2 is unchanged
        @test length(g2) == 1
    end

    @testset "Set operations with blank nodes — blank node renaming" begin
        # Blank nodes in different graphs are independent.
        # Union must rename them to prevent collision.
        g1 = Graph()
        b1 = blank!(g1)
        push!(g1, Triple(b1, rdf.type, ex.Person))
        push!(g1, Triple(b1, ex.name, Literal("Alice")))

        g2 = Graph()
        b2 = blank!(g2)
        push!(g2, Triple(b2, rdf.type, ex.Person))
        push!(g2, Triple(b2, ex.name, Literal("Bob")))

        g3 = union(g1, g2)

        # Should have 4 triples total — two blank node "clusters"
        @test length(g3) == 4

        # There should be two distinct blank node subjects
        bnode_subjects = [t.subject for t in g3 if t.subject isa BlankNode]
        @test length(unique(bnode_subjects)) == 2

        # The original graphs are not modified
        @test length(g1) == 2
        @test length(g2) == 2
    end

    @testset "issubgraph / ⊆" begin
        g1 = Graph()
        push!(g1, Triple(ex.alice, rdf.type, ex.Person))

        g2 = Graph()
        push!(g2, Triple(ex.alice, rdf.type, ex.Person))
        push!(g2, Triple(ex.bob,   rdf.type, ex.Person))

        @test issubgraph(g1, g2)
        @test g1 ⊆ g2
        @test !issubgraph(g2, g1)
        @test !(g2 ⊆ g1)

        # Every graph is a subgraph of itself
        @test g1 ⊆ g1
        @test g2 ⊆ g2

        # Empty graph is subgraph of everything
        @test Graph() ⊆ g1
        @test Graph() ⊆ g2
    end

    @testset "== — term-for-term identity" begin
        g1 = Graph()
        push!(g1, Triple(ex.alice, rdf.type, ex.Person))
        push!(g1, Triple(ex.bob,   rdf.type, ex.Person))

        g2 = Graph()
        push!(g2, Triple(ex.alice, rdf.type, ex.Person))
        push!(g2, Triple(ex.bob,   rdf.type, ex.Person))

        @test g1 == g2

        g3 = Graph()
        push!(g3, Triple(ex.alice, rdf.type, ex.Person))
        @test g1 != g3

        # Graphs with same blank node IDs are equal; different IDs are not
        g4 = Graph()
        b = blank!(g4)
        push!(g4, Triple(b, rdf.type, ex.Person))

        g5 = Graph()
        b5 = blank!(g5)
        push!(g5, Triple(b5, rdf.type, ex.Person))

        # b != b5, so g4 != g5 under == (even though they are isomorphic)
        @test g4 != g5
    end

    @testset "isomorphic / ≅ — bijection over blank nodes (spec §3.6)" begin
        # Two graphs with no blank nodes: isomorphic ↔ equal
        g1 = Graph()
        push!(g1, Triple(ex.alice, rdf.type, ex.Person))
        g2 = Graph()
        push!(g2, Triple(ex.alice, rdf.type, ex.Person))
        @test g1 ≅ g2

        # Graphs with blank nodes: different IDs but same structure → isomorphic
        g3 = Graph()
        b3 = blank!(g3)
        push!(g3, Triple(b3, rdf.type, ex.Person))
        push!(g3, Triple(b3, ex.name, Literal("Alice")))

        g4 = Graph()
        b4 = blank!(g4)
        push!(g4, Triple(b4, rdf.type, ex.Person))
        push!(g4, Triple(b4, ex.name, Literal("Alice")))

        @test g3 ≅ g4
        @test g3 != g4   # != because blank node IDs differ

        # Different structure → not isomorphic
        g5 = Graph()
        b5 = blank!(g5)
        push!(g5, Triple(b5, rdf.type, ex.Person))
        push!(g5, Triple(b5, ex.name, Literal("Bob")))  # different literal

        @test !(g3 ≅ g5)

        # Empty graphs are isomorphic
        @test Graph() ≅ Graph()

        # Different number of triples → not isomorphic
        @test !(g3 ≅ Graph())

        # Two blank nodes — isomorphic requires matching bijection
        g6 = Graph()
        a6 = blank!(g6)
        b6 = blank!(g6)
        push!(g6, Triple(a6, ex.knows, b6))
        push!(g6, Triple(a6, rdf.type, ex.Person))
        push!(g6, Triple(b6, rdf.type, ex.Person))

        g7 = Graph()
        a7 = blank!(g7)
        b7 = blank!(g7)
        push!(g7, Triple(a7, ex.knows, b7))
        push!(g7, Triple(a7, rdf.type, ex.Person))
        push!(g7, Triple(b7, rdf.type, ex.Person))

        @test g6 ≅ g7
    end

    @testset "skolemize and deskolemize" begin
        base = "http://example.org/.well-known/genid/"

        g = Graph()
        b = blank!(g)
        push!(g, Triple(b, rdf.type, ex.Person))
        push!(g, Triple(b, ex.name, Literal("Alice")))
        push!(g, Triple(ex.alice, ex.knows, b))

        # Skolemize replaces blank nodes with IRIs
        sg = skolemize(g; base=base)
        @test length(sg) == 3

        # No blank nodes remain
        @test all(t.subject isa IRI for t in sg)
        @test all(t.object isa IRI || t.object isa Literal for t in sg)

        # Skolem IRIs (formerly blank nodes) start with the base
        orig_iri_subjects = Set(t.subject for t in g if t.subject isa IRI)
        subjects = [t.subject for t in sg]
        skolem_iris = filter(s -> s isa IRI && s ∉ orig_iri_subjects, subjects)
        @test all(startswith(string(iri), base) for iri in skolem_iris)

        # Original graph is not mutated
        @test any(t.subject isa BlankNode for t in g)

        # Deskolemize reverses the operation
        dg = deskolemize(sg; base=base)
        @test dg ≅ g
    end

    @testset "Graph display" begin
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        push!(g, Triple(ex.bob,   rdf.type, ex.Person))

        r = repr(g)
        @test contains(r, "Graph")
        @test contains(r, "2")  # 2 triples
    end

end
