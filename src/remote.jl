# ── Remote SPARQL endpoints ────────────────────────────────────────────────────
#
# Transport hook + a read-only Graph-like view of a remote SPARQL endpoint.
#
# The actual HTTP transport lives in the RDFHTTPExt package extension (it
# needs HTTP.jl).  When the extension loads it installs the transport into
# _REMOTE_SPARQL; everything in this file and the SERVICE evaluator goes
# through that hook so the core package carries no HTTP dependency.

# Callable (endpoint::String, query::String; kwargs...) -> SolutionSet | Bool | Graph,
# or `nothing` when HTTP.jl has not been loaded.
const _REMOTE_SPARQL = Ref{Any}(nothing)

function _remote_sparql(endpoint::AbstractString, query::AbstractString; kwargs...)
    f = _REMOTE_SPARQL[]
    f === nothing && throw(RemoteEndpointError(String(endpoint),
        "remote SPARQL support requires HTTP.jl: run `using HTTP` to activate " *
        "the RDFHTTPExt extension, then retry"))
    f(endpoint, query; kwargs...)
end

# ── Per-endpoint options for federated SERVICE calls ──────────────────────────
#
# SERVICE clauses name only an endpoint IRI, so anything else a request needs
# (credentials, headers, timeouts) is registered out-of-band, per endpoint.

const _SERVICE_OPTIONS      = Dict{String, NamedTuple}()
const _SERVICE_OPTIONS_LOCK = ReentrantLock()

# Default number of distinct input bindings sent per bind-join request.
const SERVICE_DEFAULT_BATCH_SIZE = 200

# Keys consumed by the SERVICE evaluator itself; everything else is forwarded
# to the HTTP transport.
const _SERVICE_CONTROL_KEYS = (:batch_size, :bind_join)

_service_key(endpoint::AbstractString) = String(endpoint)
_service_key(endpoint::IRI)            = endpoint.value

function _validate_service_options(opts::NamedTuple)
    if haskey(opts, :batch_size)
        bs = opts.batch_size
        (bs isa Integer && bs > 0) ||
            throw(ArgumentError("SERVICE batch_size must be a positive integer"))
    end
    if haskey(opts, :bind_join)
        opts.bind_join isa Bool ||
            throw(ArgumentError("SERVICE bind_join must be true or false"))
    end
    opts
end

"""
    service_options!(endpoint; kwargs...) → nothing

Register options used whenever a SPARQL `SERVICE <endpoint> { … }` clause is
evaluated by the local [`sparql`](@ref).  `endpoint` is a string or [`IRI`](@ref)
and must match the IRI written in the query exactly.  Calling it again replaces
the endpoint's previous options.

HTTP keyword arguments (`headers`, `auth`, `timeout`, `retries`, …) are
forwarded to the transport exactly as [`RemoteGraph`](@ref) forwards its
keyword arguments — see the remote `sparql` documentation for the full list.
Two keys are consumed by the `SERVICE` evaluator itself:

- `batch_size::Int` (default $(SERVICE_DEFAULT_BATCH_SIZE)) — number of distinct
  input bindings sent per request when bind-joining (see [`sparql`](@ref)).
- `bind_join::Bool` (default `true`) — set `false` to send the bare pattern
  and join locally (one request, every remote solution of the pattern).

```julia
using RDF, HTTP
service_options!("https://sparql.onetcenter.org";
                 headers = ["X-API-Key" => ENV["ONET_KEY"]], timeout = 60)
```

Returns `nothing` so credentials are not echoed in a REPL or notebook.  Options
are never rendered into error messages.  Inspect with [`service_options`](@ref),
remove with [`clear_service_options!`](@ref); per-query overrides go through
`sparql(g, q; service_options = …)`.
"""
function service_options!(endpoint::Union{AbstractString, IRI}; kwargs...)
    opts = _validate_service_options(NamedTuple(kwargs))
    lock(_SERVICE_OPTIONS_LOCK) do
        _SERVICE_OPTIONS[_service_key(endpoint)] = opts
    end
    nothing
