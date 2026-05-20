using RDF
using Test

@testset "Triples and Quads" begin

    ex = Namespace("http://example.org/")

    @testset "Triple construction" begin
        # IRI subject, IRI predicate, IRI object
        t = Triple(ex.alice, rdf.type, ex.Person)
        @test t isa Triple
        @test t.subject == ex.alice
        @test t.predicate == rdf.type
        @test t.object == ex.Person

        # BlankNode subject
        g = Graph()
        b = blank!(g)
        t = Triple(b, rdf.type, ex.Person)
        @test t.subject == b
        @test t.subject isa BlankNode

        # BlankNode object
        t = Triple(ex.alice, ex.knows, b)
        @test t.object == b
        @test t.object isa BlankNode

        # Literal object
        t = Triple(ex.alice, ex.name, Literal("Alice"))
        @test t.object == Literal("Alice")
        @test t.object isa Literal

        # Language-tagged literal object
        t = Triple(ex.alice, ex.name, Literal("Alice"; lang="en"))
        @test t.object isa Literal

        # Typed literal object
        t = Triple(ex.alice, ex.age, Literal(42))
        @test t.object == Literal(42)
    end

    @testset "Triple positional type constraints" begin
        # Literal MUST NOT appear as subject — type error
        @test_throws MethodError Triple(Literal("alice"), rdf.type, ex.Person)

        # Literal MUST NOT appear as predicate — type error
        @test_throws MethodError Triple(ex.alice, Literal("type"), ex.Person)

        # BlankNode MUST NOT appear as predicate — type error
        g = Graph()
        b = blank!(g)
        @test_throws MethodError Triple(ex.alice, b, ex.Person)
    end

    @testset "Triple equality and hashing" begin
        t1 = Triple(ex.alice, rdf.type, ex.Person)
        t2 = Triple(ex.alice, rdf.type, ex.Person)
        t3 = Triple(ex.bob, rdf.type, ex.Person)

        @test t1 == t2
        @test t1 != t3
        @test hash(t1) == hash(t2)
        @test hash(t1) != hash(t3)

        # Usable as Dict key
        d = Dict{Triple, String}()
        d[t1] = "alice is a person"
        @test d[t2] == "alice is a person"
        @test !haskey(d, t3)

        # Usable in Set
        s = Set([t1, t2, t3])
        @test length(s) == 2
    end

    @testset "Triple with blank nodes — equality by node identity" begin
        g = Graph()
        b1 = blank!(g)
        b2 = blank!(g)

        t1 = Triple(b1, rdf.type, ex.Person)
        t2 = Triple(b1, rdf.type, ex.Person)
        t3 = Triple(b2, rdf.type, ex.Person)

        @test t1 == t2   # same blank node
        @test t1 != t3   # different blank node
    end

    @testset "Triple display" begin
        t = Triple(ex.alice, rdf.type, ex.Person)
        r = repr(t)
        @test contains(r, "http://example.org/alice")
        @test contains(r, "http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        @test contains(r, "http://example.org/Person")
        @test endswith(strip(r), ".")
    end

    @testset "Quad construction" begin
        graph_name = IRI("http://example.org/graph1")

        q = Quad(ex.alice, rdf.type, ex.Person, graph_name)
        @test q isa Quad
        @test q.subject == ex.alice
        @test q.predicate == rdf.type
        @test q.object == ex.Person
        @test q.graph == graph_name

        # Default graph (graph = nothing)
        q = Quad(ex.alice, rdf.type, ex.Person, nothing)
        @test q.graph === nothing

        # Blank node as graph name (spec §4 — RDF 1.1 allows this)
        g = Graph()
        b = blank!(g)
        q = Quad(ex.alice, rdf.type, ex.Person, b)
        @test q.graph == b
        @test q.graph isa BlankNode
    end

    @testset "Quad positional type constraints" begin
        graph_name = IRI("http://example.org/graph1")

        # Literal MUST NOT appear as graph name
        @test_throws MethodError Quad(ex.alice, rdf.type, ex.Person, Literal("g"))

        # Literal MUST NOT appear as subject
        @test_throws MethodError Quad(Literal("s"), rdf.type, ex.Person, graph_name)

        # Literal MUST NOT appear as predicate
        @test_throws MethodError Quad(ex.alice, Literal("p"), ex.Person, graph_name)
    end

    @testset "Triple ↔ Quad conversion" begin
        graph_name = IRI("http://example.org/graph1")
        t = Triple(ex.alice, rdf.type, ex.Person)

        # Triple → Quad
        q = Quad(t; graph=graph_name)
        @test q.subject == t.subject
        @test q.predicate == t.predicate
        @test q.object == t.object
        @test q.graph == graph_name

        # Triple → Quad (default graph)
        q = Quad(t)
        @test q.graph === nothing

        # Quad → Triple (drops graph name)
        q2 = Quad(ex.alice, rdf.type, ex.Person, graph_name)
        t2 = Triple(q2)
        @test t2.subject == ex.alice
        @test t2.predicate == rdf.type
        @test t2.object == ex.Person
        @test t2 isa Triple
    end

    @testset "GeneralizedTriple — literals and blank nodes in any position" begin
        g = Graph()
        b = blank!(g)

        # Generalized triples allow literals in any position
        gt = GeneralizedTriple(Literal("subject"), rdf.type, ex.Person)
        @test gt isa GeneralizedTriple
        @test gt.subject == Literal("subject")

        # Blank node as predicate
        gt = GeneralizedTriple(ex.alice, b, ex.Person)
        @test gt isa GeneralizedTriple
        @test gt.predicate == b

        # Literal as predicate
        gt = GeneralizedTriple(ex.alice, Literal("predicate"), ex.Person)
        @test gt isa GeneralizedTriple

        # Standard Triple does not accept these (type error)
        @test_throws MethodError Triple(Literal("subject"), rdf.type, ex.Person)
        @test_throws MethodError Triple(ex.alice, b, ex.Person)
    end

end
