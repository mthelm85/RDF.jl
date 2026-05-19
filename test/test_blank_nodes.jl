using RDF
using Test

@testset "Blank Nodes" begin

    @testset "Minting via Graph" begin
        g = Graph()

        b1 = blank!(g)
        @test b1 isa BlankNode

        b2 = blank!(g)
        @test b2 isa BlankNode

        # Every call produces a distinct node
        @test b1 != b2
        @test b1.id != b2.id

        # Bulk minting
        nodes = blank!(g, 5)
        @test length(nodes) == 5
        @test allunique(n.id for n in nodes)

        # All minted nodes are distinct from prior ones
        @test b1 ∉ nodes
        @test b2 ∉ nodes
    end

    @testset "Minting via Dataset" begin
        ds = Dataset()

        b1 = blank!(ds)
        @test b1 isa BlankNode

        b2 = blank!(ds)
        @test b1 != b2

        # Blank nodes minted from a dataset are usable in any of its graphs
        g1 = Graph()
        g2 = Graph()
        ds[IRI("http://example.org/g1")] = g1
        ds[IRI("http://example.org/g2")] = g2

        b = blank!(ds)
        # Can appear in multiple graphs within the same dataset
        p = IRI("http://example.org/p")
        o = IRI("http://example.org/o")
        push!(g1, Triple(b, p, o))
        push!(g2, Triple(b, p, o))
        @test Triple(b, p, o) in g1
        @test Triple(b, p, o) in g2
    end

    @testset "Global uniqueness across graphs" begin
        g1 = Graph()
        g2 = Graph()

        b1 = blank!(g1)
        b2 = blank!(g2)

        # Blank nodes from different graphs are always distinct
        @test b1 != b2
        @test b1.id != b2.id
    end

    @testset "Equality and hashing" begin
        g = Graph()
        b1 = blank!(g)
        b2 = blank!(g)

        @test b1 == b1
        @test b1 != b2
        @test hash(b1) == hash(b1)
        @test hash(b1) != hash(b2)  # with overwhelming probability

        # Usable as Dict keys
        d = Dict{BlankNode, String}()
        d[b1] = "first"
        @test d[b1] == "first"
        @test !haskey(d, b2)

        # Usable in Set
        s = Set([b1, b2, b1])
        @test length(s) == 2
    end

    @testset "BlankNode is a valid subject and object term" begin
        g = Graph()
        b = blank!(g)

        @test b isa RDFTerm
        @test b isa SubjectTerm
        @test b isa ObjectTerm
    end

    @testset "Blank node scope — graph registry" begin
        g = Graph()
        b = blank!(g)

        # The graph knows about its own blank nodes
        @test b ∈ blank_nodes(g)

        g2 = Graph()
        # The blank node is not in g2's registry
        @test b ∉ blank_nodes(g2)
    end

    @testset "Blank node identifiers are not serialization identifiers" begin
        # Two separate parse operations on the same document should produce
        # distinct blank nodes even if the serialization identifier is the same.
        # This tests the principle: blank node IDs are local to a parse.
        nt = "_:b0 <http://example.org/p> <http://example.org/o> .\n"

        g1 = read(IOBuffer(nt), MIME"application/n-triples"(), Graph)
        g2 = read(IOBuffer(nt), MIME"application/n-triples"(), Graph)

        # The two graphs are isomorphic (same structure)
        @test g1 ≅ g2

        # But the blank node objects are distinct (different IDs)
        b1 = only(subjects(g1))
        b2 = only(subjects(g2))
        @test b1 isa BlankNode
        @test b2 isa BlankNode
        @test b1 != b2
    end

    @testset "Thread safety of ID counter" begin
        # Mint blank nodes from multiple tasks simultaneously
        # All IDs must be unique
        n = 1000
        graphs = [Graph() for _ in 1:n]
        nodes = Vector{BlankNode}(undef, n)

        Threads.@threads for i in 1:n
            nodes[i] = blank!(graphs[i])
        end

        @test allunique(n.id for n in nodes)
    end

    @testset "Display" begin
        g = Graph()
        b = blank!(g)
        # Display shows it is a blank node; exact format is implementation-defined
        r = repr(b)
        @test startswith(r, "_:")
    end

end
