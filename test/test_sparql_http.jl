using Test
using RDF
import Sockets

# ── SPARQL/JSON reader (pure, no HTTP needed) ─────────────────────────────────
@testset "read_sparql_json" begin

    @testset "SELECT — basic bindings" begin
        body = """
        {
          "head": { "vars": ["s", "p", "o"] },
          "results": {
            "bindings": [
              {
                "s": { "type": "uri",     "value": "http://example.org/Alice" },
                "p": { "type": "uri",     "value": "http://xmlns.com/foaf/0.1/name" },
                "o": { "type": "literal", "value": "Alice", "xml:lang": "en" }
              },
              {
                "s": { "type": "uri",     "value": "http://example.org/Bob" },
                "p": { "type": "uri",     "value": "http://xmlns.com/foaf/0.1/age" },
                "o": { "type": "literal", "value": "42",
                       "datatype": "http://www.w3.org/2001/XMLSchema#integer" }
              }
            ]
          }
        }
        """
        ss = read_sparql_json(body)
        @test ss isa SolutionSet
        @test length(ss) == 2
        @test ss.variables == [:s, :p, :o]

        r1 = ss[1]
        @test r1[:s] == IRI("http://example.org/Alice")
        @test r1[:o] isa Literal
        @test (r1[:o]::Literal).language_tag == "en"
        @test (r1[:o]::Literal).lexical_form  == "Alice"

        r2 = ss[2]
        @test r2[:o] isa Literal
        @test (r2[:o]::Literal).lexical_form == "42"
        @test (r2[:o]::Literal).datatype == IRI("http://www.w3.org/2001/XMLSchema#integer")
    end

    @testset "SELECT — blank node binding" begin
        body = """
        {
          "head": { "vars": ["x"] },
          "results": {
            "bindings": [
              { "x": { "type": "bnode", "value": "b0" } }
            ]
          }
        }
        """
        ss = read_sparql_json(body)
        @test length(ss) == 1
        @test ss[1][:x] isa BlankNode
    end

    @testset "SELECT — unbound variable (OPTIONAL)" begin
        body = """
        {
          "head": { "vars": ["s", "age"] },
          "results": {
            "bindings": [
              { "s": { "type": "uri", "value": "http://example.org/Alice" } }
            ]
          }
        }
        """
        ss = read_sparql_json(body)
        @test length(ss) == 1
        @test ss[1][:s] == IRI("http://example.org/Alice")
        @test ss[1][:age] === nothing
    end

    @testset "SELECT — empty result set" begin
        body = """
        {"head":{"vars":["s"]},"results":{"bindings":[]}}
        """
        ss = read_sparql_json(body)
        @test ss isa SolutionSet
        @test length(ss) == 0
        @test ss.variables == [:s]
    end

    @testset "ASK — true" begin
        body = """{"head":{},"boolean":true}"""
        result = read_sparql_json(body)
        @test result === true
    end

    @testset "ASK — false" begin
        body = """{"head":{},"boolean":false}"""
        result = read_sparql_json(body)
        @test result === false
    end

    @testset "Literal — plain string (no datatype/lang)" begin
        body = """
        {
          "head": {"vars": ["v"]},
          "results": {"bindings": [
            {"v": {"type": "literal", "value": "hello"}}
          ]}
        }
        """
        ss = read_sparql_json(body)
        t = ss[1][:v]
        @test t isa Literal
        @test (t::Literal).lexical_form == "hello"
    end
end

# ── RDFHTTPExt integration tests (require HTTP.jl) ────────────────────────────
#
# We spin up a tiny HTTP server on localhost that returns canned SPARQL responses,
# so the tests are hermetic and work without internet access.

