using RDF
using Test
using Tables
using DataFrames

@testset "Tables.jl Integration" begin

    ex = Namespace("http://example.org/")

    function make_test_graph()
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type,  ex.Person))
        push!(g, Triple(ex.alice, ex.name,   Literal("Alice")))
        push!(g, Triple(ex.alice, ex.age,    Literal(30)))
        push!(g, Triple(ex.bob,   rdf.type,  ex.Person))
        push!(g, Triple(ex.bob,   ex.name,   Literal("Bob")))
        push!(g, Triple(ex.carol, rdf.type,  ex.Employee))
        return g
    end

    @testset "match results implement Tables.jl interface" begin
        g = make_test_graph()
        results = match(g, predicate=rdf.type)

        @test Tables.istable(results)
    end

    @testset "Tables.schema — correct column names" begin
        g = make_test_graph()
        results = match(g, predicate=rdf.type)

        schema = Tables.schema(results)
        @test schema !== nothing
        @test :subject   in schema.names
        @test :predicate in schema.names
        @test :object    in schema.names
    end

    @testset "Tables.rows — each row is a Triple" begin
        g = make_test_graph()
        results = match(g, predicate=rdf.type)

        rows = Tables.rows(results)
        row = first(rows)

        @test hasproperty(row, :subject)
        @test hasproperty(row, :predicate)
        @test hasproperty(row, :object)
        @test row.subject isa RDFTerm
        @test row.predicate isa IRI
        @test row.object isa RDFTerm
    end

    @testset "DataFrame construction from match results" begin
        g = make_test_graph()

        # DataFrame from graph match
        df = DataFrame(match(g, predicate=rdf.type))
        @test df isa DataFrame
        @test nrow(df) == 3
        @test :subject   in propertynames(df)
        @test :predicate in propertynames(df)
        @test :object    in propertynames(df)

        # All subjects are IRIs
        @test all(s isa IRI for s in df.subject)

        # All predicates are rdf:type
        @test all(p == rdf.type for p in df.predicate)

        # Objects include Person and Employee
        objects = Set(df.object)
        @test ex.Person   in objects
        @test ex.Employee in objects
    end

    @testset "DataFrame — full graph as table" begin
        g = make_test_graph()
        df = DataFrame(match(g))

        @test nrow(df) == 6
        @test ncol(df) == 3
    end

    @testset "DataFrame — filtered results" begin
        g = make_test_graph()

        # People only
        df = DataFrame(match(g, predicate=rdf.type, object=ex.Person))
        @test nrow(df) == 2
        @test all(df.object .== ex.Person)
    end

    @testset "DataFrame — empty match result" begin
        g = make_test_graph()
        df = DataFrame(match(g, subject=IRI("http://example.org/nobody")))
        @test nrow(df) == 0
        @test :subject in propertynames(df)
    end

    @testset "Dataset match results have graph column" begin
        ds = Dataset()
        g1 = Graph()
        push!(g1, Triple(ex.alice, rdf.type, ex.Person))
        n1 = IRI("http://example.org/g1")

        g2 = Graph()
        push!(g2, Triple(ex.bob, rdf.type, ex.Person))
        n2 = IRI("http://example.org/g2")

        ds[n1] = g1
        ds[n2] = g2

        results = match(ds, predicate=rdf.type)
        @test Tables.istable(results)

        schema = Tables.schema(results)
        @test :graph in schema.names

        df = DataFrame(results)
        @test :graph in propertynames(df)
        @test nrow(df) == 2
    end

    @testset "Tables.jl — works with any Tables consumer" begin
        g = make_test_graph()
        results = match(g, predicate=rdf.type)

        # Tables.dictcolumntable
        cols = Tables.dictcolumntable(results)
        @test haskey(cols, :subject)
        @test length(cols[:subject]) == 3

        # Tables.rowtable
        rows = Tables.rowtable(results)
        @test length(rows) == 3
        @test all(r -> haskey(r, :subject), rows)

        # Tables.columntable
        cols = Tables.columntable(results)
        @test haskey(cols, :subject)
        @test haskey(cols, :predicate)
        @test haskey(cols, :object)
    end

    @testset "Pipe syntax with DataFrames" begin
        g = make_test_graph()

        # The pipe syntax is idiomatic Julia for data pipelines
        df = match(g, predicate=rdf.type) |> DataFrame
        @test nrow(df) == 3
    end

end
