using RDF
using Test

@testset "IRIs" begin

    @testset "Construction" begin
        # Basic valid IRIs
        @test IRI("http://example.org/") isa IRI
        @test IRI("http://example.org/alice") isa IRI
        @test IRI("https://schema.org/Person") isa IRI
        @test IRI("urn:isbn:0451450523") isa IRI
        @test IRI("ftp://ftp.example.org/file") isa IRI

        # Fragment identifiers are allowed (spec §3.2)
        @test IRI("http://example.org/vocab#type") isa IRI
        @test IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type") isa IRI

        # Unicode characters in IRIs (RFC 3987 — IRIs extend URIs)
        @test IRI("http://example.org/\u00e9l\u00e8ve") isa IRI

        # Query strings
        @test IRI("http://example.org/search?q=rdf") isa IRI

        # Deeply nested paths
        @test IRI("http://example.org/a/b/c/d/e") isa IRI
    end

    @testset "String macro" begin
        @test iri"http://example.org/" isa IRI
        @test iri"http://example.org/" == IRI("http://example.org/")
        @test iri"http://www.w3.org/1999/02/22-rdf-syntax-ns#type" ==
              IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    end

    @testset "Validation — invalid IRIs raise IRIError" begin
        # Relative IRIs are not allowed in the abstract syntax (spec §3.2 MUST)
        @test_throws IRIError IRI("relative/path")
        @test_throws IRIError IRI("../relative")
        @test_throws IRIError IRI("/absolute/path")
        @test_throws IRIError IRI("")

        # No scheme
        @test_throws IRIError IRI("example.org/path")

        # Spaces are not valid in IRIs without percent-encoding
        @test_throws IRIError IRI("http://example.org/has space")
    end

    @testset "Validation — characters forbidden in an IRIREF raise IRIError" begin
        # RFC 3986 §2 admits only unreserved / gen-delims / sub-delims /
        # pct-encoded, and RFC 3987 adds only the non-ASCII ucschar ranges, so
        # none of these may appear in an IRI unencoded.  They are also exactly
        # the characters the Turtle / N-Triples IRIREF production excludes, so
        # rejecting them here is what makes every IRI a graph can hold both
        # serialisable and re-parseable.
        for c in ('<', '>', '"', '{', '}', '|', '^', '`', '\\')
            @test_throws IRIError IRI(string("http://example.org/a", c, "b"))
        end

        # Control characters are excluded as the range #x00-#x20.
        for c in ('\0', '\a', '\t', '\n', '\r', '\x1f')
            @test_throws IRIError IRI(string("http://example.org/a", c, "b"))
        end

        # Anywhere in the IRI, not only mid-path.
        @test_throws IRIError IRI("http://example.org/trailing>")
        @test_throws IRIError IRI("http://exa|mple.org/")
        @test_throws IRIError IRI("http://example.org/<")
    end

    @testset "Validation — legal IRI characters are still accepted" begin
        # Guards against over-rejecting: each of these is inside the IRIREF
        # production and must keep working.
        for v in ("http://example.org/a[b]c",
                  "http://example.org/a%20b",
                  "http://example.org/a#frag",
                  "http://example.org/a?q=1&r=2",
                  "http://example.org/a!\$&'()*+,;=:@",
                  "http://example.org/a~b-c_d.e",
                  "http://example.org/日本語",
                  "urn:uuid:0c2e5f7a-1f3c-4a1e-9b6d-2f1a3b4c5d6e")
            @test IRI(v).value == v
        end

        # DEL is outside #x00-#x20 and the IRIREF production does not exclude
        # it, so it stays constructible — and therefore round-trippable.
        @test IRI("http://example.org/a\x7fb") isa IRI
    end

    @testset "Equality — simple string comparison, no normalization (spec §3.2)" begin
        @test IRI("http://example.org/") == IRI("http://example.org/")
        @test IRI("http://example.org/alice") == IRI("http://example.org/alice")

        # Case sensitivity: different strings are different IRIs
        # The spec MUST NOT normalize for equality
        @test IRI("http://example.org/Alice") != IRI("http://example.org/alice")
        @test IRI("HTTP://example.org/") != IRI("http://example.org/")
        @test IRI("http://EXAMPLE.ORG/") != IRI("http://example.org/")

        # Trailing slash is significant
        @test IRI("http://example.org") != IRI("http://example.org/")

        # Percent-encoding is not normalized
        @test IRI("http://example.org/%2F") != IRI("http://example.org//")

        # Port number not collapsed
        @test IRI("http://example.org:80/") != IRI("http://example.org/")

        # Explicit default port is a different string
        @test IRI("http://example.org:80/") != IRI("http://example.org/")
    end

    @testset "Hashing — consistent with equality" begin
        a = IRI("http://example.org/alice")
        b = IRI("http://example.org/alice")
        c = IRI("http://example.org/bob")

        @test hash(a) == hash(b)
        @test hash(a) != hash(c)  # with very high probability

        # Can be used as Dict keys
        d = Dict{IRI, Int}()
        d[a] = 1
        @test d[b] == 1  # same IRI, same key

        # Can be stored in Sets
        s = Set{IRI}([a, b, c])
        @test length(s) == 2  # a and b are the same
    end

    @testset "IRI is a valid RDF term" begin
        @test IRI("http://example.org/") isa RDFTerm
        @test IRI("http://example.org/") isa SubjectTerm
        @test IRI("http://example.org/") isa ObjectTerm
    end

    @testset "String access" begin
        iri = IRI("http://example.org/alice")
        @test string(iri) == "http://example.org/alice"
        @test iri.value == "http://example.org/alice"
    end

    @testset "Display" begin
        iri = IRI("http://example.org/alice")
        @test repr(iri) == "<http://example.org/alice>"

        # Fragment IRI
        iri2 = IRI("http://example.org/vocab#Person")
        @test repr(iri2) == "<http://example.org/vocab#Person>"
    end

end
