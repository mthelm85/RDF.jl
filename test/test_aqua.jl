using Test
using Aqua
using RDF

@testset "Aqua.jl package quality checks" begin
    Aqua.test_all(RDF;
        ambiguities  = false,   # intentional multi-dispatch ambiguities exist (e.g. match)
        piracies     = true,
        deps_compat  = true,
        stale_deps   = true,
    )
end
