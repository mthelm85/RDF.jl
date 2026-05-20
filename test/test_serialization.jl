using RDF
using Test

@testset "Serialization — N-Triples and N-Quads" begin

    ex = Namespace("http://example.org/")

    # ----------------------------------------------------------------
    # Helpers
    # ----------------------------------------------------------------

    function roundtrip_graph(g::Graph)
        buf = IOBuffer()
        write(buf, MIME"application/n-triples"(), g)
        seekstart(buf)
        read(buf, MIME"application/n-triples"(), Graph)
    end

    function roundtrip_dataset(ds::Dataset)
        buf = IOBuffer()
        write(buf, MIME"application/n-quads"(), ds)
        seekstart(buf)
        read(buf, MIME"application/n-quads"(), Dataset)
    end

    function parse_graph(nt::String)
        read(IOBuffer(nt), MIME"application/n-triples"(), Graph)
    end

    function parse_dataset(nq::String)
        read(IOBuffer(nq), MIME"application/n-quads"(), Dataset)
    end

    function serialize_graph(g::Graph)
        buf = IOBuffer()
        write(buf, MIME"application/n-triples"(), g)
        String(take!(buf))
    end

    function serialize_dataset(ds::Dataset)
        buf = IOBuffer()
        write(buf, MIME"application/n-quads"(), ds)
        String(take!(buf))
    end

    # ----------------------------------------------------------------
    # N-Triples serialization
    # ----------------------------------------------------------------

    @testset "N-Triples — IRI subject, predicate, object" begin
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))

        s = serialize_graph(g)
        @test contains(s, "<http://example.org/alice>")
        @test contains(s, "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>")
        @test contains(s, "<http://example.org/Person>")
        @test contains(s, " .\n")
    end

    @testset "N-Triples — typed literal" begin
        g = Graph()
        push!(g, Triple(ex.alice, ex.age, Literal(42)))

        s = serialize_graph(g)
        @test contains(s, "\"42\"^^<http://www.w3.org/2001/XMLSchema#integer>")
    end

    @testset "N-Triples — language-tagged string" begin
        g = Graph()
        push!(g, Triple(ex.alice, ex.name, Literal("Alice"; lang="en")))

        s = serialize_graph(g)
        @test contains(s, "\"Alice\"@en")
    end

    @testset "N-Triples — plain string literal" begin
        g = Graph()
        push!(g, Triple(ex.alice, ex.desc, Literal("A person")))

        s = serialize_graph(g)
        @test contains(s, "\"A person\"^^<http://www.w3.org/2001/XMLSchema#string>") ||
              contains(s, "\"A person\"")  # xsd:string may be omitted per some serializers
    end

    @testset "N-Triples — blank node subject" begin
        g = Graph()
        b = blank!(g)
        push!(g, Triple(b, rdf.type, ex.Person))

        s = serialize_graph(g)
        @test contains(s, "_:")
        @test contains(s, "<http://example.org/Person>")
    end

    @testset "N-Triples — blank node object" begin
        g = Graph()
        b = blank!(g)
        push!(g, Triple(ex.alice, ex.knows, b))

        s = serialize_graph(g)
        @test contains(s, "<http://example.org/alice>")
        @test contains(s, "_:")
    end

    @testset "N-Triples — literal escaping" begin
        g = Graph()

        # Double quotes must be escaped
        push!(g, Triple(ex.s, ex.p, Literal("say \"hello\"")))
        s = serialize_graph(g)
        @test contains(s, "\\\"")

        # Backslash must be escaped
        g2 = Graph()
        push!(g2, Triple(ex.s, ex.p, Literal("back\\slash")))
        s2 = serialize_graph(g2)
        @test contains(s2, "\\\\")

        # Newline must be escaped
        g3 = Graph()
        push!(g3, Triple(ex.s, ex.p, Literal("line1\nline2")))
        s3 = serialize_graph(g3)
        @test contains(s3, "\\n")

        # Carriage return must be escaped
        g4 = Graph()
        push!(g4, Triple(ex.s, ex.p, Literal("cr\r")))
        s4 = serialize_graph(g4)
        @test contains(s4, "\\r")

        # Tab must be escaped
        g5 = Graph()
        push!(g5, Triple(ex.s, ex.p, Literal("tab\there")))
        s5 = serialize_graph(g5)
        @test contains(s5, "\\t")
    end

    @testset "N-Triples — unicode in literals" begin
        g = Graph()
        push!(g, Triple(ex.s, ex.p, Literal("café")))
        s = serialize_graph(g)
        # Either raw UTF-8 or \\uXXXX escaping is valid
        @test contains(s, "caf")
    end

    @testset "N-Triples — multiple triples, one per line" begin
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        push!(g, Triple(ex.alice, ex.name,  Literal("Alice")))
        push!(g, Triple(ex.bob,   rdf.type, ex.Person))

        s = serialize_graph(g)
        lines = filter(!isempty, split(s, '\n'))
        @test length(lines) == 3
        @test all(endswith(l, ".") for l in lines)
    end

    @testset "N-Triples — empty graph serializes to empty string" begin
        s = serialize_graph(Graph())
        @test isempty(strip(s))
    end

    # ----------------------------------------------------------------
    # N-Triples parsing
    # ----------------------------------------------------------------

    @testset "N-Triples parsing — basic triple" begin
        g = parse_graph("<http://example.org/s> <http://example.org/p> <http://example.org/o> .\n")
        @test length(g) == 1
        @test Triple(
            IRI("http://example.org/s"),
            IRI("http://example.org/p"),
            IRI("http://example.org/o")
        ) in g
    end

    @testset "N-Triples parsing — typed literal" begin
        g = parse_graph(
            "<http://example.org/s> <http://example.org/p> " *
            "\"42\"^^<http://www.w3.org/2001/XMLSchema#integer> .\n"
        )
        @test length(g) == 1
        t = only(g)
        @test t.object isa Literal
        @test t.object.lexical_form == "42"
        @test t.object.datatype == xsd.integer
    end

    @testset "N-Triples parsing — language-tagged string" begin
        g = parse_graph(
            "<http://example.org/s> <http://example.org/p> \"hello\"@en .\n"
        )
        t = only(g)
        @test t.object isa Literal
        @test t.object.lexical_form == "hello"
        @test t.object.language_tag == "en"
        @test t.object.datatype == rdf.langString
    end

    @testset "N-Triples parsing — blank node subject and object" begin
        g = parse_graph(
            "_:b0 <http://example.org/p> _:b1 .\n"
        )
        t = only(g)
        @test t.subject isa BlankNode
        @test t.object isa BlankNode
        @test t.subject != t.object
    end

    @testset "N-Triples parsing — same blank node identifier in multiple triples" begin
        nt = """
        _:b0 <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://example.org/Person> .
        _:b0 <http://example.org/name> "Alice" .
        """
        g = parse_graph(nt)
        @test length(g) == 2
        # Both triples have the same subject blank node
        subjects = [t.subject for t in g]
        @test subjects[1] == subjects[2]
    end

    @testset "N-Triples parsing — comments are ignored" begin
        nt = """
        # This is a comment
        <http://example.org/s> <http://example.org/p> <http://example.org/o> .
        # Another comment
        """
        g = parse_graph(nt)
        @test length(g) == 1
    end

    @testset "N-Triples parsing — whitespace variants" begin
        # Multiple spaces between components
        g = parse_graph(
            "<http://example.org/s>  <http://example.org/p>  <http://example.org/o> .\n"
        )
        @test length(g) == 1

        # Tab-separated
        g = parse_graph(
            "<http://example.org/s>\t<http://example.org/p>\t<http://example.org/o> .\n"
        )
        @test length(g) == 1
    end

    @testset "N-Triples parsing — escape sequences in literals" begin
        g = parse_graph(
            "<http://example.org/s> <http://example.org/p> \"say \\\"hello\\\"\" .\n"
        )
        t = only(g)
        @test t.object.lexical_form == "say \"hello\""

        g = parse_graph(
            "<http://example.org/s> <http://example.org/p> \"line1\\nline2\" .\n"
        )
        t = only(g)
        @test t.object.lexical_form == "line1\nline2"

        g = parse_graph(
            "<http://example.org/s> <http://example.org/p> \"back\\\\slash\" .\n"
        )
        t = only(g)
        @test t.object.lexical_form == "back\\slash"
    end

    @testset "N-Triples parsing — unicode escapes" begin
        # \\uXXXX
        g = parse_graph(
            "<http://example.org/s> <http://example.org/p> \"caf\\u00E9\" .\n"
        )
        t = only(g)
        @test t.object.lexical_form == "café"

        # \\UXXXXXXXX
        g = parse_graph(
            "<http://example.org/s> <http://example.org/p> \"\\U0001F600\" .\n"
        )
        t = only(g)
        @test t.object.lexical_form == "😀"
    end

    @testset "N-Triples parsing — ill-typed literals accepted" begin
        g = parse_graph(
            "<http://example.org/s> <http://example.org/p> " *
            "\"notanumber\"^^<http://www.w3.org/2001/XMLSchema#integer> .\n"
        )
        @test length(g) == 1
        t = only(g)
        @test t.object.lexical_form == "notanumber"
        @test t.object.datatype == xsd.integer
    end

    @testset "N-Triples parsing — ParseError on malformed input" begin
        # Missing dot
        @test_throws ParseError parse_graph(
            "<http://example.org/s> <http://example.org/p> <http://example.org/o>\n"
        )

        # Missing object
        @test_throws ParseError parse_graph(
            "<http://example.org/s> <http://example.org/p> .\n"
        )

        # Relative IRI as subject
        @test_throws ParseError parse_graph(
            "<relative> <http://example.org/p> <http://example.org/o> .\n"
        )

        # Literal as subject (not valid in N-Triples)
        @test_throws ParseError parse_graph(
            "\"hello\" <http://example.org/p> <http://example.org/o> .\n"
        )

        # Literal as predicate
        @test_throws ParseError parse_graph(
            "<http://example.org/s> \"pred\" <http://example.org/o> .\n"
        )

        # Unclosed IRI
        @test_throws ParseError parse_graph(
            "<http://example.org/s <http://example.org/p> <http://example.org/o> .\n"
        )

        # Unclosed literal
        @test_throws ParseError parse_graph(
            "<http://example.org/s> <http://example.org/p> \"unclosed .\n"
        )
    end

    # ----------------------------------------------------------------
    # Round-trip
    # ----------------------------------------------------------------

    @testset "N-Triples round-trip — IRI graph" begin
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        push!(g, Triple(ex.alice, ex.name, Literal("Alice")))
        push!(g, Triple(ex.alice, ex.age, Literal(30)))

        g2 = roundtrip_graph(g)
        @test g ≅ g2
    end

    @testset "N-Triples round-trip — blank nodes" begin
        g = Graph()
        b = blank!(g)
        push!(g, Triple(b, rdf.type, ex.Person))
        push!(g, Triple(b, ex.name, Literal("Unknown")))
        push!(g, Triple(ex.alice, ex.knows, b))

        g2 = roundtrip_graph(g)
        @test g ≅ g2
    end

    @testset "N-Triples round-trip — language-tagged strings" begin
        g = Graph()
        push!(g, Triple(ex.s, ex.p, Literal("hello"; lang="en")))
        push!(g, Triple(ex.s, ex.p, Literal("hola";  lang="es")))

        g2 = roundtrip_graph(g)
        @test g ≅ g2
    end

    # ----------------------------------------------------------------
    # N-Quads
    # ----------------------------------------------------------------

    @testset "N-Quads — serialization includes graph name" begin
        ds = Dataset()
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        ds[IRI("http://example.org/graph1")] = g

        s = serialize_dataset(ds)
        @test contains(s, "<http://example.org/alice>")
        @test contains(s, "<http://example.org/graph1>")
    end

    @testset "N-Quads — default graph triples have no graph component" begin
        ds = Dataset()
        push!(ds.default_graph, Triple(ex.alice, rdf.type, ex.Person))

        s = serialize_dataset(ds)
        lines = filter(!isempty, split(s, '\n'))
        @test length(lines) == 1
        # Default graph line has exactly 4 space-separated components ending in .
        # (no graph name before the .)
        parts = split(strip(lines[1]))
        @test last(parts) == "."
    end

    @testset "N-Quads — blank node graph name" begin
        ds = Dataset()
        b = blank!(ds)
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        ds[b] = g

        s = serialize_dataset(ds)
        @test contains(s, "_:")
    end

    @testset "N-Quads parsing — basic quad" begin
        nq = "<http://example.org/s> <http://example.org/p> <http://example.org/o> <http://example.org/g> .\n"
        ds = parse_dataset(nq)
        gname = IRI("http://example.org/g")
        @test haskey(ds, gname)
        @test Triple(
            IRI("http://example.org/s"),
            IRI("http://example.org/p"),
            IRI("http://example.org/o")
        ) in ds[gname]
    end

    @testset "N-Quads parsing — triple in default graph (no graph component)" begin
        nq = "<http://example.org/s> <http://example.org/p> <http://example.org/o> .\n"
        ds = parse_dataset(nq)
        @test Triple(
            IRI("http://example.org/s"),
            IRI("http://example.org/p"),
            IRI("http://example.org/o")
        ) in ds.default_graph
    end

    @testset "N-Quads round-trip" begin
        ds = Dataset()
        g1 = Graph()
        push!(g1, Triple(ex.alice, rdf.type, ex.Person))
        push!(g1, Triple(ex.alice, ex.name, Literal("Alice")))
        ds[IRI("http://example.org/g1")] = g1

        g2 = Graph()
        push!(g2, Triple(ex.bob, rdf.type, ex.Person))
        ds[IRI("http://example.org/g2")] = g2

        push!(ds.default_graph, Triple(ex.carol, rdf.type, ex.Employee))

        ds2 = roundtrip_dataset(ds)
        @test ntriples(ds) == ntriples(ds2)
        @test ds ≅ ds2
    end

    # ----------------------------------------------------------------
    # Streaming parser
    # ----------------------------------------------------------------

    @testset "Streaming parser — callback form" begin
        nt = """
        <http://example.org/alice> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://example.org/Person> .
        <http://example.org/bob> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://example.org/Person> .
        <http://example.org/carol> <http://example.org/name> "Carol" .
        """
        triples = Triple[]
        parse_triples(IOBuffer(nt), MIME"application/n-triples"()) do t
            push!(triples, t)
        end
        @test length(triples) == 3
    end

    @testset "Streaming parser — iterator form" begin
        nt = """
        <http://example.org/alice> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://example.org/Person> .
        <http://example.org/bob> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://example.org/Person> .
        """
        iter = parse_triples(IOBuffer(nt), MIME"application/n-triples"())
        triples = collect(iter)
        @test length(triples) == 2
        @test all(t isa Triple for t in triples)
    end

    @testset "Streaming parser — large input does not require full materialization" begin
        # Build a large N-Triples string
        buf = IOBuffer()
        for i in 1:10_000
            write(buf, "<http://example.org/s$i> <http://example.org/p> <http://example.org/o> .\n")
        end
        seekstart(buf)

        count = 0
        for _ in parse_triples(buf, MIME"application/n-triples"())
            count += 1
        end
        @test count == 10_000
    end

    # ----------------------------------------------------------------
    # File extension detection
    # ----------------------------------------------------------------

    @testset "File extension detection" begin
        mktempdir() do dir
            # Write N-Triples
            g = Graph()
            push!(g, Triple(ex.alice, rdf.type, ex.Person))

            path_nt = joinpath(dir, "test.nt")
            write(path_nt, g)
            g2 = read(path_nt, Graph)
            @test g ≅ g2

            # Write N-Quads
            ds = Dataset()
            push!(ds.default_graph, Triple(ex.alice, rdf.type, ex.Person))

            path_nq = joinpath(dir, "test.nq")
            write(path_nq, ds)
            ds2 = read(path_nq, Dataset)
            @test ntriples(ds) == ntriples(ds2)
        end
    end

end
