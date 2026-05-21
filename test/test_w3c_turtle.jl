# W3C Turtle conformance tests
#
# Activated by setting RDF_W3C_FIXTURES=1 in the environment.
# Test files live under test/w3c/fixtures/turtle/
#
# Test categories:
#   Eval tests:      .ttl + matching .nt → parse .ttl, compare with .nt (isomorphic)
#   Positive syntax: .ttl with no .nt and no "bad"/"negative" → must parse without error
#   Negative syntax: .ttl with "bad" in name → must throw

const _W3C_TTL_ACTIVE   = get(ENV, "RDF_W3C_FIXTURES", "0") == "1"
const _TTL_FIXTURES_DIR = joinpath(@__DIR__, "w3c", "fixtures", "turtle")

# W3C base URI for the turtle test suite
const _TTL_BASE_URI = "http://www.w3.org/2013/TurtleTests/"

function _parse_ttl_file(path::AbstractString)::Graph
    stem = basename(path)
    base = _TTL_BASE_URI * stem
    open(path, "r") do io
        read(io, MIME"text/turtle"(), Graph, base)
    end
end

function _parse_nt_file(path::AbstractString)::Graph
    open(path, "r") do io
        read(io, MIME"application/n-triples"(), Graph)
    end
end

if _W3C_TTL_ACTIVE && isdir(_TTL_FIXTURES_DIR)

    all_names = readdir(_TTL_FIXTURES_DIR; join=false)
    nt_stems  = Set(n[1:end-3] for n in all_names if endswith(n, ".nt"))

    # ── Eval tests ────────────────────────────────────────────────────────────
    @testset "W3C Turtle eval tests" begin
        for name in sort(all_names)
            endswith(name, ".ttl") || continue
            stem = name[1:end-4]
            stem in nt_stems || continue    # only paired files

            ttl_file = joinpath(_TTL_FIXTURES_DIR, name)
            nt_file  = joinpath(_TTL_FIXTURES_DIR, stem * ".nt")

            @testset "$name" begin
                g_ttl = _parse_ttl_file(ttl_file)
                g_nt  = _parse_nt_file(nt_file)
                @test g_ttl ≅ g_nt
            end
        end
    end

    # ── Positive syntax tests ─────────────────────────────────────────────────
    @testset "W3C Turtle positive syntax" begin
        for name in sort(all_names)
            endswith(name, ".ttl") || continue
            contains(name, "bad") || contains(name, "negative") || name[1:end-4] in nt_stems ||
                begin
                    ttl_file = joinpath(_TTL_FIXTURES_DIR, name)
                    @testset "$name" begin
                        @test_nowarn _parse_ttl_file(ttl_file)
                    end
                end
        end
    end

    # ── Negative syntax tests ─────────────────────────────────────────────────
    # Files with "bad" or "negative" in the name that do NOT have a paired .nt
    # file are negative syntax tests (expected to fail parsing).
    # Files with "negative" in the name that DO have a paired .nt are eval tests
    # (e.g. negative_numeric.ttl tests negative numbers, which are valid Turtle).
    @testset "W3C Turtle negative syntax" begin
        for name in sort(all_names)
            endswith(name, ".ttl") || continue
            (contains(name, "bad") || contains(name, "negative")) || continue
            name[1:end-4] in nt_stems && continue  # skip eval tests

            ttl_file = joinpath(_TTL_FIXTURES_DIR, name)
            @testset "$name" begin
                @test_throws Exception _parse_ttl_file(ttl_file)
            end
        end
    end

else
    @testset "W3C Turtle (skipped – set RDF_W3C_FIXTURES=1 to enable)" begin
        @test true
    end
end
