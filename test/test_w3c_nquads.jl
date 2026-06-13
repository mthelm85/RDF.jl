using RDF
using Test

# W3C RDF 1.1 N-Quads Test Suite
# https://www.w3.org/2013/N-QuadsTests/

@testset "W3C N-Quads Test Suite" begin

    function parse_nq(s::String)
        read(IOBuffer(s), MIME"application/n-quads"(), Dataset)
    end

    # ----------------------------------------------------------------
    # Positive syntax tests
    # ----------------------------------------------------------------

    @testset "Positive Syntax Tests" begin

        @testset "nq-syntax-uri-01 — quad with IRI graph name" begin
            ds = parse_nq(
                "<http://example/s> <http://example/p> <http://example/o> " *
                "<http://example/g> .\n"
            )
            g_name = IRI("http://example/g")
            @test haskey(ds, g_name)
            @test length(ds[g_name]) == 1
        end

        @testset "nq-syntax-uri-02 — multiple quads, same graph" begin
            ds = parse_nq("""
            <http://example/s1> <http://example/p1> <http://example/o1> <http://example/g> .
            <http://example/s2> <http://example/p2> <http://example/o2> <http://example/g> .
            """)
            g_name = IRI("http://example/g")
            @test haskey(ds, g_name)
            @test length(ds[g_name]) == 2
        end

        @testset "nq-syntax-uri-03 — multiple quads, multiple graphs" begin
            ds = parse_nq("""
            <http://example/s1> <http://example/p1> <http://example/o1> <http://example/g1> .
            <http://example/s2> <http://example/p2> <http://example/o2> <http://example/g2> .
            """)
            @test haskey(ds, IRI("http://example/g1"))
            @test haskey(ds, IRI("http://example/g2"))
            @test length(ds) == 2
        end

        @testset "nq-syntax-uri-04 — triple in default graph (no graph component)" begin
            ds = parse_nq(
                "<http://example/s> <http://example/p> <http://example/o> .\n"
            )
            @test !isempty(ds.default_graph)
            @test Triple(
                IRI("http://example/s"),
                IRI("http://example/p"),
                IRI("http://example/o")
            ) in ds.default_graph
        end

        @testset "nq-syntax-bnode-01 — blank node subject in quad" begin
            ds = parse_nq(
                "_:b1 <http://example/p> <http://example/o> <http://example/g> .\n"
            )
            g_name = IRI("http://example/g")
            @test haskey(ds, g_name)
            t = only(ds[g_name])
            @test t.subject isa BlankNode
        end

        @testset "nq-syntax-bnode-02 — blank node as graph name" begin
            ds = parse_nq(
                "<http://example/s> <http://example/p> <http://example/o> _:g .\n"
            )
            @test length(ds) == 1
            graph_name = only(keys(ds))
            @test graph_name isa BlankNode
        end

        @testset "nq-syntax-bnode-03 — blank node shared across quads in same graph" begin
            ds = parse_nq("""
            _:b1 <http://example/p1> <http://example/o1> <http://example/g> .
            <http://example/s> <http://example/p2> _:b1 <http://example/g> .
            """)
            g = ds[IRI("http://example/g")]
            @test length(g) == 2

            subjects = [t.subject for t in g]
            objects  = [t.object  for t in g]
            bnode_sub = first(filter(s -> s isa BlankNode, subjects))
            bnode_obj = first(filter(o -> o isa BlankNode, objects))
            @test bnode_sub == bnode_obj
        end

        @testset "nq-syntax-literal-01 — typed literal in quad" begin
            ds = parse_nq(
                "<http://example/s> <http://example/p> " *
                "\"42\"^^<http://www.w3.org/2001/XMLSchema#integer> " *
                "<http://example/g> .\n"
            )
            g = ds[IRI("http://example/g")]
            t = only(g)
            @test t.object.datatype == xsd.integer
            @test t.object.lexical_form == "42"
        end

        @testset "nq-syntax-literal-02 — language-tagged literal in quad" begin
            ds = parse_nq(
                "<http://example/s> <http://example/p> \"hello\"@en " *
                "<http://example/g> .\n"
            )
            g = ds[IRI("http://example/g")]
            t = only(g)
            @test t.object.language_tag == "en"
        end

        @testset "nq-syntax-comment-01 — comment in N-Quads file" begin
            ds = parse_nq("""
            # a comment
            <http://example/s> <http://example/p> <http://example/o> <http://example/g> .
            """)
            @test ntriples(ds) == 1
        end

        @testset "nq-syntax-empty — empty N-Quads file" begin
            ds = parse_nq("")
            @test ntriples(ds) == 0
        end

        @testset "nq-syntax-mixed — default graph and named graph" begin
            ds = parse_nq("""
            <http://example/s1> <http://example/p1> <http://example/o1> .
            <http://example/s2> <http://example/p2> <http://example/o2> <http://example/g> .
            """)
            @test !isempty(ds.default_graph)
            @test haskey(ds, IRI("http://example/g"))
            @test ntriples(ds) == 2
        end

    end

    # ----------------------------------------------------------------
    # Negative syntax tests
    # ----------------------------------------------------------------

    @testset "Negative Syntax Tests" begin

        @testset "nq-syntax-bad-01 — relative IRI as subject" begin
            @test_throws ParseError parse_nq(
                "<s> <http://example/p> <http://example/o> <http://example/g> .\n"
            )
        end

        @testset "nq-syntax-bad-02 — relative IRI as graph name" begin
            @test_throws ParseError parse_nq(
                "<http://example/s> <http://example/p> <http://example/o> <g> .\n"
            )
        end

        @testset "nq-syntax-bad-03 — literal as subject" begin
            @test_throws ParseError parse_nq(
                "\"lit\" <http://example/p> <http://example/o> <http://example/g> .\n"
            )
        end

        @testset "nq-syntax-bad-04 — literal as predicate" begin
            @test_throws ParseError parse_nq(
                "<http://example/s> \"lit\" <http://example/o> <http://example/g> .\n"
            )
        end

        @testset "nq-syntax-bad-05 — literal as graph name" begin
            @test_throws ParseError parse_nq(
                "<http://example/s> <http://example/p> <http://example/o> \"g\" .\n"
            )
        end

        @testset "nq-syntax-bad-06 — missing dot" begin
            @test_throws ParseError parse_nq(
                "<http://example/s> <http://example/p> <http://example/o> <http://example/g>\n"
            )
        end

        @testset "nq-syntax-bad-07 — five components" begin
            @test_throws ParseError parse_nq(
                "<http://example/s> <http://example/p> <http://example/o> " *
                "<http://example/g> <http://example/extra> .\n"
            )
        end

    end

    # ----------------------------------------------------------------
    # Evaluation tests
    # ----------------------------------------------------------------

    @testset "Evaluation Tests" begin

        @testset "Round-trip equivalence" begin
            original_nq = """
            <http://example/s1> <http://example/p1> <http://example/o1> <http://example/g1> .
            <http://example/s2> <http://example/p2> "hello"@en <http://example/g1> .
            _:b1 <http://example/p3> <http://example/o3> <http://example/g2> .
            <http://example/s4> <http://example/p4> <http://example/o4> .
            """

            ds1 = parse_nq(original_nq)

            buf = IOBuffer()
            write(buf, MIME"application/n-quads"(), ds1)
            seekstart(buf)
            ds2 = read(buf, MIME"application/n-quads"(), Dataset)

            @test ntriples(ds1) == ntriples(ds2)
            @test ds1 ≅ ds2
        end

        @testset "Blank nodes in N-Triples vs N-Quads scope" begin
            # The same blank node label in different serialization contexts
            # refers to different blank nodes in the abstract syntax
            nt = "_:b0 <http://example/p> <http://example/o> .\n"
            nq = "_:b0 <http://example/p> <http://example/o> <http://example/g> .\n"

            g  = read(IOBuffer(nt), MIME"application/n-triples"(), Graph)
            ds = read(IOBuffer(nq), MIME"application/n-quads"(), Dataset)

            # The blank node from the N-Triples parse is distinct from
            # the one in the N-Quads parse
            bnode_nt = only(subjects(g))
            bnode_nq = only(subjects(ds[IRI("http://example/g")]))

            @test bnode_nt isa BlankNode
            @test bnode_nq isa BlankNode
            @test bnode_nt != bnode_nq
        end

        @testset "Graph isolation — triples in different graphs are independent" begin
            ds = parse_nq("""
            <http://example/alice> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> \
            <http://example/Person> <http://example/g1> .
            <http://example/alice> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> \
            <http://example/Employee> <http://example/g2> .
            """)

            g1 = ds[IRI("http://example/g1")]
            g2 = ds[IRI("http://example/g2")]

            @test length(g1) == 1
            @test length(g2) == 1

            alice = IRI("http://example/alice")
            @test Triple(alice, rdf.type, IRI("http://example/Person"))   in g1
            @test Triple(alice, rdf.type, IRI("http://example/Employee")) in g2
            @test Triple(alice, rdf.type, IRI("http://example/Employee")) ∉ g1
            @test Triple(alice, rdf.type, IRI("http://example/Person"))   ∉ g2
        end

    end

    # NOTE: the vendored W3C N-Quads fixture files are exercised
    # unconditionally by test/w3c/w3c_tests.jl (positive + negative syntax,
    # RDF 1.1 and 1.2).  A previous env-gated block here pointed at a fixture
    # path that never existed and silently ran zero tests; it was removed.

end
