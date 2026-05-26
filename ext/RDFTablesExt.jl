module RDFTablesExt

using RDF, Tables, Dates

# ── Term coercion ─────────────────────────────────────────────────────────────
#
# Each RDFTerm is mapped to the most appropriate native Julia type so that
# DataFrame columns contain plain Julia values rather than RDF wrappers:
#
#   IRI        → String  (the full IRI string)
#   BlankNode  → String  ("_:b{id}")
#   TripleTerm → String  (serialized <<subject predicate object>>)
#   Literal    → typed by XSD datatype:
#     xsd:integer and integer sub-types → Int64
#     xsd:double / xsd:float / xsd:decimal → Float64
#     xsd:boolean → Bool
#     xsd:date    → Dates.Date
#     xsd:dateTime → Dates.DateTime
#     all other literals (xsd:string, rdf:langString, …) → String (lexical form)
#
# Unbound SPARQL variables (nothing) become `missing`.

const _XSD = "http://www.w3.org/2001/XMLSchema#"

const _INT_TYPES = Set{String}([
    _XSD * "integer",            _XSD * "int",              _XSD * "long",
    _XSD * "short",              _XSD * "byte",
    _XSD * "nonNegativeInteger", _XSD * "positiveInteger",
    _XSD * "nonPositiveInteger", _XSD * "negativeInteger",
    _XSD * "unsignedInt",        _XSD * "unsignedLong",
    _XSD * "unsignedShort",      _XSD * "unsignedByte",
])

function _coerce_term(t::RDF.RDFTerm)
    t isa RDF.IRI       && return t.value
    t isa RDF.BlankNode && return string(t)                # "_:b{id}"
    if t isa RDF.Literal
        dt = t.datatype.value
        lf = t.lexical_form
        dt in _INT_TYPES        && return something(tryparse(Int64,        lf), lf)
        dt == _XSD * "double"   && return something(tryparse(Float64,      lf), lf)
        dt == _XSD * "float"    && return something(tryparse(Float64,      lf), lf)
        dt == _XSD * "decimal"  && return something(tryparse(Float64,      lf), lf)
        dt == _XSD * "boolean"  && return lf == "true"
        dt == _XSD * "date"     && return something(tryparse(Dates.Date,   lf), lf)
        if dt == _XSD * "dateTime"
            # Strip timezone suffix before parsing (Julia's DateTime doesn't support it)
            clean = replace(lf, r"Z$|[+-]\d{2}:\d{2}$" => "")
            return something(tryparse(Dates.DateTime, clean), lf)
        end
        return lf  # xsd:string, rdf:langString, unknown → lexical form as String
    end
    return string(t)  # TripleTerm or any future term type
end

# Build a correctly typed Vector from a Vector{Any} of coerced values (and `missing`).
#
# Rules:
#   • All non-missing values share one type T  →  Vector{T} or Vector{Union{T,Missing}}
#   • Mix of Int64 and Float64                 →  Vector{Float64} (numeric promotion)
#   • Any other mix                            →  Vector{String}  (stringify all)
function _typed_column(vals::Vector{Any})
    has_missing = any(v -> v === missing, vals)
    non_missing = [v for v in vals if v !== missing]

    if isempty(non_missing)
        return Union{String, Missing}[missing for _ in vals]
    end

    types = unique!(map(typeof, non_missing))

    T = if length(types) == 1
        only(types)
    elseif all(t -> t <: Union{Int64, Float64}, types)
        Float64   # promote mixed integer/float
    else
        nothing   # heterogeneous — fall back to String
    end

    if T !== nothing
        promote = T === Float64
        if has_missing
            return Union{T, Missing}[
                v === missing ? missing : (promote ? Float64(v) : v) for v in vals]
        else
            return promote ? Float64[Float64(v) for v in vals] : T[v for v in vals]
        end
    end

    # Heterogeneous: stringify everything
    strs = [v === missing ? missing : string(v) for v in vals]
    return has_missing ? Union{String, Missing}[v for v in strs] :
                         String[v for v in strs]
end

# ── Triple match (Graph) ──────────────────────────────────────────────────────
#
# Materialises the lazy iterator into typed column vectors.
# subject and predicate are always IRIs (or BlankNode for subjects) → String.
# object can be any RDFTerm; its column type is inferred from the actual values.

Tables.istable(::Type{RDF._TripleMatchIterator})      = true
Tables.columnaccess(::Type{RDF._TripleMatchIterator}) = true
Tables.columnnames(::RDF._TripleMatchIterator)        = (:subject, :predicate, :object)

function Tables.columns(it::RDF._TripleMatchIterator)
    subj_col = String[]
    pred_col = String[]
    obj_raw  = Any[]

    for t in it
        push!(subj_col, t.subject isa RDF.IRI ? t.subject.value : string(t.subject))
        push!(pred_col, t.predicate.value)
        push!(obj_raw,  _coerce_term(t.object))
    end

    (subject   = subj_col,
     predicate = pred_col,
     object    = _typed_column(obj_raw))
end

Tables.schema(::RDF._TripleMatchIterator) = nothing   # inferred from columns at construction time

# ── Quad match (Dataset) ──────────────────────────────────────────────────────

Tables.istable(::Type{RDF._DatasetMatchIterator})      = true
Tables.columnaccess(::Type{RDF._DatasetMatchIterator}) = true
Tables.columnnames(::RDF._DatasetMatchIterator)        = (:subject, :predicate, :object, :graph)

function Tables.columns(it::RDF._DatasetMatchIterator)
    subj_col  = String[]
    pred_col  = String[]
    obj_raw   = Any[]
    graph_col = Union{String, Missing}[]

    for q in it
        push!(subj_col, q.subject isa RDF.IRI ? q.subject.value : string(q.subject))
        push!(pred_col, q.predicate.value)
        push!(obj_raw,  _coerce_term(q.object))
        gv = q.graph
        push!(graph_col, gv === nothing ? missing :
              (gv isa RDF.IRI ? gv.value : string(gv)))
    end

    (subject   = subj_col,
     predicate = pred_col,
     object    = _typed_column(obj_raw),
     graph     = graph_col)
end

Tables.schema(::RDF._DatasetMatchIterator) = nothing

# ── SolutionSet (SPARQL SELECT results) ──────────────────────────────────────
#
# Each SPARQL variable becomes a column typed by the actual values in that
# column.  Unbound variables (OPTIONAL bindings) become `missing`.

Tables.istable(::Type{RDF.SolutionSet})      = true
Tables.columnaccess(::Type{RDF.SolutionSet}) = true
Tables.columns(ss::RDF.SolutionSet)          = ss
Tables.columnnames(ss::RDF.SolutionSet)      = ss.variables

function Tables.getcolumn(ss::RDF.SolutionSet, nm::Symbol)
    idx = get(ss._var_idx, nm, 0)
    idx == 0 && throw(ArgumentError("SolutionSet has no variable :$(nm)"))
    raw = Any[v === nothing ? missing : _coerce_term(v) for v in ss._cols[idx]]
    _typed_column(raw)
end

function Tables.getcolumn(ss::RDF.SolutionSet, i::Int)
    Tables.getcolumn(ss, ss.variables[i])
end

function Tables.schema(ss::RDF.SolutionSet)
    types = [eltype(Tables.getcolumn(ss, v)) for v in ss.variables]
    Tables.Schema(ss.variables, types)
end

end # module RDFTablesExt
