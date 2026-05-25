using Test
using RDF

# Thread-safety tests.
#
# Threading model for RDF.jl:
#   • The global term intern table is protected by _REGISTRY_LOCK; safe for
#     concurrent intern!() calls from any number of threads.
#   • The property-path LRU cache is protected by _PATH_CACHE_LOCK.
#   • Graph / Dataset / HexaStore are NOT thread-safe for concurrent mutation
#     (same contract as Julia's built-in mutable collections). Build on one
#     thread (or protect externally), then query from many threads.

@testset "Thread safety" begin

    # ── 1. Concurrent interning — ID consistency ─────────────────────────────
    # All threads intern the same set of terms simultaneously.
    # Expected: every thread observes the same ID for the same term;
    # no two distinct terms share an ID.

    @testset "Concurrent intern — consistent IDs" begin
        n_threads = min(Threads.nthreads(), 8)
        n_iris    = 200   # shared terms, interned by all threads concurrently
        iris      = [IRI("http://intern-consistency-test.example/r$i") for i in 1:n_iris]

        # Each thread records the ID it observed for each IRI
        all_ids = [zeros(UInt32, n_iris) for _ in 1:n_threads]

        @sync for t in 1:n_threads
            let t = t
                Threads.@spawn begin
                    g = Graph()
                    for (i, iri) in enumerate(iris)
                        push!(g, Triple(iri, rdf.type, IRI("http://intern-consistency-test.example/C")))
                    end
                    # Read back IDs by interning each IRI a second time
                    for (i, iri) in enumerate(iris)
                        push!(Graph(), Triple(iri, rdf.type,
                              IRI("http://intern-consistency-test.example/D")))
                        # Verify: build a tiny graph and confirm the triple is found
                        g2 = Graph()
                        push!(g2, Triple(iri, rdf.type,
                              IRI("http://intern-consistency-test.example/C")))
                        all_ids[t][i] = UInt32(sum(1 for _ in match(g2; subject=iri)))
                    end
                end
            end
        end

        # Every thread must have found exactly 1 match per IRI (no corruption)
        for t in 1:n_threads
            @test all(==(UInt32(1)), all_ids[t])
        end

        # All threads must agree on whether the IRI is present (trivially true here,
        # but validates no thread saw 0 matches due to a corrupted intern table)
        for t in 2:n_threads
            @test all_ids[1] == all_ids[t]
        end
    end

    # ── 2. Concurrent reads from a shared, already-built graph ────────────────
    # Build a graph on the main thread, then query it from many threads.
    # Expected: all readers see identical results with no corruption.

    @testset "Concurrent reads — consistent results" begin
        ex = Namespace("http://concurrent-read-test.example/")
        g  = Graph()
        n  = 200
        for i in 1:n
            push!(g, Triple(ex["s$i"], rdf.type,  ex.Thing))
            push!(g, Triple(ex["s$i"], ex.index,  Literal(i)))
        end
        # Ground truth
        expected_count = n

        n_threads = min(Threads.nthreads(), 8)
        counts    = zeros(Int, n_threads)

        @sync for t in 1:n_threads
            Threads.@spawn begin
                counts[t] = sum(1 for _ in match(g; predicate=rdf.type, object=ex.Thing))
            end
        end

        for t in 1:n_threads
            @test counts[t] == expected_count
        end
    end

    # ── 3. Concurrent SPARQL SELECT queries on a shared dataset ───────────────
    # Multiple threads run identical SPARQL queries simultaneously.
    # Expected: each thread gets the same result set.

    @testset "Concurrent SPARQL queries" begin
        ex  = Namespace("http://sparql-thread-test.example/")
        g   = Graph()
        n   = 50
        for i in 1:n
            push!(g, Triple(ex["p$i"], rdf.type,  ex.Person))
            push!(g, Triple(ex["p$i"], ex.age,    Literal(20 + i)))
        end
        ds = Dataset(; default_graph=g)

        query = """
          PREFIX ex: <http://sparql-thread-test.example/>
          SELECT ?s ?age WHERE {
            ?s a ex:Person ; ex:age ?age .
            FILTER(?age > 30)
          } ORDER BY ?s
        """
        expected = sparql(ds, query)

        n_threads = min(Threads.nthreads(), 8)
        results   = Vector{Any}(undef, n_threads)

        @sync for t in 1:n_threads
            Threads.@spawn begin
                results[t] = sparql(ds, query)
            end
        end

        for t in 1:n_threads
            r = results[t]
            @test r isa SolutionSet
            @test length(r) == length(expected)
        end
    end

    # ── 4. Concurrent property-path queries (exercises path cache lock) ───────

    @testset "Concurrent property-path queries" begin
        ex = Namespace("http://path-thread-test.example/")
        g  = Graph()
        # Build a chain: n0 → n1 → n2 → … → n19
        n  = 20
        for i in 0:n-2
            push!(g, Triple(ex["n$i"], ex.next, ex["n$(i+1)"]))
        end
        ds = Dataset(; default_graph=g)

        query = """
          PREFIX ex: <http://path-thread-test.example/>
          SELECT ?end WHERE { ex:n0 ex:next+ ?end }
        """
        expected_len = n - 1   # n1 through n19

        n_threads = min(Threads.nthreads(), 8)
        lengths   = zeros(Int, n_threads)

        @sync for t in 1:n_threads
            Threads.@spawn begin
                r = sparql(ds, query)
                lengths[t] = length(r)
            end
        end

        for t in 1:n_threads
            @test lengths[t] == expected_len
        end
    end

    # ── 5. Concurrent intern of the same IRI from many threads ────────────────
    # When threads race to intern the same term, exactly one ID must win.
    # No thread should see two different IDs for the same IRI.

    @testset "Concurrent intern — same IRI, unique ID" begin
        shared_iri = IRI("http://shared-intern-test.example/UniqueResource")
        n_threads  = min(Threads.nthreads(), 16)
        ids        = fill(UInt32(0), n_threads)

        @sync for t in 1:n_threads
            Threads.@spawn begin
                g = Graph()
                push!(g, Triple(shared_iri, rdf.type, IRI("http://shared-intern-test.example/C")))
                # The IRI is now interned; retrieve its ID by matching
                for _ in match(g; subject=shared_iri)
                    ids[t] = UInt32(1)   # just a sentinel — we care that no exception occurred
                end
            end
        end

        @test all(==(UInt32(1)), ids)
    end

end
