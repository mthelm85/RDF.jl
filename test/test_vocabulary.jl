using Test
using RDF

# Shared IRIs
const _V_RDF_TYPE     = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
const _V_RDFS_CLASS   = IRI("http://www.w3.org/2000/01/rdf-schema#Class")
const _V_RDFS_PROP    = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#Property")
const _V_RDFS_LABEL   = IRI("http://www.w3.org/2000/01/rdf-schema#label")
const _V_RDFS_COMMENT = IRI("http://www.w3.org/2000/01/rdf-schema#comment")

# Build a small in-memory vocabulary graph for most tests
function _make_test_graph()
    ns = Namespace("http://example.org/vocab/")
    g  = Graph()

    # Classes
    push!(g, Triple(ns.Foo, _V_RDF_TYPE,     _V_RDFS_CLASS))
    push!(g, Triple(ns.Foo, _V_RDFS_LABEL,   Literal("Foo thing"; lang="en")))
    push!(g, Triple(ns.Foo, _V_RDFS_LABEL,   Literal("Cosa Foo"; lang="es")))
    push!(g, Triple(ns.Foo, _V_RDFS_COMMENT, Literal("A description of Foo"; lang="en")))

    push!(g, Triple(ns.Bar, _V_RDF_TYPE,   _V_RDFS_CLASS))
    push!(g, Triple(ns.Bar, _V_RDFS_LABEL, Literal("Bar thing")))   # plain literal

    # Property with no label
    push!(g, Triple(ns.hasFoo, _V_RDF_TYPE, _V_RDFS_PROP))

    g
end

