using Dates

"""
    value(lit::Literal)
    value(T::Type, lit::Literal)

Parse the lexical form of `lit` to a Julia value. The one-argument form infers
the type from the datatype IRI; the two-argument form additionally checks that
the result is of type `T`.

Supported datatypes: `xsd:string`, `rdf:langString`, `xsd:boolean`,
`xsd:integer` (and variants), `xsd:double`, `xsd:float`, `xsd:decimal`,
`xsd:date`, `xsd:dateTime`.

Throws `LiteralValueError` if parsing fails or the value is not of type `T`.
See also [`tryvalue`](@ref).

```julia
value(Literal(42))           # => 42 (Int64)
value(Int64, Literal(42))    # => 42
value(Literal(true))         # => true
```
"""
function value(lit::Literal)
    dt = lit.datatype.value
    _XSD = "http://www.w3.org/2001/XMLSchema#"
    if dt == _XSD * "string"  || lit.datatype == _RDF_LANGSTRING
        return lit.lexical_form
    elseif dt == _XSD * "boolean"
        lit.lexical_form in ("true", "1")  && return true
        lit.lexical_form in ("false", "0") && return false
    elseif dt == _XSD * "integer" || dt == _XSD * "long" || dt == _XSD * "int" ||
           dt == _XSD * "short"   || dt == _XSD * "byte" ||
           dt == _XSD * "nonNegativeInteger" || dt == _XSD * "positiveInteger" ||
           dt == _XSD * "nonPositiveInteger" || dt == _XSD * "negativeInteger" ||
           dt == _XSD * "unsignedLong" || dt == _XSD * "unsignedInt" ||
           dt == _XSD * "unsignedShort" || dt == _XSD * "unsignedByte"
        v = tryparse(Int64, lit.lexical_form)
        v !== nothing && return v
        v2 = tryparse(BigInt, lit.lexical_form)
        v2 !== nothing && return v2
    elseif dt == _XSD * "double" || dt == _XSD * "float"
        lit.lexical_form == "INF"  && return Inf64
        lit.lexical_form == "-INF" && return -Inf64
        lit.lexical_form == "NaN"  && return NaN64
        v = tryparse(Float64, lit.lexical_form)
        v !== nothing && return v
    elseif dt == _XSD * "decimal"
        v = tryparse(BigFloat, lit.lexical_form)
        v !== nothing && return v
    elseif dt == _XSD * "date"
        v = tryparse(Dates.Date, lit.lexical_form)
        v !== nothing && return v
    elseif dt == _XSD * "dateTime" || dt == _XSD * "dateTimeStamp"
        # Remove timezone suffix if present (Julia DateTime doesn't support TZ)
        s = replace(lit.lexical_form, r"(Z|[+-]\d{2}:\d{2})$" => "")
        v = tryparse(Dates.DateTime, s)
        v !== nothing && return v
    end
    throw(LiteralValueError(lit, Any))
end

function value(T::Type, lit::Literal)
    v = try
        value(lit)
    catch e
        e isa LiteralValueError || rethrow()
        throw(LiteralValueError(lit, T))
    end
    v isa T && return v::T
    throw(LiteralValueError(lit, T))
end

"""
    tryvalue(lit::Literal)

Like [`value`](@ref) but returns `nothing` instead of throwing on failure.
"""
function tryvalue(lit::Literal)
    try
        value(lit)
    catch _
        nothing
    end
end
