using Test
using RDF
import JSON

const _JLD_MIME = MIME"application/ld+json"()

# ── Helpers ───────────────────────────────────────────────────────────────────

function roundtrip_graph(g::Graph)::Graph
    buf = IOBuffer()
    Base.write(buf, _JLD_MIME, g)
    seekstart(buf)
    Base.read(buf, _JLD_MIME, Graph)
end

function parse_jsonld_graph(json::String)::Graph
    buf = IOBuffer(json)
    Base.read(buf, _JLD_MIME, Graph)
end

function parse_jsonld_dataset(json::String)::Dataset
    buf = IOBuffer(json)
    Base.read(buf, _JLD_MIME, Dataset)
end

function serialize_graph(g::Graph; context=nothing)::String
    buf = IOBuffer()
    Base.write(buf, _JLD_MIME, g; context=context)
    String(take!(buf))
end

function serialize_dataset(ds::Dataset; context=nothing)::String
    buf = IOBuffer()
    Base.write(buf, _JLD_MIME, ds; context=context)
    String(take!(buf))
end

@testset "JSON-LD" begin

    # ── 1. Round-trip: write → read → equal ──────────────────────────────────
    @testset "Round-trip Graph" begin
        ex = "http://example.org/"
        g = Graph()
        push!(g, Triple(IRI(ex*"alice"), IRI(ex*"name"), Literal("Alice")))
        push!(g, Triple(IRI(ex*"alice"), IRI(ex*"age"),  Literal("30", IRI("http://www.w3.org/2001/XMLSchema#integer"))))
        push!(g, Triple(IRI(ex*"alice"), IRI(ex*"knows"), IRI(ex*"bob")))

        g2 = roundtrip_graph(g)
        @test length(g2) == length(g)
        for t in g
            @test t in g2
        end
    end

    # ── 2. Parse @context with prefix expansion ───────────────────────────────
    @testset "Prefix expansion" begin
        json = """
        {
          "@context": {
            "ex":   "http://example.org/",
            "name": {"@id": "http://example.org/name"}
          },
          "@id": "ex:alice",
          "name": "Alice"
        }
        """
        g = parse_jsonld_graph(json)
        @test any(t -> t.subject == IRI("http://example.org/alice") &&
                       t.predicate == IRI("http://example.org/name") &&
                       t.object == Literal("Alice"),
                  g)
    end

    # ── 3. @type shorthand ────────────────────────────────────────────────────
    @testset "Parse @type" begin
        json = """
        {
          "@context": {"ex": "http://example.org/"},
          "@id": "ex:alice",
          "@type": "ex:Person"
        }
        """
        g = parse_jsonld_graph(json)
        rdf_type = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        @test any(t -> t.subject   == IRI("http://example.org/alice") &&
                       t.predicate == rdf_type &&
                       t.object    == IRI("http://example.org/Person"),
                  g)
    end

    # ── 4. Language-tagged literals ───────────────────────────────────────────
    @testset "Language-tagged literals" begin
        json = """
        {
          "@context": {"ex": "http://example.org/"},
          "@id": "ex:item",
          "ex:label": {"@value": "Hello", "@language": "en"}
        }
        """
        g = parse_jsonld_graph(json)
        expected = Literal("Hello"; lang="en")
        @test any(t -> t.object == expected, g)
    end

    # ── 5. Typed literals ─────────────────────────────────────────────────────
    @testset "Typed literals" begin
        json = """
        {
          "@context": {"ex": "http://example.org/"},
          "@id": "ex:item",
          "ex:value": {"@value": "42", "@type": "http://www.w3.org/2001/XMLSchema#integer"}
        }
        """
        g = parse_jsonld_graph(json)
        xsd_int = IRI("http://www.w3.org/2001/XMLSchema#integer")
        @test any(t -> t.object isa Literal &&
                       (t.object::Literal).lexical_form == "42" &&
                       (t.object::Literal).datatype == xsd_int,
                  g)
    end

    # ── 6. Nested objects (blank nodes) ───────────────────────────────────────
    @testset "Nested objects / blank node generation" begin
        json = """
        {
          "@context": {"ex": "http://example.org/"},
          "@id": "ex:alice",
          "ex:address": {
            "ex:city": "Wonderland"
          }
        }
        """
        g = parse_jsonld_graph(json)
        # There should be a triple ex:alice ex:address _:some_blank
        # and a triple _:some_blank ex:city "Wonderland"
        ex_address = IRI("http://example.org/address")
        ex_city    = IRI("http://example.org/city")
        alice      = IRI("http://example.org/alice")

        addr_triples = [t for t in g if t.subject == alice && t.predicate == ex_address]
        @test length(addr_triples) == 1
        blank = addr_triples[1].object
        @test blank isa BlankNode

        city_triples = [t for t in g if t.subject == blank && t.predicate == ex_city]
        @test length(city_triples) == 1
        @test city_triples[1].object == Literal("Wonderland")
    end

    # ── 7. Named graphs with @graph ───────────────────────────────────────────
    @testset "Named graphs" begin
        json = """
        [
          {
            "@id": "http://example.org/graph1",
            "@graph": [
              {
                "@id": "http://example.org/alice",
                "http://example.org/name": [{"@value": "Alice"}]
              }
            ]
          }
        ]
        """
        ds = parse_jsonld_dataset(json)
        g1_iri = IRI("http://example.org/graph1")
        @test haskey(ds, g1_iri)
        g1 = ds[g1_iri]
        @test any(t -> t.subject == IRI("http://example.org/alice") &&
                       t.object  == Literal("Alice"),
                  g1)
    end

    # ── 8. Serialize Graph with IRIs, blank nodes, literals ───────────────────
    @testset "Serialization" begin
        ex = "http://example.org/"
        g = Graph()
        bn = blank!(g)
        push!(g, Triple(IRI(ex*"doc"), IRI(ex*"creator"), bn))
        push!(g, Triple(bn, IRI(ex*"name"), Literal("Unknown")))
        push!(g, Triple(IRI(ex*"doc"), IRI(ex*"title"),
                        Literal("My Doc"; lang="en")))

        s = serialize_graph(g)
        @test occursin("application/ld", _JLD_MIME |> string)
        # Re-parse and verify
        g2 = parse_jsonld_graph(s)
        @test length(g2) == 3
    end

    # ── 9. Serialize with context ─────────────────────────────────────────────
    @testset "Serialize with context" begin
        ex = "http://example.org/"
        g = Graph()
        push!(g, Triple(IRI(ex*"alice"), IRI(ex*"name"), Literal("Alice")))

        ctx = Dict("ex" => "http://example.org/")
        s = serialize_graph(g; context=ctx)
        @test occursin("@context", s)
        @test occursin("ex", s)
    end

    # ── 10. Top-level array ───────────────────────────────────────────────────
    @testset "Top-level array" begin
        json = """
        [
          {
            "@context": {"ex": "http://example.org/"},
            "@id": "ex:a",
            "ex:prop": [{"@value": "val1"}]
          },
          {
            "@context": {"ex": "http://example.org/"},
            "@id": "ex:b",
            "ex:prop": [{"@value": "val2"}]
          }
        ]
        """
        g = parse_jsonld_graph(json)
        @test any(t -> t.subject == IRI("http://example.org/a") &&
                       t.object  == Literal("val1"), g)
        @test any(t -> t.subject == IRI("http://example.org/b") &&
                       t.object  == Literal("val2"), g)
    end

    # ── 11. @vocab default vocabulary ────────────────────────────────────────
    @testset "@vocab" begin
        json = """
        {
          "@context": {
            "@vocab": "http://schema.org/"
          },
          "@id": "http://example.org/alice",
          "name": "Alice"
        }
        """
        g = parse_jsonld_graph(json)
        schema_name = IRI("http://schema.org/name")
        @test any(t -> t.predicate == schema_name &&
                       t.object    == Literal("Alice"), g)
    end

    # ── 12. @language default ────────────────────────────────────────────────
    @testset "@language default" begin
        json = """
        {
          "@context": {
            "ex": "http://example.org/",
            "@language": "fr"
          },
          "@id": "ex:item",
          "ex:label": "Bonjour"
        }
        """
        g = parse_jsonld_graph(json)
        expected = Literal("Bonjour"; lang="fr")
        @test any(t -> t.object == expected, g)
    end

    # ── 13. Boolean and numeric values ───────────────────────────────────────
    @testset "Boolean and numeric values" begin
        json = """
        {
          "@context": {"ex": "http://example.org/"},
          "@id": "ex:item",
          "ex:active":  {"@value": true,  "@type": "http://www.w3.org/2001/XMLSchema#boolean"},
          "ex:count":   {"@value": 7,     "@type": "http://www.w3.org/2001/XMLSchema#integer"}
        }
        """
        g = parse_jsonld_graph(json)
        xsd_bool = IRI("http://www.w3.org/2001/XMLSchema#boolean")
        xsd_int  = IRI("http://www.w3.org/2001/XMLSchema#integer")
        @test any(t -> t.object isa Literal &&
                       (t.object::Literal).datatype == xsd_bool, g)
        @test any(t -> t.object isa Literal &&
                       (t.object::Literal).datatype == xsd_int &&
                       (t.object::Literal).lexical_form == "7", g)
    end

    # ── 14. Remote context throws ParseError ─────────────────────────────────
    @testset "Remote context rejected" begin
        json = """{"@context": "https://schema.org/", "@id": "http://example.org/x"}"""
        @test_throws ParseError parse_jsonld_graph(json)
    end

    # ── 15. Dataset round-trip ────────────────────────────────────────────────
    @testset "Dataset round-trip" begin
        ex = "http://example.org/"
        ds = Dataset()
        g1 = Graph()
        push!(g1, Triple(IRI(ex*"s"), IRI(ex*"p"), Literal("val")))
        ds[IRI(ex*"g1")] = g1

        s  = serialize_dataset(ds)
        ds2 = parse_jsonld_dataset(s)

        @test haskey(ds2, IRI(ex*"g1"))
        g1b = ds2[IRI(ex*"g1")]
        @test any(t -> t.object == Literal("val"), g1b)
    end

    # ── 16. rdf_read / rdf_write file extension dispatch ─────────────────────
    @testset "File extension dispatch" begin
        ex = "http://example.org/"
        g = Graph()
        push!(g, Triple(IRI(ex*"x"), IRI(ex*"y"), Literal("z")))

        tmp = tempname() * ".jsonld"
        try
            rdf_write(tmp, g)
            result = rdf_read(tmp)
            @test result isa Dataset
            ds = result::Dataset
            # All triples land in default graph or named graphs
            all_triples = collect(ds.default_graph)
            for (_, ng) in ds.named_graphs
                append!(all_triples, collect(ng))
            end
            @test any(t -> t.object == Literal("z"), all_triples)
        finally
            isfile(tmp) && rm(tmp)
        end
    end

