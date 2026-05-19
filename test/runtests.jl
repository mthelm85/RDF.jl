using RDF
using Test
using Aqua
using JET

@testset "RDF.jl" begin
    @testset "Code quality (Aqua.jl)" begin
        Aqua.test_all(RDF; ambiguities = false,)
    end
    @testset "Code linting (JET.jl)" begin
        JET.test_package(RDF; target_defined_modules = true)
    end
    # Write your tests here.
end
