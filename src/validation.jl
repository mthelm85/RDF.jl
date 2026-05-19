struct ValidationWarning
    triple::Triple
    message::String
    code::Symbol
end

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

# BCP47: simplified — primary tag of 1-8 ASCII letters, optional subtags
const _LANG_RE = r"^[a-z]{1,8}(-[a-z0-9]{1,8})*$"i

_valid_lang_tag(tag::String) = occursin(_LANG_RE, tag)

# Known numeric XSD datatypes and their validators
const _XSD = "http://www.w3.org/2001/XMLSchema#"

function _is_known_datatype(dt::IRI)
    startswith(dt.value, _XSD)
end

function _check_lexical_form(lex::String, dt::IRI)::Bool
    s = dt.value
    if s == _XSD * "integer" || s == _XSD * "nonNegativeInteger" ||
       s == _XSD * "positiveInteger" || s == _XSD * "nonPositiveInteger" ||
       s == _XSD * "negativeInteger" || s == _XSD * "long" ||
       s == _XSD * "int" || s == _XSD * "short" || s == _XSD * "byte" ||
       s == _XSD * "unsignedLong" || s == _XSD * "unsignedInt" ||
       s == _XSD * "unsignedShort" || s == _XSD * "unsignedByte"
        return tryparse(Int64, lex) !== nothing || tryparse(BigInt, lex) !== nothing
    elseif s == _XSD * "decimal"
        return tryparse(BigFloat, lex) !== nothing
    elseif s == _XSD * "double" || s == _XSD * "float"
        return lex in ("INF", "-INF", "NaN") || tryparse(Float64, lex) !== nothing
    elseif s == _XSD * "boolean"
        return lex in ("true", "false", "1", "0")
    elseif s == _XSD * "date"
        return _valid_xsd_date(lex)
    elseif s == _XSD * "dateTime" || s == _XSD * "dateTimeStamp"
        return _valid_xsd_datetime(lex)
    end
    true  # unknown XSD type: accept
end

const _DATE_RE     = r"^-?\d{4,}-\d{2}-\d{2}(Z|[+-]\d{2}:\d{2})?$"
const _DATETIME_RE = r"^-?\d{4,}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$"

_valid_xsd_date(s::String) = occursin(_DATE_RE, s)
_valid_xsd_datetime(s::String) = occursin(_DATETIME_RE, s)