end # @testset "JSON-LD"

@testset "JSON-LD context-compilation cache" begin
    mime = MIME"application/ld+json"()
    exp  = Triple(IRI("http://x/1"), IRI("https://purl.org/ctdl/terms/name"), Literal("hi"))

    # A large CTDL-style inline context as a JSON string.
    big_ctx_json(n) = "{" * join(vcat(
        ["\"ceterms\":\"https://purl.org/ctdl/terms/\""],
        ["\"term$i\":\"https://purl.org/ctdl/terms/term$i\"" for i in 1:n]), ",") * "}"

    # ── Inline context: identical content across reads must hit the cache ────────
    RDF._jsonld_ctx_cache_reset!()
    ctxj = big_ctx_json(200)
    doc  = "{\"@context\":$ctxj,\"@id\":\"http://x/1\",\"ceterms:name\":\"hi\"}"
    g1 = read(IOBuffer(doc), mime, Graph)
    g2 = read(IOBuffer(doc), mime, Graph)
    g3 = read(IOBuffer(doc), mime, Graph)
    h, m = RDF._jsonld_ctx_cache_stats()
    @test m >= 1                       # first read compiled the context
    @test h >= 2                       # subsequent reads reused it
    @test exp in g1 && exp in g2 && exp in g3
    @test isomorphic(g1, g2)

    # ── A different context must NOT get a stale hit ─────────────────────────────
    RDF._jsonld_ctx_cache_reset!()
    docA = "{\"@context\":{\"a\":\"http://a/\"},\"@id\":\"http://x/1\",\"a:p\":\"v\"}"
    docB = "{\"@context\":{\"a\":\"http://b/\"},\"@id\":\"http://x/1\",\"a:p\":\"v\"}"
    gA = read(IOBuffer(docA), mime, Graph)
    gB = read(IOBuffer(docB), mime, Graph)
    @test Triple(IRI("http://x/1"), IRI("http://a/p"), Literal("v")) in gA
    @test Triple(IRI("http://x/1"), IRI("http://b/p"), Literal("v")) in gB
    @test !(Triple(IRI("http://x/1"), IRI("http://a/p"), Literal("v")) in gB)

    # ── URL-referenced context: hits via the stable loader-returned object ───────
    RDF._jsonld_ctx_cache_reset!()
    ctxobj   = JSON.parse(ctxj)                       # one stable object, reused
    contexts = Dict("http://ctx.example/c" => ctxobj)
    refdoc = "{\"@context\":\"http://ctx.example/c\",\"@id\":\"http://x/1\",\"ceterms:name\":\"hi\"}"
    r1 = read(IOBuffer(refdoc), mime, Graph; contexts=contexts)
    r2 = read(IOBuffer(refdoc), mime, Graph; contexts=contexts)
    r3 = read(IOBuffer(refdoc), mime, Graph; contexts=contexts)
    h2, m2 = RDF._jsonld_ctx_cache_stats()
    @test m2 >= 1
    @test h2 >= 2
    @test exp in r1 && exp in r2 && exp in r3

    # ── Equivalence: a never-cached (fresh) compile yields the same graph ────────
    RDF._jsonld_ctx_cache_reset!()
    fresh = read(IOBuffer(doc), mime, Graph)
    @test isomorphic(fresh, g1)

    # ── A context that sets @base must survive cache hits (base not clobbered) ───
    RDF._jsonld_ctx_cache_reset!()
    bdoc = "{\"@context\":{\"@base\":\"http://base.example/\",\"p\":\"http://p/\"}," *
           "\"@id\":\"rel\",\"p:x\":\"v\"}"
    b1 = read(IOBuffer(bdoc), mime, Graph)     # miss
    b2 = read(IOBuffer(bdoc), mime, Graph)     # hit — must keep the context's @base
    b3 = read(IOBuffer(bdoc), mime, Graph)     # hit
    expb = Triple(IRI("http://base.example/rel"), IRI("http://p/x"), Literal("v"))
    @test expb in b1
    @test expb in b2
    @test expb in b3
    @test isomorphic(b1, b2) && isomorphic(b1, b3)

    # ── @type:@id coercion (uses the term-by-@id index) must survive cache reuse ──
    RDF._jsonld_ctx_cache_reset!()
    lctx  = Dict("e" => "http://e/",
                 "link" => Dict("@id" => "http://e/link", "@type" => "@id"))
    lcontexts = Dict("http://ctx/link" => lctx)
    ldoc = "{\"@context\":\"http://ctx/link\",\"@id\":\"http://x/1\"," *
           "\"link\":\"http://target/\"}"
    l1 = read(IOBuffer(ldoc), mime, Graph; contexts=lcontexts)   # miss
    l2 = read(IOBuffer(ldoc), mime, Graph; contexts=lcontexts)   # hit
    # @type:@id coerces the string value to an IRI object, not a literal
    expl = Triple(IRI("http://x/1"), IRI("http://e/link"), IRI("http://target/"))
    @test expl in l1
    @test expl in l2
    @test isomorphic(l1, l2)

    # ── Shared context OBJECT reuse (expandcontext) skips rehash, still correct ──
    RDF._jsonld_ctx_cache_reset!()
    shared = Dict{String,Any}("q" => "http://q/")
    xdoc   = "{\"@id\":\"http://x/1\",\"q:v\":\"w\"}"
    x1 = read(IOBuffer(xdoc), mime, Graph; expandcontext=shared)
    x2 = read(IOBuffer(xdoc), mime, Graph; expandcontext=shared)
    hx, mx = RDF._jsonld_ctx_cache_stats()
    @test hx >= 1                       # second read reused the compiled context
    expq = Triple(IRI("http://x/1"), IRI("http://q/v"), Literal("w"))
    @test expq in x1 && expq in x2

    # ── Reordered-but-equal inline contexts stay CORRECT (hit or recompile) ──────
    RDF._jsonld_ctx_cache_reset!()
    d1 = "{\"@context\":{\"a\":\"http://a/\",\"b\":\"http://b/\"},\"@id\":\"http://x/1\",\"a:p\":\"v\"}"
    d2 = "{\"@context\":{\"b\":\"http://b/\",\"a\":\"http://a/\"},\"@id\":\"http://x/1\",\"a:p\":\"v\"}"
    o1 = read(IOBuffer(d1), mime, Graph)
    o2 = read(IOBuffer(d2), mime, Graph)
    @test isomorphic(o1, o2)            # never a stale/wrong hit

    # ── _ordered_json_eq: O(n) verify semantics ─────────────────────────────────
    p1 = JSON.parse("{\"x\":{\"y\":[1,2]},\"z\":\"s\"}")
    p2 = JSON.parse("{\"x\":{\"y\":[1,2]},\"z\":\"s\"}")
    p3 = JSON.parse("{\"x\":{\"y\":[1,3]},\"z\":\"s\"}")
    @test RDF._ordered_json_eq(p1, p2)
    @test !RDF._ordered_json_eq(p1, p3)
