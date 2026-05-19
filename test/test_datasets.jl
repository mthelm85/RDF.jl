using RDF
using Test

@testset "Datasets" begin

    const ex = Namespace("http://example.org/")

    @testset "Construction" begin
        ds = Dataset()
        @test ds isa Dataset
        @test isempty(ds.default_graph)
        @test length(ds) == 0  # no named graphs

        # With default graph
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        ds = Dataset(default_graph=g)
        @test length(ds.default_graph) == 1
        @test Triple(ex.alice, rdf.type, ex.Person) in ds.default_graph
    end

    @testset "Named graph add and retrieve" begin
        ds = Dataset()
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))

        name = IRI("http://example.org/graph1")
        ds[name] = g

        # Retrieve
        retrieved = ds[name]
        @test retrieved isa Graph
        @test length(retrieved) == 1
        @test Triple(ex.alice, rdf.type, ex.Person) in retrieved
    end

    @testset "Named graph membership" begin
        ds = Dataset()
        name1 = IRI("http://example.org/graph1")
        name2 = IRI("http://example.org/graph2")

        ds[name1] = Graph()
        @test haskey(ds, name1)
        @test !haskey(ds, name2)
    end

    @testset "Named graph deletion" begin
        ds = Dataset()
        name = IRI("http://example.org/graph1")
        ds[name] = Graph()

        @test haskey(ds, name)
        delete!(ds, name)
        @test !haskey(ds, name)

        # Deleting non-existent graph is a no-op
        @test_nowarn delete!(ds, name)
    end

    @testset "get with default" begin
        ds = Dataset()
        name = IRI("http://example.org/graph1")

        default = Graph()
        result = get(ds, name, default)
        @test result === default

        ds[name] = Graph()
        result = get(ds, name, default)
        @test result !== default
        @test result isa Graph
    end

    @testset "KeyError on missing graph" begin
        ds = Dataset()
        name = IRI("http://example.org/missing")
        @test_throws KeyError ds[name]
    end

    @testset "Graph names are unique" begin
        ds = Dataset()
        name = IRI("http://example.org/graph1")

        g1 = Graph()
        push!(g1, Triple(ex.alice, rdf.type, ex.Person))
        ds[name] = g1

        g2 = Graph()
        push!(g2, Triple(ex.bob, rdf.type, ex.Person))
        ds[name] = g2  # replaces g1

        @test length(ds) == 1
        @test Triple(ex.bob, rdf.type, ex.Person) in ds[name]
        @test Triple(ex.alice, rdf.type, ex.Person) ∉ ds[name]
    end

    @testset "Default graph access and replacement" begin
        ds = Dataset()
        @test isempty(ds.default_graph)

        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        ds.default_graph = g

        @test Triple(ex.alice, rdf.type, ex.Person) in ds.default_graph
        @test length(ds.default_graph) == 1
    end

    @testset "Iteration — (name, graph) pairs" begin
        ds = Dataset()
        n1 = IRI("http://example.org/g1")
        n2 = IRI("http://example.org/g2")
        g1 = Graph(); push!(g1, Triple(ex.alice, rdf.type, ex.Person))
        g2 = Graph(); push!(g2, Triple(ex.bob,   rdf.type, ex.Person))

        ds[n1] = g1
        ds[n2] = g2

        pairs = collect(ds)
        @test length(pairs) == 2
        @test all(p isa Pair for p in pairs)

        names  = [p.first  for p in pairs]
        graphs = [p.second for p in pairs]
        @test n1 in names
        @test n2 in names
        @test all(g isa Graph for g in graphs)
    end

    @testset "keys, values, length" begin
        ds = Dataset()
        n1 = IRI("http://example.org/g1")
        n2 = IRI("http://example.org/g2")
        ds[n1] = Graph()
        ds[n2] = Graph()

        @test length(ds) == 2
        @test Set(keys(ds)) == Set([n1, n2])
        @test all(g isa Graph for g in values(ds))
        @test length(collect(values(ds))) == 2
    end

    @testset "ntriples — total count across all graphs" begin
        ds = Dataset()

        # Add to default graph
        push!(ds.default_graph, Triple(ex.alice, rdf.type, ex.Person))

        # Add named graphs
        g1 = Graph()
        push!(g1, Triple(ex.bob,   rdf.type, ex.Person))
        push!(g1, Triple(ex.carol, rdf.type, ex.Person))
        ds[IRI("http://example.org/g1")] = g1

        g2 = Graph()
        push!(g2, Triple(ex.dave, rdf.type, ex.Person))
        ds[IRI("http://example.org/g2")] = g2

        @test ntriples(ds) == 4
    end

    @testset "quads — lazy iterator of all triples as Quads" begin
        ds = Dataset()
        push!(ds.default_graph, Triple(ex.alice, rdf.type, ex.Person))

        g1 = Graph()
        push!(g1, Triple(ex.bob, rdf.type, ex.Person))
        name1 = IRI("http://example.org/g1")
        ds[name1] = g1

        qs = collect(quads(ds))
        @test length(qs) == 2
        @test all(q isa Quad for q in qs)

        # Default graph quad has graph=nothing
        default_quads = filter(q -> q.graph === nothing, qs)
        @test length(default_quads) == 1
        @test default_quads[1].subject == ex.alice

        # Named graph quad has the graph name
        named_quads = filter(q -> q.graph == name1, qs)
        @test length(named_quads) == 1
        @test named_quads[1].subject == ex.bob
    end

    @testset "Blank node graph names (spec §4 — RDF 1.1 allows this)" begin
        ds = Dataset()
        b = blank!(ds)
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))

        ds[b] = g
        @test haskey(ds, b)
        retrieved = ds[b]
        @test Triple(ex.alice, rdf.type, ex.Person) in retrieved
    end

    @testset "Blank node sharing between graphs (spec §4)" begin
        ds = Dataset()
        b = blank!(ds)  # dataset-scoped blank node

        g1 = Graph()
        g2 = Graph()
        name1 = IRI("http://example.org/g1")
        name2 = IRI("http://example.org/g2")

        push!(g1, Triple(b, rdf.type, ex.Person))
        push!(g2, Triple(b, ex.name, Literal("Alice")))

        ds[name1] = g1
        ds[name2] = g2

        # Same blank node in both graphs
        t1 = only(match(g1, subject=b))
        t2 = only(match(g2, subject=b))
        @test t1.subject == t2.subject
        @test t1.subject == b
    end

    @testset "Dataset isomorphism" begin
        ds1 = Dataset()
        b1 = blank!(ds1)
        push!(ds1.default_graph, Triple(b1, rdf.type, ex.Person))

        ds2 = Dataset()
        b2 = blank!(ds2)
        push!(ds2.default_graph, Triple(b2, rdf.type, ex.Person))

        @test ds1 ≅ ds2
        @test ds1 != ds2  # different blank node IDs
    end

end