end

"""
    service_options(endpoint) → NamedTuple

The options registered for `endpoint` with [`service_options!`](@ref), or an
empty `NamedTuple` when none are set.
"""
service_options(endpoint::Union{AbstractString, IRI}) =
    lock(_SERVICE_OPTIONS_LOCK) do
        get(_SERVICE_OPTIONS, _service_key(endpoint), NamedTuple())
    end

"""
    clear_service_options!(endpoint) → nothing
    clear_service_options!()         → nothing

Remove the options registered for one endpoint, or for every endpoint.
"""
function clear_service_options!(endpoint::Union{AbstractString, IRI})
    lock(_SERVICE_OPTIONS_LOCK) do
        delete!(_SERVICE_OPTIONS, _service_key(endpoint))
    end
    nothing
end

function clear_service_options!()
    lock(_SERVICE_OPTIONS_LOCK) do
        empty!(_SERVICE_OPTIONS)
    end
    nothing
end

# Normalise the query-scoped `service_options` keyword of `sparql(g, q)`.
_normalize_service_options(::Nothing) = Dict{String, NamedTuple}()
function _normalize_service_options(d::AbstractDict)
    out = Dict{String, NamedTuple}()
    for (k, v) in d
        (k isa AbstractString || k isa IRI) || throw(ArgumentError(
            "service_options keys must be endpoint strings or IRIs"))
        nt = v isa NamedTuple ? v : NamedTuple(Symbol(first(p)) => last(p) for p in pairs(v))
        out[_service_key(k)] = _validate_service_options(nt)
    end
    out
end
_normalize_service_options(x) = throw(ArgumentError(
    "service_options must be a Dict mapping endpoint => NamedTuple of options"))

# Effective options for one endpoint: registry, overridden by query scope.
_service_effective_options(endpoint::String, scoped::Dict{String, NamedTuple}) =
    merge(service_options(endpoint), get(scoped, endpoint, NamedTuple()))

"""
    RemoteGraph(endpoint::AbstractString; kwargs...)

A **read-only**, Graph-like view of a remote SPARQL endpoint.  Pattern matching,
counting, membership tests, and iteration are translated into SPARQL Protocol
requests, so data never has to fit in local memory:

```julia
using RDF, HTTP

wikidata = RemoteGraph("https://query.wikidata.org/sparql")

# Pattern match → SELECT query
for t in match(wikidata; subject=IRI("http://www.wikidata.org/entity/Q42"),
                          predicate=IRI("http://www.wikidata.org/prop/direct/P31"))
    println(t.object)
end

# Membership test → ASK query
Triple(s, p, o) in wikidata

# Forward a full SPARQL query
sparql(wikidata, "SELECT ?s WHERE { ?s ?p ?o } LIMIT 10")
```

Keyword arguments (`auth`, `headers`, `timeout`, …) are stored and forwarded
to every HTTP request — see the remote `sparql` documentation for the full
list.  Requires HTTP.jl (`using HTTP`).

Supported operations: [`match`](@ref), `length`, `isempty`, `in`, iteration
(`collect`), and [`sparql`](@ref).  Mutation (`push!`, `delete!`) is not
supported; use `sparql_update!` against an update endpoint instead.
"""
struct RemoteGraph
    endpoint::String
    http_kwargs::NamedTuple
end

RemoteGraph(endpoint::AbstractString; kwargs...) =
    RemoteGraph(String(endpoint), NamedTuple(kwargs))

Base.show(io::IO, rg::RemoteGraph) = print(io, "RemoteGraph(\"", rg.endpoint, "\")")

_rg_query(rg::RemoteGraph, q::AbstractString) =
    _remote_sparql(rg.endpoint, q; rg.http_kwargs...)

"""
    sparql(rg::RemoteGraph, query; kwargs...) → SolutionSet | Bool | Graph

Execute a SPARQL query against the endpoint behind `rg`.  Keyword arguments
are merged with (and override) those stored in the `RemoteGraph`.
"""
sparql(rg::RemoteGraph, query::AbstractString; kwargs...) =
    _remote_sparql(rg.endpoint, query; rg.http_kwargs..., kwargs...)

