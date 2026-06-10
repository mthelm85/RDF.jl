using Test
using RDF
import RDF: Graph
import Sockets

# ── SPARQL SERVICE federation + RemoteGraph ────────────────────────────────────
#
# TDD spec.  Contract under test:
#
#   • RDF._sp_render_pattern(pat)::String
#       Renders a parsed graph pattern back to SPARQL text (a brace-wrapped
#       group graph pattern, all IRIs absolute).  Round-trip property:
#       parsing the rendered text and evaluating gives identical results.
#
#   • RDF._REMOTE_SPARQL::Ref{Any}
#       Transport hook.  `nothing` until the HTTP extension is loaded; the
#       extension installs a callable (endpoint::String, query::String;
#       kwargs...) -> SolutionSet | Bool | Graph.
#
#   • SERVICE <iri> { pattern }
#       Evaluated by sending `SELECT * WHERE { pattern }` to the endpoint via
#       the hook and joining the returned solutions with the current ones.
#       - hook missing / request fails  → loud error (no silent empty results)
#       - SERVICE SILENT + failure      → acts as the join identity (outer
#                                         solutions pass through, service
#                                         variables unbound)
#       - variable endpoint             → loud error (unsupported)
#
#   • RemoteGraph(endpoint::AbstractString; kwargs...)
#       Read-only Graph-like view of a remote endpoint:
#       match / length / isempty / in / iterate / sparql(rg, q).

const _sr_ex   = Namespace("http://sr-test.example.org/")
const _sr_foaf = Namespace("http://xmlns.com/foaf/0.1/")

_sr_rows(ss::SolutionSet) =
    sort([join([repr(row[v]) for v in ss.variables], "|") for row in ss])

# Evaluate `SELECT vars WHERE { pat_src }` directly and via render round-trip;
# both must agree.
function _sr_roundtrip(g, vars::String, pat_src::String)
    q1 = "SELECT $vars WHERE { $pat_src }"
    unit = RDF.sparql_parse(q1)
    rendered = RDF._sp_render_pattern(unit.query.pattern)
    q2 = "SELECT $vars WHERE $rendered"
    r1 = sparql(g, q1)
    r2 = sparql(g, q2)
    _sr_rows(r1) == _sr_rows(r2) || @info "render mismatch" q1 rendered
    (_sr_rows(r1) == _sr_rows(r2), length(r1))
end

