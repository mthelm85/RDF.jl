using Test
using RDF
import RDF: Graph

# ── SERVICE: per-endpoint HTTP options + bind join (issue #23) ────────────────
#
# Contract under test:
#
#   • service_options!(endpoint; kwargs...)  — register options for SERVICE
#     calls to `endpoint`.  HTTP kwargs (headers, auth, timeout, …) are
#     forwarded to the transport exactly as RemoteGraph forwards them; the
#     SERVICE-level keys `batch_size` and `bind_join` are consumed locally.
#   • service_options(endpoint) → NamedTuple (empty when unset)
#   • clear_service_options!(endpoint) / clear_service_options!()
#   • sparql(g, q; service_options = Dict(endpoint => (; …)))  — query-scoped
#     override, merged over the registry.
#   • Bind join: input bindings for variables shared with the SERVICE pattern
#     are sent as a VALUES block in batches, results are hash-joined back.
#     Semantics must equal the plain (bind_join=false) evaluation.

const _bj_ex   = Namespace("http://bj-test.example.org/")
const _bj_foaf = Namespace("http://xmlns.com/foaf/0.1/")
const _BJ_EP   = "http://remote.example.org/sparql"
const _BJ_PRE  = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> PREFIX ex: <http://bj-test.example.org/>\n"

_bj_rows(ss::SolutionSet) =
    sort([join([repr(row[v]) for v in sort(ss.variables)], "|") for row in ss])

# Install a recording fake transport backed by `remote_g`; run `f(calls)`.
function _bj_with_transport(f, remote_g; fail_on = Int[])
    calls = NamedTuple[]
    fake = (endpoint, query; kwargs...) -> begin
        push!(calls, (endpoint = String(endpoint), query = String(query),
                      kwargs = NamedTuple(kwargs)))
        length(calls) in fail_on && error("simulated network failure")
        sparql(remote_g, query)
    end
    saved = RDF._REMOTE_SPARQL[]
    RDF._REMOTE_SPARQL[] = fake
    try
        f(calls)
    finally
        RDF._REMOTE_SPARQL[] = saved
        clear_service_options!()
    end
end

# Count VALUES data rows in a query sent to the transport.
function _bj_values_rows(q::AbstractString)
    m = match(r"VALUES\s*\([^)]*\)\s*\{(.*?)\}\s*\{"s, q)
    m === nothing && return 0
    count(==('('), m.captures[1])
end

