using Test
using RDF
import RDF: Graph, RDFTerm

# ── Embedding index — semantic (vector → graph) retrieval ──────────────────────
#
# TDD spec.  This is the missing entry point of the GraphRAG loop: map RDF terms
# to dense vectors, find the terms nearest a query vector, and hand those seeds
# to the existing ego_graph / to_context pipeline.  Contract under test:
#
#   • EmbeddingIndex(dim)                     -> empty Float32 index of width dim
#     EmbeddingIndex{Float64}(dim)            -> empty Float64 index
#     EmbeddingIndex(pairs)                   -> from term => vector pairs (dim inferred)
#
#   • index!(idx, term, vec)                  -> insert or update; stores an L2-
#                                                normalized copy; dedups on term
#     index!(idx, pairs)                      -> bulk insert
#
#   • length(idx), haskey(idx, term), term in idx, idx[term]
#
#   • knn(idx, query; k=5) -> Vector{Pair{RDFTerm,Float64}}
#       the k nearest terms by cosine similarity, descending; scores in [-1, 1];
#       k > length returns all; empty index returns [].
#
#   • retrieve(g, idx, query; k, hops, through_types, budget, prefixes) -> String
#       knn -> seed terms -> ego_graph(g, seeds) -> to_context(...): vector search
#       to prompt-ready text in one call.

const _em = Namespace("http://emb-test.example.org/")

