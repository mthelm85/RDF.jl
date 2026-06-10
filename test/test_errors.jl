# Error types are tested in test_validation.jl alongside validation tests.
# This file is intentionally minimal — it exists as a placeholder so the
# runtests.jl include list is self-documenting.
using RDF
using Test

@testset "Errors (see also test_validation.jl)" begin
    # All error type hierarchy tests live in test_validation.jl.
    # This testset verifies the errors module is loaded correctly.
    @test isdefined(RDF, :RDFError)
    @test isdefined(RDF, :IRIError)
    @test isdefined(RDF, :ParseError)
    @test isdefined(RDF, :LiteralValueError)
    @test isdefined(RDF, :BlankNodeScopeError)
    @test isdefined(RDF, :RemoteEndpointError)

    @testset "RemoteEndpointError" begin
        @test RemoteEndpointError <: RDFError
        err = RemoteEndpointError("https://endpoint.example/sparql", "boom")
        msg = sprint(showerror, err)
        @test occursin("boom", msg)
        @test occursin("endpoint.example", msg)
    end

    @testset "sparql / sparql_update! reject the wrong statement kind" begin
        g  = Graph()
        ds = Dataset()
        # A query handed to sparql_update!, and an update handed to sparql,
        # are caller mistakes → typed ArgumentError, not a bare ErrorException.
        @test_throws ArgumentError sparql(g,
            "INSERT DATA { <http://e.example/s> <http://e.example/p> 1 }")
        @test_throws ArgumentError sparql_update!(ds,
            "SELECT ?s WHERE { ?s ?p ?o }")
    end
end
