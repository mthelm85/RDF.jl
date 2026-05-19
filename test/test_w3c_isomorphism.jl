using RDF
using Test

# W3C RDF 1.1 Graph Isomorphism Tests
# Tests the ≅ operator against the spec definition (§3.6):
# Two RDF graphs G and G' are isomorphic if there is a bijection M
# between the sets of nodes such that:
# 1. M maps blank nodes to blank nodes
# 2. M(lit) = lit for all literals
# 3. M(iri) = iri for all IRIs
# 4. (s, p, o) ∈ G ↔ (M(s), p, M(o)) ∈ G'

@testset "W3C Graph Isomorphism" begin

    const ex = Namespace("http://example.org/")

    function make_graph(triples)
        g = Graph()
        for t in triples
            push!(g, t)
        end
        return g
    end

    # ----------------------------------------------------------------
    # Isomorphic graph pairs (≅ must hold)
    # ----------------------------------------------------------------

    @testset "Isomorphic pairs" begin

        @testset "Empty graphs are isomorphic" begin
            @test Graph() ≅ Graph()
        end

        @testset "Ground graphs — same triples" begin
            g1 = make_graph([
                Triple(ex.alice, rdf.type, ex.Person),
                Triple(ex.bob,   rdf.type, ex.Person),
            ])
            g2 = make_graph([
                Triple(ex.alice, rdf.type, ex.Person),
                Triple(ex.bob,   rdf.type, ex.Person),
            ])
            @test g1 ≅ g2
        end

        @testset "Single blank node — same structure" begin
            g1 = Graph()
            b1 = blank!(g1)
            push!(g1, Triple(b1, rdf.type, ex.Person))

            g2 = Graph()
            b2 = blank!(g2)
            push!(g2, Triple(b2, rdf.type, ex.Person))

            @test g1 ≅ g2
        end

        @testset "Single blank node — subject and object" begin
            g1 = Graph()
            b1 = blank!(g1)
            push!(g1, Triple(b1, rdf.type, ex.Person))
            push!(g1, Triple(b1, ex.name, Literal("Alice")))
            push!(g1, Triple(ex.bob, ex.knows, b1))

            g2 = Graph()
            b2 = blank!(g2)
            push!(g2, Triple(b2, rdf.type, ex.Person))
            push!(g2, Triple(b2, ex.name, Literal("Alice")))
            push!(g2, Triple(ex.bob, ex.knows, b2))

            @test g1 ≅ g2
        end

        @testset "Two blank nodes with same structure" begin
            g1 = Graph()
            a1 = blank!(g1)
            b1 = blank!(g1)
            push!(g1, Triple(a1, ex.knows, b1))
            push!(g1, Triple(a1, rdf.type, ex.Person))
            push!(g1, Triple(b1, rdf.type, ex.Person))

            g2 = Graph()
            a2 = blank!(g2)
            b2 = blank!(g2)
            push!(g2, Triple(a2, ex.knows, b2))
            push!(g2, Triple(a2, rdf.type, ex.Person))
            push!(g2, Triple(b2, rdf.type, ex.Person))

            @test g1 ≅ g2
        end

        @testset "Chain of blank nodes" begin
            g1 = Graph()
            n1a, n2a, n3a = blank!(g1, 3)
            push!(g1, Triple(n1a, ex.next, n2a))
            push!(g1, Triple(n2a, ex.next, n3a))

            g2 = Graph()
            n1b, n2b, n3b = blank!(g2, 3)
            push!(g2, Triple(n1b, ex.next, n2b))
            push!(g2, Triple(n2b, ex.next, n3b))

            @test g1 ≅ g2
        end

        @testset "Blank node self-reference" begin
            g1 = Graph()
            b1 = blank!(g1)
            push!(g1, Triple(b1, ex.knows, b1))

            g2 = Graph()
            b2 = blank!(g2)
            push!(g2, Triple(b2, ex.knows, b2))

            @test g1 ≅ g2
        end

        @testset "Mixed ground and blank node triples" begin
            g1 = Graph()
            b1 = blank!(g1)
            push!(g1, Triple(ex.alice, rdf.type, ex.Person))
            push!(g1, Triple(b1,       rdf.type, ex.Person))
            push!(g1, Triple(ex.alice, ex.knows, b1))

            g2 = Graph()
            b2 = blank!(g2)
            push!(g2, Triple(ex.alice, rdf.type, ex.Person))
            push!(g2, Triple(b2,       rdf.type, ex.Person))
            push!(g2, Triple(ex.alice, ex.knows, b2))

            @test g1 ≅ g2
        end

        @testset "Blank nodes with identical property sets" begin
            # Two blank nodes each with the same set of properties —
            # the bijection must correctly map them
            g1 = Graph()
            a1 = blank!(g1)
            b1 = blank!(g1)
            push!(g1, Triple(a1, ex.age, Literal(30)))
            push!(g1, Triple(a1, rdf.type, ex.Person))
            push!(g1, Triple(b1, ex.age, Literal(30)))
            push!(g1, Triple(b1, rdf.type, ex.Person))

            g2 = Graph()
            a2 = blank!(g2)
            b2 = blank!(g2)
            push!(g2, Triple(a2, ex.age, Literal(30)))
            push!(g2, Triple(a2, rdf.type, ex.Person))
            push!(g2, Triple(b2, ex.age, Literal(30)))
            push!(g2, Triple(b2, rdf.type, ex.Person))

            @test g1 ≅ g2
        end

    end

    # ----------------------------------------------------------------
    # Non-isomorphic graph pairs (≅ must NOT hold)
    # ----------------------------------------------------------------

    @testset "Non-isomorphic pairs" begin

        @testset "Different number of triples" begin
            g1 = make_graph([Triple(ex.alice, rdf.type, ex.Person)])
            g2 = Graph()
            @test !(g1 ≅ g2)
        end

        @testset "Different IRIs" begin
            g1 = make_graph([Triple(ex.alice, rdf.type, ex.Person)])
            g2 = make_graph([Triple(ex.bob,   rdf.type, ex.Person)])
            @test !(g1 ≅ g2)
        end

        @testset "Different literal values" begin
            g1 = Graph()
            b1 = blank!(g1)
            push!(g1, Triple(b1, ex.name, Literal("Alice")))

            g2 = Graph()
            b2 = blank!(g2)
            push!(g2, Triple(b2, ex.name, Literal("Bob")))

            @test !(g1 ≅ g2)
        end

        @testset "Different literal datatypes" begin
            g1 = Graph()
            b1 = blank!(g1)
            push!(g1, Triple(b1, ex.age, Literal("30", xsd.integer)))

            g2 = Graph()
            b2 = blank!(g2)
            push!(g2, Triple(b2, ex.age, Literal("30", xsd.string)))

            @test !(g1 ≅ g2)
        end

        @testset "Different language tags" begin
            g1 = Graph()
            b1 = blank!(g1)
            push!(g1, Triple(b1, ex.name, Literal("hello"; lang="en")))

            g2 = Graph()
            b2 = blank!(g2)
            push!(g2, Triple(b2, ex.name, Literal("hello"; lang="fr")))

            @test !(g1 ≅ g2)
        end

        @testset "Different predicates" begin
            g1 = Graph()
            b1 = blank!(g1)
            push!(g1, Triple(b1, ex.knows, ex.alice))

            g2 = Graph()
            b2 = blank!(g2)
            push!(g2, Triple(b2, ex.likes, ex.alice))

            @test !(g1 ≅ g2)
        end

        @testset "Chain vs non-chain" begin
            # Linear chain of 3 blank nodes
            g1 = Graph()
            a1, b1, c1 = blank!(g1, 3)
            push!(g1, Triple(a1, ex.next, b1))
            push!(g1, Triple(b1, ex.next, c1))

            # Star — two spokes from center
            g2 = Graph()
            center, spoke1, spoke2 = blank!(g2, 3)
            push!(g2, Triple(center, ex.next, spoke1))
            push!(g2, Triple(center, ex.next, spoke2))

            @test !(g1 ≅ g2)
        end

        @testset "Wrong number of blank nodes" begin
            g1 = Graph()
            b1 = blank!(g1)
            push!(g1, Triple(b1, rdf.type, ex.Person))

            g2 = Graph()
            a2 = blank!(g2)
            b2 = blank!(g2)
            push!(g2, Triple(a2, rdf.type, ex.Person))
            push!(g2, Triple(b2, rdf.type, ex.Person))

            @test !(g1 ≅ g2)
        end

        @testset "IRI vs blank node — distinct (spec §3.1)" begin
            # IRIs and blank nodes are always distinct
            g1 = Graph()
            b1 = blank!(g1)
            push!(g1, Triple(b1, rdf.type, ex.Person))

            g2 = make_graph([Triple(ex.alice, rdf.type, ex.Person)])

            @test !(g1 ≅ g2)
        end

        @testset "Subgraph — not isomorphic to supergraph" begin
            g1 = make_graph([
                Triple(ex.alice, rdf.type, ex.Person),
            ])
            g2 = make_graph([
                Triple(ex.alice, rdf.type, ex.Person),
                Triple(ex.bob,   rdf.type, ex.Person),
            ])
            @test !(g1 ≅ g2)
            @test !(g2 ≅ g1)
        end

    end

    # ----------------------------------------------------------------
    # Isomorphism properties
    # ----------------------------------------------------------------

    @testset "Isomorphism is an equivalence relation" begin
        g1 = Graph()
        b1 = blank!(g1)
        push!(g1, Triple(b1, rdf.type, ex.Person))

        g2 = Graph()
        b2 = blank!(g2)
        push!(g2, Triple(b2, rdf.type, ex.Person))

        g3 = Graph()
        b3 = blank!(g3)
        push!(g3, Triple(b3, rdf.type, ex.Person))

        # Reflexive
        @test g1 ≅ g1

        # Symmetric
        @test g1 ≅ g2
        @test g2 ≅ g1

        # Transitive
        @test g2 ≅ g3
        @test g1 ≅ g3
    end

    @testset "Isomorphism implies equal length" begin
        for _ in 1:20
            g1 = Graph()
            n = rand(0:10)
            bnodes = blank!(g1, max(n, 1))
            for i in 1:n
                push!(g1, Triple(bnodes[rand(1:max(n,1))], ex.rel, bnodes[rand(1:max(n,1))]))
            end

            g2 = Graph()
            m = rand(0:10)
            bnodes2 = blank!(g2, max(m, 1))
            for i in 1:m
                push!(g2, Triple(bnodes2[rand(1:max(m,1))], ex.rel, bnodes2[rand(1:max(m,1))]))
            end

            if length(g1) != length(g2)
                @test !(g1 ≅ g2)
            end
        end
    end

    @testset "skolemize → deskolemize preserves isomorphism" begin
        g = Graph()
        b = blank!(g)
        push!(g, Triple(b, rdf.type, ex.Person))
        push!(g, Triple(b, ex.name, Literal("Unknown")))

        base = "http://example.org/.well-known/genid/"
        sg = skolemize(g; base=base)
        dg = deskolemize(sg; base=base)

        @test g ≅ dg
    end

end
