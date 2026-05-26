using RDF
using Test
using Dates

@testset "Literals" begin

    @testset "Construction from Julia types" begin
        # Integer → xsd:integer
        lit = Literal(42)
        @test lit isa Literal
        @test lit.datatype == xsd.integer
        @test lit.lexical_form == "42"
        @test lit.language_tag == ""

        @test Literal(0).datatype == xsd.integer
        @test Literal(-1).datatype == xsd.integer
        @test Literal(typemax(Int64)).datatype == xsd.integer

        # Float → xsd:double
        lit = Literal(3.14)
        @test lit.datatype == xsd.double
        @test lit isa Literal

        @test Literal(0.0).datatype == xsd.double
        @test Literal(-1.5).datatype == xsd.double
        @test Literal(Inf).datatype == xsd.double
        @test Literal(NaN).datatype == xsd.double

        # Float32 → xsd:float
        @test Literal(Float32(3.14)).datatype == xsd.float

        # Bool → xsd:boolean
        @test Literal(true).datatype == xsd.boolean
        @test Literal(true).lexical_form == "true"
        @test Literal(false).lexical_form == "false"

        # String → xsd:string
        lit = Literal("hello")
        @test lit.datatype == xsd.string
        @test lit.lexical_form == "hello"

        @test Literal("").datatype == xsd.string
        @test Literal("unicode: \u00e9").datatype == xsd.string

        # Date → xsd:date
        @test Literal(Date(2024, 1, 15)).datatype == xsd.date
        @test Literal(Date(2024, 1, 15)).lexical_form == "2024-01-15"

        # DateTime → xsd:dateTime
        @test Literal(DateTime(2024, 1, 15, 10, 30, 0)).datatype == xsd.dateTime
    end

    @testset "Explicit typed literal construction" begin
        # Valid typed literal
        lit = Literal("42", xsd.integer)
        @test lit.lexical_form == "42"
        @test lit.datatype == xsd.integer
        @test lit.language_tag == ""

        # Non-standard lexical form — still valid (spec §3.3 MUST accept)
        lit = Literal("01", xsd.integer)
        @test lit.lexical_form == "01"
        @test lit.datatype == xsd.integer

        # Custom datatype IRI
        my_type = IRI("http://example.org/myType")
        lit = Literal("custom value", my_type)
        @test lit.datatype == my_type
    end

    @testset "Ill-typed literals MUST be accepted (spec §3.3)" begin
        # These are ill-typed but MUST NOT throw on construction
        @test Literal("notanumber", xsd.integer) isa Literal
        @test Literal("notadate", xsd.date) isa Literal
        @test Literal("notabool", xsd.boolean) isa Literal
        @test Literal("", xsd.integer) isa Literal

        # And must be storable in a graph without error
        g = Graph()
        s = IRI("http://example.org/s")
        p = IRI("http://example.org/p")
        @test_nowarn push!(g, Triple(s, p, Literal("notanumber", xsd.integer)))
    end

    @testset "Language-tagged string construction" begin
        lit = Literal("hello"; lang="en")
        @test lit.lexical_form == "hello"
        @test lit.datatype == rdf.langString
        @test lit.language_tag == "en"

        lit = Literal("hola"; lang="es")
        @test lit.language_tag == "es"

        lit = Literal("你好"; lang="zh")
        @test lit.language_tag == "zh"

        # Subtag
        lit = Literal("hello"; lang="en-US")
        @test lit.language_tag == "en-us"  # normalized to lowercase

        lit = Literal("hello"; lang="en-GB")
        @test lit.language_tag == "en-gb"

        # Language tag is always lowercased (spec §3.3 MAY; we normalize)
        lit = Literal("hello"; lang="EN")
        @test lit.language_tag == "en"

        lit = Literal("hello"; lang="ZH-HANT")
        @test lit.language_tag == "zh-hant"
    end

    @testset "Language tag invariant" begin
        # rdf:langString requires non-empty language tag
        @test_throws ArgumentError Literal("hello", rdf.langString)  # no lang tag

        # Non-langString must not have a language tag
        @test_throws ArgumentError Literal("hello"; lang="en") |>
            lit -> Literal(lit.lexical_form, xsd.string, lit.language_tag)

        # Empty language tag is not valid
        @test_throws ArgumentError Literal("hello"; lang="")
    end

    @testset "Literal term equality — lexical, not value-based (spec §3.3)" begin
        # Same lexical form, same datatype → equal
        @test Literal("42", xsd.integer) == Literal("42", xsd.integer)
        @test Literal("hello") == Literal("hello")
        @test Literal("hello"; lang="en") == Literal("hello"; lang="en")

        # Different lexical forms, same value → NOT equal (spec is explicit)
        @test Literal("1", xsd.integer) != Literal("01", xsd.integer)
        @test Literal("true", xsd.boolean) != Literal("1", xsd.boolean)
        @test Literal("1.0", xsd.decimal) != Literal("1", xsd.decimal)

        # Different datatypes → not equal
        @test Literal("42", xsd.integer) != Literal("42", xsd.string)
        @test Literal("42", xsd.integer) != Literal("42", xsd.decimal)

        # Different language tags → not equal
        @test Literal("hello"; lang="en") != Literal("hello"; lang="fr")
        @test Literal("hello"; lang="en") != Literal("hello"; lang="en-gb")

        # Literal vs IRI — never equal
        @test Literal("http://example.org/") != IRI("http://example.org/")

        # xsd:string literal vs plain string — these are the same in RDF 1.1
        # (simple literals are xsd:string)
        @test Literal("hello", xsd.string) == Literal("hello")
    end

    @testset "Literal hashing — consistent with equality" begin
        a = Literal("42", xsd.integer)
        b = Literal("42", xsd.integer)
        c = Literal("43", xsd.integer)

        @test hash(a) == hash(b)
        @test hash(a) != hash(c)

        # Usable as Dict key
        d = Dict{Literal, String}()
        d[a] = "forty-two"
        @test d[b] == "forty-two"

        # Usable in Set
        s = Set([a, b, c])
        @test length(s) == 2
    end

    @testset "Literal is a valid object term" begin
        @test Literal("hello") isa RDFTerm
        @test Literal("hello") isa ObjectTerm

        # Literals are NOT subject terms
        @test !(Literal("hello") isa SubjectTerm)
    end

    @testset "value() — coercion to Julia types" begin
        # Basic round-trips
        @test value(Literal(42)) == 42
        @test value(Literal(3.14)) ≈ 3.14
        @test value(Literal(true)) == true
        @test value(Literal(false)) == false
        @test value(Literal("hello")) == "hello"
        @test value(Literal(Date(2024, 1, 15))) == Date(2024, 1, 15)

        # Language-tagged string — returns the string without the tag
        @test value(Literal("hello"; lang="en")) == "hello"

        # Boolean lexical variants
        @test value(Literal("true", xsd.boolean)) == true
        @test value(Literal("false", xsd.boolean)) == false
        @test value(Literal("1", xsd.boolean)) == true
        @test value(Literal("0", xsd.boolean)) == false

        # Integer from explicit lexical form
        @test value(Literal("42", xsd.integer)) == 42
        @test value(Literal("-1", xsd.integer)) == -1

        # Ill-typed → throws LiteralValueError
        @test_throws LiteralValueError value(Literal("notanumber", xsd.integer))
        @test_throws LiteralValueError value(Literal("notadate", xsd.date))
        @test_throws LiteralValueError value(Literal("notabool", xsd.boolean))
    end

    @testset "value(T, lit) — type-converting form" begin
        # Same type: identity
        @test value(Int64,  Literal("42", xsd.integer)) === Int64(42)
        @test value(Float64, Literal("3.14", xsd.double)) isa Float64
        @test value(Float32, Literal("3.14", xsd.float))  isa Float32
        @test value(Bool,   Literal("true", xsd.boolean)) === true
        @test value(String, Literal("hello")) == "hello"
        @test value(Date,   Literal("2024-01-15", xsd.date)) == Date(2024, 1, 15)

        # Numeric widening via convert
        @test value(Float64, Literal(42))    === 42.0         # Int64 → Float64
        @test value(Float32, Literal(42))    === Float32(42)  # Int64 → Float32
        @test value(Float64, Literal(Float32(1.0))) === 1.0   # Float32 → Float64

        # Abstract supertypes work
        @test value(Number,       Literal(42))   == 42
        @test value(AbstractFloat, Literal(3.14)) isa AbstractFloat
        @test value(Integer,      Literal(42))   isa Integer

        # Inexact conversion throws
        @test_throws LiteralValueError value(Int64, Literal(3.14))
        @test_throws LiteralValueError value(Int8,  Literal(1000))  # overflow

        # Incompatible types throw
        @test_throws LiteralValueError value(Int64,  Literal("hello"))
        @test_throws LiteralValueError value(Float64, Literal("hello"))
        @test_throws LiteralValueError value(Int64,  Literal("notanumber", xsd.integer))
    end

    @testset "tryvalue(lit) — returns nothing on failure" begin
        @test tryvalue(Literal(42)) == 42
        @test tryvalue(Literal("notanumber", xsd.integer)) === nothing
        @test tryvalue(Literal("notadate", xsd.date)) === nothing
        @test tryvalue(Literal("hello")) == "hello"
    end

    @testset "tryvalue(T, lit) — type-converting, returns nothing on failure" begin
        # Successful conversions
        @test tryvalue(Int64,   Literal(42))      === Int64(42)
        @test tryvalue(Float64, Literal(42))      === 42.0     # Int64 → Float64
        @test tryvalue(Float64, Literal(3.14))    isa Float64
        @test tryvalue(Float32, Literal(42))      === Float32(42)
        @test tryvalue(String,  Literal("hello")) == "hello"

        # Failures return nothing
        @test tryvalue(Int64,   Literal(3.14))    === nothing  # inexact
        @test tryvalue(Int64,   Literal("hello")) === nothing
        @test tryvalue(Float64, Literal("oops", xsd.double)) === nothing
        @test tryvalue(Int64,   Literal("notanumber", xsd.integer)) === nothing
    end

    @testset "Display" begin
        # Plain string literal
        @test repr(Literal("hello")) == "\"hello\""

        # Typed literal
        @test repr(Literal("42", xsd.integer)) ==
              "\"42\"^^<http://www.w3.org/2001/XMLSchema#integer>"

        # Language-tagged string
        @test repr(Literal("hello"; lang="en")) == "\"hello\"@en"

        # Escaping in lexical form
        lit = Literal("say \"hello\"")
        @test repr(lit) == "\"say \\\"hello\\\"\""

        # Newlines
        lit = Literal("line1\nline2")
        @test repr(lit) == "\"line1\\nline2\""
    end

end
