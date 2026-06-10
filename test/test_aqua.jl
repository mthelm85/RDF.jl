using Test
using Aqua
using RDF

@testset "Aqua.jl package quality checks" begin
    Aqua.test_all(RDF;
        ambiguities  = true,
        piracies     = true,
        deps_compat  = true,
        stale_deps   = true,
    )
end