@testset "SERVICE options and bind join" begin

    local_g = Graph()
    for (who, name) in [(:alice, "Alice"), (:bob, "Bob"), (:carol, "Carol"),
                        (:dave, "Dave"), (:erin, "Erin")]
        push!(local_g, Triple(_bj_ex[string(who)], _bj_foaf.name, Literal(name)))
    end
    push!(local_g, Triple(_bj_ex.alice, _bj_foaf.knows, _bj_ex.bob))
    push!(local_g, Triple(_bj_ex.bob,   _bj_foaf.knows, _bj_ex.dave))
    # A blank-node subject with a name — cannot be shipped to the remote side.
    anon = blank!(local_g)
    push!(local_g, Triple(anon, _bj_foaf.name, Literal("Anon")))

    remote_g = Graph()
    for (who, age) in [(:alice, 30), (:bob, 25), (:dave, 41), (:erin, 19), (:zed, 50)]
        push!(remote_g, Triple(_bj_ex[string(who)], _bj_foaf.age, Literal(age)))
        push!(remote_g, Triple(_bj_ex[string(who)], rdf.type, _bj_foaf.Person))
    end
    push!(remote_g, Triple(_bj_ex.alice, _bj_foaf.nick, Literal("Al")))

    q_ages = _BJ_PRE * """
        SELECT ?s ?name ?age WHERE {
          ?s foaf:name ?name .
          SERVICE <$_BJ_EP> { ?s foaf:age ?age }
        }"""

    # ── Options registry ──────────────────────────────────────────────────────
    @testset "registry: set / inspect / clear" begin
        clear_service_options!()
        @test service_options(_BJ_EP) == NamedTuple()
        @test service_options!(_BJ_EP; headers = ["X-API-Key" => "s3cret"],
                               timeout = 60) === nothing   # never echo secrets
        opts = service_options(_BJ_EP)
        @test opts.headers == ["X-API-Key" => "s3cret"]
        @test opts.timeout == 60
        # IRI endpoints are accepted too
        @test service_options(IRI(_BJ_EP)) == opts
        # setting again replaces
        service_options!(_BJ_EP; timeout = 5)
        @test service_options(_BJ_EP) == (timeout = 5,)
        clear_service_options!(_BJ_EP)
        @test service_options(_BJ_EP) == NamedTuple()
        service_options!("http://a.example/"; timeout = 1)
        service_options!("http://b.example/"; timeout = 2)
        clear_service_options!()
        @test service_options("http://a.example/") == NamedTuple()
        @test service_options("http://b.example/") == NamedTuple()
        # validation of SERVICE-level keys
        @test_throws ArgumentError service_options!(_BJ_EP; batch_size = 0)
        @test_throws ArgumentError service_options!(_BJ_EP; bind_join = "yes")
    end

    @testset "headers/auth forwarded to the transport" begin
        _bj_with_transport(remote_g) do calls
            service_options!(_BJ_EP; headers = ["X-API-Key" => "s3cret"],
                             timeout = 60, batch_size = 2)
            r = sparql(local_g, q_ages)
            @test length(r) == 4
            @test !isempty(calls)
            for c in calls
                @test c.endpoint == _BJ_EP
                @test c.kwargs.headers == ["X-API-Key" => "s3cret"]
                @test c.kwargs.timeout == 60
                # SERVICE-level keys are not passed to HTTP
                @test !haskey(c.kwargs, :batch_size)
                @test !haskey(c.kwargs, :bind_join)
            end
            # other endpoints do not see these options
            empty!(calls)
            sparql(local_g, replace(q_ages, _BJ_EP => "http://other.example/sparql"))
            @test all(c -> !haskey(c.kwargs, :headers), calls)
        end
    end

    @testset "query-scoped service_options override" begin
        _bj_with_transport(remote_g) do calls
            service_options!(_BJ_EP; headers = ["X-API-Key" => "global"], timeout = 60)
            r = sparql(local_g, q_ages;
                       service_options = Dict(_BJ_EP => (; headers = ["X-API-Key" => "local"])))
            @test length(r) == 4
            @test all(c -> c.kwargs.headers == ["X-API-Key" => "local"], calls)
            @test all(c -> c.kwargs.timeout == 60, calls)   # merged, not replaced
            # registry untouched by the query-scoped override
            @test service_options(_BJ_EP).headers == ["X-API-Key" => "global"]

            # query-scoped options alone (nothing registered), IRI keys accepted
            clear_service_options!()
            empty!(calls)
            sparql(local_g, q_ages;
                   service_options = Dict(IRI(_BJ_EP) => (; auth = "tok")))
            @test all(c -> c.kwargs.auth == "tok", calls)
        end
    end

    @testset "secrets never rendered into errors" begin
        saved = RDF._REMOTE_SPARQL[]
        RDF._REMOTE_SPARQL[] = (endpoint, query; kwargs...) ->
            error("request failed: headers=$(kwargs[:headers])")
        try
            service_options!(_BJ_EP; headers = ["X-API-Key" => "s3cret"])
            err = try
                sparql(local_g, q_ages); nothing
            catch e
                e
            end
            @test err isa RemoteEndpointError
            @test !occursin("s3cret", sprint(showerror, err))
            # nor in the printed exception stack ("caused by: …")
            stack_txt = try
                sparql(local_g, q_ages); ""
            catch
                sprint(Base.display_error, Base.current_exceptions())
            end
            @test !occursin("s3cret", stack_txt)
        finally
            RDF._REMOTE_SPARQL[] = saved
            clear_service_options!()
        end
    end

    # ── Bind join ─────────────────────────────────────────────────────────────
    @testset "VALUES pushdown" begin
        _bj_with_transport(remote_g) do calls
            r = sparql(local_g, q_ages)
            # one request for the IRI keys, one for the blank-node key
            # (whose ?s column is left out, not sent)
            @test length(calls) == 2
            q = calls[1].query
            @test occursin("VALUES", q)
            @test all(c -> !occursin("_:", c.query), calls)
            @test occursin("<http://bj-test.example.org/alice>", q)
            @test occursin("<http://bj-test.example.org/erin>", q)
            @test !occursin("_:", q)            # blank nodes never shipped
            got = Dict(value(String, row[:name]) => value(Int64, row[:age]) for row in r)
            @test got == Dict("Alice" => 30, "Bob" => 25, "Dave" => 41, "Erin" => 19)
            @test all(v -> !startswith(string(v), "__"), r.variables)  # helper var hidden
        end
    end

    @testset "batching" begin
        _bj_with_transport(remote_g) do calls
            service_options!(_BJ_EP; batch_size = 2)
            r = sparql(local_g, q_ages)
            # 6 distinct ?s keys: 5 IRIs in batches of 2,2,1 + the blank-node
            # key in its own request
            @test length(calls) == 4
            @test all(c -> _bj_values_rows(c.query) <= 2, calls)
            @test sum(c -> _bj_values_rows(c.query), calls) == 6
            @test length(r) == 4

            # bind_join = false → single unrestricted request, same answers
            empty!(calls)
            r0 = sparql(local_g, q_ages;
                        service_options = Dict(_BJ_EP => (; bind_join = false)))
            @test length(calls) == 1
            @test !occursin("VALUES", calls[1].query)
            @test _bj_rows(r0) == _bj_rows(r)
        end
    end

    @testset "equivalence with plain evaluation" begin
        queries = [
            # simple join
            q_ages,
            # OPTIONAL inside SERVICE
            _BJ_PRE * """SELECT * WHERE { ?s foaf:name ?n .
                SERVICE <$_BJ_EP> { ?s a foaf:Person OPTIONAL { ?s foaf:nick ?k } } }""",
            # shared variable unbound in some input rows (UNDEF)
            _BJ_PRE * """SELECT * WHERE { ?x foaf:name ?n OPTIONAL { ?x foaf:knows ?s }
                SERVICE <$_BJ_EP> { ?s foaf:age ?a } }""",
            # two shared variables, one sometimes unbound
            _BJ_PRE * """SELECT * WHERE { ?s foaf:name ?n OPTIONAL { ?s foaf:knows ?k }
                SERVICE <$_BJ_EP> { ?s foaf:age ?a OPTIONAL { ?k foaf:age ?ka } } }""",
            # FILTER scope: !BOUND on a shared OPTIONAL variable
            _BJ_PRE * """SELECT * WHERE { ?s foaf:name ?n OPTIONAL { ?s foaf:knows ?k }
                SERVICE <$_BJ_EP> { ?s a foaf:Person OPTIONAL { ?s foaf:knows ?k }
                                    FILTER(!BOUND(?k)) } }""",
            # duplicate input rows (multiplicity preserved)
            _BJ_PRE * """SELECT ?s ?a WHERE { { ?s foaf:name ?n } UNION { ?s foaf:name ?n }
                SERVICE <$_BJ_EP> { ?s foaf:age ?a } }""",
            # variable shared only through a FILTER (not in scope of the pattern)
            _BJ_PRE * """SELECT * WHERE { ?s foaf:name ?n .
                SERVICE <$_BJ_EP> { ?p foaf:age ?a FILTER(?a > 40 || BOUND(?n)) } }""",
            # no shared variables at all
            _BJ_PRE * """SELECT * WHERE { ?s foaf:knows ?o .
                SERVICE <$_BJ_EP> { ?p foaf:nick ?k } }""",
        ]
        for q in queries, bs in (1, 2, 200)
            _bj_with_transport(remote_g) do calls
                plain = sparql(local_g, q;
                    service_options = Dict(_BJ_EP => (; bind_join = false)))
                bound = sparql(local_g, q;
                    service_options = Dict(_BJ_EP => (; batch_size = bs)))
                @test _bj_rows(bound) == _bj_rows(plain)
                @test length(bound) == length(plain)
            end
        end
    end

    @testset "UNDEF and blank nodes in pushed bindings" begin
        _bj_with_transport(remote_g) do calls
            sparql(local_g, _BJ_PRE * """SELECT * WHERE { ?x foaf:name ?n
                OPTIONAL { ?x foaf:knows ?s } SERVICE <$_BJ_EP> { ?s foaf:age ?a } }""")
            # rows with ?s unbound go in a separate request without a ?s
            # column; UNDEF is never sent
            @test length(calls) == 2
            @test all(c -> !occursin("UNDEF", c.query), calls)
            @test all(c -> !occursin("_:", c.query), calls)
            @test count(c -> occursin("VALUES (?__rdfjl_bj ?s)", c.query), calls) == 1
        end
        # A blank-node-only input never matches remote IRIs
        g = Graph()
        push!(g, Triple(blank!(g), _bj_foaf.name, Literal("Ghost")))
        _bj_with_transport(remote_g) do calls
            r = sparql(g, q_ages)
            @test length(r) == 0
            @test !occursin("_:", calls[1].query)
        end
    end

    @testset "empty input → no remote call" begin
        _bj_with_transport(remote_g) do calls
            r = sparql(local_g, _BJ_PRE * """SELECT * WHERE { ?s foaf:homepage ?h .
                SERVICE <$_BJ_EP> { ?s foaf:age ?a } }""")
            @test length(r) == 0
            @test isempty(calls)
            r = sparql(local_g, _BJ_PRE * """SELECT * WHERE { ?s foaf:homepage ?h .
                SERVICE SILENT <$_BJ_EP> { ?s foaf:age ?a } }""")
            @test length(r) == 0
            @test isempty(calls)
        end
    end

    @testset "SERVICE SILENT per batch" begin
        q_silent = replace(q_ages, "SERVICE <" => "SERVICE SILENT <")
        # batch 2 of 4 fails: its input rows pass through unjoined
        _bj_with_transport(remote_g; fail_on = [2]) do calls
            service_options!(_BJ_EP; batch_size = 2)
            r = sparql(local_g, q_silent)
            @test length(calls) == 4
            # rows of the failed batch have ?age unbound, the rest joined
            unbound = [row for row in r if row[:age] === nothing]
            joined  = [row for row in r if row[:age] !== nothing]
            @test length(unbound) == 2
            @test !isempty(joined)
        end
        # non-silent: the failure propagates
        _bj_with_transport(remote_g; fail_on = [2]) do calls
            service_options!(_BJ_EP; batch_size = 2)
            @test_throws Exception sparql(local_g, q_ages)
        end
    end

    @testset "endpoint result missing the batch index is an error" begin
        saved = RDF._REMOTE_SPARQL[]
        # An endpoint that ignores VALUES and just evaluates the bare pattern
        RDF._REMOTE_SPARQL[] = (endpoint, query; kwargs...) ->
            sparql(remote_g, _BJ_PRE * "SELECT * WHERE { ?s foaf:age ?age }")
        try
            @test_throws RemoteEndpointError sparql(local_g, q_ages)
        finally
            RDF._REMOTE_SPARQL[] = saved
        end
    end

    # ── Optional live smoke test against Wikidata ─────────────────────────────
    @testset "live Wikidata bind join (opt-in)" begin
        if get(ENV, "RDF_LIVE_SERVICE_TESTS", "") != "1"
            @test_skip "set RDF_LIVE_SERVICE_TESTS=1 to run"
        else
            HTTP = Base.require(Main, :HTTP)
            g = Graph()
            wd = Namespace("http://www.wikidata.org/entity/")
            for q in ("Q28865", "Q2005", "Q15777")   # Python, JavaScript, C
                push!(g, Triple(wd[q], IRI("http://example.org/tracked"), Literal(true)))
            end
            r = sparql(g, """
                SELECT ?item ?label WHERE {
                  ?item <http://example.org/tracked> true .
                  SERVICE <https://query.wikidata.org/sparql> {
                    ?item <http://www.w3.org/2000/01/rdf-schema#label> ?label .
                    FILTER(LANG(?label) = "en")
                  }
                }"""; service_options = Dict(
                    "https://query.wikidata.org/sparql" => (; batch_size = 2)))
            @test length(r) == 3
        end
    end
end
