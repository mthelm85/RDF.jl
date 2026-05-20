# W3C N-Triples and N-Quads conformance tests (RDF 1.1 and RDF 1.2).
#
# Activated by setting RDF_W3C_FIXTURES=1 in the environment.
# Test files live under test/w3c/fixtures/:
#   ntriples/   — RDF 1.1 N-Triples  (https://www.w3.org/2013/N-TriplesTests/)
#   nquads/     — RDF 1.1 N-Quads    (https://www.w3.org/2013/N-QuadsTests/)
#   ntriples12/ — RDF 1.2 N-Triples  (https://w3c.github.io/rdf-tests/rdf/rdf12/rdf-n-triples/)
#   nquads12/   — RDF 1.2 N-Quads    (https://w3c.github.io/rdf-tests/rdf/rdf12/rdf-n-quads/)

const W3C_FIXTURES = get(ENV, "RDF_W3C_FIXTURES", "0") == "1"
const FIXTURES_DIR = joinpath(@__DIR__, "fixtures")

function _w3c_pos(dir, ext)
    d = joinpath(FIXTURES_DIR, dir)
    isdir(d) || return String[]
    filter(f -> endswith(f, ext) && !contains(basename(f), "bad"), readdir(d; join=true))
end

function _w3c_neg(dir, ext)
    d = joinpath(FIXTURES_DIR, dir)
    isdir(d) || return String[]
    filter(f -> endswith(f, ext) && contains(basename(f), "bad"), readdir(d; join=true))
end

if W3C_FIXTURES
    @testset "W3C RDF 1.1 N-Triples positive syntax" begin
        for f in _w3c_pos("ntriples", ".nt")
            @testset "$(basename(f))" begin
                @test_nowarn open(io -> read(io, MIME"application/n-triples"(), Graph), f)
            end
        end
    end

    @testset "W3C RDF 1.1 N-Triples negative syntax" begin
        for f in _w3c_neg("ntriples", ".nt")
            @testset "$(basename(f))" begin
                @test_throws Exception open(io -> read(io, MIME"application/n-triples"(), Graph), f)
            end
        end
    end

    @testset "W3C RDF 1.1 N-Quads positive syntax" begin
        for f in _w3c_pos("nquads", ".nq")
            @testset "$(basename(f))" begin
                @test_nowarn open(io -> read(io, MIME"application/n-quads"(), Dataset), f)
            end
        end
    end

    @testset "W3C RDF 1.1 N-Quads negative syntax" begin
        for f in _w3c_neg("nquads", ".nq")
            @testset "$(basename(f))" begin
                @test_throws Exception open(io -> read(io, MIME"application/n-quads"(), Dataset), f)
            end
        end
    end

    @testset "W3C RDF 1.2 N-Triples positive syntax" begin
        for f in _w3c_pos("ntriples12", ".nt")
            @testset "$(basename(f))" begin
                @test_nowarn open(io -> read(io, MIME"application/n-triples"(), Graph), f)
            end
        end
    end

    @testset "W3C RDF 1.2 N-Triples negative syntax" begin
        for f in _w3c_neg("ntriples12", ".nt")
            @testset "$(basename(f))" begin
                @test_throws Exception open(io -> read(io, MIME"application/n-triples"(), Graph), f)
            end
        end
    end

    @testset "W3C RDF 1.2 N-Quads positive syntax" begin
        for f in _w3c_pos("nquads12", ".nq")
            @testset "$(basename(f))" begin
                @test_nowarn open(io -> read(io, MIME"application/n-quads"(), Dataset), f)
            end
        end
    end

    @testset "W3C RDF 1.2 N-Quads negative syntax" begin
        for f in _w3c_neg("nquads12", ".nq")
            @testset "$(basename(f))" begin
                @test_throws Exception open(io -> read(io, MIME"application/n-quads"(), Dataset), f)
            end
        end
    end
end
