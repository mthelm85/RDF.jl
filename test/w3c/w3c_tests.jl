# W3C N-Triples and N-Quads conformance tests.
#
# To run: set the environment variable RDF_W3C_FIXTURES=1 and place the
# official W3C test files under:
#   test/w3c/fixtures/ntriples/   (from https://www.w3.org/2013/N-TriplesTests/)
#   test/w3c/fixtures/nquads/     (from https://www.w3.org/2013/N-QuadsTests/)
#
# Without the fixtures directory populated or RDF_W3C_FIXTURES=1, these are skipped.

const W3C_FIXTURES = get(ENV, "RDF_W3C_FIXTURES", "0") == "1"
const FIXTURES_DIR = joinpath(@__DIR__, "fixtures")

function _nt_positive_files()
    dir = joinpath(FIXTURES_DIR, "ntriples")
    isdir(dir) || return String[]
    filter(f -> endswith(f, ".nt") && !contains(f, "bad"), readdir(dir; join=true))
end

function _nt_negative_files()
    dir = joinpath(FIXTURES_DIR, "ntriples")
    isdir(dir) || return String[]
    filter(f -> endswith(f, ".nt") && contains(f, "bad"), readdir(dir; join=true))
end

function _nq_positive_files()
    dir = joinpath(FIXTURES_DIR, "nquads")
    isdir(dir) || return String[]
    filter(f -> endswith(f, ".nq") && !contains(f, "bad"), readdir(dir; join=true))
end

function _nq_negative_files()
    dir = joinpath(FIXTURES_DIR, "nquads")
    isdir(dir) || return String[]
    filter(f -> endswith(f, ".nq") && contains(f, "bad"), readdir(dir; join=true))
end

if W3C_FIXTURES
    @testset "W3C N-Triples positive syntax tests" begin
        for f in _nt_positive_files()
            @testset "$(basename(f))" begin
                @test_nowarn open(io -> read(io, MIME"application/n-triples"(), Graph), f)
            end
        end
    end

    @testset "W3C N-Triples negative syntax tests" begin
        for f in _nt_negative_files()
            @testset "$(basename(f))" begin
                @test_throws Exception open(io -> read(io, MIME"application/n-triples"(), Graph), f)
            end
        end
    end

    @testset "W3C N-Quads positive syntax tests" begin
        for f in _nq_positive_files()
            @testset "$(basename(f))" begin
                @test_nowarn open(io -> read(io, MIME"application/n-quads"(), Dataset), f)
            end
        end
    end

    @testset "W3C N-Quads negative syntax tests" begin
        for f in _nq_negative_files()
            @testset "$(basename(f))" begin
                @test_throws Exception open(io -> read(io, MIME"application/n-quads"(), Dataset), f)
            end
        end
    end
end
