# ── SPARQL 1.1 Query Language ──────────────────────────────────────────────────
#
# This file defines the public API surface and result types for SPARQL 1.1 support.

# ── SPARQL sub-components ─────────────────────────────────────────────────────
include("sparql/ast.jl")
include("sparql/lexer.jl")
include("sparql/parser.jl")
include("sparql/builtins.jl")
include("sparql/eval.jl")
include("sparql/update.jl")

# ── Result type ───────────────────────────────────────────────────────────────

"""
    SolutionSet

The result of a SPARQL SELECT query: an ordered sequence of solution mappings.

Each row maps a projected variable name (`Symbol`) to a bound `RDFTerm`, or
`nothing` if the variable is unbound in that solution (common with OPTIONAL).

The Tables.jl interface (via the RDFTablesExt extension) presents unbound
variables as `missing` so that `DataFrame(sol)` works naturally.

For CONSTRUCT / DESCRIBE queries the return type is `Graph`; for ASK it is `Bool`.
"""
struct SolutionSet
    variables::Vector{Symbol}
    rows::Vector{Dict{Symbol, Union{RDFTerm, Nothing}}}
end

SolutionSet(vars::Vector{Symbol}) =
    SolutionSet(vars, Dict{Symbol, Union{RDFTerm, Nothing}}[])

Base.length(s::SolutionSet)  = length(s.rows)
Base.isempty(s::SolutionSet) = isempty(s.rows)
Base.iterate(s::SolutionSet, state...) = iterate(s.rows, state...)

function Base.:(==)(a::SolutionSet, b::SolutionSet)
    a.variables == b.variables || return false
    length(a.rows) == length(b.rows) || return false
    all(ra == rb for (ra, rb) in zip(a.rows, b.rows))
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    sparql_parse(query::AbstractString)

Parse a SPARQL 1.1 query or update string and return its internal AST.
Returns a `SpQueryUnit` for SELECT/CONSTRUCT/ASK/DESCRIBE queries, or a
`SpUpdateUnit` for SPARQL Update operations.
Throws `ParseError` if the string is syntactically invalid.

Useful for query validation without executing against a dataset.
"""
# sparql_parse is defined in sparql/parser.jl

"""
    sparql(g, query; base=nothing) → SolutionSet | Graph | Bool

Execute a SPARQL 1.1 query against a `Graph` or `Dataset`.

| Query form  | Return type   |
|-------------|---------------|
| SELECT      | `SolutionSet` |
| ASK         | `Bool`        |
| CONSTRUCT   | `Graph`       |
| DESCRIBE    | `Graph`       |

`base` is an optional absolute IRI used to resolve relative IRIs in the query
(e.g. `FROM <relative.ttl>`). When `nothing`, relative IRIs in the query that
lack a `BASE` declaration are resolved against an implementation-defined default.

Throws `ParseError` on a syntactically invalid query, and `RDFError` on
evaluation errors (e.g. an undeclared prefix).
"""
function sparql(g::Union{Graph, Dataset}, query::AbstractString;
                base::Union{AbstractString, Nothing} = nothing)
    unit = sparql_parse(query)
    unit isa SpQueryUnit || error("Expected a query, got an update")
    base_str = base === nothing ? nothing : String(base)
    # Prefer BASE declaration from query over external base
    effective_base = unit.base !== nothing ? unit.base : base_str
    ctx = _SpEvalCtx(g, effective_base)
    _sp_execute_query(unit, ctx)
end

"""
    sparql_update!(ds, update; base=nothing)

Execute a SPARQL 1.1 Update operation against a `Dataset`, mutating it in place.
Multiple update operations separated by `;` are supported.

`base` is an optional absolute IRI used to resolve relative IRIs in the update.

Throws `ParseError` on a syntactically invalid update.
"""
function sparql_update!(ds::Dataset, update::AbstractString;
                        base::Union{AbstractString, Nothing} = nothing)
    unit = sparql_parse(update)
    unit isa SpUpdateUnit || error("Expected an update, got a query")
    base_str = base === nothing ? nothing : String(base)
    # Prefer BASE declaration from update over external base
    effective_base = unit.base !== nothing ? unit.base : base_str
    ctx = _SpEvalCtx(ds, effective_base)
    _sp_execute_update!(unit, ctx)
    nothing
end