# Render one match-pattern position: a constant term or a variable.
function _rg_position(term::Union{RDFTerm, Nothing}, var::String)::String
    term === nothing && return var
    term isa BlankNode &&
        throw(ArgumentError("blank nodes cannot be matched against a remote " *
                            "endpoint: blank node labels are scoped to the " *
                            "remote document"))
    sprint(_sp_render_rdfterm, term)
end

"""
    match(rg::RemoteGraph; subject=nothing, predicate=nothing, object=nothing)
        -> Vector{Triple}

Pattern matching against a remote endpoint.  Unbound positions are wildcards.
Translates to a `SELECT` query (or `ASK` when all three positions are bound)
and materialises the matching triples.
"""
function match(rg::RemoteGraph;
               subject::Union{SubjectTerm, Nothing}     = nothing,
               predicate::Union{PredicateTerm, Nothing} = nothing,
               object::Union{ObjectTerm, Nothing}       = nothing)
    s_txt = _rg_position(subject,   "?s")
    p_txt = _rg_position(predicate, "?p")
    o_txt = _rg_position(object,    "?o")

    if subject !== nothing && predicate !== nothing && object !== nothing
        hit = _rg_query(rg, "ASK { $s_txt $p_txt $o_txt }")
        return hit === true ? [Triple(subject, predicate, object)] : Triple[]
    end

    vars = String[]
    subject   === nothing && push!(vars, "?s")
    predicate === nothing && push!(vars, "?p")
    object    === nothing && push!(vars, "?o")
    ss = _rg_query(rg, "SELECT $(join(vars, ' ')) WHERE { $s_txt $p_txt $o_txt }")
    ss isa SolutionSet || throw(RemoteEndpointError(rg.endpoint,
        "endpoint returned $(typeof(ss)); expected SELECT solutions"))

    out = Triple[]
    sizehint!(out, length(ss))
    for row in ss
        s = subject   === nothing ? row[:s] : subject
        p = predicate === nothing ? row[:p] : predicate
        o = object    === nothing ? row[:o] : object
        (s === nothing || p === nothing || o === nothing) && continue
        push!(out, Triple(s::SubjectTerm, p::IRI, o::ObjectTerm))
    end
    out
end

function Base.length(rg::RemoteGraph)
    ss = _rg_query(rg, "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }")
    (ss isa SolutionSet && length(ss) == 1) || throw(RemoteEndpointError(
        rg.endpoint, "endpoint returned an unexpected COUNT result"))
    n = ss[1][:n]
    n isa Literal || throw(RemoteEndpointError(
        rg.endpoint, "endpoint returned a non-literal COUNT result"))
    value(Int64, n)
end

Base.isempty(rg::RemoteGraph) = _rg_query(rg, "ASK { ?s ?p ?o }") !== true

function Base.in(t::Triple, rg::RemoteGraph)
    s_txt = _rg_position(t.subject,   "?s")
    p_txt = _rg_position(t.predicate, "?p")
    o_txt = _rg_position(t.object,    "?o")
    _rg_query(rg, "ASK { $s_txt $p_txt $o_txt }") === true
end

function Base.iterate(rg::RemoteGraph)
    ts = match(rg)
    isempty(ts) && return nothing
    (ts[1], (ts, 2))
end

function Base.iterate(::RemoteGraph, state::Tuple{Vector{Triple}, Int})
    ts, i = state
    i > length(ts) && return nothing
    (ts[i], (ts, i + 1))
end

Base.eltype(::Type{RemoteGraph}) = Triple
Base.IteratorSize(::Type{RemoteGraph}) = Base.SizeUnknown()

Base.push!(::RemoteGraph, ::Triple) = throw(ArgumentError(
    "RemoteGraph is read-only; use sparql_update! against an update endpoint"))
Base.delete!(::RemoteGraph, ::Triple) = throw(ArgumentError(
    "RemoteGraph is read-only; use sparql_update! against an update endpoint"))
