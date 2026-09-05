using Dates

# Pre-defined datatype IRI strings — avoids string allocation on every value() call
const _LV_XSD            = "http://www.w3.org/2001/XMLSchema#"
const _LV_XSD_STRING     = _LV_XSD * "string"
const _LV_XSD_BOOLEAN    = _LV_XSD * "boolean"
const _LV_XSD_INTEGER    = _LV_XSD * "integer"
const _LV_XSD_LONG       = _LV_XSD * "long"
const _LV_XSD_INT        = _LV_XSD * "int"
const _LV_XSD_SHORT      = _LV_XSD * "short"
const _LV_XSD_BYTE       = _LV_XSD * "byte"
const _LV_XSD_NONNEG_INT = _LV_XSD * "nonNegativeInteger"
const _LV_XSD_POS_INT    = _LV_XSD * "positiveInteger"
const _LV_XSD_NONPOS_INT = _LV_XSD * "nonPositiveInteger"
const _LV_XSD_NEG_INT    = _LV_XSD * "negativeInteger"
const _LV_XSD_ULONG      = _LV_XSD * "unsignedLong"
const _LV_XSD_UINT       = _LV_XSD * "unsignedInt"
const _LV_XSD_USHORT     = _LV_XSD * "unsignedShort"
const _LV_XSD_UBYTE      = _LV_XSD * "unsignedByte"
const _LV_XSD_DOUBLE     = _LV_XSD * "double"
const _LV_XSD_FLOAT      = _LV_XSD * "float"
const _LV_XSD_DECIMAL    = _LV_XSD * "decimal"
const _LV_XSD_DATE       = _LV_XSD * "date"
const _LV_XSD_DATETIME   = _LV_XSD * "dateTime"
const _LV_XSD_DT_STAMP   = _LV_XSD * "dateTimeStamp"
const _LV_RDF_LANGSTRING    = "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString"
const _LV_RDF_DIRLANGSTRING = "http://www.w3.org/1999/02/22-rdf-syntax-ns#dirLangString"

"""
    value(lit::Literal)
    value(T::Type, lit::Literal)

Parse the lexical form of `lit` to a Julia value.

The **one-argument form** infers the target type from the datatype IRI:

| XSD / RDF datatype | Julia type |
|--------------------|-----------|
| `xsd:string`, `rdf:langString`, `rdf:dirLangString` | `String` |
| `xsd:boolean` | `Bool` |
| `xsd:integer` and all integer subtypes | `Int64` (or `BigInt` if too large) |
| `xsd:double` | `Float64` |
| `xsd:float` | `Float32` |
| `xsd:decimal` | `BigFloat` (finite-precision approximation) |
| `xsd:date` | `Dates.Date` |
| `xsd:dateTime`, `xsd:dateTimeStamp` | `Dates.DateTime` (timezone dropped) |

A lexical form outside the datatype's XSD lexical space is a
`LiteralValueError`, not a value. That covers forms Julia's own parsers accept
but XSD does not — `"0x10"^^xsd:integer`, `" 3 "^^xsd:int`, `"1E5"^^xsd:decimal`
— so an ill-formed literal cannot come back as a plausible-looking number.
Range constraints on the bounded integer types are *not* checked: `value` reads
`"999"^^xsd:byte` as `999`.

An out-of-range magnitude such as `"1E400"^^xsd:double` is `Inf`, per XSD, and
`Dates.DateTime` has no timezone, so an offset is dropped rather than applied:
`"2006-08-23T09:00:00+01:00"` reads as `09:00`, not the UTC instant.

The **two-argument form** additionally converts the result to `T` using Julia's
`convert`. This means numeric widening works naturally:

```julia
value(Literal(42))              # => 42  (Int64)
value(Int64,   Literal(42))     # => 42
value(Float64, Literal(42))     # => 42.0   (Int64 → Float64 via convert)
value(Int64,   Literal(3.14))   # throws LiteralValueError (inexact)
```

Throws `LiteralValueError` if the lexical form cannot be parsed or if the
resulting value cannot be `convert`ed to `T`.  See [`tryvalue`](@ref) for a
non-throwing variant.
"""
function value(lit::Literal)
    dt = lit.datatype.value
    if dt == _LV_XSD_STRING || dt == _LV_RDF_LANGSTRING || dt == _LV_RDF_DIRLANGSTRING
        return lit.lexical_form
    elseif dt == _LV_XSD_BOOLEAN
        lit.lexical_form in ("true", "1")  && return true
        lit.lexical_form in ("false", "0") && return false
    elseif dt == _LV_XSD_INTEGER || dt == _LV_XSD_LONG     || dt == _LV_XSD_INT   ||
           dt == _LV_XSD_SHORT   || dt == _LV_XSD_BYTE     ||
           dt == _LV_XSD_NONNEG_INT || dt == _LV_XSD_POS_INT  ||
           dt == _LV_XSD_NONPOS_INT || dt == _LV_XSD_NEG_INT  ||
           dt == _LV_XSD_ULONG   || dt == _LV_XSD_UINT     ||
           dt == _LV_XSD_USHORT  || dt == _LV_XSD_UBYTE
        # Check the lexical space first: Julia's integer parsing accepts hex
        # ("0x10" → 16) and surrounding whitespace, neither of which XSD admits.
        if xsd_is_integer_lexical(lit.lexical_form)
            v = tryparse(Int64, lit.lexical_form)
            v !== nothing && return v
            v2 = tryparse(BigInt, lit.lexical_form)
            v2 !== nothing && return v2
        end
    elseif dt == _LV_XSD_DOUBLE
        v = _xsd_parse_floating(lit.lexical_form)
        v !== nothing && return v
    elseif dt == _LV_XSD_FLOAT
        v = _xsd_parse_floating(lit.lexical_form)
        v !== nothing && return Float32(v)
    elseif dt == _LV_XSD_DECIMAL
        # xsd:decimal admits no exponent, so "1E5" is ill-formed even though
        # BigFloat parses it happily.
        if xsd_is_decimal_lexical(lit.lexical_form)
            v = tryparse(BigFloat, lit.lexical_form)
            v !== nothing && return v
        end
    elseif dt == _LV_XSD_DATE
        v = _xsd_parse_date(lit.lexical_form)
        v !== nothing && return v
    elseif dt == _LV_XSD_DATETIME || dt == _LV_XSD_DT_STAMP
        # Julia's DateTime carries no timezone, so the offset is dropped and the
        # time is returned as written (see the note in the docstring).
        fields = _xsd_datetime_fields(lit.lexical_form)
        fields !== nothing && return fields[1]
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
    # Fast path: already the right type (covers abstract supertypes too)
    v isa T && return v::T
    # Try convert — handles numeric widening (Int64 → Float64, etc.)
    try
        return convert(T, v)::T
    catch e
        (e isa InexactError || e isa MethodError) || rethrow()
        throw(LiteralValueError(lit, T))
    end
end

"""
    tryvalue(lit::Literal)
    tryvalue(T::Type, lit::Literal)

Like [`value`](@ref) but returns `nothing` instead of throwing on failure.

```julia
tryvalue(Literal(42))               # => 42
tryvalue(Float64, Literal(42))      # => 42.0
tryvalue(Int64,   Literal(3.14))    # => nothing  (inexact)
tryvalue(Int64,   Literal("oops", xsd.integer))  # => nothing
```
"""
function tryvalue(lit::Literal)
    try
        value(lit)
    catch _
        nothing
    end
end

function tryvalue(T::Type, lit::Literal)
    try
        value(T, lit)
    catch _
        nothing
    end
end
