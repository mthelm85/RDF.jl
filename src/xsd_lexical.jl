# XSD lexical spaces
#
# Whether a literal's lexical form is well-formed for its datatype is asked in
# two places — `value`/`tryvalue` (literal_values.jl) and SPARQL's comparison
# and type-error rules (sparql/builtins.jl). They used to answer it separately,
# by handing the string to a Julia parser, and drifted apart: each accepted a
# different set of strings that XSD does not admit.
#
# Julia's parsers are deliberately lenient in ways XSD is not:
#
#   tryparse(Int64,   "0x10")  == 16     hex is not an XSD integer
#   tryparse(Int64,   " 3 ")   == 3      leading/trailing space is not either
#   tryparse(Float64, "1E400") === nothing   but XSD maps overflow to INF
#   tryparse(BigFloat,"1E5")   == 100000.0   xsd:decimal admits no exponent
#
# So the lexical space is matched directly, from the grammars in XML Schema
# Part 2, and both layers share these predicates.
#
# Scope: this is the *lexical* space only. Range constraints on the bounded
# integer types (xsd:byte admitting -128..127, and so on) belong to the value
# space and are not enforced here.

# ── Lexical grammars ──────────────────────────────────────────────────────────

# integer and every derived integer type
const _XSD_RE_INTEGER  = r"^[+-]?[0-9]+$"

# decimal: a plain decimal numeral, no exponent
const _XSD_RE_DECIMAL  = r"^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$"

# double and float: decimal numeral with optional exponent
const _XSD_RE_FLOATING = r"^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([Ee][+-]?[0-9]+)?$"

const _XSD_RE_DATE     = r"^-?[0-9]{4,}-[0-9]{2}-[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})?$"

const _XSD_RE_DATETIME =
    r"^-?[0-9]{4,}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})?$"

# Captured form, for the callers that need the components.
const _XSD_RE_DATETIME_PARTS =
    r"^(-?[0-9]{4,})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})?$"

# The special floating-point values, which are case-sensitive in XSD.
const _XSD_FLOAT_SPECIALS = ("INF", "+INF", "-INF", "NaN")

# ── Predicates ────────────────────────────────────────────────────────────────

xsd_is_integer_lexical(s::AbstractString)::Bool  = occursin(_XSD_RE_INTEGER, s)
xsd_is_decimal_lexical(s::AbstractString)::Bool  = occursin(_XSD_RE_DECIMAL, s)
xsd_is_boolean_lexical(s::AbstractString)::Bool  = s in ("true", "false", "0", "1")

xsd_is_floating_lexical(s::AbstractString)::Bool =
    s in _XSD_FLOAT_SPECIALS || occursin(_XSD_RE_FLOATING, s)

xsd_is_date_lexical(s::AbstractString)::Bool     = occursin(_XSD_RE_DATE, s)

# Also rejects the field combinations the regex cannot express, so that
# "2006-13-45" is not accepted merely for having the right shape.
function xsd_is_datetime_lexical(s::AbstractString)::Bool
    occursin(_XSD_RE_DATETIME, s) || return false
    return _xsd_datetime_fields(s) !== nothing
end

# ── Parsing ───────────────────────────────────────────────────────────────────

"""
    _xsd_datetime_fields(s) -> (DateTime, tz) | nothing

Split an xsd:dateTime lexical form into a naive `DateTime` and its timezone
suffix (`nothing` when absent). Hour 24 is XSD's spelling of midnight starting
the next day and is rolled over. Returns `nothing` if the fields are out of
range, which is what makes an in-shape but impossible date ill-formed.
"""
function _xsd_datetime_fields(s::AbstractString)
    m = match(_XSD_RE_DATETIME_PARTS, s)
    m === nothing && return nothing
    y  = parse(Int, m[1]); mo = parse(Int, m[2]); d = parse(Int, m[3])
    h  = parse(Int, m[4]); mi = parse(Int, m[5]); se = parse(Int, m[6])
    ms = m[7] === nothing ? 0 : round(Int, parse(Float64, "0" * m[7]) * 1000)

    rollover = false
    if h == 24
        (mi == 0 && se == 0) || return nothing
        h = 0; rollover = true
    end
    dt = try
        Dates.DateTime(y, mo, d, h, mi, se, ms)
    catch
        return nothing        # e.g. month 13, or 31 February
    end
    rollover && (dt += Dates.Day(1))
    return (dt, m[8])
end

"""
    _xsd_parse_date(s) -> Date | nothing

Parse an xsd:date lexical form, tolerating the timezone suffix that Julia's own
`Date` parser rejects.
"""
function _xsd_parse_date(s::AbstractString)
    xsd_is_date_lexical(s) || return nothing
    body = replace(s, r"(Z|[+-][0-9]{2}:[0-9]{2})$" => "")
    return tryparse(Dates.Date, body)
end

"""
    _xsd_parse_floating(s) -> Float64 | nothing

Parse an xsd:double / xsd:float lexical form. An out-of-range magnitude maps to
±INF rather than failing, which is what XSD specifies and what `tryparse` alone
does not do.
"""
function _xsd_parse_floating(s::AbstractString)
    s == "NaN"                && return NaN
    (s == "INF" || s == "+INF") && return Inf
    s == "-INF"               && return -Inf
    occursin(_XSD_RE_FLOATING, s) || return nothing
    v = tryparse(Float64, s)
    v !== nothing && return v
    # tryparse returns nothing on overflow; XSD rounds to infinity.
    return startswith(s, "-") ? -Inf : Inf
end
