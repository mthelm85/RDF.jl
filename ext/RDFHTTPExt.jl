"""
RDFHTTPExt — remote SPARQL endpoint client for RDF.jl
======================================================

Activated automatically when both RDF and HTTP are loaded:

    using RDF, HTTP

Provides an overload of `sparql` that queries remote SPARQL 1.1 endpoints
over HTTP using the W3C SPARQL Protocol (application/x-www-form-urlencoded POST,
with GET fallback for short queries):

    results = sparql("https://query.wikidata.org/sparql", query)

Return types mirror the local `sparql(dataset, query)` API:
  • SELECT  → SolutionSet
  • ASK     → Bool
  • CONSTRUCT / DESCRIBE → Graph  (parsed from Turtle or N-Triples response)
"""
module RDFHTTPExt

using RDF
using HTTP
using Base64

# ── Query-type detection ───────────────────────────────────────────────────────
#
# Scans past PREFIX/BASE declarations to find the first operative keyword.
# Returns one of :select, :ask, :construct, :describe.

function _detect_query_type(query::AbstractString)::Symbol
    for line in eachline(IOBuffer(query))
        # Strip comments
        stripped = strip(replace(line, r"#[^\"]*$" => ""))
        isempty(stripped) && continue
        m = match(r"^\s*([A-Za-z]+)", stripped)
        m === nothing && continue
        kw = uppercase(m.captures[1])
        kw in ("PREFIX", "BASE") && continue
        kw == "SELECT"    && return :select
        kw == "ASK"       && return :ask
        kw == "CONSTRUCT" && return :construct
        kw == "DESCRIBE"  && return :describe
        # Unknown first keyword — fall through to default
        break
    end
    return :select   # conservative default
end

# ── Content-type helpers ───────────────────────────────────────────────────────

function _ct_contains(ct::AbstractString, token::AbstractString)
    occursin(token, lowercase(ct))
end

# ── Response parser (RDF graph) ────────────────────────────────────────────────

function _parse_rdf_response(resp::HTTP.Response)::Graph
    ct = HTTP.header(resp, "Content-Type", "text/turtle")
    io = IOBuffer(resp.body)
    if _ct_contains(ct, "n-triples") || _ct_contains(ct, "application/n-triples")
        return Base.read(io, MIME"application/n-triples"(), Graph)
    else
        # Turtle is the preferred and most widely supported RDF serialisation
        return Base.read(io, MIME"text/turtle"(), Graph)
    end
end

# ── Main API ───────────────────────────────────────────────────────────────────

"""
    sparql(endpoint, query; kwargs...) → SolutionSet | Bool | Graph

Execute a SPARQL 1.1 query against a remote HTTP endpoint.

# Arguments
- `endpoint::AbstractString` — SPARQL endpoint URL
  (e.g. `"https://query.wikidata.org/sparql"`)
- `query::AbstractString`    — SPARQL 1.1 query string

# Keyword arguments
| Keyword          | Type                          | Default  | Description |
|------------------|-------------------------------|----------|-------------|
| `timeout`        | `Real`                        | `60`     | Read timeout in seconds |
| `auth`           | `Nothing`, `Tuple`, `String`  | `nothing`| `("user","pass")` for Basic; `"token"` for Bearer |
| `prefixes`       | `AbstractDict`                | `Dict()` | Extra `PREFIX` declarations prepended to the query |
| `default_graph`  | `AbstractString`, `IRI`, `Nothing` | `nothing` | `default-graph-uri` parameter |
| `named_graph`    | `AbstractString`, `IRI`, `Nothing` | `nothing` | `named-graph-uri` parameter |
| `method`         | `Symbol`                      | `:auto`  | `:get`, `:post`, or `:auto` (GET for ≤ 2 kB, POST otherwise) |
| `retries`        | `Int`                         | `2`      | Number of retry attempts on transient errors (5xx) |

# Return types
| Query form  | Return type   |
|-------------|---------------|
| SELECT      | `SolutionSet` |
| ASK         | `Bool`        |
| CONSTRUCT   | `Graph`       |
| DESCRIBE    | `Graph`       |

# Examples
```julia
using RDF, HTTP

# Query Wikidata for chemical elements
query = \"\"\"
  PREFIX wd:  <http://www.wikidata.org/entity/>
  PREFIX wdt: <http://www.wikidata.org/prop/direct/>
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
  SELECT ?element ?name WHERE {
    ?element wdt:P31 wd:Q11344 ;
             rdfs:label ?name .
    FILTER(LANG(?name) = "en")
  } ORDER BY ?name LIMIT 20
\"\"\"
results = sparql("https://query.wikidata.org/sparql", query)
for row in results
    println(value(String, row[:name]))
end

# ASK query
exists = sparql("https://query.wikidata.org/sparql",
                "ASK { wd:Q2 wdt:P31 wd:Q523 }";
                prefixes=Dict("wd" => "http://www.wikidata.org/entity/",
                              "wdt" => "http://www.wikidata.org/prop/direct/"))

# With Basic authentication
results = sparql("https://my-endpoint.example/sparql", query;
                 auth=("username", "password"))

# With Bearer token
results = sparql("https://my-endpoint.example/sparql", query;
                 auth="my-bearer-token")
```
"""
function RDF.sparql(endpoint::AbstractString, query::AbstractString;
                    timeout::Real    = 60,
                    auth             = nothing,
                    prefixes::AbstractDict = Dict{String,String}(),
                    default_graph    = nothing,
                    named_graph      = nothing,
                    method::Symbol   = :auto,
                    retries::Int     = 2)

    qtype = _detect_query_type(query)

    # Prepend any caller-supplied prefix declarations
    if !isempty(prefixes)
        prefix_lines = join(
            ["PREFIX $(k): <$(v)>" for (k, v) in prefixes], "\n")
        query = prefix_lines * "\n" * query
    end

    # Accept header: prefer the most information-rich parseable format
    accept = if qtype in (:select, :ask)
        # Always request JSON — widely supported and we have a fast reader
        "application/sparql-results+json"
    else
        # Turtle first, N-Triples as fallback (both parseable without extra deps)
        "text/turtle;q=1.0, application/n-triples;q=0.9"
    end

    # Build request headers
    headers = Pair{String,String}[
        "Accept"       => accept,
        "Content-Type" => "application/x-www-form-urlencoded",
        "User-Agent"   => "RDF.jl/0.1 (+https://github.com/mthelm85/RDF.jl)",
    ]

    if auth !== nothing
        if auth isa Tuple
            creds = base64encode("$(auth[1]):$(auth[2])")
            push!(headers, "Authorization" => "Basic $creds")
        elseif auth isa AbstractString
            push!(headers, "Authorization" => "Bearer $auth")
        end
    end

    # Build URL-encoded form body (SPARQL Protocol §2.1)
    params = Pair{String,String}["query" => query]
    if default_graph !== nothing
        dg = default_graph isa IRI ? default_graph.value : string(default_graph)
        push!(params, "default-graph-uri" => dg)
    end
    if named_graph !== nothing
        ng = named_graph isa IRI ? named_graph.value : string(named_graph)
        push!(params, "named-graph-uri" => ng)
    end
    body = HTTP.URIs.escapeuri(params)

    # Decide GET vs POST
    use_get = (method === :get) ||
              (method === :auto && ncodeunits(body) <= 2048)

    timeout_ms = round(Int, timeout * 1000)

    # Make the request with retry on transient server errors
    resp = _http_request(endpoint, headers, body, use_get, timeout_ms, retries)

    # Parse and return
    if qtype in (:select, :ask)
        body_str = String(resp.body)
        return read_sparql_json(body_str)
    else
        return _parse_rdf_response(resp)
    end
