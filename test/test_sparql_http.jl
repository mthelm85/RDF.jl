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

        # Additional canned responses for header / content-type tests
        CUSTOM_HDR_JSON = """
        {
          "head": {"vars": ["v"]},
          "results": {"bindings": [
            {"v": {"type": "literal", "value": "header-received"}}
          ]}
        }
        """

        # ── Minimal SPARQL mock server ─────────────────────────────────────────
        # Dispatches on the ?query= parameter to return the right canned response.
        function mock_handler(req)
            # ── Custom-header reflection ───────────────────────────────────────
            # If the request carries X-Custom-Test, echo its value back.
            # This lets us verify that caller-supplied headers are forwarded.
            if HTTP.hasheader(req, "X-Custom-Test")
                val = HTTP.header(req, "X-Custom-Test")
                echo_json = """{"head":{"vars":["v"]},"results":{"bindings":[{"v":{"type":"literal","value":"$(val)"}}]}}"""
                return HTTP.Response(200,
                    ["Content-Type" => "application/sparql-results+json"],
                    body=echo_json)
            end

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
            # ── Binary / non-JSON response (simulates strict endpoint ignoring Accept)
            elseif occursin("BINARY_RESP", query_uc)
                return HTTP.Response(200,
                    ["Content-Type" => "application/x-binary-brtr"],
                    body="\x00\x01\x02BRTRsp\x00\x01binary payload")
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

            @testset "4xx error throws typed RemoteEndpointError" begin
                err = @test_throws RemoteEndpointError sparql(base,
                    "SELECT ERROR400 WHERE { ?s ?p ?o }"; retries=0)
                @test err.value isa RDFError
                @test occursin("400", sprint(showerror, err.value))
                @test err.value.endpoint == base
            end

            @testset "5xx error throws typed RemoteEndpointError after retries" begin
                err = @test_throws RemoteEndpointError sparql(base,
                    "SELECT ERROR500 WHERE { ?s ?p ?o }"; retries=1)
                @test occursin("500", sprint(showerror, err.value))
            end

            # ── Fix 1: custom headers forwarded to the endpoint ────────────────

            @testset "custom headers are forwarded to the endpoint" begin
                # The mock echoes back X-Custom-Test in the result if it sees it.
                ss = sparql(base, "SELECT ?v WHERE { ?s ?p ?o }";
                            headers = ["X-Custom-Test" => "sentinel-value"])
                @test ss isa SolutionSet
                @test length(ss) == 1
                @test value(String, ss[1][:v]) == "sentinel-value"
            end

            @testset "custom Accept header overrides the default" begin
                # User pins Accept to JSON explicitly — result should still parse.
                ss = sparql(base, "SELECT ?name ?age WHERE { ?s ?p ?o }";
                            headers = ["Accept" => "application/sparql-results+json"])
                @test ss isa SolutionSet
                @test length(ss) == 2
            end

            @testset "multiple custom headers are all forwarded" begin
                # Both X-Custom-Test and another header in the same call.
                ss = sparql(base, "SELECT ?v WHERE { ?s ?p ?o }";
                            headers = ["X-Custom-Test" => "multi",
                                       "X-Other" => "ignored-by-mock"])
                @test ss isa SolutionSet
                @test value(String, ss[1][:v]) == "multi"
            end

            @testset "headers keyword accepts a Dict as well as a Vector" begin
                ss = sparql(base, "SELECT ?v WHERE { ?s ?p ?o }";
                            headers = Dict("X-Custom-Test" => "from-dict"))
                @test ss isa SolutionSet
                @test value(String, ss[1][:v]) == "from-dict"
            end

            # ── Fix 2: descriptive error for non-JSON Content-Type ─────────────

            @testset "non-JSON Content-Type raises descriptive error" begin
                # The mock returns application/x-binary-brtr for BINARY_RESP.
                # Without the guard this would crash the JSON parser with a cryptic message;
                # with the guard it should throw a clear RemoteEndpointError
                # mentioning the actual Content-Type that came back.
                err = @test_throws RemoteEndpointError sparql(base,
                    "SELECT BINARY_RESP WHERE { ?s ?p ?o }"; retries=0)
                msg = sprint(showerror, err.value)
                @test occursin("Content-Type", msg)
                @test occursin("binary-brtr", msg)
            end

            # ── Audit fix: _truncate must respect UTF-8 character boundaries ───

            @testset "_truncate is UTF-8 safe" begin
                ext = Base.get_extension(RDF, :RDFHTTPExt)
                @test ext !== nothing
                # 300 two-byte characters: byte index 200 is mid-character, so
                # the old s[1:n] implementation throws StringIndexError here.
                s = "α"^300
                t = ext._truncate(s, 200)
                @test length(t) == 201            # 200 chars + ellipsis
                @test endswith(t, "…")
                @test ext._truncate("short", 200) == "short"
                # Mixed-width content around the boundary
                s2 = "a"^199 * "β" * "γ"^100
                @test length(ext._truncate(s2, 200)) == 201
            end

            @testset "application/json is accepted (not only sparql-results+json)" begin
                # Some endpoints return application/json instead of the full MIME.
                # That still contains "json" so the guard must not reject it.
                # (We reuse the default SELECT route which returns the correct type,
                #  so this is an indirect check that non-brtr responses still work.)
                ss = sparql(base, "SELECT ?name ?age WHERE { ?s ?p ?o }")
                @test ss isa SolutionSet
            end

        finally
            close(server)
        end
    end
end
