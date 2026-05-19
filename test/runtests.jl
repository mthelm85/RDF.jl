using RDF
using Test
using Aqua
using JET
using Dates

@testset "RDF.jl" begin

    @testset "Code quality (Aqua.jl)" begin
        Aqua.test_all(RDF; ambiguities=false)
    end

    @testset "Code linting (JET.jl)" begin
        JET.test_package(RDF; target_defined_modules=true)
    end

    # ── IRI ──────────────────────────────────────────────────────────────────

    @testset "IRI" begin
        iri = IRI("http://example.org/foo")
        @test iri.value == "http://example.org/foo"
        @test IRI("http://example.org/foo") == IRI("http://example.org/foo")
        @test IRI("http://example.org/foo") != IRI("http://example.org/bar")
        @test hash(IRI("http://a.org/")) == hash(IRI("http://a.org/"))

        # Absolute required
        @test_throws IRIError IRI("not-absolute")
        @test_throws IRIError IRI("")
        @test_throws IRIError IRI("/relative/path")

        # Fragment identifiers are fine
        @test IRI("http://example.org/foo#bar").value == "http://example.org/foo#bar"

        # String macro
        iri2 = iri"http://example.org/x"
        @test iri2 isa IRI
        @test iri2.value == "http://example.org/x"
    end

    # ── BlankNode ─────────────────────────────────────────────────────────────

    @testset "BlankNode" begin
        g = Graph()
        b1 = blank!(g)
        b2 = blank!(g)
        @test b1 isa BlankNode
        @test b1 != b2
        @test b1.id != b2.id

        bs = blank!(g, 3)
        @test length(bs) == 3
        @test allunique(b.id for b in bs)
    end

    # ── Literal ───────────────────────────────────────────────────────────────

    @testset "Literal" begin
        @testset "construction" begin
            ls = Literal("hello")
            @test ls.lexical_form == "hello"
            @test ls.datatype == IRI("http://www.w3.org/2001/XMLSchema#string")
            @test ls.language_tag == ""

            ll = Literal("hello"; lang="EN")
            @test ll.language_tag == "en"   # lowercased
            @test ll.datatype == IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#langString")

            li = Literal(42)
            @test li.lexical_form == "42"
            @test li.datatype == IRI("http://www.w3.org/2001/XMLSchema#integer")

            lf = Literal(3.14)
            @test lf.datatype == IRI("http://www.w3.org/2001/XMLSchema#double")

            lb = Literal(true)
            @test lb.lexical_form == "true"

            ld = Literal(Date(2024, 1, 1))
            @test ld.datatype == IRI("http://www.w3.org/2001/XMLSchema#date")
        end

        @testset "equality" begin
            @test Literal("a") == Literal("a")
            @test Literal("a") != Literal("b")
            @test Literal("a"; lang="en") != Literal("a"; lang="fr")
            @test Literal("42", xsd.integer) != Literal("42", xsd.string)
        end

        @testset "value extraction" begin
            @test value(Literal(42)) == 42
            @test value(Literal(true)) == true
            @test value(Literal(false)) == false
            @test value(Literal("hello")) == "hello"
            @test value(Literal(Date(2024,1,1))) == Date(2024,1,1)
            @test value(Literal("INF", xsd.double)) == Inf
            @test value(Literal("-INF", xsd.double)) == -Inf
            @test isnan(value(Literal("NaN", xsd.double)))
            @test_throws LiteralValueError value(Literal("notanint", xsd.integer))
            @test tryvalue(Literal("bad", xsd.integer)) === nothing
            @test tryvalue(Literal(42)) == 42
        end

        @testset "ill-typed accepted" begin
            # Must not throw at construction
            @test_nowarn Literal("not-a-boolean", xsd.boolean)
        end
    end

    # ── Namespace ─────────────────────────────────────────────────────────────

    @testset "Namespace" begin
        ex = Namespace("http://example.org/")
        @test ex.foo == IRI("http://example.org/foo")
        @test ex["bar-baz"] == IRI("http://example.org/bar-baz")
        @test string(ex) == "http://example.org/"
    end

    # ── Vocabulary constants ──────────────────────────────────────────────────

    @testset "Vocabulary" begin
        @test rdf.type isa IRI
        @test rdf.type.value == "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
        @test rdfs.subClassOf isa IRI
        @test xsd.integer isa IRI
        @test owl.Class isa IRI
        @test skos.Concept isa IRI
        @test dc.title isa IRI
        @test dcterms.creator isa IRI
        @test foaf.Person isa IRI
        @test schema.Person isa IRI
    end

    # ── Triple ────────────────────────────────────────────────────────────────

    @testset "Triple" begin
        ex = Namespace("http://example.org/")
        t = Triple(ex.alice, rdf.type, ex.Person)
        @test t.subject == ex.alice
        @test t.predicate == rdf.type
        @test t.object == ex.Person
        @test t == Triple(ex.alice, rdf.type, ex.Person)
        @test t != Triple(ex.bob, rdf.type, ex.Person)

        # Quad round-trip
        q = Quad(t, ex.graph1)
        @test Triple(q) == t
        @test q.graph == ex.graph1
    end

    # ── Graph ─────────────────────────────────────────────────────────────────

    @testset "Graph" begin
        ex = Namespace("http://example.org/")

        @testset "push/in/length" begin
            g = Graph()
            t = Triple(ex.alice, rdf.type, ex.Person)
            push!(g, t)
            @test length(g) == 1
            @test t ∈ g
            # duplicate silently ignored
            push!(g, t)
            @test length(g) == 1
        end

        @testset "delete" begin
            g = Graph()
            t = Triple(ex.alice, rdf.type, ex.Person)
            push!(g, t)
            delete!(g, t)
            @test t ∉ g
            @test length(g) == 0
        end

        @testset "iteration" begin
            g = Graph()
            ts = [Triple(ex["s$i"], ex.p, ex["o$i"]) for i in 1:5]
            for t in ts; push!(g, t); end
            @test Set(g) == Set(ts)
        end

        @testset "do-block construction" begin
            g = Graph() do g
                push!(g, Triple(ex.alice, rdf.type, ex.Person))
            end
            @test length(g) == 1
        end

        @testset "issubgraph" begin
            g1 = Graph(); push!(g1, Triple(ex.a, ex.p, ex.b))
            g2 = Graph(); push!(g2, Triple(ex.a, ex.p, ex.b)); push!(g2, Triple(ex.c, ex.p, ex.d))
            @test issubgraph(g1, g2)
            @test !issubgraph(g2, g1)
            @test g1 ⊆ g2
        end

        @testset "set operations" begin
            g1 = Graph(); push!(g1, Triple(ex.a, ex.p, ex.b))
            g2 = Graph(); push!(g2, Triple(ex.a, ex.p, ex.b)); push!(g2, Triple(ex.c, ex.p, ex.d))
            u = union(g1, g2)
            @test length(u) == 2
            i = intersect(g1, g2)
            @test length(i) == 1
            d = setdiff(g2, g1)
            @test length(d) == 1
            @test Triple(ex.c, ex.p, ex.d) ∈ d
        end

        @testset "union blank node renaming" begin
            g1 = Graph(); b1 = blank!(g1); push!(g1, Triple(b1, ex.p, ex.o))
            g2 = Graph(); b2 = blank!(g2); push!(g2, Triple(b2, ex.p, ex.o))
            u = union(g1, g2)
            # Both triples should be present, blank nodes distinct
            triples = collect(u)
            @test length(triples) == 2
            subjs = [t.subject for t in triples]
            @test allunique(subjs)
        end

        @testset "isomorphic" begin
            g1 = Graph(); b1 = blank!(g1); push!(g1, Triple(b1, ex.p, ex.o))
            g2 = Graph(); b2 = blank!(g2); push!(g2, Triple(b2, ex.p, ex.o))
            @test isomorphic(g1, g2)
            @test g1 ≅ g2
        end

        @testset "skolemize / deskolemize" begin
            g = Graph()
            b = blank!(g)
            push!(g, Triple(b, ex.p, ex.o))
            base = "http://example.org/.well-known/genid/"
            sg = skolemize(g; base=base)
            for t in sg
                @test t.subject isa IRI
                @test startswith((t.subject::IRI).value, base)
            end
            dg = deskolemize(sg; base=base)
            @test isomorphic(g, dg)
        end
    end

    # ── Dataset ───────────────────────────────────────────────────────────────

    @testset "Dataset" begin
        ex = Namespace("http://example.org/")
        ds = Dataset()
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        ds[ex.graph1] = g
        @test haskey(ds, ex.graph1)
        @test length(ds) == 1
        @test ntriples(ds) == 1
        @test length(ds.default_graph) == 0
        delete!(ds, ex.graph1)
        @test !haskey(ds, ex.graph1)
    end

    # ── Pattern matching ──────────────────────────────────────────────────────

    @testset "match" begin
        ex = Namespace("http://example.org/")
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        push!(g, Triple(ex.bob,   rdf.type, ex.Person))
        push!(g, Triple(ex.alice, ex.name, Literal("Alice")))

        @test length(collect(match(g; subject=ex.alice))) == 2
        @test length(collect(match(g; predicate=rdf.type))) == 2
        @test length(collect(match(g; object=ex.Person))) == 2
        @test length(collect(match(g; subject=ex.alice, predicate=rdf.type))) == 1
        @test length(collect(match(g))) == 3

        # TriplePattern form
        pat = TriplePattern(ex.alice, nothing, nothing)
        @test length(collect(match(g, pat))) == 2

        # accessors
        @test ex.Person ∈ collect(objects(g; predicate=rdf.type))
        @test ex.alice ∈ collect(subjects(g; predicate=rdf.type))
        @test rdf.type ∈ collect(predicates(g; subject=ex.alice))

        # unbound term returns empty
        @test isempty(collect(match(g; subject=ex.nobody)))
    end

    # ── N-Triples round-trip ──────────────────────────────────────────────────

    @testset "N-Triples serialization" begin
        ex = Namespace("http://example.org/")
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        push!(g, Triple(ex.alice, ex.name, Literal("Alice"; lang="en")))
        push!(g, Triple(ex.alice, ex.age, Literal(30)))

        buf = IOBuffer()
        write(buf, MIME"application/n-triples"(), g)
        nt = String(take!(buf))

        g2 = read(IOBuffer(nt), MIME"application/n-triples"(), Graph)
        @test isomorphic(g, g2)
    end

    @testset "N-Triples special chars" begin
        g = Graph()
        ex = Namespace("http://example.org/")
        push!(g, Triple(ex.s, ex.p, Literal("tab\there\nnewline\r")))
        buf = IOBuffer()
        write(buf, MIME"application/n-triples"(), g)
        g2 = read(IOBuffer(take!(buf)), MIME"application/n-triples"(), Graph)
        @test isomorphic(g, g2)
    end

    # ── N-Quads round-trip ────────────────────────────────────────────────────

    @testset "N-Quads serialization" begin
        ex = Namespace("http://example.org/")
        ds = Dataset()
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        ds[ex.graph1] = g
        push!(ds.default_graph, Triple(ex.bob, rdf.type, ex.Person))

        buf = IOBuffer()
        write(buf, MIME"application/n-quads"(), ds)
        ds2 = read(IOBuffer(take!(buf)), MIME"application/n-quads"(), Dataset)
        @test ntriples(ds) == ntriples(ds2)
        @test haskey(ds2, ex.graph1)
    end

    # ── RDFS inference ────────────────────────────────────────────────────────

    @testset "RDFS inference" begin
        ex = Namespace("http://example.org/")
        g = Graph()
        # Animal ← Mammal ← Dog
        push!(g, Triple(ex.Mammal, rdfs.subClassOf, ex.Animal))
        push!(g, Triple(ex.Dog,    rdfs.subClassOf, ex.Mammal))
        push!(g, Triple(ex.rex,    rdf.type, ex.Dog))

        ig = infer_rdfs(g)
        @test Triple(ex.rex, rdf.type, ex.Mammal) ∈ ig
        @test Triple(ex.rex, rdf.type, ex.Animal) ∈ ig

        # domain inference
        g2 = Graph()
        push!(g2, Triple(ex.hasAge, rdfs.domain, ex.Person))
        push!(g2, Triple(ex.alice, ex.hasAge, Literal(30)))
        ig2 = infer_rdfs(g2)
        @test Triple(ex.alice, rdf.type, ex.Person) ∈ ig2

        # range inference
        g3 = Graph()
        push!(g3, Triple(ex.hasAge, rdfs.range, xsd.integer))
        push!(g3, Triple(ex.alice, ex.hasAge, ex.thing))
        ig3 = infer_rdfs(g3)
        @test Triple(ex.thing, rdf.type, xsd.integer) ∈ ig3

        # entails
        @test entails(g, Triple(ex.rex, rdf.type, ex.Animal))
    end

    # ── Validation ────────────────────────────────────────────────────────────

    @testset "validate" begin
        ex = Namespace("http://example.org/")
        g = Graph()
        push!(g, Triple(ex.s, ex.p, Literal("notanint", xsd.integer)))
        warnings = validate(g)
        @test any(w -> w.code == :ill_typed_literal, warnings)

        g2 = Graph()
        push!(g2, Triple(ex.s, ex.p, Literal("valid", xsd.string)))
        @test isempty(validate(g2))

        # Bad language tag
        # construct manually to bypass constructor (which lowercases — that's fine)
        g3 = Graph()
        push!(g3, Triple(ex.s, ex.p, Literal("hello"; lang="invalid!!tag")))
        warnings3 = validate(g3)
        @test any(w -> w.code == :invalid_lang_tag, warnings3)
    end

    # ── Display ───────────────────────────────────────────────────────────────

    @testset "show" begin
        @test repr(IRI("http://example.org/")) == "<http://example.org/>"
        @test repr(Literal("hello"; lang="en")) == "\"hello\"@en"
        @test repr(Literal("42", xsd.integer)) == "\"42\"^^<http://www.w3.org/2001/XMLSchema#integer>"

        ex = Namespace("http://example.org/")
        g = Graph()
        push!(g, Triple(ex.s, ex.p, ex.o))
        @test occursin("1 triple", repr(g))

        g2 = Graph()
        @test occursin("0 triple", repr(g2))
    end

    # ── W3C conformance tests (skipped unless fixtures present) ───────────────

    include("w3c/w3c_tests.jl")

end