@testset "Vocabulary" begin

    g = _make_test_graph()
    BASE = "http://example.org/vocab/"

    # ── Construction ──────────────────────────────────────────────────────────
    @testset "construction with base" begin
        v = Vocabulary(g; base=BASE)
        @test v isa Vocabulary
        @test length(v) == 3   # Foo, Bar, hasFoo
        @test !isempty(v)
    end

    @testset "construction without base" begin
        v = Vocabulary(g)
        @test length(v) == 3
    end

    # ── Dot-notation term access ───────────────────────────────────────────────
    @testset "getproperty — known terms" begin
        v = Vocabulary(g; base=BASE)
        @test v.Foo    == IRI("$(BASE)Foo")
        @test v.Bar    == IRI("$(BASE)Bar")
        @test v.hasFoo == IRI("$(BASE)hasFoo")
    end

    @testset "getproperty — unknown term falls back to base+name" begin
        v = Vocabulary(g; base=BASE)
        @test v.Unknown == IRI("$(BASE)Unknown")
    end

    @testset "getproperty — no base, unknown term raises KeyError" begin
        v = Vocabulary(g)
        @test_throws KeyError v.NonExistent
    end

    @testset "getproperty — struct fields are accessible" begin
        v = Vocabulary(g; base=BASE)
        @test v.graph isa Graph
        @test v.base  == BASE
    end

    # ── String indexing ────────────────────────────────────────────────────────
    @testset "getindex — local name" begin
        v = Vocabulary(g; base=BASE)
        @test v["Foo"] == IRI("$(BASE)Foo")
        @test v["Bar"] == IRI("$(BASE)Bar")
    end

    @testset "getindex — full IRI passthrough" begin
        v = Vocabulary(g; base=BASE)
        full = "$(BASE)Foo"
        @test v[full] == IRI(full)
        # Even for IRIs not in the vocab
        @test v["http://other.org/term"] == IRI("http://other.org/term")
    end

    @testset "getindex — unknown local name falls back to base" begin
        v = Vocabulary(g; base=BASE)
        @test v["NewTerm"] == IRI("$(BASE)NewTerm")
    end

    @testset "getindex — no base, unknown key raises KeyError" begin
        v = Vocabulary(g)
        @test_throws KeyError v["NonExistent"]
    end

    # ── terms() enumeration ───────────────────────────────────────────────────
    @testset "terms" begin
        v  = Vocabulary(g; base=BASE)
        ts = collect(terms(v))
        @test length(ts) == 3
        @test IRI("$(BASE)Foo")    in ts
        @test IRI("$(BASE)Bar")    in ts
        @test IRI("$(BASE)hasFoo") in ts
    end

    # ── label() ────────────────────────────────────────────────────────────────
    @testset "label — language-matched" begin
        v = Vocabulary(g; base=BASE)
        @test label(v, v.Foo) == "Foo thing"
    end

    @testset "label — alternate language" begin
        v = Vocabulary(g; base=BASE)
        @test label(v, v.Foo; lang="es") == "Cosa Foo"
    end

    @testset "label — plain literal fallback" begin
        v = Vocabulary(g; base=BASE)
        @test label(v, v.Bar) == "Bar thing"
    end

    @testset "label — no label returns nothing" begin
        v = Vocabulary(g; base=BASE)
        @test label(v, v.hasFoo) === nothing
    end

    @testset "label — IRI not in vocab returns nothing" begin
        v = Vocabulary(g; base=BASE)
        @test label(v, IRI("http://nowhere.example/X")) === nothing
    end

    # ── comment() ─────────────────────────────────────────────────────────────
    @testset "comment — found" begin
        v = Vocabulary(g; base=BASE)
        @test comment(v, v.Foo) == "A description of Foo"
    end

    @testset "comment — missing returns nothing" begin
        v = Vocabulary(g; base=BASE)
        @test comment(v, v.Bar)    === nothing
        @test comment(v, v.hasFoo) === nothing
    end

    # ── propertynames ─────────────────────────────────────────────────────────
    @testset "propertynames" begin
        v = Vocabulary(g; base=BASE)
        pn = propertynames(v)
        @test :graph in pn
        @test :base  in pn
        @test :Foo   in pn
        @test :Bar   in pn
    end

    # ── show ──────────────────────────────────────────────────────────────────
    @testset "show with base" begin
        v = Vocabulary(g; base=BASE)
        s = sprint(show, v)
        @test occursin("http://example.org/vocab/", s)
        @test occursin("3 terms", s)
    end

    @testset "show without base" begin
        v = Vocabulary(g)
        s = sprint(show, v)
        @test occursin("3 terms", s)
    end

    @testset "show singular" begin
        g2 = Graph()
        ns = Namespace("http://example.org/vocab/")
        push!(g2, Triple(ns.Solo, _V_RDF_TYPE, _V_RDFS_CLASS))
        v = Vocabulary(g2; base="http://example.org/vocab/")
        @test occursin("1 term", sprint(show, v))
        @test !occursin("1 terms", sprint(show, v))
    end

    # ── load_vocabulary from local Turtle file ─────────────────────────────────
    @testset "load_vocabulary — Turtle file" begin
        ttl = """
        @prefix ex:   <http://example.org/vocab/> .
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
        @prefix rdf:  <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .

        ex:Widget a rdfs:Class ;
            rdfs:label   "Widget"@en ;
            rdfs:comment "A widget resource"@en .

        ex:name a rdf:Property .
        """
        tmp = tempname() * ".ttl"
        write(tmp, ttl)
        try
            v = load_vocabulary(tmp; base="http://example.org/vocab/")
            @test v isa Vocabulary
            @test v.Widget == IRI("http://example.org/vocab/Widget")
            @test v.name   == IRI("http://example.org/vocab/name")
            @test label(v, v.Widget)   == "Widget"
            @test comment(v, v.Widget) == "A widget resource"
            @test comment(v, v.name)   === nothing
        finally
            rm(tmp; force=true)
        end
    end

    @testset "load_vocabulary — N-Triples file" begin
        nt = """
        <http://example.org/vocab/Alpha> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/2000/01/rdf-schema#Class> .
        <http://example.org/vocab/Alpha> <http://www.w3.org/2000/01/rdf-schema#label> "Alpha"@en .
        """
        tmp = tempname() * ".nt"
        write(tmp, nt)
        try
            v = load_vocabulary(tmp; base="http://example.org/vocab/")
            @test v.Alpha == IRI("http://example.org/vocab/Alpha")
            @test label(v, v.Alpha) == "Alpha"
        finally
            rm(tmp; force=true)
        end
    end

    @testset "load_vocabulary — unknown extension raises ArgumentError" begin
        tmp = tempname() * ".rdf2"
        write(tmp, "")
        try
            @test_throws ArgumentError load_vocabulary(tmp)
        finally
            rm(tmp; force=true)
        end
    end

    @testset "load_vocabulary — URL without HTTP.jl raises error" begin
        @test_throws ErrorException load_vocabulary("https://example.org/vocab.ttl")
    end

    # ── Fragment-IRI local name extraction ─────────────────────────────────────
    @testset "local name via fragment (#)" begin
        # IRIs with # delimiter (OWL-style)
        g2 = Graph()
        ns = Namespace("http://example.org/onto#")
        push!(g2, Triple(IRI("http://example.org/onto#Thing"),
                         _V_RDF_TYPE, _V_RDFS_CLASS))
        v = Vocabulary(g2)
        @test v.Thing == IRI("http://example.org/onto#Thing")
    end

    # ── Mixed-namespace graph without base ────────────────────────────────────
    @testset "no base — indexes all subject IRIs" begin
        g2 = Graph()
        push!(g2, Triple(IRI("http://a.org/A"), _V_RDF_TYPE, _V_RDFS_CLASS))
        push!(g2, Triple(IRI("http://b.org/B"), _V_RDF_TYPE, _V_RDFS_CLASS))
        v = Vocabulary(g2)
        @test v.A == IRI("http://a.org/A")
        @test v.B == IRI("http://b.org/B")
    end

end
