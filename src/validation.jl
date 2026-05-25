"""
    ValidationWarning

A warning produced by [`validate`](@ref), containing:
- `triple::Triple` — the offending triple
- `message::String` — human-readable description
- `code::Symbol` — machine-readable code (`:invalid_lang_tag`, `:ill_typed_literal`)
"""
struct ValidationWarning
    triple::Triple
    message::String
    code::Symbol
end

"""
    validate(g::Graph) -> Vector{ValidationWarning}
    validate(ds::Dataset) -> Vector{ValidationWarning}

Check all literals in `g` (or `ds`) for conformance issues and return a list of
`ValidationWarning`s. An empty list means no issues were found.

Checks performed:
- Language tags must conform to BCP47 syntax
- Lexical forms must be valid for known XSD datatypes

```julia
warns = validate(g)
isempty(warns) || foreach(w -> @warn(w.message), warns)
```
"""
function validate(g::Graph)::Vector{ValidationWarning}
    warnings = ValidationWarning[]
    for t in g
        _check_triple!(warnings, t)
    end
    warnings
end

function validate(ds::Dataset)::Vector{ValidationWarning}
    warnings = ValidationWarning[]
    for t in ds.default_graph
        _check_triple!(warnings, t)
    end
    for g in values(ds.named_graphs)
        for t in g
            _check_triple!(warnings, t)
        end
    end
    warnings
end

function _check_triple!(warnings::Vector{ValidationWarning}, t::Triple)
    _check_literal!(warnings, t, t.object)
end

function _check_literal!(warnings, t, obj)
    obj isa Literal || return
    lit = obj::Literal
    # Check language tag BCP47 conformance (basic check)
    if !isempty(lit.language_tag) && !_valid_lang_tag(lit.language_tag)
        push!(warnings, ValidationWarning(t, "Language tag '$(lit.language_tag)' does not conform to BCP47", :invalid_lang_tag))
    end
    # Check ill-typed literals for known datatypes
    if _is_known_datatype(lit.datatype)
        ok = _check_lexical_form(lit.lexical_form, lit.datatype)
        if !ok
            push!(warnings, ValidationWarning(t,
                "Lexical form $(repr(lit.lexical_form)) is not valid for datatype <$(lit.datatype.value)>",
                :ill_typed_literal))
        end
    end
end

# BCP47 + RDF 1.2 directional tags: primary tag, optional subtags, optional --dir suffix
const _LANG_RE = r"^[a-z]{1,8}(-[a-z0-9]{1,8})*(--[a-z]{2,3})?$"i

_valid_lang_tag(tag::String) = occursin(_LANG_RE, tag)

# Pre-defined XSD datatype IRI strings — avoids string allocation on every validate() call
const _VAL_XSD          = "http://www.w3.org/2001/XMLSchema#"
const _VAL_XSD_INTEGER  = _VAL_XSD * "integer"
const _VAL_XSD_NONNEG   = _VAL_XSD * "nonNegativeInteger"
const _VAL_XSD_POS      = _VAL_XSD * "positiveInteger"
const _VAL_XSD_NONPOS   = _VAL_XSD * "nonPositiveInteger"
const _VAL_XSD_NEG      = _VAL_XSD * "negativeInteger"
const _VAL_XSD_LONG     = _VAL_XSD * "long"
const _VAL_XSD_INT      = _VAL_XSD * "int"
const _VAL_XSD_SHORT    = _VAL_XSD * "short"
const _VAL_XSD_BYTE     = _VAL_XSD * "byte"
const _VAL_XSD_ULONG    = _VAL_XSD * "unsignedLong"
const _VAL_XSD_UINT     = _VAL_XSD * "unsignedInt"
const _VAL_XSD_USHORT   = _VAL_XSD * "unsignedShort"
const _VAL_XSD_UBYTE    = _VAL_XSD * "unsignedByte"
const _VAL_XSD_DECIMAL  = _VAL_XSD * "decimal"
const _VAL_XSD_DOUBLE   = _VAL_XSD * "double"
const _VAL_XSD_FLOAT    = _VAL_XSD * "float"
const _VAL_XSD_BOOLEAN  = _VAL_XSD * "boolean"
const _VAL_XSD_DATE     = _VAL_XSD * "date"
const _VAL_XSD_DATETIME = _VAL_XSD * "dateTime"
const _VAL_XSD_DT_STAMP = _VAL_XSD * "dateTimeStamp"

function _is_known_datatype(dt::IRI)
    startswith(dt.value, _VAL_XSD)
end

function _check_lexical_form(lex::String, dt::IRI)::Bool
    s = dt.value
    if s == _VAL_XSD_INTEGER || s == _VAL_XSD_NONNEG  || s == _VAL_XSD_POS   ||
       s == _VAL_XSD_NONPOS  || s == _VAL_XSD_NEG     || s == _VAL_XSD_LONG  ||
       s == _VAL_XSD_INT     || s == _VAL_XSD_SHORT   || s == _VAL_XSD_BYTE  ||
       s == _VAL_XSD_ULONG   || s == _VAL_XSD_UINT    || s == _VAL_XSD_USHORT ||
       s == _VAL_XSD_UBYTE
        return tryparse(Int64, lex) !== nothing || tryparse(BigInt, lex) !== nothing
    elseif s == _VAL_XSD_DECIMAL
        return tryparse(BigFloat, lex) !== nothing
    elseif s == _VAL_XSD_DOUBLE || s == _VAL_XSD_FLOAT
        return lex in ("INF", "-INF", "NaN") || tryparse(Float64, lex) !== nothing
    elseif s == _VAL_XSD_BOOLEAN
        return lex in ("true", "false", "1", "0")
    elseif s == _VAL_XSD_DATE
        return _valid_xsd_date(lex)
    elseif s == _VAL_XSD_DATETIME || s == _VAL_XSD_DT_STAMP
        return _valid_xsd_datetime(lex)
    end
    true  # unknown XSD type: accept
end

const _DATE_RE     = r"^-?\d{4,}-\d{2}-\d{2}(Z|[+-]\d{2}:\d{2})?$"
const _DATETIME_RE = r"^-?\d{4,}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$"

_valid_xsd_date(s::String) = occursin(_DATE_RE, s)
_valid_xsd_datetime(s::String) = occursin(_DATETIME_RE, s)
