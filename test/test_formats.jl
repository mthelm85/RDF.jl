using RDF
using Test

# Symbol format aliases (:ttl, :jsonld, …) layered over the MIME dispatch used
# by the serializers. Every symbol must land on exactly the same bytes as the
# MIME it aliases, and a bad symbol must produce a helpful ArgumentError.

@testset "Format specifiers" begin

    ex = "http://example.org/"
    g  = Graph()
    push!(g, Triple(IRI(ex * "alice"), IRI(ex * "knows"), IRI(ex * "bob")))
    push!(g, Triple(IRI(ex * "alice"), IRI(ex * "name"),  Literal("Alice")))

    ds = Dataset(; default_graph=g)

    _bytes(f, x; kw...) = (io = IOBuffer(); write(io, f, x; kw...); String(take!(io)))

    @testset "_format_mime normalization" begin
        @test RDF._format_mime(:ttl)      == MIME"text/turtle"()
        @test RDF._format_mime(:turtle)   == MIME"text/turtle"()
        @test RDF._format_mime(:nt)       == MIME"application/n-triples"()
        @test RDF._format_mime(:ntriples) == MIME"application/n-triples"()
        @test RDF._format_mime(:nq)       == MIME"application/n-quads"()
        @test RDF._format_mime(:nquads)   == MIME"application/n-quads"()
        @test RDF._format_mime(:jsonld)   == MIME"application/ld+json"()
        @test RDF._format_mime(:rdfxml)   == MIME"application/rdf+xml"()
        @test RDF._format_mime(:xml)      == MIME"application/rdf+xml"()

        # MIME values and MIME strings pass through
        @test RDF._format_mime(MIME"text/turtle"()) == MIME"text/turtle"()
        @test RDF._format_mime("text/turtle")       == MIME"text/turtle"()
    end

    @testset "_results_format_mime normalization" begin
        @test RDF._results_format_mime(:json) == MIME"application/sparql-results+json"()
        @test RDF._results_format_mime(:srj)  == MIME"application/sparql-results+json"()
        @test RDF._results_format_mime(:xml)  == MIME"application/sparql-results+xml"()
        @test RDF._results_format_mime(:srx)  == MIME"application/sparql-results+xml"()
        @test RDF._results_format_mime(:csv)  == MIME"text/csv"()
        @test RDF._results_format_mime(:tsv)  == MIME"text/tab-separated-values"()
        @test RDF._results_format_mime(MIME"text/csv"()) == MIME"text/csv"()
    end

    @testset "unknown symbols give a helpful ArgumentError" begin
        err = try; RDF._format_mime(:turtel); catch e; e; end
        @test err isa ArgumentError
        @test occursin("turtel", err.msg)
        @test occursin(":ttl", err.msg)          # lists the valid names

        # :json is deliberately NOT an RDF-graph alias (it would be ambiguous
        # with SPARQL results JSON) — it must error and point at :jsonld.
        @test_throws ArgumentError RDF._format_mime(:json)
        @test occursin(":jsonld", (try; RDF._format_mime(:json); catch e; e.msg; end))

        err2 = try; RDF._results_format_mime(:jsonld); catch e; e; end
        @test err2 isa ArgumentError
        @test occursin(":srj", err2.msg)

        # …and the error surfaces through the read/write entry points
        @test_throws ArgumentError read(IOBuffer(""), :bogus, Graph)
        @test_throws ArgumentError write(IOBuffer(), :bogus, g)
        @test_throws ArgumentError rdf_read(tempname() * ".ttl"; format=:bogus)
    end

    @testset "write(io, symbol, x) matches write(io, mime, x)" begin
        for (sym, mime) in [(:ttl,      MIME"text/turtle"()),
                            (:turtle,   MIME"text/turtle"()),
                            (:nt,       MIME"application/n-triples"()),
                            (:ntriples, MIME"application/n-triples"()),
                            (:jsonld,   MIME"application/ld+json"())]
            @test _bytes(sym, g) == _bytes(mime, g)
        end
        for (sym, mime) in [(:nq,     MIME"application/n-quads"()),
                            (:nquads, MIME"application/n-quads"()),
                            (:jsonld, MIME"application/ld+json"())]
            @test _bytes(sym, ds) == _bytes(mime, ds)
        end
    end

    @testset "keyword arguments forward through the symbol form" begin
        prefixes = Dict("ex" => ex)
        @test _bytes(:ttl, g; prefixes=prefixes) ==
              _bytes(MIME"text/turtle"(), g; prefixes=prefixes)
        @test occursin("@prefix ex:", _bytes(:ttl, g; prefixes=prefixes))

        ctx = Dict("@vocab" => ex)
        @test _bytes(:jsonld, g; context=ctx) ==
              _bytes(MIME"application/ld+json"(), g; context=ctx)
        @test occursin("@vocab", _bytes(:jsonld, g; context=ctx))
    end

    @testset "read(io, symbol, T) round-trips" begin
        @test read(IOBuffer(_bytes(:ttl, g)), :ttl, Graph)   == g
        @test read(IOBuffer(_bytes(:nt,  g)), :nt,  Graph)   == g
        @test length(read(IOBuffer(_bytes(:jsonld, g)), :jsonld, Graph)) == length(g)
        @test read(IOBuffer(_bytes(:nq, ds)), :nq, Dataset) isa Dataset

        # Vector{Triple} target
        ts = read(IOBuffer(_bytes(:ttl, g)), :ttl, Vector{Triple})
        @test ts isa Vector{Triple}
        @test length(ts) == 2
    end

    @testset "base IRI argument survives the symbol form" begin
        ttl = "<alice> <http://example.org/name> \"Alice\" ."
        gb  = read(IOBuffer(ttl), :ttl, Graph, "http://base.example/")
        @test IRI("http://base.example/alice") in subjects(gb)

        tb = read(IOBuffer(ttl), :ttl, Vector{Triple}, "http://base.example/")
        @test tb[1].subject == IRI("http://base.example/alice")
    end

    @testset "path-based read/write via the filename fallback in Base" begin
        path = tempname() * ".dat"      # extension deliberately meaningless
        try
            open(io -> write(io, :ttl, g), path, "w")
            @test read(path, :ttl, Graph) == g
        finally
            isfile(path) && rm(path)
        end
    end

    @testset "parse_triples accepts symbols" begin
        nt = _bytes(:nt, g)
        collected = Triple[]
        parse_triples(t -> push!(collected, t), IOBuffer(nt), :nt)
        @test length(collected) == 2
        @test length(collect(parse_triples(IOBuffer(nt), :ntriples))) == 2
    end

    @testset "SPARQL results formats" begin
        res = sparql(ds, "SELECT ?s ?o WHERE { ?s <$(ex)name> ?o }")
        for (sym, mime) in [(:json, MIME"application/sparql-results+json"()),
                            (:srj,  MIME"application/sparql-results+json"()),
                            (:xml,  MIME"application/sparql-results+xml"()),
                            (:srx,  MIME"application/sparql-results+xml"()),
                            (:csv,  MIME"text/csv"()),
                            (:tsv,  MIME"text/tab-separated-values"())]
            @test _bytes(sym, res) == _bytes(mime, res)
        end

        # ASK results are plain Bools, so they take the MIME form only — a
        # `write(io, ::Symbol, ::Bool)` method would be type piracy over Base.
        ask = sparql(ds, "ASK { ?s ?p ?o }")
        @test ask === true
        @test _bytes(MIME"application/sparql-results+json"(), ask) ==
              "{\"head\":{},\"boolean\":true}"
        # (`hasmethod` is no help — Base's `write(io, x, xs...)` fallback
        # matches. Check that the fallback is what resolves.)
        @test which(write, Tuple{IO, Symbol, Bool}).module === Base

        # A graph format is not a results format
        @test_throws ArgumentError write(IOBuffer(), :ttl, res)
    end

    @testset "write_sparql_results — both arms of the sparql union" begin
        sel = sparql(ds, "SELECT ?s ?o WHERE { ?s <$(ex)name> ?o }")
        ask = sparql(ds, "ASK { ?s ?p ?o }")
        no  = sparql(ds, "ASK { <$(ex)nobody> ?p ?o }")

        @test sel isa SolutionSet
        @test ask isa Bool
        @test no  === false

        _wsr(f, x) = (io = IOBuffer(); write_sparql_results(io, f, x); String(take!(io)))

        # SELECT: identical to the write(io, format, sol) path
        for f in (:json, :srj, :xml, :srx, :csv, :tsv)
            @test _wsr(f, sel) == _bytes(f, sel)
        end
        @test _wsr(MIME"text/csv"(), sel) == _bytes(:csv, sel)

        # ASK: identical to the MIME write(io, mime, bool) path
        @test _wsr(:json, ask) == _bytes(MIME"application/sparql-results+json"(), ask)
        @test _wsr(:srj,  ask) == _bytes(MIME"application/sparql-results+json"(), ask)
        @test _wsr(:xml,  ask) == _bytes(MIME"application/sparql-results+xml"(),  ask)
        @test _wsr(:srx,  ask) == _bytes(MIME"application/sparql-results+xml"(),  ask)
        @test _wsr(:json, no)  == "{\"head\":{},\"boolean\":false}"
        @test _wsr(MIME"application/sparql-results+json"(), ask) == _wsr(:json, ask)

        # The point of the function: a caller that does not know the query form
        for q in ["SELECT ?s WHERE { ?s ?p ?o }", "ASK { ?s ?p ?o }"]
            io = IOBuffer()
            write_sparql_results(io, :json, sparql(ds, q))
            @test !isempty(take!(io))
        end

        # ASK has no CSV/TSV form in the W3C spec — say so, do not emit garbage
        for f in (:csv, :tsv, MIME"text/csv"(), MIME"text/tab-separated-values"())
            e = try; _wsr(f, ask); catch err; err; end
            @test e isa ArgumentError
            @test occursin("ASK", e.msg)
        end

        # Unknown format names still produce the helpful error
        @test_throws ArgumentError write_sparql_results(IOBuffer(), :bogus, sel)
        @test_throws ArgumentError write_sparql_results(IOBuffer(), :bogus, ask)
        @test_throws ArgumentError write_sparql_results(IOBuffer(), :jsonld, ask)

        @test write_sparql_results(IOBuffer(), :json, ask) === nothing
    end

    @testset "rdf_read / rdf_write format override" begin
        # Extension says nothing; `format` decides.
        path = tempname() * ".txt"
        try
            rdf_write(path, g; format=:ttl)
            @test occursin("<http://example.org/alice>", read(path, String))
            @test rdf_read(path; format=:ttl) == g
            @test rdf_read(path; format=MIME"text/turtle"()) == g
            @test rdf_read(path; format=:turtle) == g
        finally
            isfile(path) && rm(path)
        end

        # `format` overrides a misleading extension.
        path2 = tempname() * ".ttl"
        try
            rdf_write(path2, g; format=:nt)
            @test occursin("^^<http://www.w3.org/2001/XMLSchema#string>", read(path2, String))
            @test rdf_read(path2; format=:nt) == g
        finally
            isfile(path2) && rm(path2)
        end

        # Datasets take the same keyword.
        path3 = tempname() * ".txt"
        try
            rdf_write(path3, ds; format=:nq)
            @test rdf_read(path3; format=:nq) isa Dataset
        finally
            isfile(path3) && rm(path3)
        end
    end

    @testset "rdf_write refuses formats it cannot serialize" begin
        # Unknown extension: an error, not a silent N-Triples fallback.
        @test_throws ArgumentError rdf_write(tempname() * ".foo", g)
        err = try; rdf_write(tempname() * ".foo", g); catch e; e; end
        @test occursin("format=:ttl", err.msg)

        # Format/value mismatches.
        @test_throws ArgumentError rdf_write(tempname() * ".nq",  g)    # Graph → N-Quads
        @test_throws ArgumentError rdf_write(tempname() * ".ttl", ds)   # Dataset → Turtle
        @test_throws ArgumentError rdf_write(tempname() * ".nt",  ds)   # Dataset → N-Triples
        @test_throws ArgumentError rdf_write(tempname() * ".rdf", g)    # RDF/XML is read-only

        mm = try; rdf_write(tempname() * ".nq", g); catch e; e; end
        @test occursin("Graph", mm.msg)
        @test occursin("application/n-quads", mm.msg)

        # write(path, x) remains the "just give me N-Triples/N-Quads" escape hatch.
        p = tempname() * ".foo"
        try
            write(p, g)
            @test read(IOBuffer(read(p, String)), :nt, Graph) == g
        finally
            isfile(p) && rm(p)
        end
    end

    @testset "extension inference still works with no format given" begin
        for (ext, T) in [(".ttl", Graph), (".nt", Graph), (".jsonld", Dataset)]
            path = tempname() * ext
            try
                rdf_write(path, g)
                @test rdf_read(path) isa T
            finally
                isfile(path) && rm(path)
            end
        end
        path = tempname() * ".nq"
        try
            rdf_write(path, ds)
            @test rdf_read(path) isa Dataset
        finally
            isfile(path) && rm(path)
        end
    end

    @testset "_format_accept for content negotiation" begin
        @test RDF._format_accept(:ttl)    == "text/turtle"
        @test RDF._format_accept(:jsonld) == "application/ld+json"
        @test RDF._format_accept(MIME"application/n-triples"()) == "application/n-triples"
        # A full Accept header passes through untouched
        @test RDF._format_accept("text/turtle;q=1.0, application/ld+json;q=0.7") ==
              "text/turtle;q=1.0, application/ld+json;q=0.7"
    end
end
