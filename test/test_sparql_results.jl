using Test
using RDF

# Helper: build a small SolutionSet for reuse across format tests
function _make_sol()
    vars = [:name, :age]
    rows = [
        Dict{Symbol,Union{RDFTerm,Nothing}}(
            :name => Literal("Alice"),
            :age  => Literal("30", IRI("http://www.w3.org/2001/XMLSchema#integer")),
        ),
        Dict{Symbol,Union{RDFTerm,Nothing}}(
            :name => Literal("Bob"; lang="en"),
            :age  => nothing,   # unbound
        ),
        Dict{Symbol,Union{RDFTerm,Nothing}}(
            :name => IRI("http://example.org/Charlie"),
            :age  => Literal("25", IRI("http://www.w3.org/2001/XMLSchema#integer")),
        ),
    ]
    SolutionSet(vars, rows)
end

@testset "SPARQL result format serialization" begin

    sol = _make_sol()

    # ── SPARQL/JSON ───────────────────────────────────────────────────────────

    @testset "SPARQL/JSON SELECT" begin
        io = IOBuffer()
        write(io, MIME"application/sparql-results+json"(), sol)
        s = String(take!(io))

        # Must be valid-looking JSON
        @test startswith(s, "{")
        @test occursin("\"head\"", s)
        @test occursin("\"vars\"", s)
        @test occursin("\"name\"", s)
        @test occursin("\"age\"", s)
        @test occursin("\"results\"", s)
        @test occursin("\"bindings\"", s)

        # Alice row — typed literal
        @test occursin("\"Alice\"", s)
        @test occursin("\"type\":\"literal\"", s)
        @test occursin("XMLSchema#integer", s)

        # Bob row — lang-tagged literal
        @test occursin("\"xml:lang\"", s)
        @test occursin("\"en\"", s)

        # Bob row — unbound :age must produce no binding entry for "age" in that row.
        # In SPARQL/JSON the key is simply absent; Bob's binding object closes with
        # two braces immediately after the value (no "age" key follows).
        @test occursin("\"value\":\"Bob\"}}", s)

        # Charlie row — URI term
        @test occursin("\"type\":\"uri\"", s)
        @test occursin("http://example.org/Charlie", s)
    end

    @testset "SPARQL/JSON ASK" begin
        io = IOBuffer()
        write(io, MIME"application/sparql-results+json"(), true)
        s = String(take!(io))
        @test occursin("\"boolean\":true", s)
        @test occursin("\"head\"", s)

        io = IOBuffer()
        write(io, MIME"application/sparql-results+json"(), false)
        s = String(take!(io))
        @test occursin("\"boolean\":false", s)
    end

    # ── SPARQL/XML ────────────────────────────────────────────────────────────

    @testset "SPARQL/XML SELECT" begin
        io = IOBuffer()
        write(io, MIME"application/sparql-results+xml"(), sol)
        s = String(take!(io))

        @test startswith(s, "<?xml")
        @test occursin("<sparql", s)
        @test occursin("<head>", s)
        @test occursin("<variable name=\"name\"", s)
        @test occursin("<variable name=\"age\"", s)
        @test occursin("<results>", s)
        @test occursin("<result>", s)

        # Alice — typed literal
        @test occursin("<literal datatype=\"http://www.w3.org/2001/XMLSchema#integer\">30</literal>", s)

        # Bob — lang-tagged literal
        @test occursin("xml:lang=\"en\"", s)

        # Charlie — URI term
        @test occursin("<uri>http://example.org/Charlie</uri>", s)

        # XML escaping: ensure no bare < or & in IRI values
        @test !occursin("<http://", s)  # IRIs wrapped in <uri>...</uri>, not bare

        @test occursin("</sparql>", s)
    end

    @testset "SPARQL/XML ASK" begin
        io = IOBuffer()
        write(io, MIME"application/sparql-results+xml"(), true)
        s = String(take!(io))
        @test occursin("<boolean>true</boolean>", s)
        @test occursin("<head/>", s)

        io = IOBuffer()
        write(io, MIME"application/sparql-results+xml"(), false)
        s = String(take!(io))
        @test occursin("<boolean>false</boolean>", s)
    end

    # ── SPARQL/CSV ────────────────────────────────────────────────────────────

    @testset "SPARQL/CSV SELECT" begin
        io = IOBuffer()
        write(io, MIME"text/csv"(), sol)
        s = String(take!(io))
        lines = split(rstrip(s), '\n')

        # Header line
        @test lines[1] == "name,age"

        # Alice: plain lexical form, integer lexical form
        @test occursin("Alice", lines[2])
        @test occursin("30", lines[2])

        # Bob: lang-tagged literal → just lexical form in CSV; unbound age → empty
        @test startswith(lines[3], "Bob,") || lines[3] == "Bob,"

        # Charlie: IRI → raw IRI value
        @test occursin("http://example.org/Charlie", lines[4])
    end

    @testset "SPARQL/CSV quoting" begin
        # Literal with comma must be double-quoted
        vars = [:v]
        rows = [Dict{Symbol,Union{RDFTerm,Nothing}}(:v => Literal("hello, world"))]
        sol2 = SolutionSet(vars, rows)
        io = IOBuffer()
        write(io, MIME"text/csv"(), sol2)
        s = String(take!(io))
        @test occursin("\"hello, world\"", s)

        # Literal with embedded double-quote → RFC 4180 escaping
        rows2 = [Dict{Symbol,Union{RDFTerm,Nothing}}(:v => Literal("say \"hi\""))]
        sol3 = SolutionSet(vars, rows2)
        io = IOBuffer()
        write(io, MIME"text/csv"(), sol3)
        s = String(take!(io))
        @test occursin("\"say \"\"hi\"\"\"", s)
    end

    # ── SPARQL/TSV ────────────────────────────────────────────────────────────

    @testset "SPARQL/TSV SELECT" begin
        io = IOBuffer()
        write(io, MIME"text/tab-separated-values"(), sol)
        s = String(take!(io))
        lines = split(rstrip(s), '\n')

        # Header: ?-prefixed variable names
        @test lines[1] == "?name\t?age"

        # Alice — typed literal in N-Triples style
        @test occursin("\"Alice\"^^<http://www.w3.org/2001/XMLSchema#string>", lines[2]) ||
              occursin("\"Alice\"", lines[2])   # xsd:string may be abbreviated
        @test occursin("\"30\"^^<http://www.w3.org/2001/XMLSchema#integer>", lines[2])

        # Bob — lang-tagged literal; unbound age → empty field at end
        @test occursin("\"Bob\"@en", lines[3])
        @test endswith(lines[3], "\t") || !occursin("30", lines[3])

        # Charlie — IRI in angle brackets
        @test occursin("<http://example.org/Charlie>", lines[4])
    end

    # ── Blank-node serialization ──────────────────────────────────────────────

    @testset "Blank nodes in results" begin
        g_bn = Graph()
        bn = blank!(g_bn)
        vars = [:s]
        rows = [Dict{Symbol,Union{RDFTerm,Nothing}}(:s => bn)]
        sol_bn = SolutionSet(vars, rows)

        io = IOBuffer()
        write(io, MIME"application/sparql-results+json"(), sol_bn)
        s = String(take!(io))
        @test occursin("\"type\":\"bnode\"", s)

        io = IOBuffer()
        write(io, MIME"application/sparql-results+xml"(), sol_bn)
        s = String(take!(io))
        @test occursin("<bnode>", s)

        io = IOBuffer()
        write(io, MIME"text/tab-separated-values"(), sol_bn)
        s = String(take!(io))
        @test occursin("_:b", s)
    end

    # ── XML character escaping ────────────────────────────────────────────────

    @testset "XML escaping in results" begin
        vars = [:v]
        rows = [Dict{Symbol,Union{RDFTerm,Nothing}}(:v => Literal("<tag> & \"quote\""))]
        sol_xml = SolutionSet(vars, rows)
        io = IOBuffer()
        write(io, MIME"application/sparql-results+xml"(), sol_xml)
        s = String(take!(io))
        @test occursin("&lt;tag&gt;", s)
        @test occursin("&amp;", s)
        @test occursin("&quot;", s)
        # Must not contain raw < or & inside element content
        # (outside of XML tags themselves)
        @test !occursin("&\"", s)
    end

    # ── Empty solution set ────────────────────────────────────────────────────

    @testset "Empty SolutionSet" begin
        empty_sol = SolutionSet([:x, :y])
        for mime in (MIME"application/sparql-results+json"(),
                     MIME"application/sparql-results+xml"(),
                     MIME"text/csv"(),
                     MIME"text/tab-separated-values"())
            io = IOBuffer()
            write(io, mime, empty_sol)
            s = String(take!(io))
            @test !isempty(s)  # header must still be present
        end
    end

end