end

  @testset "JSON-LD remote context cache" begin
    mime = MIME"application/ld+json"()
    document = """{"@context":"https://contexts.example/schema","@id":"http://example.org/x","ex:name":"Alice"}"""
    expected = Triple(IRI("http://example.org/x"), IRI("http://example.org/name"), Literal("Alice"))
    previous_loader = RDF._JSONLD_REMOTE_LOADER[]
    fetches = Ref(0)
    RDF._jsonld_remote_ctx_cache_reset!()
    RDF._JSONLD_REMOTE_LOADER[] = function (iri)
      @test iri == "https://contexts.example/schema"
      fetches[] += 1
      Dict("ex" => "http://example.org/")
    end

    try
      g1 = read(IOBuffer(document), mime, Graph; load_remote_contexts=true)
      g2 = read(IOBuffer(document), mime, Graph; load_remote_contexts=true)
      @test expected in g1 && expected in g2
      @test fetches[] == 1

      g3 = read(IOBuffer(document), mime, Graph; load_remote_contexts=true,
            remote_context_cache_ttl=0)
      @test expected in g3
      @test fetches[] == 2

      @test_throws ArgumentError read(IOBuffer(document), mime, Graph;
                       load_remote_contexts=true,
                       remote_context_cache_ttl=-1)
    finally
      RDF._JSONLD_REMOTE_LOADER[] = previous_loader
      RDF._jsonld_remote_ctx_cache_reset!()
    end
  end
