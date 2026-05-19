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
