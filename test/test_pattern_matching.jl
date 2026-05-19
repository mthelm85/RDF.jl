using RDF
using Test

@testset "Pattern Matching" begin

    const ex = Namespace("http://example.org/")

    # Build a reusable test graph
    function make_test_graph()
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type,   ex.Person))
        push!(g, Triple(ex.alice, ex.name,    Literal("Alice")))
        push!(g, Triple(ex.alice, ex.age,     Literal(30)))
        push!(g, Triple(ex.alice, ex.knows,   ex.bob))
        push!(g, Triple(ex.bob,   rdf.type,   ex.Person))
        push!(g, Triple(ex.bob,   ex.name,    Literal("Bob")))
        push!(g, Triple(ex.bob,   ex.age,     Literal(25)))
        push!(g, Triple(ex.carol, rdf.type,   ex.Employee))
        push!(g, Triple(ex.carol, ex.name,    Literal("Carol")))
        push!(g, Triple(ex.carol, ex.worksAt, ex.acme))
        return g
    end

    @testset "match — no bindings returns all triples" begin
        g = make_test_graph()
        results = collect(match(g))
        @test length(results) == 10
        @test all(t isa Triple for t in results)
    end

    @testset "match — subject bound" begin
        g = make_test_graph()

        results = collect(match(g, subject=ex.alice))
        @test length(results) == 4
        @test all(t.subject == ex.alice for t in results)

        results = collect(match(g, subject=ex.bob))
        @test length(results) == 3

        # No match
        results = collect(match(g, subject=IRI("http://example.org/nobody")))
        @test isempty(results)
    end

    @testset "match — predicate bound" begin
        g = make_test_graph()

        results = collect(match(g, predicate=rdf.type))
        @test length(results) == 3
        @test all(t.predicate == rdf.type for t in results)

        results = collect(match(g, predicate=ex.name))
        @test length(results) == 3

        results = collect(match(g, predicate=ex.knows))
        @test length(results) == 1
    end

    @testset "match — object bound" begin
        g = make_test_graph()

        results = collect(match(g, object=ex.Person))
        @test length(results) == 2
        @test all(t.object == ex.Person for t in results)

        results = collect(match(g, object=Literal("Alice")))
        @test length(results) == 1

        results = collect(match(g, object=Literal(30)))
        @test length(results) == 1
    end

    @testset "match — subject and predicate bound" begin
        g = make_test_graph()

        results = collect(match(g, subject=ex.alice, predicate=ex.name))
        @test length(results) == 1
        @test results[1].object == Literal("Alice")

        results = collect(match(g, subject=ex.alice, predicate=rdf.type))
        @test length(results) == 1
        @test results[1].object == ex.Person
    end

    @testset "match — subject and object bound" begin
        g = make_test_graph()

        results = collect(match(g, subject=ex.alice, object=ex.Person))
        @test length(results) == 1
        @test results[1].predicate == rdf.type

        results = collect(match(g, subject=ex.alice, object=ex.Employee))
        @test isempty(results)
    end

    @testset "match — predicate and object bound" begin
        g = make_test_graph()

        results = collect(match(g, predicate=rdf.type, object=ex.Person))
        @test length(results) == 2
        subjects = Set(t.subject for t in results)
        @test ex.alice in subjects
        @test ex.bob in subjects

        results = collect(match(g, predicate=rdf.type, object=ex.Employee))
        @test length(results) == 1
        @test results[1].subject == ex.carol
    end

    @testset "match — all three bound (membership check)" begin
        g = make_test_graph()

        # Existing triple
        results = collect(match(g,
            subject=ex.alice, predicate=rdf.type, object=ex.Person))
        @test length(results) == 1

        # Non-existing triple
        results = collect(match(g,
            subject=ex.alice, predicate=rdf.type, object=ex.Employee))
        @test isempty(results)
    end

    @testset "match returns a lazy iterator — no upfront allocation" begin
        g = make_test_graph()
        iter = match(g, predicate=rdf.type)

        # It's an iterator, not a collection
        @test !isa(iter, Vector)
        @test !isa(iter, Set)

        # But it can be iterated
        count = 0
        for t in iter
            count += 1
        end
        @test count == 3

        # And collected
        results = collect(iter)
        @test length(results) == 3
    end

    @testset "match — composable with Iterators" begin
        g = make_test_graph()

        # Filter on top of match
        adults = match(g, predicate=ex.age) |>
                 iter -> Iterators.filter(t -> value(Int, t.object) >= 30, iter) |>
                 collect
        @test length(adults) == 1
        @test adults[1].subject == ex.alice

        # Map on top of match
        names = match(g, predicate=ex.name) |>
                iter -> Iterators.map(t -> value(String, t.object), iter) |>
                collect
        @test length(names) == 3
        @test "Alice" in names
        @test "Bob" in names
    end

    @testset "TriplePattern — programmatic construction" begin
        g = make_test_graph()

        # Keyword construction
        p = TriplePattern(subject=ex.alice)
        @test p isa TriplePattern
        @test p.subject == ex.alice
        @test p.predicate === nothing
        @test p.object === nothing

        p = TriplePattern(predicate=rdf.type, object=ex.Person)
        @test p.subject === nothing
        @test p.predicate == rdf.type
        @test p.object == ex.Person

        # match(g, pattern) is equivalent to match(g; kwargs...)
        r1 = collect(match(g, subject=ex.alice, predicate=rdf.type))
        r2 = collect(match(g, TriplePattern(subject=ex.alice, predicate=rdf.type)))
        @test Set(r1) == Set(r2)

        # All-unbound pattern matches everything
        p = TriplePattern()
        @test length(collect(match(g, p))) == 10
    end

    @testset "match — with blank nodes" begin
        g = Graph()
        b = blank!(g)
        push!(g, Triple(b, rdf.type, ex.Person))
        push!(g, Triple(b, ex.name, Literal("Unknown")))
        push!(g, Triple(ex.alice, ex.knows, b))

        # Match by blank node identity
        results = collect(match(g, subject=b))
        @test length(results) == 2

        results = collect(match(g, object=b))
        @test length(results) == 1
        @test results[1].subject == ex.alice
    end

    @testset "subjects convenience accessor" begin
        g = make_test_graph()

        all_subjects = collect(subjects(g))
        @test length(all_subjects) >= 3  # at least alice, bob, carol

        # subjects with predicate filter
        type_subjects = collect(subjects(g, predicate=rdf.type))
        @test ex.alice in type_subjects
        @test ex.bob in type_subjects
        @test ex.carol in type_subjects

        # subjects with predicate and object filter
        person_subjects = collect(subjects(g, predicate=rdf.type, object=ex.Person))
        @test ex.alice in person_subjects
        @test ex.bob in person_subjects
        @test ex.carol ∉ person_subjects
    end

    @testset "predicates convenience accessor" begin
        g = make_test_graph()

        alice_predicates = collect(predicates(g, subject=ex.alice))
        @test rdf.type in alice_predicates
        @test ex.name in alice_predicates
        @test ex.age in alice_predicates
        @test ex.knows in alice_predicates
    end

    @testset "objects convenience accessor" begin
        g = make_test_graph()

        alice_names = collect(objects(g, subject=ex.alice, predicate=ex.name))
        @test length(alice_names) == 1
        @test alice_names[1] == Literal("Alice")

        type_objects = collect(objects(g, predicate=rdf.type))
        @test ex.Person in type_objects
        @test ex.Employee in type_objects
    end

    @testset "Dataset match — across all named graphs" begin
        ds = Dataset()
        g1 = Graph()
        push!(g1, Triple(ex.alice, rdf.type, ex.Person))
        push!(g1, Triple(ex.bob,   rdf.type, ex.Person))
        n1 = IRI("http://example.org/g1")

        g2 = Graph()
        push!(g2, Triple(ex.carol, rdf.type, ex.Employee))
        n2 = IRI("http://example.org/g2")

        ds[n1] = g1
        ds[n2] = g2

        # Match across all graphs — returns Quads
        results = collect(match(ds, predicate=rdf.type))
        @test length(results) == 3
        @test all(q isa Quad for q in results)
    end

    @testset "Dataset match — with graph bound" begin
        ds = Dataset()
        g1 = Graph()
        push!(g1, Triple(ex.alice, rdf.type, ex.Person))
        n1 = IRI("http://example.org/g1")

        g2 = Graph()
        push!(g2, Triple(ex.alice, rdf.type, ex.Employee))
        n2 = IRI("http://example.org/g2")

        ds[n1] = g1
        ds[n2] = g2

        # Only from g1
        results = collect(match(ds, subject=ex.alice, graph=n1))
        @test length(results) == 1
        @test results[1].object == ex.Person

        # Only from g2
        results = collect(match(ds, subject=ex.alice, graph=n2))
        @test length(results) == 1
        @test results[1].object == ex.Employee
    end

    @testset "match — empty graph" begin
        g = Graph()
        @test isempty(collect(match(g)))
        @test isempty(collect(match(g, subject=ex.alice)))
        @test isempty(collect(match(g, predicate=rdf.type)))
    end

end
