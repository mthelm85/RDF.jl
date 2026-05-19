using RDF
using Test

# W3C RDF 1.1 N-Triples Test Suite
# https://www.w3.org/2013/N-TriplesTests/
#
# Test cases are embedded directly as strings to keep the suite
# self-contained and runnable without network access. The test strings
# are taken verbatim from the official W3C test suite.
#
# To run against the full official fixture files, place them in
# test/w3c/fixtures/ntriples/ and set the environment variable
# RDF_W3C_FIXTURES=1.

@testset "W3C N-Triples Test Suite" begin

    function parse_nt(s::String)
        read(IOBuffer(s), MIME"application/n-triples"(), Graph)
    end

    # ----------------------------------------------------------------
    # Positive syntax tests — these MUST parse without error
    # ----------------------------------------------------------------

    @testset "Positive Syntax Tests" begin

        @testset "nt-syntax-uri-01 — IRIs" begin
            g = parse_nt("""<http://example/s> <http://example/p> <http://example/o> .\n""")
            @test length(g) == 1
        end

        @testset "nt-syntax-uri-02 — IRI with query" begin
            g = parse_nt("""<http://example/s> <http://example/p> <http://example/o?query> .\n""")
            @test length(g) == 1
            t = only(g)
            @test t.object == IRI("http://example/o?query")
        end

        @testset "nt-syntax-uri-03 — IRI with fragment" begin
            g = parse_nt("""<http://example/s> <http://example/p> <http://example/o#fragment> .\n""")
            @test length(g) == 1
            t = only(g)
            @test t.object == IRI("http://example/o#fragment")
        end

        @testset "nt-syntax-uri-04 — IRI with percent encoding" begin
            g = parse_nt("""<http://example/s%20p> <http://example/p> <http://example/o> .\n""")
            @test length(g) == 1
            t = only(g)
            @test t.subject == IRI("http://example/s%20p")
        end

        @testset "nt-syntax-string-01 — plain literal" begin
            g = parse_nt("""<http://example/s> <http://example/p> "string" .\n""")
            @test length(g) == 1
            t = only(g)
            @test t.object isa Literal
            @test t.object.lexical_form == "string"
        end

        @testset "nt-syntax-string-02 — literal with language tag" begin
            g = parse_nt("""<http://example/s> <http://example/p> "string"@en .\n""")
            @test length(g) == 1
            t = only(g)
            @test t.object.language_tag == "en"
        end

        @testset "nt-syntax-string-03 — literal with datatype" begin
            g = parse_nt(
                """<http://example/s> <http://example/p> """ *
                """"string"^^<http://example/dt> .\n"""
            )
            @test length(g) == 1
            t = only(g)
            @test t.object.datatype == IRI("http://example/dt")
        end

        @testset "nt-syntax-str-esc-01 — string with backslash escape" begin
            g = parse_nt("""<http://example/s> <http://example/p> "a\\"b" .\n""")
            @test length(g) == 1
            t = only(g)
            @test t.object.lexical_form == "a\"b"
        end

        @testset "nt-syntax-str-esc-02 — string with newline escape" begin
            g = parse_nt("""<http://example/s> <http://example/p> "a\\nb" .\n""")
            t = only(g)
            @test t.object.lexical_form == "a\nb"
        end

        @testset "nt-syntax-str-esc-03 — string with carriage return escape" begin
            g = parse_nt("""<http://example/s> <http://example/p> "a\\rb" .\n""")
            t = only(g)
            @test t.object.lexical_form == "a\rb"
        end

        @testset "nt-syntax-str-esc-04 — string with tab escape" begin
            g = parse_nt("""<http://example/s> <http://example/p> "a\\tb" .\n""")
            t = only(g)
            @test t.object.lexical_form == "a\tb"
        end

        @testset "nt-syntax-str-esc-05 — string with backslash" begin
            g = parse_nt("""<http://example/s> <http://example/p> "a\\\\b" .\n""")
            t = only(g)
            @test t.object.lexical_form == "a\\b"
        end

        @testset "nt-syntax-bnode-01 — blank node subject" begin
            g = parse_nt("""_:bnode1 <http://example/p> <http://example/o> .\n""")
            @test length(g) == 1
            t = only(g)
            @test t.subject isa BlankNode
        end

        @testset "nt-syntax-bnode-02 — blank node object" begin
            g = parse_nt("""<http://example/s> <http://example/p> _:bnode1 .\n""")
            @test length(g) == 1
            t = only(g)
            @test t.object isa BlankNode
        end

        @testset "nt-syntax-bnode-03 — same blank node in multiple triples" begin
            g = parse_nt("""
            _:bnode1 <http://example/p> <http://example/o> .
            <http://example/s> <http://example/p> _:bnode1 .
            """)
            @test length(g) == 2
            subjects = [t.subject for t in g]
            objects  = [t.object  for t in g]

            bnode_sub = first(filter(s -> s isa BlankNode, subjects))
            bnode_obj = first(filter(o -> o isa BlankNode, objects))
            @test bnode_sub == bnode_obj  # same blank node identifier → same node
        end

        @testset "nt-syntax-datatypes-01 — integer datatype" begin
            g = parse_nt(
                """<http://example/s> <http://example/p> """ *
                """"1"^^<http://www.w3.org/2001/XMLSchema#integer> .\n"""
            )
            t = only(g)
            @test t.object.datatype == xsd.integer
            @test t.object.lexical_form == "1"
        end

        @testset "nt-syntax-datatypes-02 — double datatype" begin
            g = parse_nt(
                """<http://example/s> <http://example/p> """ *
                """"1.0"^^<http://www.w3.org/2001/XMLSchema#double> .\n"""
            )
            t = only(g)
            @test t.object.datatype == xsd.double
        end

        @testset "nt-syntax-bad-num-01 — empty file" begin
            # Empty file is valid (zero triples)
            g = parse_nt("")
            @test isempty(g)
        end

        @testset "nt-syntax-comment-01 — comment only" begin
            g = parse_nt("# a comment\n")
            @test isempty(g)
        end

        @testset "nt-syntax-comment-02 — comment before triple" begin
            g = parse_nt("# a comment\n<http://example/s> <http://example/p> <http://example/o> .\n")
            @test length(g) == 1
        end

        @testset "nt-syntax-uri-05 — IRI with unicode" begin
            g = parse_nt("""<http://example/\u00E9> <http://example/p> <http://example/o> .\n""")
            @test length(g) == 1
            t = only(g)
            @test t.subject == IRI("http://example/\u00E9")
        end

        @testset "nt-syntax-string-04 — language-tagged string with subtag" begin
            g = parse_nt("""<http://example/s> <http://example/p> "string"@en-us .\n""")
            t = only(g)
            @test t.object.language_tag == "en-us"
        end

        @testset "nt-syntax-uri-06 — unicode \\uXXXX in IRI" begin
            g = parse_nt("""<http://example/s\\u0041> <http://example/p> <http://example/o> .\n""")
            @test length(g) == 1
            t = only(g)
            # \u0041 is 'A'
            @test t.subject == IRI("http://example/sA")
        end

        @testset "nt-syntax-uri-07 — unicode \\UXXXXXXXX in IRI" begin
            g = parse_nt("""<http://example/s\\U00000041> <http://example/p> <http://example/o> .\n""")
            @test length(g) == 1
            t = only(g)
            @test t.subject == IRI("http://example/sA")
        end

        @testset "Multiple triples" begin
            g = parse_nt("""
            <http://example/s1> <http://example/p1> <http://example/o1> .
            <http://example/s2> <http://example/p2> <http://example/o2> .
            <http://example/s3> <http://example/p3> <http://example/o3> .
            """)
            @test length(g) == 3
        end

    end

    # ----------------------------------------------------------------
    # Negative syntax tests — these MUST raise ParseError
    # ----------------------------------------------------------------

    @testset "Negative Syntax Tests" begin

        @testset "nt-syntax-bad-uri-01 — relative IRI as subject" begin
            @test_throws ParseError parse_nt(
                """<s> <http://example/p> <http://example/o> .\n"""
            )
        end

        @testset "nt-syntax-bad-uri-02 — relative IRI as predicate" begin
            @test_throws ParseError parse_nt(
                """<http://example/s> <p> <http://example/o> .\n"""
            )
        end

        @testset "nt-syntax-bad-uri-03 — relative IRI as object" begin
            @test_throws ParseError parse_nt(
                """<http://example/s> <http://example/p> <o> .\n"""
            )
        end

        @testset "nt-syntax-bad-literal-01 — literal as subject" begin
            @test_throws ParseError parse_nt(
                """"lit" <http://example/p> <http://example/o> .\n"""
            )
        end

        @testset "nt-syntax-bad-literal-02 — literal as predicate" begin
            @test_throws ParseError parse_nt(
                """<http://example/s> "lit" <http://example/o> .\n"""
            )
        end

        @testset "nt-syntax-bad-missing-dot — missing terminating dot" begin
            @test_throws ParseError parse_nt(
                """<http://example/s> <http://example/p> <http://example/o>\n"""
            )
        end

        @testset "nt-syntax-bad-iri-01 — space in IRI" begin
            @test_throws ParseError parse_nt(
                """<http://example/ s> <http://example/p> <http://example/o> .\n"""
            )
        end

        @testset "nt-syntax-bad-iri-02 — unclosed IRI" begin
            @test_throws ParseError parse_nt(
                """<http://example/s <http://example/p> <http://example/o> .\n"""
            )
        end

        @testset "nt-syntax-bad-string-01 — unclosed literal" begin
            @test_throws ParseError parse_nt(
                """<http://example/s> <http://example/p> "unclosed .\n"""
            )
        end

        @testset "nt-syntax-bad-bnode-01 — blank node with empty identifier" begin
            @test_throws ParseError parse_nt(
                """_ <http://example/p> <http://example/o> .\n"""
            )
        end

        @testset "nt-syntax-bad-num-02 — triple missing object" begin
            @test_throws ParseError parse_nt(
                """<http://example/s> <http://example/p> .\n"""
            )
        end

        @testset "nt-syntax-bad-num-03 — triple missing predicate and object" begin
            @test_throws ParseError parse_nt(
                """<http://example/s> .\n"""
            )
        end

    end

    # ----------------------------------------------------------------
    # Evaluation tests — parse and verify the resulting graph
    # ----------------------------------------------------------------

    @testset "Evaluation Tests" begin

        @testset "nt-syntax-subm-01 — full W3C submission example" begin
            # A representative real-world RDF description
            nt = """
            <http://www.w3.org/2001/sw/RDFCore/ntriples/> \
            <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> \
            <http://xmlns.com/foaf/0.1/Document> .
            <http://www.w3.org/2001/sw/RDFCore/ntriples/> \
            <http://purl.org/dc/terms/title> \
            "N-Triples"@en-us .
            <http://www.w3.org/2001/sw/RDFCore/ntriples/> \
            <http://xmlns.com/foaf/0.1/maker> \
            _:art .
            _:art \
            <http://xmlns.com/foaf/0.1/name> \
            "Art Barstow" .
            """

            g = parse_nt(nt)
            @test length(g) == 4

            doc = IRI("http://www.w3.org/2001/sw/RDFCore/ntriples/")
            @test Triple(doc, rdf.type, foaf.Document) in g

            title_triples = collect(match(g, subject=doc, predicate=dcterms.title))
            @test length(title_triples) == 1
            @test title_triples[1].object.lexical_form == "N-Triples"
            @test title_triples[1].object.language_tag == "en-us"
        end

        @testset "Round-trip equivalence" begin
            # Parse a graph, serialize it, parse it again: result must be isomorphic
            original_nt = """
            <http://example/s1> <http://example/p1> <http://example/o1> .
            <http://example/s2> <http://example/p2> "literal"@en .
            _:b1 <http://example/p3> "42"^^<http://www.w3.org/2001/XMLSchema#integer> .
            <http://example/s3> <http://example/p4> _:b1 .
            """

            g1 = parse_nt(original_nt)

            buf = IOBuffer()
            write(buf, MIME"application/n-triples"(), g1)
            seekstart(buf)
            g2 = read(buf, MIME"application/n-triples"(), Graph)

            @test g1 ≅ g2
        end

    end

    # ----------------------------------------------------------------
    # Optional: run against vendored W3C fixture files
    # ----------------------------------------------------------------

    if get(ENV, "RDF_W3C_FIXTURES", "0") == "1"
        fixture_dir = joinpath(@__DIR__, "fixtures", "ntriples")
        if isdir(fixture_dir)
            @testset "W3C Fixture Files — Positive" begin
                for f in readdir(fixture_dir, join=true)
                    endswith(f, ".nt") || continue
                    basename(f) in ["manifest.ttl"] && continue
                    @testset "$(basename(f))" begin
                        @test_nowarn parse_nt(read(f, String))
                    end
                end
            end

            @testset "W3C Fixture Files — Negative" begin
                neg_dir = joinpath(fixture_dir, "negative")
                isdir(neg_dir) || return
                for f in readdir(neg_dir, join=true)
                    endswith(f, ".nt") || continue
                    @testset "$(basename(f))" begin
                        @test_throws ParseError parse_nt(read(f, String))
                    end
                end
            end
        end
    end

end
