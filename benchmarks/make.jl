"""
PkgBenchmark entry-point for RDF.jl
====================================

Used by PkgBenchmark.jl and CI tooling.  The file must define SUITE at module
scope and not run any benchmarks itself.

Usage (from the Julia REPL):
    using PkgBenchmark
    results = benchmarkpkg("RDF")
    export_markdown(stdout, results)

    # Compare HEAD against main:
    judge_results = judge("RDF", "main")
    export_markdown(stdout, judge_results)

CI (GitHub Actions example — see .github/workflows/benchmark.yml):
    julia --project=benchmarks benchmarks/make.jl
"""

# benchmarks/benchmarks.jl defines SUITE; include it here so PkgBenchmark
# can find it.  The runner block at the bottom of that file is guarded by
# `abspath(PROGRAM_FILE) == @__FILE__` and therefore does NOT execute when
# included by PkgBenchmark.
include(joinpath(@__DIR__, "benchmarks.jl"))