@testset "SERVICE federation and RemoteGraph" begin

    # ── Local fixture (plays the rôle of the outer/local data) ────────────────
    local_g = Graph()
    push!(local_g, Triple(_sr_ex.alice, _sr_foaf.name, Literal("Alice")))
    push!(local_g, Triple(_sr_ex.bob,   _sr_foaf.name, Literal("Bob")))
    push!(local_g, Triple(_sr_ex.carol, _sr_foaf.name, Literal("Carol")))

    # ── "Remote" fixture (what the endpoint serves) ───────────────────────────
    remote_g = Graph()
    push!(remote_g, Triple(_sr_ex.alice, _sr_foaf.age, Literal(30)))
    push!(remote_g, Triple(_sr_ex.bob,   _sr_foaf.age, Literal(25)))
    push!(remote_g, Triple(_sr_ex.alice, rdf.type, _sr_foaf.Person))
    push!(remote_g, Triple(_sr_ex.bob,   rdf.type, _sr_foaf.Person))
    push!(remote_g, Triple(_sr_ex.dave,  rdf.type, _sr_foaf.Person))

    # ── Pattern rendering (pure, no transport) ────────────────────────────────
    @testset "_sp_render_pattern round-trips" begin
        # Build a richer graph for round-trip checks
        g = Graph()
        push!(g, Triple(_sr_ex.alice, _sr_foaf.name, Literal("Alice"; lang="en")))
        push!(g, Triple(_sr_ex.alice, _sr_foaf.age,  Literal(30)))
        push!(g, Triple(_sr_ex.alice, rdf.type, _sr_foaf.Person))
        push!(g, Triple(_sr_ex.bob,   _sr_foaf.name, Literal("Bob")))
        push!(g, Triple(_sr_ex.bob,   _sr_foaf.age,  Literal(25)))
        push!(g, Triple(_sr_ex.alice, _sr_foaf.knows, _sr_ex.bob))
        push!(g, Triple(_sr_ex.bob,   _sr_foaf.knows, _sr_ex.carol))
        push!(g, Triple(_sr_ex.carol, _sr_foaf.name, Literal("Carol")))

        pre = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> PREFIX ex: <http://sr-test.example.org/>"

        cases = [
            # (vars, pattern source, expected row count)
            ("?s ?o",    "?s foaf:name ?o", 3),
            ("?s",       "?s foaf:name \"Alice\"@en", 1),
            ("?s",       "?s foaf:age 25", 1),
            ("?s",       "?s a foaf:Person", 1),
            ("?s ?n",    "?s foaf:name ?n . FILTER(STRLEN(?n) > 3)", 2),
            ("?s",       "?s foaf:age ?a . FILTER(?a >= 25 && ?a < 100)", 2),
            ("?s ?a",    "?s foaf:name ?n . OPTIONAL { ?s foaf:age ?a }", 3),
            ("?s",       "{ ?s foaf:age 30 } UNION { ?s foaf:age 25 }", 2),
            ("?s",       "?s foaf:name ?n . MINUS { ?s foaf:age 25 }", 2),
            ("?s ?b",    "?s foaf:name ?n . BIND(STRLEN(?n) AS ?b)", 3),
            ("?s",       "VALUES ?n { \"Alice\"@en \"Bob\" } ?s foaf:name ?n", 2),
            ("?s ?n",    "VALUES (?s ?n) { (ex:alice UNDEF) (ex:bob \"Bob\") } ", 2),
            ("?x",       "ex:alice foaf:knows/foaf:name ?x", 1),
            ("?x",       "ex:alice foaf:knows+ ?x", 2),
            ("?x",       "ex:alice foaf:knows* ?x", 3),
            ("?x",       "ex:alice (foaf:knows|foaf:name) ?x", 2),
            ("?x",       "?x ^foaf:knows ex:bob", 1),
            ("?x",       "ex:alice !foaf:name ?x", 3),
            ("?s",       "?s foaf:name ?n . FILTER(?n IN (\"Bob\", \"Carol\"))", 2),
            ("?s",       "?s foaf:name ?n . FILTER EXISTS { ?s foaf:age ?a }", 2),
            ("?s",       "?s foaf:name ?n . FILTER NOT EXISTS { ?s foaf:age ?a }", 1),
            ("?s ?v",    "?s foaf:age ?a . BIND(IF(?a > 27, \"old\", \"young\") AS ?v)", 2),
            ("?s ?v",    "?s foaf:name ?n . BIND(COALESCE(?missing, ?n) AS ?v)", 3),
            ("?s",       "?s foaf:name ?n . FILTER(REGEX(?n, \"^A\"))", 1),
            ("?n",       "{ SELECT ?n WHERE { ?s foaf:name ?n } ORDER BY ?n LIMIT 2 }", 2),
        ]
        for (vars, src, nrows) in cases
            unit = RDF.sparql_parse("$pre SELECT $vars WHERE { $src }")
            rendered = RDF._sp_render_pattern(unit.query.pattern)
            r1 = sparql(g, "$pre SELECT $vars WHERE { $src }")
            r2 = sparql(g, "SELECT $vars WHERE $rendered")
            @test _sr_rows(r1) == _sr_rows(r2)
            @test length(r1) == nrows
        end
    end

    # ── SERVICE via an in-process fake transport ──────────────────────────────
    @testset "SERVICE with fake transport hook" begin
        seen_endpoints = String[]
        fake = (endpoint, query; kwargs...) -> begin
            push!(seen_endpoints, string(endpoint))
            sparql(remote_g, query)
        end

        saved = RDF._REMOTE_SPARQL[]
        RDF._REMOTE_SPARQL[] = fake
        try
            # join local names with remote ages on shared ?s
            r = sparql(local_g, """
                PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                SELECT ?name ?age WHERE {
                  ?s foaf:name ?name .
                  SERVICE <http://remote.example.org/sparql> {
                    ?s foaf:age ?age
                  }
                }""")
            @test r isa SolutionSet
            @test length(r) == 2
            got = Dict(value(String, row[:name]) => value(Int64, row[:age]) for row in r)
            @test got == Dict("Alice" => 30, "Bob" => 25)
            @test seen_endpoints == ["http://remote.example.org/sparql"]

            # SERVICE-only query (no local pattern)
            r2 = sparql(local_g, """
                PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                SELECT ?p WHERE {
                  SERVICE <http://remote.example.org/sparql> { ?p a foaf:Person }
                }""")
            @test length(r2) == 3

            # complex inner pattern (FILTER + OPTIONAL) survives the round trip
            r3 = sparql(local_g, """
                PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                SELECT ?s ?age WHERE {
                  ?s foaf:name ?name .
                  SERVICE <http://remote.example.org/sparql> {
                    ?s a foaf:Person .
                    OPTIONAL { ?s foaf:age ?age }
                    FILTER(BOUND(?age) || !BOUND(?age))
                  }
                }""")
            @test length(r3) == 2   # alice, bob (carol is not a remote Person)
        finally
            RDF._REMOTE_SPARQL[] = saved
        end
    end

    @testset "SERVICE failure modes" begin
        saved = RDF._REMOTE_SPARQL[]

        # 1. No transport installed → loud error mentioning HTTP
        RDF._REMOTE_SPARQL[] = nothing
        try
            err = nothing
            try
                sparql(local_g, """
                    PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                    SELECT ?s WHERE {
                      SERVICE <http://remote.example.org/sparql> { ?s ?p ?o }
                    }""")
            catch e
                err = e
            end
            @test err !== nothing
            @test occursin("HTTP", sprint(showerror, err))

            # SERVICE SILENT + no transport → join identity, not an error
            r = sparql(local_g, """
                PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                SELECT ?name ?age WHERE {
                  ?s foaf:name ?name .
                  SERVICE SILENT <http://remote.example.org/sparql> {
                    ?s foaf:age ?age
                  }
                }""")
            @test length(r) == 3                       # all local rows survive
            @test all(row[:age] === nothing for row in r)  # service vars unbound
        finally
            RDF._REMOTE_SPARQL[] = saved
        end

        # 2. Transport throws → non-silent propagates, SILENT is identity
        RDF._REMOTE_SPARQL[] = (endpoint, query; kwargs...) ->
            error("connection refused")
        try
            @test_throws Exception sparql(local_g, """
                PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                SELECT ?s WHERE {
                  SERVICE <http://remote.example.org/sparql> { ?s ?p ?o }
                }""")

            r = sparql(local_g, """
                PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                SELECT ?name WHERE {
                  ?s foaf:name ?name .
                  SERVICE SILENT <http://remote.example.org/sparql> { ?s ?p ?o }
                }""")
            @test length(r) == 3
        finally
            RDF._REMOTE_SPARQL[] = saved
        end

        # 3. Variable endpoint → loud error (unsupported)
        RDF._REMOTE_SPARQL[] = (endpoint, query; kwargs...) -> sparql(remote_g, query)
        try
            @test_throws Exception sparql(local_g, """
                PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                SELECT ?s WHERE {
                  SERVICE ?endpoint { ?s ?p ?o }
                }""")
        finally
            RDF._REMOTE_SPARQL[] = saved
        end
    end

    # ── RemoteGraph with fake transport ───────────────────────────────────────
    @testset "RemoteGraph with fake transport hook" begin
        saved = RDF._REMOTE_SPARQL[]
        RDF._REMOTE_SPARQL[] = (endpoint, query; kwargs...) -> sparql(remote_g, query)
        try
            rg = RemoteGraph("http://remote.example.org/sparql")
            @test rg isa RemoteGraph

            # length / isempty (COUNT(*) under the hood)
            @test length(rg) == length(remote_g)
            @test !isempty(rg)

            # pattern match
            ts = collect(match(rg; predicate=_sr_foaf.age))
            @test length(ts) == 2
            @test all(t isa Triple for t in ts)
            @test Set(t.subject for t in ts) == Set([_sr_ex.alice, _sr_ex.bob])
            @test Triple(_sr_ex.alice, _sr_foaf.age, Literal(30)) in ts

            ts2 = collect(match(rg; subject=_sr_ex.alice))
            @test length(ts2) == 2

            # fully bound membership test (ASK under the hood)
            @test Triple(_sr_ex.alice, _sr_foaf.age, Literal(30)) in rg
            @test !(Triple(_sr_ex.carol, _sr_foaf.age, Literal(99)) in rg)

            # full iteration
            all_ts = collect(rg)
            @test length(all_ts) == length(remote_g)
            @test Set(all_ts) == Set(collect(remote_g))

            # query forwarding
            r = sparql(rg, """
                PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                SELECT ?s WHERE { ?s a foaf:Person }""")
            @test r isa SolutionSet
            @test length(r) == 3

            # read-only: mutation is an error
            @test_throws Exception push!(rg, Triple(_sr_ex.x, _sr_foaf.name, Literal("x")))
        finally
            RDF._REMOTE_SPARQL[] = saved
        end
    end

    @testset "RemoteGraph without transport errors loudly" begin
        saved = RDF._REMOTE_SPARQL[]
        RDF._REMOTE_SPARQL[] = nothing
        try
            rg = RemoteGraph("http://remote.example.org/sparql")
            err = nothing
            try
                length(rg)
            catch e
                err = e
            end
            @test err !== nothing
            @test occursin("HTTP", sprint(showerror, err))
        finally
            RDF._REMOTE_SPARQL[] = saved
        end
    end

    # ── Real HTTP integration: a live mock endpoint backed by remote_g ────────
    @testset "SERVICE + RemoteGraph over real HTTP" begin
        HTTP = try
            Base.require(Main, :HTTP)
        catch
            nothing
        end
        if HTTP === nothing
            @warn "HTTP.jl not available — skipping SERVICE HTTP integration tests"
            @test_skip "HTTP.jl not available"
        else
            # A genuine SPARQL endpoint: decodes the protocol request and
            # evaluates the query against remote_g with RDF.jl itself.
            function sparql_endpoint_handler(req)
                raw = if req.method == "POST"
                    String(req.body)
                else
                    String(HTTP.URI(req.target).query)
                end
                params = HTTP.URIs.queryparams(raw)
                query  = get(params, "query", "")
                result = sparql(remote_g, query)
                io = IOBuffer()
                if result isa Bool
                    write(io, """{"head":{},"boolean":$(result)}""")
                else
                    write(io, MIME"application/sparql-results+json"(), result)
                end
                HTTP.Response(200,
                    ["Content-Type" => "application/sparql-results+json"],
                    body=String(take!(io)))
            end

            port = let sock = Sockets.listen(Sockets.IPv4(0), 0)
                _, p = Sockets.getsockname(sock)
                close(sock)
                Int(p)
            end
            server   = HTTP.serve!(sparql_endpoint_handler, "127.0.0.1", port)
            endpoint = "http://127.0.0.1:$port/sparql"

            try
                # federated query over real HTTP
                r = sparql(local_g, """
                    PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                    SELECT ?name ?age WHERE {
                      ?s foaf:name ?name .
                      SERVICE <$endpoint> { ?s foaf:age ?age }
                    }""")
                @test length(r) == 2
                got = Dict(value(String, row[:name]) => value(Int64, row[:age]) for row in r)
                @test got == Dict("Alice" => 30, "Bob" => 25)

                # RemoteGraph over real HTTP
                rg = RemoteGraph(endpoint)
                @test length(rg) == length(remote_g)
                @test length(collect(match(rg; predicate=_sr_foaf.age))) == 2
                @test Triple(_sr_ex.alice, _sr_foaf.age, Literal(30)) in rg

                # SERVICE SILENT against a dead endpoint still succeeds
                r2 = sparql(local_g, """
                    PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                    SELECT ?name WHERE {
                      ?s foaf:name ?name .
                      SERVICE SILENT <http://127.0.0.1:1/sparql> { ?s foaf:age ?age }
                    }""")
                @test length(r2) == 3
            finally
                close(server)
            end
        end
    end
end
