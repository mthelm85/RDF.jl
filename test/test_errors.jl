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
end