end

# Retry wrapper: transparent retries on 5xx or connection errors.
function _http_request(endpoint::AbstractString,
                       headers,
                       body::AbstractString,
                       use_get::Bool,
                       timeout_ms::Int,
                       retries::Int)
    last_exc = nothing
    for attempt in 1:(retries + 1)
        try
            resp = if use_get
                url = endpoint * (occursin('?', endpoint) ? "&" : "?") * body
                HTTP.get(url, headers;
                         readtimeout = timeout_ms,
                         status_exception = false)
            else
                HTTP.post(endpoint, headers, body;
                          readtimeout = timeout_ms,
                          status_exception = false)
            end

            # 2xx → success
            if resp.status < 300
                return resp
            end

            # 4xx → client error, do not retry
            if resp.status < 500
                _sparql_http_error(resp)
            end

            # 5xx → transient, retry after a short back-off
            last_exc = ErrorException(
                "SPARQL endpoint returned $(resp.status): " *
                _truncate(String(resp.body), 200))
            attempt <= retries && sleep(0.5 * attempt)

        catch exc
            # Network-level errors (connection refused, timeout, etc.) are retried
            last_exc = exc
            attempt <= retries && sleep(0.5 * attempt)
        end
    end
    throw(last_exc)
end

function _sparql_http_error(resp::HTTP.Response)
    msg = _truncate(String(resp.body), 400)
    error("SPARQL endpoint error $(resp.status): $msg")
end

_truncate(s::AbstractString, n::Int) =
    length(s) <= n ? s : s[1:n] * "…"


# ── Vocabulary loading over HTTP ───────────────────────────────────────────────

"""
    load_vocabulary(url; base=nothing, format=nothing) -> Vocabulary

Fetch and load an RDF vocabulary from an HTTP/HTTPS URL.

Content-negotiation requests Turtle first (`q=1.0`), then N-Triples (`q=0.9`),
then JSON-LD (`q=0.7`).  Pass `format` to request a specific MIME type instead.

Activated automatically when `HTTP.jl` is loaded alongside `RDF.jl`.

# Examples

```julia
using RDF, HTTP

ctdl = load_vocabulary("https://credreg.net/ctdl/schema/encoding/turtle";
                        base="http://purl.org/ctdl/terms/")

ctdl.BachelorDegree          # => IRI("http://purl.org/ctdl/terms/BachelorDegree")
label(ctdl, ctdl.Course)     # => "Course"
```
"""
function RDF._vocab_load_http(source::AbstractString;
                               base   = nothing,
                               format = nothing)
    accept = if format !== nothing
        string(format)   # e.g. "text/turtle"
    else
        "text/turtle;q=1.0, application/n-triples;q=0.9, application/ld+json;q=0.7"
    end

    headers = Pair{String,String}[
        "Accept"     => accept,
        "User-Agent" => "RDF.jl/0.1 (+https://github.com/mthelm85/RDF.jl)",
    ]

    resp = _http_request(source, headers, "", true, 60_000, 2)

    ct = HTTP.header(resp, "Content-Type", "text/turtle")
    io = IOBuffer(resp.body)

    g = if _ct_contains(ct, "n-triples")
        Base.read(io, MIME"application/n-triples"(), Graph)
    elseif _ct_contains(ct, "ld+json") || _ct_contains(ct, "application/json")
        ds = Base.read(io, MIME"application/ld+json"(), Dataset)
        RDF._dataset_to_graph(ds)
    else
        # Turtle is the default / most common for vocabulary endpoints
        Base.read(io, MIME"text/turtle"(), Graph)
    end

    RDF.Vocabulary(g; base=base)
end

end # module RDFHTTPExt
