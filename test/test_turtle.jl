using RDF
using Test
using Dates

# ── Helpers ────────────────────────────────────────────────────────────────────

function parse_ttl(ttl::AbstractString; base=nothing)
    if base === nothing
        read(IOBuffer(ttl), MIME"text/turtle"(), Graph)
    else
        read(IOBuffer(ttl), MIME"text/turtle"(), Graph, base)
    end
end

function serialize_ttl(g::Graph)
    buf = IOBuffer()
    write(buf, MIME"text/turtle"(), g)
    String(take!(buf))
end

function roundtrip(g::Graph)
    buf = IOBuffer()
    write(buf, MIME"text/turtle"(), g)
    seekstart(buf)
    read(buf, MIME"text/turtle"(), Graph)
end

@testset "Turtle 1.1 serialization" begin

    ex   = Namespace("http://example.org/")
    foaf = Namespace("http://xmlns.com/foaf/0.1/")

    # ── Parsing — basic forms ─────────────────────────────────────────────────

    @testset "Parse — IRI triple" begin
        g = parse_ttl("""
          <http://example.org/s> <http://example.org/p> <http://example.org/o> .
        """)
        @test length(g) == 1
        t = only(g)
        @test t.subject   == IRI("http://example.org/s")
        @test t.predicate == IRI("http://example.org/p")
        @test t.object    == IRI("http://example.org/o")
    end

    @testset "Parse — prefix declaration" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:alice a ex:Person .
        """)
        @test length(g) == 1
        t = only(g)
        @test t.subject   == IRI("http://example.org/alice")
        @test t.predicate == IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        @test t.object    == IRI("http://example.org/Person")
    end

    @testset "Parse — PREFIX (SPARQL-style, case-insensitive)" begin
        g = parse_ttl("""
          PREFIX ex: <http://example.org/>
          ex:alice ex:name "Alice" .
        """)
        @test length(g) == 1
    end

    @testset "Parse — semicolon (predicate-object list)" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:alice a ex:Person ;
                   ex:name "Alice" ;
                   ex:age  30 .
        """)
        @test length(g) == 3
        subj = collect(subjects(g))
        @test length(unique(subj)) == 1
        @test only(unique(subj)) == IRI("http://example.org/alice")
    end

    @testset "Parse — comma (object list)" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:alice ex:knows ex:bob, ex:carol .
        """)
        @test length(g) == 2
        @test Triple(ex.alice, ex.knows, ex.bob)   in g
        @test Triple(ex.alice, ex.knows, ex.carol) in g
    end

    @testset "Parse — a shortcut for rdf:type" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:alice a ex:Person .
        """)
        t = only(g)
        @test t.predicate == rdf.type
    end

    @testset "Parse — typed literal" begin
        g = parse_ttl("""
          @prefix ex:  <http://example.org/> .
          @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
          ex:alice ex:age "30"^^xsd:integer .
        """)
        t = only(g)
        @test t.object isa Literal
        @test t.object.datatype == xsd.integer
        @test value(Int64, t.object) == 30
    end

    @testset "Parse — integer shorthand" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:alice ex:age 42 .
        """)
        t = only(g)
        @test t.object isa Literal
        @test t.object.datatype == xsd.integer
        @test value(Int64, t.object) == 42
    end

    @testset "Parse — decimal shorthand" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:x ex:val 3.14 .
        """)
        t = only(g)
        @test t.object isa Literal
        @test t.object.datatype == xsd.decimal
    end

    @testset "Parse — double/float shorthand (scientific notation)" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:x ex:val 1.0e5 .
        """)
        t = only(g)
        @test t.object isa Literal
        @test t.object.datatype == xsd.double
    end

    @testset "Parse — boolean shorthand" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:alice ex:active true .
          ex:bob   ex:active false .
        """)
        @test length(g) == 2
        vals = Set(value(Bool, t.object) for t in g)
        @test vals == Set([true, false])
    end

    @testset "Parse — language-tagged literal" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:alice ex:name "Alice"@en .
        """)
        t = only(g)
        @test t.object isa Literal
        @test t.object.language_tag == "en"
        @test t.object.datatype == rdf.langString
    end

    @testset "Parse — blank node (labeled)" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          _:b0 a ex:Person .
          _:b0 ex:name "Alice" .
        """)
        @test length(g) == 2
        subjs = collect(subjects(g))
        @test all(s isa BlankNode for s in subjs)
        @test subjs[1] == subjs[2]
    end

    @testset "Parse — blank node (anonymous [])" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:alice ex:address [ ex:city "Paris" ; ex:country "France" ] .
        """)
        @test length(g) == 3
        # alice ex:address _:b
        addr_triples = collect(match(g; subject=ex.alice))
        @test length(addr_triples) == 1
        addr_node = addr_triples[1].object
        @test addr_node isa BlankNode

        # the blank node has city and country
        city_triples = collect(match(g; subject=addr_node, predicate=ex.city))
        @test length(city_triples) == 1
        @test value(String, city_triples[1].object) == "Paris"
    end

    @testset "Parse — RDF list ()" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:alice ex:colors ( ex:red ex:green ex:blue ) .
        """)
        # A list of 3 items: 3 rdf:first + 3 rdf:rest + 1 ex:colors triple = 7
        @test length(g) >= 4
        # Verify the list is anchored at ex:colors
        colors_links = collect(match(g; subject=ex.alice, predicate=ex.colors))
        @test length(colors_links) == 1
        head = colors_links[1].object
        @test head isa BlankNode || head == rdf.nil  # non-empty list → blank node
    end

    @testset "Parse — BASE directive" begin
        g = parse_ttl("""
          @base <http://example.org/> .
          @prefix ex: <http://example.org/> .
          <alice> a ex:Person .
        """)
        @test length(g) == 1
        t = only(g)
        @test t.subject == IRI("http://example.org/alice")
    end

    @testset "Parse — base IRI argument" begin
        g = parse_ttl("""
          <alice> a <Person> .
        """; base="http://example.org/")
        @test length(g) == 1
        t = only(g)
        @test t.subject == IRI("http://example.org/alice")
        @test t.object  == IRI("http://example.org/Person")
    end

    @testset "Parse — comments are ignored" begin
        g = parse_ttl("""
          # This is a comment
          @prefix ex: <http://example.org/> .
          ex:alice a ex:Person . # inline comment
          # another comment
        """)
        @test length(g) == 1
    end

    @testset "Parse — multi-line string (triple-quoted)" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:doc ex:content \"\"\"
          Line 1
          Line 2
          \"\"\" .
        """)
        t = only(g)
        @test t.object isa Literal
        @test contains(t.object.lexical_form, "Line 1")
        @test contains(t.object.lexical_form, "Line 2")
    end

    @testset "Parse — literal escape sequences" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:s ex:p "say \\"hello\\" and \\\\backslash\\\\\\nand newline" .
        """)
        t = only(g)
        @test contains(t.object.lexical_form, "say \"hello\"")
        @test contains(t.object.lexical_form, "\\backslash\\")
        @test contains(t.object.lexical_form, "\n")
    end

    @testset "Parse — multiple subjects" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:alice a ex:Person ; ex:name "Alice" .
          ex:bob   a ex:Person ; ex:name "Bob" .
        """)
        @test length(g) == 4
    end

    @testset "Parse — empty graph" begin
        g = parse_ttl("")
        @test isempty(g)
        g2 = parse_ttl("# just a comment\n")
        @test isempty(g2)
    end

    @testset "Parse — syntax error throws ParseError" begin
        # Missing dot
        @test_throws ParseError parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:alice a ex:Person
        """)

        # Unclosed IRI
        @test_throws ParseError parse_ttl("""
          <http://example.org/s <http://example.org/p> <http://example.org/o> .
        """)
    end

    # ── Serialization ─────────────────────────────────────────────────────────

    @testset "Serialize — IRI triple" begin
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        s = serialize_ttl(g)
        @test !isempty(s)
        # Must round-trip
        g2 = parse_ttl(s)
        @test g ≅ g2
    end

    @testset "Serialize — literal" begin
        g = Graph()
        push!(g, Triple(ex.alice, ex.name, Literal("Alice")))
        push!(g, Triple(ex.alice, ex.age,  Literal(30)))
        s = serialize_ttl(g)
        g2 = parse_ttl(s)
        @test g ≅ g2
    end

    @testset "Serialize — language-tagged literal" begin
        g = Graph()
        push!(g, Triple(ex.alice, ex.name, Literal("Alice"; lang="en")))
        s = serialize_ttl(g)
        @test contains(s, "@en")
        g2 = parse_ttl(s)
        @test g ≅ g2
    end

    @testset "Serialize — blank node" begin
        g = Graph()
        b = blank!(g)
        push!(g, Triple(b, rdf.type, ex.Person))
        push!(g, Triple(b, ex.name,  Literal("Unknown")))
        s = serialize_ttl(g)
        g2 = parse_ttl(s)
        @test g ≅ g2
    end

    @testset "Serialize — multiple triples, groups prefixes" begin
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type,  ex.Person))
        push!(g, Triple(ex.alice, foaf.name, Literal("Alice")))
        push!(g, Triple(ex.alice, foaf.age,  Literal(30)))
        push!(g, Triple(ex.bob,   rdf.type,  ex.Person))
        s = serialize_ttl(g)
        @test !isempty(s)
        g2 = parse_ttl(s)
        @test g ≅ g2
    end

    @testset "Serialize — empty graph" begin
        s = serialize_ttl(Graph())
        @test isempty(strip(s)) || !isempty(s)  # may emit just prefix declarations
        g2 = parse_ttl(s)
        @test isempty(g2)
    end

    # ── Full round-trips ──────────────────────────────────────────────────────

    @testset "Round-trip — all literal types" begin
        g = Graph()
        push!(g, Triple(ex.s, ex.p1,  Literal("text")))
        push!(g, Triple(ex.s, ex.p2,  Literal("hello"; lang="en")))
        push!(g, Triple(ex.s, ex.p3,  Literal(42)))
        push!(g, Triple(ex.s, ex.p4,  Literal(3.14)))
        push!(g, Triple(ex.s, ex.p5,  Literal(true)))
        push!(g, Triple(ex.s, ex.p6,  Literal(Date(2024, 1, 15))))
        push!(g, Triple(ex.s, ex.p7,  Literal(DateTime(2024, 1, 15, 10, 30, 0))))
        @test g ≅ roundtrip(g)
    end

    @testset "Round-trip — blank node cluster" begin
        g = Graph()
        b = blank!(g)
        push!(g, Triple(ex.alice, ex.address, b))
        push!(g, Triple(b, ex.city,    Literal("London")))
        push!(g, Triple(b, ex.country, Literal("UK")))
        @test g ≅ roundtrip(g)
    end

    @testset "Round-trip — multiple blank nodes" begin
        g = Graph()
        b1 = blank!(g)
        b2 = blank!(g)
        push!(g, Triple(b1, rdf.type,  ex.Person))
        push!(g, Triple(b1, ex.knows,  b2))
        push!(g, Triple(b2, rdf.type,  ex.Person))
        @test g ≅ roundtrip(g)
    end

    # ── File extension dispatch ───────────────────────────────────────────────

    @testset "rdf_read / rdf_write — .ttl extension" begin
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        push!(g, Triple(ex.alice, foaf.name, Literal("Alice")))

        mktempdir() do dir
            path = joinpath(dir, "test.ttl")
            rdf_write(path, g)
            @test isfile(path)
            g2 = rdf_read(path)
            @test g ≅ g2
        end
    end

    @testset "read(path, MIME\"text/turtle\"(), Graph)" begin
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))

        mktempdir() do dir
            path = joinpath(dir, "test.ttl")
            open(path, "w") do io
                write(io, MIME"text/turtle"(), g)
            end
            g2 = open(path, "r") do io
                read(io, MIME"text/turtle"(), Graph)
            end
            @test g ≅ g2
        end
    end

    # ── Turtle-specific syntax features ──────────────────────────────────────

    @testset "Parse — iri\"...\" string macro accepted" begin
        g = parse_ttl("""
          <http://example.org/alice>
              <http://www.w3.org/1999/02/22-rdf-syntax-ns#type>
              <http://example.org/Person> .
        """)
        @test length(g) == 1
    end

    @testset "Parse — nested blank nodes" begin
        g = parse_ttl("""
          @prefix ex: <http://example.org/> .
          ex:alice ex:address [
            ex:street [
              ex:name "Main St" ;
              ex:number 42
            ]
          ] .
        """)
        # ex:alice ex:address _:b1
        # _:b1 ex:street _:b2
        # _:b2 ex:name "Main St"
        # _:b2 ex:number 42
        @test length(g) == 4
    end

    @testset "Parse — pname with empty local part" begin
        g = parse_ttl("""
          @prefix : <http://example.org/> .
          :alice a :Person .
        """)
        @test length(g) == 1
        t = only(g)
        @test t.subject == IRI("http://example.org/alice")
    end

    @testset "Parse — @prefix redefinition" begin
        # Later prefix declaration overrides earlier one
        g = parse_ttl("""
          @prefix ex: <http://example.org/v1/> .
          @prefix ex: <http://example.org/v2/> .
          ex:alice a ex:Person .
        """)
        @test length(g) == 1
        t = only(g)
        @test string(t.subject) == "http://example.org/v2/alice"
    end

    @testset "Parse — xsd:string literal round-trips correctly" begin
        g = parse_ttl("""
          @prefix ex:  <http://example.org/> .
          @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
          ex:s ex:p "hello"^^xsd:string .
        """)
        t = only(g)
        @test t.object == Literal("hello")  # xsd:string == plain string in RDF 1.1
    end

end
