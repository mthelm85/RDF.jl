using Test
using RDF
import RDF: Graph

# ── RDF-star annotation ergonomics ─────────────────────────────────────────────
#
# TDD spec.  Contract under test:
#
#   • annotate!(g, t::Triple, pred::IRI, obj) -> BlankNode (the reifier)
#       Asserts `t` (if absent), then attaches an annotation using the
#       standard RDF 1.2 reifier pattern:
#           t                                   (asserted)
#           _:r rdf:reifies <<( s p o )>> .     (reifier, created once per t)
#           _:r pred obj .                      (the annotation)
#       Non-RDFTerm objects are converted with Literal(); repeated calls on
#       the same triple reuse the same reifier.
#
#   • annotate!(g, t; confidence=0.9, source=IRI(...), ...) -> BlankNode
#       Keyword convenience: each keyword `k` maps to the predicate `anno.k`
#       in the exported `anno` annotation namespace.
#
#   • annotations(g, t) -> Vector{Pair{IRI, ObjectTerm}}
#       All (predicate => object) annotations attached to `t` across all of
#       its reifiers, excluding the rdf:reifies link itself.
#
#   • annotations(g, t, pred::IRI) -> Vector{ObjectTerm}
#       Just the values for one annotation predicate.
#
#   • The whole pattern is plain RDF 1.2 — it must survive an N-Triples
#       round-trip (with blank-node renaming) intact.

const _an_ex = Namespace("http://anno-test.example.org/")

@testset "RDF-star annotations" begin

    @testset "annotate! asserts and annotates" begin
        g = Graph()
        t = Triple(_an_ex.alice, _an_ex.age, Literal(30))
        r = annotate!(g, t, _an_ex.certainty, 0.87)

        @test r isa BlankNode
        @test t in g                                    # asserted
        @test length(g) == 3                            # t + reifies + annotation
        @test Triple(r, rdf.reifies,
                     TripleTerm(_an_ex.alice, _an_ex.age, Literal(30))) in g
        @test Triple(r, _an_ex.certainty, Literal(0.87)) in g
    end

    @testset "annotate! reuses the reifier for the same triple" begin
        g = Graph()
        t = Triple(_an_ex.alice, _an_ex.age, Literal(30))
        r1 = annotate!(g, t, _an_ex.certainty, 0.87)
        r2 = annotate!(g, t, _an_ex.source, _an_ex.doc1)

        @test r1 == r2
        @test length(g) == 4        # t + reifies + 2 annotations
    end

    @testset "annotate! does not duplicate an already-asserted triple" begin
        g = Graph()
        t = Triple(_an_ex.bob, _an_ex.name, Literal("Bob"))
        push!(g, t)
        annotate!(g, t, _an_ex.certainty, 1.0)
        @test length(g) == 3
    end

    @testset "keyword form maps through the anno namespace" begin
        g = Graph()
        t = Triple(_an_ex.alice, _an_ex.knows, _an_ex.bob)
        r = annotate!(g, t; confidence=0.92, source=_an_ex.doc7,
                            model=Literal("gpt-x"))

        @test r isa BlankNode
        @test Triple(r, anno.confidence, Literal(0.92)) in g
        @test Triple(r, anno.source, _an_ex.doc7) in g
        @test Triple(r, anno.model, Literal("gpt-x")) in g
        # positional and keyword forms share the reifier
        annotate!(g, t, _an_ex.reviewed, true)
        @test Triple(r, _an_ex.reviewed, Literal(true)) in g
    end

    @testset "annotations retrieval" begin
        g = Graph()
        t = Triple(_an_ex.alice, _an_ex.age, Literal(30))
        annotate!(g, t; confidence=0.87, source=_an_ex.doc1)

        pairs = annotations(g, t)
        @test pairs isa Vector{Pair{IRI, ObjectTerm}}
        @test length(pairs) == 2
        @test (anno.confidence => Literal(0.87)) in pairs
        @test (anno.source => _an_ex.doc1) in pairs
        # rdf:reifies plumbing is not reported as an annotation
        @test all(p.first != rdf.reifies for p in pairs)

        # single-predicate accessor
        vals = annotations(g, t, anno.confidence)
        @test vals == [Literal(0.87)]
        @test value(Float64, vals[1]) == 0.87
        @test annotations(g, t, anno.model) == []
    end

    @testset "annotations on an unannotated / absent triple are empty" begin
        g = Graph()
        push!(g, Triple(_an_ex.alice, _an_ex.age, Literal(30)))
        @test annotations(g, Triple(_an_ex.alice, _an_ex.age, Literal(30))) == []
        @test annotations(g, Triple(_an_ex.ghost, _an_ex.p, Literal(1))) == []
    end

    @testset "multiple reifiers are aggregated" begin
        # Hand-built second reifier (e.g. two extraction runs annotating the
        # same statement) — annotations() must see both.
        g  = Graph()
        t  = Triple(_an_ex.alice, _an_ex.age, Literal(30))
        annotate!(g, t; confidence=0.8)
        r2 = blank!(g)
        push!(g, Triple(r2, rdf.reifies, TripleTerm(t.subject, t.predicate, t.object)))
        push!(g, Triple(r2, anno.confidence, Literal(0.95)))

        vals = annotations(g, t, anno.confidence)
        @test length(vals) == 2
        @test Literal(0.8) in vals && Literal(0.95) in vals
    end

    @testset "filtering by confidence (the LLM-extraction loop)" begin
        g = Graph()
        annotate!(g, Triple(_an_ex.a, _an_ex.p, _an_ex.b); confidence=0.95)
        annotate!(g, Triple(_an_ex.c, _an_ex.p, _an_ex.d); confidence=0.4)
        push!(g, Triple(_an_ex.e, _an_ex.p, _an_ex.f))   # unannotated

        confident = [t for t in match(g; predicate=_an_ex.p)
                     if any(value(Float64, v) > 0.9
                            for v in annotations(g, t, anno.confidence))]
        @test confident == [Triple(_an_ex.a, _an_ex.p, _an_ex.b)]
    end

    @testset "annotations survive an N-Triples round-trip" begin
        g = Graph()
        t = Triple(_an_ex.alice, _an_ex.age, Literal(30))
        annotate!(g, t; confidence=0.87, source=_an_ex.doc1)

        buf = IOBuffer()
        write(buf, MIME"application/n-triples"(), g)
        g2 = read(IOBuffer(take!(buf)), MIME"application/n-triples"(), Graph)

        @test t in g2
        # blank-node ids are renamed on parse, but lookup goes through the
        # rdf:reifies link so the annotations are still found
        pairs = annotations(g2, t)
        @test length(pairs) == 2
        @test (anno.confidence => Literal(0.87)) in pairs
        @test (anno.source => _an_ex.doc1) in pairs
    end
end
