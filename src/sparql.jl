# ── SPARQL 1.1 Query Language ──────────────────────────────────────────────────
#
# This file defines the public API surface and result types for SPARQL 1.1 support.
# The implementation (parser, algebra translator, evaluator) is forthcoming;
# these stubs allow the test harness to compile and drive development.

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
Throws `ParseError` if the string is syntactically invalid.

Useful for query validation without executing against a dataset.
"""
function sparql_parse(query::AbstractString)
    error("SPARQL query parsing is not yet implemented")
end

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
    error("SPARQL query execution is not yet implemented")
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
    error("SPARQL update execution is not yet implemented")
end
