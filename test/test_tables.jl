using RDF
using Test
using Tables
using DataFrames
using Dates

@testset "Tables.jl Integration" begin

    ex   = Namespace("http://example.org/")
    foaf = Namespace("http://xmlns.com/foaf/0.1/")

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

    # ── Interface ─────────────────────────────────────────────────────────────

    @testset "match results implement Tables.jl interface" begin
        g = make_test_graph()
        @test Tables.istable(match(g; predicate=rdf.type))
    end

    @testset "Tables.schema — correct column names" begin
        g = make_test_graph()
        schema = Tables.schema(match(g; predicate=rdf.type))
        # schema may be nothing for lazy iterators; column names are on the iterator
        @test Tables.columnnames(match(g; predicate=rdf.type)) == (:subject, :predicate, :object)
    end

    # ── Coercion: column types ────────────────────────────────────────────────

    @testset "IRI columns become String" begin
        g = make_test_graph()
        df = DataFrame(match(g; predicate=rdf.type))

        @test eltype(df.subject)   == String
        @test eltype(df.predicate) == String
        @test eltype(df.object)    == String
    end

    @testset "Literal integer column becomes Int64" begin
        g = make_test_graph()
        df = DataFrame(match(g; predicate=ex.age))

        # object column holds xsd:integer literals → coerced to Int64
        @test eltype(df.object) == Int64
        @test 30 in df.object
    end

    @testset "Literal string column becomes String" begin
        g = make_test_graph()
        df = DataFrame(match(g; predicate=ex.name))

        @test eltype(df.object) == String
        @test "Alice" in df.object
        @test "Bob"   in df.object
    end

    @testset "Heterogeneous object column falls back to String" begin
        # Full graph: objects are IRIs (rdf:type rows), plain strings (name rows),
        # and integers (age rows) — heterogeneous → String fallback
        g = make_test_graph()
        df = DataFrame(match(g))

        @test nrow(df) == 6
        @test ncol(df) == 3
        # subject and predicate are always String
        @test eltype(df.subject)   == String
        @test eltype(df.predicate) == String
        # object is heterogeneous → String
        @test eltype(df.object) == String
    end

    # ── DataFrame construction ────────────────────────────────────────────────

    @testset "DataFrame construction from match results" begin
        g = make_test_graph()
        df = DataFrame(match(g; predicate=rdf.type))

        @test df isa DataFrame
        @test nrow(df) == 3
        @test :subject   in propertynames(df)
        @test :predicate in propertynames(df)
        @test :object    in propertynames(df)

        # Values are plain strings, not RDF wrappers
        @test all(s isa String for s in df.subject)
        @test all(p == rdf.type.value for p in df.predicate)

        objects = Set(df.object)
        @test ex.Person.value   in objects
        @test ex.Employee.value in objects
    end

    @testset "DataFrame — filtered results" begin
        g = make_test_graph()
        df = DataFrame(match(g; predicate=rdf.type, object=ex.Person))

        @test nrow(df) == 2
        @test all(==(ex.Person.value), df.object)
    end

    @testset "DataFrame — empty match result" begin
        g = make_test_graph()
        df = DataFrame(match(g; subject=IRI("http://example.org/nobody")))
        @test nrow(df) == 0
        @test :subject in propertynames(df)
    end

    @testset "Pipe syntax" begin
        g = make_test_graph()
        df = match(g; predicate=rdf.type) |> DataFrame
        @test nrow(df) == 3
    end

    # ── Dataset match (Quad) ─────────────────────────────────────────────────

    @testset "Dataset match — graph column is String" begin
        ds = Dataset()
        g1 = Graph(); push!(g1, Triple(ex.alice, rdf.type, ex.Person))
        g2 = Graph(); push!(g2, Triple(ex.bob,   rdf.type, ex.Person))
        n1 = IRI("http://example.org/g1")
        n2 = IRI("http://example.org/g2")
        ds[n1] = g1; ds[n2] = g2

        df = DataFrame(match(ds; predicate=rdf.type))

        @test :graph in propertynames(df)
        @test nrow(df) == 2
        # graph column contains IRI strings
        @test all(g isa String for g in df.graph)
        graphs = Set(df.graph)
        @test n1.value in graphs
        @test n2.value in graphs
    end

    @testset "Dataset match — default graph rows have missing graph" begin
        ds = Dataset()
        push!(ds.default_graph, Triple(ex.alice, rdf.type, ex.Person))
        g1 = Graph(); push!(g1, Triple(ex.bob, rdf.type, ex.Person))
        ds[IRI("http://example.org/g1")] = g1

        df = DataFrame(match(ds; predicate=rdf.type))
        @test nrow(df) == 2
        # default-graph row has missing graph
        @test any(ismissing, df.graph)
    end

    # ── SolutionSet (SPARQL SELECT) ───────────────────────────────────────────

    @testset "SolutionSet — string column" begin
        ttl = """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          ex:alice foaf:name "Alice" .
          ex:bob   foaf:name "Bob"   .
        """
        ds  = Dataset(; default_graph=read(IOBuffer(ttl), MIME"text/turtle"(), Graph))
        sol = sparql(ds, "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?name WHERE { ?s foaf:name ?name }")
        df  = DataFrame(sol)

        @test :name in propertynames(df)
        @test eltype(df.name) == String
        @test Set(df.name) == Set(["Alice", "Bob"])
    end

    @testset "SolutionSet — integer column" begin
        ttl = """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          ex:alice foaf:age 30 .
          ex:bob   foaf:age 25 .
        """
        ds  = Dataset(; default_graph=read(IOBuffer(ttl), MIME"text/turtle"(), Graph))
        sol = sparql(ds, "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?age WHERE { ?s foaf:age ?age }")
        df  = DataFrame(sol)

        @test eltype(df.age) == Int64
        @test Set(df.age) == Set([30, 25])
    end

    @testset "SolutionSet — float column" begin
        ttl = """
          PREFIX ex: <http://example.org/>
          ex:a ex:score 3.14 .
          ex:b ex:score 2.72 .
        """
        ds  = Dataset(; default_graph=read(IOBuffer(ttl), MIME"text/turtle"(), Graph))
        sol = sparql(ds, "PREFIX ex: <http://example.org/> SELECT ?score WHERE { ?s ex:score ?score }")
        df  = DataFrame(sol)

        @test eltype(df.score) == Float64
        @test any(x -> isapprox(x, 3.14; atol=1e-9), df.score)
    end

    @testset "SolutionSet — boolean column" begin
        ttl = """
          PREFIX ex: <http://example.org/>
          ex:a ex:active "true"^^<http://www.w3.org/2001/XMLSchema#boolean> .
          ex:b ex:active "false"^^<http://www.w3.org/2001/XMLSchema#boolean> .
        """
        ds  = Dataset(; default_graph=read(IOBuffer(ttl), MIME"text/turtle"(), Graph))
        sol = sparql(ds, "PREFIX ex: <http://example.org/> SELECT ?active WHERE { ?s ex:active ?active }")
        df  = DataFrame(sol)

        @test eltype(df.active) == Bool
        @test true  in df.active
        @test false in df.active
    end

    @testset "SolutionSet — missing for unbound OPTIONAL" begin
        ttl = """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          ex:alice foaf:name "Alice" ; foaf:age 30 .
          ex:bob   foaf:name "Bob"   .
        """
        ds  = Dataset(; default_graph=read(IOBuffer(ttl), MIME"text/turtle"(), Graph))
        sol = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name ?age WHERE {
            ?s foaf:name ?name .
            OPTIONAL { ?s foaf:age ?age }
          }
        """)
        df = DataFrame(sol)

        @test :name in propertynames(df)
        @test :age  in propertynames(df)
        @test any(ismissing, df.age)
        @test !any(ismissing, df.name)
    end

    @testset "SolutionSet — mixed numeric promotes to Float64" begin
        # If one column contains both Int64 and Float64 values, column is Float64
        ttl = """
          PREFIX ex: <http://example.org/>
          ex:a ex:val 1 .
          ex:b ex:val 2.5 .
        """
        ds  = Dataset(; default_graph=read(IOBuffer(ttl), MIME"text/turtle"(), Graph))
        sol = sparql(ds, "PREFIX ex: <http://example.org/> SELECT ?val WHERE { ?s ex:val ?val }")
        df  = DataFrame(sol)

        @test eltype(df.val) == Float64
    end

    @testset "SolutionSet — IRI column becomes String" begin
        ttl = """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          ex:alice a foaf:Person .
          ex:bob   a foaf:Person .
        """
        ds  = Dataset(; default_graph=read(IOBuffer(ttl), MIME"text/turtle"(), Graph))
        sol = sparql(ds, "SELECT ?s WHERE { ?s a <http://xmlns.com/foaf/0.1/Person> }")
        df  = DataFrame(sol)

        @test eltype(df.s) == String
        @test all(s -> startswith(s, "http://"), df.s)
    end

    @testset "SolutionSet — Tables.jl consumer compatibility" begin
        ttl = """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          ex:alice foaf:name "Alice" ; foaf:age 30 .
        """
        ds  = Dataset(; default_graph=read(IOBuffer(ttl), MIME"text/turtle"(), Graph))
        sol = sparql(ds, "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?name ?age WHERE { ?s foaf:name ?name ; foaf:age ?age }")

        @test Tables.istable(sol)
        cols = Tables.columntable(sol)
        @test haskey(cols, :name)
        @test haskey(cols, :age)
        @test cols[:name] == ["Alice"]
        @test cols[:age]  == [30]
    end

end
