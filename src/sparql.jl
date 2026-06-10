# ── SPARQL 1.1 Query Language ──────────────────────────────────────────────────
#
# This file defines the public API surface and result types for SPARQL 1.1 support.

# ── SPARQL sub-components ─────────────────────────────────────────────────────
include("sparql/ast.jl")
include("sparql/lexer.jl")
include("sparql/parser.jl")
include("sparql/builtins.jl")
include("sparql/render.jl")
include("sparql/eval.jl")
include("sparql/update.jl")

# ── Result type ───────────────────────────────────────────────────────────────

"""
    SolutionSet

The result of a SPARQL SELECT query: an ordered sequence of solution mappings
stored in a column-oriented layout.

Each row maps a projected variable name (`Symbol`) to a bound `RDFTerm`, or
`nothing` if the variable is unbound in that solution (common with OPTIONAL).

Iteration yields [`SolutionRow`](@ref) views; individual rows can be accessed
by integer index (`sol[i]`).  Variable values are retrieved with `row[:name]`.

The Tables.jl interface (via the RDFTablesExt extension) presents unbound
variables as `missing` so that `DataFrame(sol)` works naturally.

For CONSTRUCT / DESCRIBE queries the return type is `Graph`; for ASK it is `Bool`.
"""
struct SolutionSet
    variables::Vector{Symbol}
    _var_idx::Dict{Symbol, Int}          # variable → column index
    _cols::Vector{Vector{Union{RDFTerm, Nothing}}}  # one vector per variable
end

"""
    SolutionRow

A lightweight view of a single row in a [`SolutionSet`](@ref).

Supports:
- `row[:varname]`                     — retrieve a binding (`RDFTerm` or `nothing`)
- `get(row, :varname, default)`       — retrieve with a default
- `keys(row)`                         — all variable names in the parent `SolutionSet`
"""
struct SolutionRow
    _sol::SolutionSet
    _row::Int
end

# ── SolutionSet constructors ──────────────────────────────────────────────────

"""
    SolutionSet(vars::Vector{Symbol}) -> SolutionSet

Construct an empty `SolutionSet` with the given projected variables.
"""
function SolutionSet(vars::Vector{Symbol})
    idx = Dict{Symbol,Int}(v => i for (i, v) in enumerate(vars))
    cols = [Union{RDFTerm,Nothing}[] for _ in vars]
    SolutionSet(vars, idx, cols)
end

"""
    SolutionSet(vars, rows) -> SolutionSet

Construct a `SolutionSet` from a `Vector{Dict{Symbol,Union{RDFTerm,Nothing}}}`.
Provided for compatibility with code that builds result sets row-by-row using
plain dictionaries.
"""
function SolutionSet(vars::Vector{Symbol},
                     rows::Vector{Dict{Symbol, Union{RDFTerm, Nothing}}})
    ss = SolutionSet(vars)
    isempty(rows) && return ss
    for col in ss._cols; sizehint!(col, length(rows)); end
    for row in rows; _ss_push_dict!(ss, row); end
    ss
end

@inline function _ss_push_dict!(ss::SolutionSet,
                                 row::Dict{Symbol, Union{RDFTerm, Nothing}})
    for (i, v) in enumerate(ss.variables)
        push!(ss._cols[i], get(row, v, nothing))
    end
end

# ── SolutionSet interface ─────────────────────────────────────────────────────

Base.length(s::SolutionSet)  = isempty(s._cols) ? 0 : length(s._cols[1])
Base.isempty(s::SolutionSet) = length(s) == 0

"""
    push!(ss::SolutionSet, row::Dict{Symbol,Union{RDFTerm,Nothing}}) -> SolutionSet

Append a solution row (given as a `Dict`) to a `SolutionSet`.
"""
function Base.push!(ss::SolutionSet, row::Dict{Symbol, Union{RDFTerm, Nothing}})
    _ss_push_dict!(ss, row)
    ss
end

Base.getindex(ss::SolutionSet, i::Int) = (@boundscheck checkbounds(ss, i); SolutionRow(ss, i))
Base.checkbounds(ss::SolutionSet, i::Int) =
    (1 <= i <= length(ss)) || throw(BoundsError(ss, i))

function Base.iterate(ss::SolutionSet, state::Int=1)
    state > length(ss) && return nothing
    (SolutionRow(ss, state), state + 1)
end

Base.eltype(::Type{SolutionSet}) = SolutionRow

function Base.:(==)(a::SolutionSet, b::SolutionSet)
    a.variables == b.variables || return false
    length(a) == length(b) || return false
    for i in 1:length(a)
        a[i] == b[i] || return false
    end
    true
end

# ── SolutionRow interface ─────────────────────────────────────────────────────

function Base.getindex(r::SolutionRow, v::Symbol)
    idx = get(r._sol._var_idx, v, 0)
    idx == 0 && return nothing
    @inbounds r._sol._cols[idx][r._row]
end

function Base.get(r::SolutionRow, v::Symbol, default)
    idx = get(r._sol._var_idx, v, 0)
    idx == 0 && return default          # variable not in this SolutionSet
    @inbounds r._sol._cols[idx][r._row] # nothing means "unbound", not "missing key"
end

Base.keys(r::SolutionRow) = r._sol.variables

function Base.:(==)(a::SolutionRow, b::SolutionRow)
    length(a._sol.variables) == length(b._sol.variables) || return false
    for (i, _) in enumerate(a._sol.variables)
        @inbounds a._sol._cols[i][a._row] == b._sol._cols[i][b._row] || return false
    end
    true
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

# ── Result format serialization ───────────────────────────────────────────────
# Included after SolutionSet is defined so the methods can reference it.
include("sparql/results.jl")
