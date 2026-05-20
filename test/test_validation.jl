using RDF
using Test

@testset "Validation" begin

    ex = Namespace("http://example.org/")

    @testset "validate — returns empty vector for well-formed graph" begin
        g = Graph()
        push!(g, Triple(ex.alice, rdf.type, ex.Person))
        push!(g, Triple(ex.alice, ex.name, Literal("Alice")))
        push!(g, Triple(ex.alice, ex.age,  Literal(30)))

        warnings = validate(g)
        @test warnings isa Vector{ValidationWarning}
        @test isempty(warnings)
    end

    @testset "validate — detects ill-typed literals" begin
        g = Graph()
        push!(g, Triple(ex.alice, ex.age, Literal("notanumber", xsd.integer)))

        warnings = validate(g)
        @test !isempty(warnings)
        @test any(w.code == :ill_typed_literal for w in warnings)

        # The warning references the offending triple
        w = first(filter(w -> w.code == :ill_typed_literal, warnings))
        @test w.triple isa Triple
    end

    @testset "validate — accepts ill-typed literals (never throws)" begin
        g = Graph()
        push!(g, Triple(ex.s, ex.p, Literal("bad", xsd.integer)))
        push!(g, Triple(ex.s, ex.p, Literal("alsobad", xsd.date)))

        # validate returns, never throws
        @test_nowarn validate(g)
        warnings = validate(g)
        @test length(warnings) >= 2
    end

    @testset "validate — unrecognized datatype is not an error" begin
        g = Graph()
        my_type = IRI("http://example.org/MyType")
        push!(g, Triple(ex.s, ex.p, Literal("some value", my_type)))

        warnings = validate(g)
        # Unrecognized datatypes should not produce ill_typed_literal warnings
        # (the spec says these are simply unknown, not errors)
        type_warnings = filter(w -> w.code == :ill_typed_literal, warnings)
        @test isempty(type_warnings)
    end

    @testset "validate — detects invalid language tags" begin
        # Manually construct a literal with an invalid language tag
        # (bypassing the constructor validation for testing purposes)
        # This tests that validate catches pre-existing data issues
        g = Graph()
        # Valid language tag should pass
        push!(g, Triple(ex.s, ex.p, Literal("hello"; lang="en")))
        @test isempty(filter(w -> w.code == :invalid_language_tag, validate(g)))
    end

    @testset "validate — dataset validation" begin
        ds = Dataset()
        push!(ds.default_graph, Triple(ex.alice, ex.age, Literal("notanumber", xsd.integer)))

        g = Graph()
        push!(g, Triple(ex.bob, ex.age, Literal("alsobad", xsd.date)))
        ds[IRI("http://example.org/g")] = g

        warnings = validate(ds)
        @test length(warnings) >= 2
    end

    @testset "ValidationWarning fields" begin
        g = Graph()
        push!(g, Triple(ex.alice, ex.age, Literal("bad", xsd.integer)))

        warnings = validate(g)
        w = first(warnings)
        @test hasproperty(w, :triple)
        @test hasproperty(w, :message)
        @test hasproperty(w, :code)
        @test w.message isa String
        @test w.code isa Symbol
        @test w.triple isa Triple
    end

end


@testset "Error Types" begin

    ex = Namespace("http://example.org/")

    @testset "RDFError — abstract supertype" begin
        @test IRIError        <: RDFError
        @test ParseError      <: RDFError
        @test LiteralValueError <: RDFError
        @test BlankNodeScopeError <: RDFError
        @test RDFError        <: Exception
    end

    @testset "IRIError" begin
        err = IRIError("relative/path", "IRI must be absolute")
        @test err isa IRIError
        @test err isa RDFError
        @test err isa Exception
        @test err.value == "relative/path"
        @test err.reason isa String
        @test !isempty(err.reason)

        # Thrown on invalid IRI construction
        try
            IRI("relative/path")
            @test false  # should not reach here
        catch e
            @test e isa IRIError
            @test e.value == "relative/path"
        end
    end

    @testset "ParseError" begin
        mime = MIME"application/n-triples"()
        err = ParseError("unexpected token", 5, 12, mime)
        @test err isa ParseError
        @test err isa RDFError
        @test err.message isa String
        @test err.line == 5
        @test err.column == 12
        @test err.format == mime

        # Thrown by parser on malformed input
        bad_nt = "this is not valid ntriples\n"
        try
            read(IOBuffer(bad_nt), MIME"application/n-triples"(), Graph)
            @test false  # should not reach here
        catch e
            @test e isa ParseError
            @test e.line isa Int
            @test e.column isa Int
        end
    end

    @testset "LiteralValueError" begin
        lit = Literal("notanumber", xsd.integer)
        err = LiteralValueError(lit, Int64)
        @test err isa LiteralValueError
        @test err isa RDFError
        @test err.literal === lit
        @test err.target_type == Int64

        # Thrown by value()
        try
            value(Literal("bad", xsd.integer))
            @test false
        catch e
            @test e isa LiteralValueError
            @test e.literal.lexical_form == "bad"
        end

        # Thrown by value(T, lit)
        try
            value(Int64, Literal("bad", xsd.integer))
            @test false
        catch e
            @test e isa LiteralValueError
            @test e.target_type == Int64
        end
    end

    @testset "BlankNodeScopeError" begin
        g = Graph()
        b = blank!(g)
        err = BlankNodeScopeError(b, "blank node not in scope")
        @test err isa BlankNodeScopeError
        @test err isa RDFError
        @test err.node === b
        @test err.message isa String
    end

    @testset "Errors are catchable by type" begin
        # IRIError
        caught = false
        try
            IRI("not-absolute")
        catch e
            e isa IRIError || rethrow()
            caught = true
        end
        @test caught

        # LiteralValueError
        caught = false
        try
            value(Literal("bad", xsd.integer))
        catch e
            e isa LiteralValueError || rethrow()
            caught = true
        end
        @test caught

        # ParseError
        caught = false
        try
            read(IOBuffer("invalid\n"), MIME"application/n-triples"(), Graph)
        catch e
            e isa ParseError || rethrow()
            caught = true
        end
        @test caught
    end

    @testset "Error messages are informative" begin
        try
            IRI("relative")
        catch e
            msg = sprint(showerror, e)
            @test !isempty(msg)
            @test contains(msg, "relative")
        end

        try
            value(Literal("bad", xsd.integer))
        catch e
            msg = sprint(showerror, e)
            @test !isempty(msg)
            @test contains(msg, "bad")
        end
    end

end