@testset "RDFHTTPExt — local mock endpoint" begin
    # Skip the whole block if HTTP isn't loaded (test suite runs without it)
    HTTP = try
        Base.require(Main, :HTTP)
    catch
        nothing
    end
    if HTTP === nothing
        @warn "HTTP.jl not available — skipping RDFHTTPExt integration tests"
        @test_skip "HTTP.jl not available"
    else
        # ── Canned responses ──────────────────────────────────────────────────
        SELECT_JSON = """
        {
          "head": {"vars": ["name", "age"]},
          "results": {"bindings": [
            {
              "name": {"type":"literal","value":"Alice","xml:lang":"en"},
              "age":  {"type":"literal","value":"30",
                       "datatype":"http://www.w3.org/2001/XMLSchema#integer"}
            },
            {
              "name": {"type":"literal","value":"Bob","xml:lang":"en"},
              "age":  {"type":"literal","value":"25",
                       "datatype":"http://www.w3.org/2001/XMLSchema#integer"}
            }
          ]}
        }
        """

        ASK_TRUE_JSON  = """{"head":{},"boolean":true}"""
        ASK_FALSE_JSON = """{"head":{},"boolean":false}"""

        TURTLE_GRAPH = """
        @prefix ex: <http://example.org/> .
        ex:Alice a ex:Person ; ex:name "Alice" .
        ex:Bob   a ex:Person ; ex:name "Bob"   .
        """

        # ── Minimal SPARQL mock server ─────────────────────────────────────────
        # Dispatches on the ?query= parameter to return the right canned response.
        function mock_handler(req)
            raw_query = ""
            if req.method == "POST"
                raw_query = String(req.body)
            else
                uri = HTTP.URI(req.target)
                params = HTTP.queryparams(uri)
                raw_query = get(params, "query", "")
            end
            query_uc = uppercase(strip(replace(raw_query, r"%[0-9A-Fa-f]{2}" => "")))

            if occursin("ASK", query_uc)
                if occursin("EXIST_FALSE", query_uc)
                    return HTTP.Response(200,
                        ["Content-Type" => "application/sparql-results+json"],
                        body=ASK_FALSE_JSON)
                else
                    return HTTP.Response(200,
                        ["Content-Type" => "application/sparql-results+json"],
                        body=ASK_TRUE_JSON)
                end
            elseif occursin("CONSTRUCT", query_uc) || occursin("DESCRIBE", query_uc)
                return HTTP.Response(200,
                    ["Content-Type" => "text/turtle"],
                    body=TURTLE_GRAPH)
            elseif occursin("ERROR500", query_uc)
                return HTTP.Response(500,
                    ["Content-Type" => "text/plain"],
                    body="Internal Server Error")
            elseif occursin("ERROR400", query_uc)
                return HTTP.Response(400,
                    ["Content-Type" => "text/plain"],
                    body="Bad Request")
            else
                return HTTP.Response(200,
                    ["Content-Type" => "application/sparql-results+json"],
                    body=SELECT_JSON)
            end
        end

        # Find a free port, then start the server on it
        local port = let sock = Sockets.listen(Sockets.IPv4(0), 0)
            _, p = Sockets.getsockname(sock)
            close(sock)
            Int(p)
        end
        server = HTTP.serve!(mock_handler, "127.0.0.1", port)
        base   = "http://127.0.0.1:$port/sparql"

        try
            @testset "SELECT query returns SolutionSet" begin
                ss = sparql(base, "SELECT ?name ?age WHERE { ?s ?p ?o }")
                @test ss isa SolutionSet
                @test length(ss) == 2
                @test ss.variables == [:name, :age]
                names = [value(String, row[:name]) for row in ss]
                @test "Alice" in names
                @test "Bob"   in names
            end

            @testset "ASK query — true" begin
                r = sparql(base, "ASK { ?s ?p ?o }")
                @test r === true
            end

            @testset "ASK query — false" begin
                r = sparql(base, "ASK { EXIST_FALSE ?s ?p ?o }")
                @test r === false
            end

            @testset "CONSTRUCT returns Graph" begin
                g = sparql(base,
                    "CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }")
                @test g isa Graph
                @test length(g) == 4   # 2 rdf:type + 2 ex:name
            end

            @testset "Extra prefixes prepended" begin
                ss = sparql(base,
                    "SELECT ?name WHERE { ?s ex:name ?name }";
                    prefixes = Dict("ex" => "http://example.org/"))
                @test ss isa SolutionSet
            end

            @testset "GET method for short query" begin
                ss = sparql(base, "SELECT ?s WHERE { ?s ?p ?o }"; method=:get)
                @test ss isa SolutionSet
            end

            @testset "POST method forced" begin
                ss = sparql(base, "SELECT ?s WHERE { ?s ?p ?o }"; method=:post)
                @test ss isa SolutionSet
            end

            @testset "4xx error throws" begin
                @test_throws Exception sparql(base,
                    "SELECT ERROR400 WHERE { ?s ?p ?o }"; retries=0)
            end

            @testset "5xx error throws after retries" begin
                @test_throws Exception sparql(base,
                    "SELECT ERROR500 WHERE { ?s ?p ?o }"; retries=1)
            end

        finally
            close(server)
        end
    end
end