@testset "EmbeddingIndex — semantic retrieval" begin

    # ── construction ────────────────────────────────────────────────────────────
    @testset "construction and eltype" begin
        idx = EmbeddingIndex(4)
        @test idx isa EmbeddingIndex{Float32}
        @test idx.dim == 4
        @test length(idx) == 0

        idx64 = EmbeddingIndex{Float64}(4)
        @test idx64 isa EmbeddingIndex{Float64}
        @test length(idx64) == 0
    end

    @testset "bulk construction from pairs infers dim" begin
        idx = EmbeddingIndex([_em.a => Float32[1, 0, 0],
                              _em.b => Float32[0, 1, 0]])
        @test idx.dim == 3
        @test length(idx) == 2
        @test haskey(idx, _em.a)
        @test _em.b in idx
    end

    # ── population ───────────────────────────────────────────────────────────────
    @testset "index! stores a normalized vector" begin
        idx = EmbeddingIndex(2)
        index!(idx, _em.a, Float32[3, 4])          # norm 5
        @test length(idx) == 1
        @test haskey(idx, _em.a)
        @test _em.a in idx
        v = idx[_em.a]
        @test v ≈ Float32[0.6, 0.8]                 # normalized on insert
        @test sum(abs2, v) ≈ 1.0f0
    end

    @testset "index! on the same term updates in place (no duplicate)" begin
        idx = EmbeddingIndex(2)
        index!(idx, _em.a, Float32[1, 0])
        index!(idx, _em.a, Float32[0, 1])
        @test length(idx) == 1
        @test idx[_em.a] ≈ Float32[0, 1]
    end

    @testset "bulk index!" begin
        idx = EmbeddingIndex(3)
        index!(idx, [_em.a => Float32[1, 0, 0],
                     _em.b => Float32[0, 1, 0],
                     _em.c => Float32[0, 0, 1]])
        @test length(idx) == 3
    end

    # ── errors ───────────────────────────────────────────────────────────────────
    @testset "dimension mismatch is an error" begin
        idx = EmbeddingIndex(3)
        @test_throws DimensionMismatch index!(idx, _em.a, Float32[1, 0])
        index!(idx, _em.a, Float32[1, 0, 0])
        @test_throws DimensionMismatch knn(idx, Float32[1, 0]; k=1)
    end

    @testset "missing term lookup throws KeyError" begin
        idx = EmbeddingIndex(2)
        @test_throws KeyError idx[_em.nope]
    end

    # ── k-NN correctness ─────────────────────────────────────────────────────────
    @testset "knn returns the single nearest term" begin
        idx = EmbeddingIndex(3)
        index!(idx, _em.a, Float32[1, 0, 0])
        index!(idx, _em.b, Float32[0, 1, 0])
        index!(idx, _em.c, Float32[0, 0, 1])

        hits = knn(idx, Float32[0, 1, 0]; k=1)
        @test hits isa Vector{Pair{RDFTerm,Float64}}
        @test length(hits) == 1
        @test first(hits[1]) == _em.b
        @test last(hits[1]) ≈ 1.0
    end

    @testset "knn ranks by descending cosine similarity" begin
        idx = EmbeddingIndex(3)
        index!(idx, _em.a, Float32[1, 0, 0])
        index!(idx, _em.b, Float32[0, 1, 0])
        index!(idx, _em.c, Float32[0, 0, 1])

        hits = knn(idx, Float32[2, 1, 0]; k=3)      # cos: a>b>c
        @test [first(h) for h in hits] == [_em.a, _em.b, _em.c]
        scores = [last(h) for h in hits]
        @test issorted(scores; rev=true)
        @test all(-1.0 - 1e-6 <= s <= 1.0 + 1e-6 for s in scores)
        @test scores[1] ≈ 2 / sqrt(5)
        @test scores[2] ≈ 1 / sqrt(5)
        @test scores[3] ≈ 0.0 atol = 1e-6
    end

    @testset "cosine is scale invariant to query magnitude" begin
        idx = EmbeddingIndex(3)
        index!(idx, _em.a, Float32[1, 0, 0])
        index!(idx, _em.b, Float32[0, 1, 0])
        h1 = knn(idx, Float32[2, 1, 0]; k=2)
        h2 = knn(idx, Float32[4, 2, 0]; k=2)
        @test [first(h) for h in h1] == [first(h) for h in h2]
        @test [last(h) for h in h1] ≈ [last(h) for h in h2]
    end

    @testset "anti-parallel term scores near -1 and ranks last" begin
        idx = EmbeddingIndex(2)
        index!(idx, _em.pos, Float32[1, 0])
        index!(idx, _em.neg, Float32[-1, 0])
        hits = knn(idx, Float32[1, 0]; k=2)
        @test first(hits[1]) == _em.pos
        @test last(hits[1]) ≈ 1.0
        @test first(hits[2]) == _em.neg
        @test last(hits[2]) ≈ -1.0
    end

    @testset "k larger than the index returns all; empty index returns []" begin
        idx = EmbeddingIndex(2)
        index!(idx, _em.a, Float32[1, 0])
        index!(idx, _em.b, Float32[0, 1])
        @test length(knn(idx, Float32[1, 0]; k=100)) == 2

        empty_idx = EmbeddingIndex(2)
        @test knn(empty_idx, Float32[1, 0]; k=5) == Pair{RDFTerm,Float64}[]
    end

    @testset "works on terms never pushed to any graph (keyed by term, not term_id)" begin
        idx = EmbeddingIndex(2)
        ghost = _em.ghost
        @test term_id(ghost) == 0                    # never interned
        index!(idx, ghost, Float32[1, 0])
        hits = knn(idx, Float32[1, 0]; k=1)
        @test first(hits[1]) == ghost
    end

    # ── retrieve: the loop end to end ─────────────────────────────────────────────
    @testset "retrieve turns a query vector into prompt context" begin
        g = Graph()
        push!(g, Triple(_em.alice, _em.knows, _em.bob))
        push!(g, Triple(_em.bob,   _em.name,  Literal("Bob")))
        push!(g, Triple(_em.carol, _em.knows, _em.dave))
        push!(g, Triple(_em.dave,  _em.name,  Literal("Dave")))

        idx = EmbeddingIndex(2)
        index!(idx, _em.alice, Float32[1, 0])
        index!(idx, _em.carol, Float32[0, 1])

        ctx = retrieve(g, idx, Float32[1, 0]; k=1, hops=2, budget=2000,
                       prefixes=Dict("em" => "http://emb-test.example.org/"))
        @test ctx isa String
        @test !isempty(ctx)
        @test occursin("bob", ctx)                   # alice's 2-hop neighbourhood
        @test occursin("Bob", ctx)
        @test !occursin("carol", ctx)                # carol's block excluded
        @test !occursin("Dave", ctx)
        @test occursin("em:", ctx)                   # prefixes applied
    end

    @testset "retrieve on an indexed term absent from the graph returns empty" begin
        g = Graph()
        push!(g, Triple(_em.alice, _em.knows, _em.bob))

        idx = EmbeddingIndex(2)
        index!(idx, _em.orphan, Float32[1, 0])       # not a node in g

        ctx = retrieve(g, idx, Float32[1, 0]; k=1, hops=2)
        @test ctx == ""
    end

    # ── type stability ────────────────────────────────────────────────────────────
    @testset "type stability" begin
        idx = EmbeddingIndex(2)
        index!(idx, _em.a, Float32[1, 0])
        @test (@inferred length(idx)) == 1
        @test knn(idx, Float32[1, 0]; k=1) isa Vector{Pair{RDFTerm,Float64}}
    end
end
