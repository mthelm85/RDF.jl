using RDF
using Test

# Type stability tests ensure the Julia compiler can infer return types
# statically. Failures here indicate performance regressions.
# All public functions must be type-stable per requirements §8.1.

@testset "Type Stability" begin

    const ex = Namespace("http://example.org/")

    @testset "IRI construction" begin
        @inferred IRI("http://example.org/alice")
    end

    @testset "Literal construction" begin
        @inferred Literal("hello")
        @inferred Literal(42)
        @inferred Literal(3.14)
        @inferred Literal(true)
        @inferred Literal("hello"; lang="en")
        @inferred Literal("42", xsd.integer)
    end

    @testset "value(T, lit) — type-stable coercion" begin
        lit_int    = Literal("42", xsd.integer)
        lit_float  = Literal("3.14", xsd.double)
        lit_bool   = Literal("true", xsd.boolean)
        lit_string = Literal("hello")

        @inferred value(Int64,   lit_int)
        @inferred value(Float64, lit_float)
        @inferred value(Bool,    lit_bool)
        @inferred value(String,  lit_string)
    end

    @testset "Triple construction" begin
        @inferred Triple(ex.alice, rdf.type, ex.Person)
        g = Graph()
        b = blank!(g)
        @inferred Triple(b, rdf.type, ex.Person)
        @inferred Triple(ex.alice, ex.name, Literal("Alice"))
    end

    @testset "Quad construction" begin
        g_name = IRI("http://example.org/g")
        @inferred Quad(ex.alice, rdf.type, ex.Person, g_name)
        @inferred Quad(ex.alice, rdf.type, ex.Person, nothing)
    end

    @testset "Graph operations" begin
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))

        @inferred length(g)
        @inferred isempty(g)

        t = Triple(ex.alice, rdf.type, ex.Person)
        @inferred in(t, g)
    end

    @testset "Namespace IRI generation" begin
        ns = Namespace("http://example.org/")
        @inferred ns.alice
        @inferred ns["birth-date"]
        @inferred string(ns)
    end

    @testset "match returns consistent iterator type" begin
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))

        # The return type of match should be inferrable
        # (it's always the same iterator type regardless of which pattern)
        r1 = @inferred match(g)
        r2 = @inferred match(g, subject=ex.alice)
        r3 = @inferred match(g, predicate=rdf.type)
        r4 = @inferred match(g, object=ex.Person)
        r5 = @inferred match(g, subject=ex.alice, predicate=rdf.type)

        @test typeof(r1) == typeof(r2) == typeof(r3) == typeof(r4) == typeof(r5)
    end

    @testset "TriplePattern construction" begin
        @inferred TriplePattern()
        @inferred TriplePattern(subject=ex.alice)
        @inferred TriplePattern(predicate=rdf.type)
        @inferred TriplePattern(subject=ex.alice, predicate=rdf.type)
    end

    @testset "Serialization write/read" begin
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        buf = IOBuffer()
        @inferred write(buf, MIME"application/n-triples"(), g)
    end

    @testset "Vocabulary constants — no inference cost" begin
        # Accessing vocabulary constants should be free (they are const)
        @inferred rdf.type
        @inferred xsd.integer
        @inferred rdfs.subClassOf
    end

    @testset "blank! minting" begin
        g = Graph()
        @inferred blank!(g)
    end

    @testset "infer_rdfs" begin
        g = Graph()
        push!(g, Triple(ex.Dog, rdfs.subClassOf, ex.Animal))
        @inferred infer_rdfs(g)
    end

    @testset "validate" begin
        g = Graph()
        @inferred validate(g)
    end

    @testset "Graph set operations" begin
        g1 = Graph()
        g2 = Graph()
        @inferred union(g1, g2)
        @inferred intersect(g1, g2)
        @inferred setdiff(g1, g2)
        @inferred issubgraph(g1, g2)
        @inferred isomorphic(g1, g2)
    end

    @testset "subjects, predicates, objects accessors" begin
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        @inferred subjects(g)
        @inferred predicates(g)
        @inferred objects(g)
    end

end
