# ── SPARQL 1.1 Built-in Function Evaluation ───────────────────────────────────
#
# This file implements all SPARQL 1.1 built-in functions and type-checking.
# Included into the RDF module; no module declaration.
#
# Convention: functions raise a Julia exception (any type) on type errors or
# evaluation errors. The evaluator catches these and treats them as "errors"
# (unbound / filter-false depending on context).

# ── XSD / RDF IRI constants ───────────────────────────────────────────────────

const _SP_XSD  = "http://www.w3.org/2001/XMLSchema#"
const _SP_RDF  = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

const _SP_XSD_STRING   = _SP_XSD * "string"
const _SP_XSD_INTEGER  = _SP_XSD * "integer"
const _SP_XSD_DECIMAL  = _SP_XSD * "decimal"
const _SP_XSD_DOUBLE   = _SP_XSD * "double"
const _SP_XSD_FLOAT    = _SP_XSD * "float"
const _SP_XSD_BOOLEAN  = _SP_XSD * "boolean"
const _SP_XSD_DATE     = _SP_XSD * "date"
const _SP_XSD_DATETIME = _SP_XSD * "dateTime"
const _SP_XSD_TIME     = _SP_XSD * "time"
const _SP_XSD_DURATION = _SP_XSD * "duration"
const _SP_XSD_INT      = _SP_XSD * "int"
const _SP_XSD_LONG     = _SP_XSD * "long"
const _SP_XSD_SHORT    = _SP_XSD * "short"
const _SP_XSD_BYTE     = _SP_XSD * "byte"
const _SP_XSD_NON_NEG  = _SP_XSD * "nonNegativeInteger"
const _SP_XSD_POS      = _SP_XSD * "positiveInteger"
const _SP_XSD_NON_POS  = _SP_XSD * "nonPositiveInteger"
const _SP_XSD_NEG      = _SP_XSD * "negativeInteger"
const _SP_XSD_UNSIGNED_BYTE  = _SP_XSD * "unsignedByte"
const _SP_XSD_UNSIGNED_SHORT = _SP_XSD * "unsignedShort"
const _SP_XSD_UNSIGNED_INT   = _SP_XSD * "unsignedInt"
const _SP_XSD_UNSIGNED_LONG  = _SP_XSD * "unsignedLong"
const _SP_RDF_LANGSTRING    = _SP_RDF * "langString"
const _SP_RDF_DIRLANGSTRING = _SP_RDF * "dirLangString"
const _SP_RDF_TYPE          = _SP_RDF * "type"

# Integer subtypes — all treated as xsd:integer for arithmetic
const _SP_INTEGER_TYPES = Set{String}([
    _SP_XSD_INTEGER, _SP_XSD_INT, _SP_XSD_LONG, _SP_XSD_SHORT, _SP_XSD_BYTE,
    _SP_XSD_NON_NEG, _SP_XSD_POS, _SP_XSD_NON_POS, _SP_XSD_NEG,
    _SP_XSD_UNSIGNED_BYTE, _SP_XSD_UNSIGNED_SHORT, _SP_XSD_UNSIGNED_INT, _SP_XSD_UNSIGNED_LONG,
])

# Numeric types
const _SP_NUMERIC_TYPES = Set{String}([
    _SP_XSD_INTEGER, _SP_XSD_INT, _SP_XSD_LONG, _SP_XSD_SHORT, _SP_XSD_BYTE,
    _SP_XSD_NON_NEG, _SP_XSD_POS, _SP_XSD_NON_POS, _SP_XSD_NEG,
    _SP_XSD_UNSIGNED_BYTE, _SP_XSD_UNSIGNED_SHORT, _SP_XSD_UNSIGNED_INT, _SP_XSD_UNSIGNED_LONG,
    _SP_XSD_DECIMAL, _SP_XSD_DOUBLE, _SP_XSD_FLOAT,
])

# ── Type classification helpers ───────────────────────────────────────────────

_sp_is_integer(dt::String) = dt in _SP_INTEGER_TYPES
_sp_is_numeric(dt::String) = dt in _SP_NUMERIC_TYPES

function _sp_is_numeric_literal(t::RDFTerm)
    t isa Literal && _sp_is_numeric(t.datatype.value)
end

function _sp_is_plain_literal(t::RDFTerm)
    t isa Literal && (t.datatype.value == _SP_XSD_STRING || !isempty(t.language_tag))
end

function _sp_is_string_literal(t::RDFTerm)
    t isa Literal && (t.datatype.value == _SP_XSD_STRING ||
                      t.datatype.value == _SP_RDF_LANGSTRING ||
                      t.datatype.value == _SP_RDF_DIRLANGSTRING)
end

# ── Numeric coercion ──────────────────────────────────────────────────────────

function _sp_to_float(lit::Literal)::Float64
    dt = lit.datatype.value
    dt in _SP_NUMERIC_TYPES || error("Not a numeric literal: $lit")
    s = lit.lexical_form
    s in ("INF", "+INF")  && return Inf
    s == "-INF"           && return -Inf
    s == "NaN"            && return NaN
    Parsers.parse(Float64, s)
end

# Fast path: use pre-cached numeric value when we have a term ID
# Returns NaN for non-numeric terms (which correctly fails numeric comparisons)
@inline _sp_to_float_id(id::UInt32)::Float64 = _numeric_float(id)

# Parse a decimal lexical form (e.g. "3.14", "+33.33") to an exact Rational{BigInt}
function _sp_parse_decimal_rational(s::String)::Rational{BigInt}
    neg = startswith(s, "-")
    s2 = (neg || startswith(s, "+")) ? s[2:end] : s
    if occursin('.', s2)
        dot_pos = findfirst('.', s2)
        int_part  = s2[1:dot_pos-1]
        frac_part = s2[dot_pos+1:end]
        int_part = isempty(int_part) ? "0" : int_part
        n = parse(BigInt, int_part * frac_part)
        d = BigInt(10)^length(frac_part)
    else
        n = parse(BigInt, s2)
        d = BigInt(1)
    end
    r = n // d   # Rational{BigInt}, automatically reduced
    return neg ? -r : r
end

# Format a Rational{BigInt} as a minimal xsd:decimal string.
# min_places=1 (default): whole numbers are formatted as "N.0" (for arithmetic results).
# min_places=0: whole numbers are formatted as "N" (for CEIL/FLOOR/ROUND results).
function _sp_decimal_string(r::Rational{BigInt}; min_places::Int=1)::String
    n = numerator(r)
    d = denominator(r)

    # Reduce denominator to factors of 2 and 5 only (finite decimal test)
    d2 = d
    a = 0; while d2 % 2 == 0; d2 = d2 ÷ 2; a += 1; end
    b = 0; while d2 % 5 == 0; d2 = d2 ÷ 5; b += 1; end

    if d2 != 1
        # Non-terminating decimal — round-trip via Float64 (shouldn't occur in W3C tests)
        return string(Float64(n) / Float64(d))
    end

    places = max(min_places, a, b)

    if places == 0
        # Integer-valued result with no minimum decimal places: output without decimal point
        return string(n)  # n/d where d=1, so this is just the integer
    end

    factor = BigInt(2)^max(0, places - a) * BigInt(5)^max(0, places - b)
    scaled = abs(n) * factor
    s = string(scaled)
    while length(s) <= places; s = "0" * s; end
    int_str  = s[1:end - places]
    frac_str = rstrip(s[end - places + 1:end], '0')
    int_str  = isempty(int_str) ? "0" : int_str
    frac_str = isempty(frac_str) ? "0" : frac_str  # keep at least "0" after decimal
    result   = int_str * "." * frac_str
    return n < 0 ? "-" * result : result
end

function _sp_to_decimal(lit::Literal)::Rational{BigInt}
    dt = lit.datatype.value
    dt in _SP_NUMERIC_TYPES || error("Not a numeric literal: $lit")
    s = lit.lexical_form
    if _sp_is_integer(dt)
        n = parse(BigInt, s)
        return n // BigInt(1)
    elseif dt == _SP_XSD_DECIMAL
        return _sp_parse_decimal_rational(s)
    else  # double/float — convert via Float64 to rational (only used for non-double paths)
        f = parse(BigFloat, s)
        return Rational{BigInt}(f)
    end
end

function _sp_numeric_add(a::Literal, b::Literal)::Literal
    adt = a.datatype.value; bdt = b.datatype.value
    # SPARQL type promotion: double > decimal > integer
    if adt == _SP_XSD_DOUBLE || bdt == _SP_XSD_DOUBLE || adt == _SP_XSD_FLOAT || bdt == _SP_XSD_FLOAT
        v = _sp_to_float(a) + _sp_to_float(b)
        return Literal(_double_lexical(v), _XSD_DOUBLE, "")
    elseif adt == _SP_XSD_DECIMAL || bdt == _SP_XSD_DECIMAL
        v = _sp_to_decimal(a) + _sp_to_decimal(b)
        return Literal(_sp_decimal_string(v), IRI(_SP_XSD_DECIMAL), "")
    else
        va = parse(BigInt, a.lexical_form)
        vb = parse(BigInt, b.lexical_form)
        return Literal(string(va + vb), IRI(_SP_XSD_INTEGER), "")
    end
end

function _sp_numeric_sub(a::Literal, b::Literal)::Literal
    adt = a.datatype.value; bdt = b.datatype.value
    if adt == _SP_XSD_DOUBLE || bdt == _SP_XSD_DOUBLE || adt == _SP_XSD_FLOAT || bdt == _SP_XSD_FLOAT
        v = _sp_to_float(a) - _sp_to_float(b)
        return Literal(_double_lexical(v), _XSD_DOUBLE, "")
    elseif adt == _SP_XSD_DECIMAL || bdt == _SP_XSD_DECIMAL
        v = _sp_to_decimal(a) - _sp_to_decimal(b)
        return Literal(_sp_decimal_string(v), IRI(_SP_XSD_DECIMAL), "")
    else
        va = parse(BigInt, a.lexical_form); vb = parse(BigInt, b.lexical_form)
        return Literal(string(va - vb), IRI(_SP_XSD_INTEGER), "")
    end
end

function _sp_numeric_mul(a::Literal, b::Literal)::Literal
    adt = a.datatype.value; bdt = b.datatype.value
    if adt == _SP_XSD_DOUBLE || bdt == _SP_XSD_DOUBLE || adt == _SP_XSD_FLOAT || bdt == _SP_XSD_FLOAT
        v = _sp_to_float(a) * _sp_to_float(b)
        return Literal(_double_lexical(v), _XSD_DOUBLE, "")
    elseif adt == _SP_XSD_DECIMAL || bdt == _SP_XSD_DECIMAL
        v = _sp_to_decimal(a) * _sp_to_decimal(b)
        return Literal(_sp_decimal_string(v), IRI(_SP_XSD_DECIMAL), "")
    else
        va = parse(BigInt, a.lexical_form); vb = parse(BigInt, b.lexical_form)
        return Literal(string(va * vb), IRI(_SP_XSD_INTEGER), "")
    end
end

function _sp_numeric_div(a::Literal, b::Literal)::Literal
    adt = a.datatype.value; bdt = b.datatype.value
    if adt == _SP_XSD_DOUBLE || bdt == _SP_XSD_DOUBLE || adt == _SP_XSD_FLOAT || bdt == _SP_XSD_FLOAT
        v = _sp_to_float(a) / _sp_to_float(b)
        return Literal(_double_lexical(v), _XSD_DOUBLE, "")
    else
        # Integer / Decimal → Decimal (exact rational arithmetic)
        va = _sp_to_decimal(a); vb = _sp_to_decimal(b)
        iszero(vb) && error("Division by zero")
        v = va // vb   # Rational{BigInt} division
        return Literal(_sp_decimal_string(v), IRI(_SP_XSD_DECIMAL), "")
    end
end

function _sp_numeric_neg(a::Literal)::Literal
    dt = a.datatype.value
    _sp_is_numeric(dt) || error("Not numeric: $a")
    if dt == _SP_XSD_DOUBLE || dt == _SP_XSD_FLOAT
        v = -_sp_to_float(a)
        return Literal(_double_lexical(v), _XSD_DOUBLE, "")
    elseif dt == _SP_XSD_DECIMAL
        v = -_sp_to_decimal(a)
        return Literal(_sp_decimal_string(v), IRI(_SP_XSD_DECIMAL), "")
    else
        v = -parse(BigInt, a.lexical_form)
        return Literal(string(v), IRI(_SP_XSD_INTEGER), "")
    end
end

# ── Boolean coercion ──────────────────────────────────────────────────────────

function _sp_to_bool(v::RDFTerm)::Bool
    v isa Literal || error("Cannot coerce $(typeof(v)) to boolean")
    dt = v.datatype.value
    if dt == _SP_XSD_BOOLEAN
        v.lexical_form in ("true", "1")  && return true
        v.lexical_form in ("false", "0") && return false
        error("Invalid boolean: $(v.lexical_form)")
    elseif _sp_is_numeric(dt)
        n = _sp_to_float(v)
        return !isnan(n) && n != 0.0
    elseif dt == _SP_XSD_STRING
        # Only xsd:string / simple literals have an EBV (SPARQL §17.2.2);
        # language-tagged and directional strings are a type error.
        return !isempty(v.lexical_form)
    else
        error("Cannot coerce $dt to boolean")
    end
end

_sp_bool_literal(b::Bool) = Literal(b ? "true" : "false", IRI(_SP_XSD_BOOLEAN), "")

# ── Term comparison (SPARQL ordering) ─────────────────────────────────────────
# Returns -1, 0, or 1; errors on incomparable types.

function _sp_compare(a::RDFTerm, b::RDFTerm)::Int
    # Same term → equal
    a == b && return 0

    if a isa IRI && b isa IRI
        return cmp(a.value, b.value)
    end
    if a isa BlankNode && b isa BlankNode
        return cmp(a.id, b.id)
    end
    if a isa Literal && b isa Literal
        return _sp_compare_literals(a, b)
    end
    # SPARQL 1.2: triple terms are ordered component-wise (subject, predicate,
    # then object), recursing through _sp_compare.
    if a isa TripleTerm && b isa TripleTerm
        c = _sp_compare(a.subject::RDFTerm, b.subject::RDFTerm); c != 0 && return c
        c = _sp_compare(a.predicate, b.predicate);               c != 0 && return c
        return _sp_compare(a.object::RDFTerm, b.object::RDFTerm)
    end
    # Incomparable categories — SPARQL ordering:
    # BlankNode < IRI < Literal < TripleTerm
    rank(t) = t isa BlankNode ? 0 : t isa IRI ? 1 : t isa Literal ? 2 : 3
    cmp(rank(a), rank(b))
end

function _sp_compare_literals(a::Literal, b::Literal)::Int
    adt = a.datatype.value; bdt = b.datatype.value
    # Both numeric → compare numerically
    if _sp_is_numeric(adt) && _sp_is_numeric(bdt)
        fa = _sp_to_float(a); fb = _sp_to_float(b)
        fa < fb && return -1
        fa > fb && return  1
        return 0
    end
    # Both xsd:string (same lang or no lang)
    if adt == _SP_XSD_STRING && bdt == _SP_XSD_STRING
        return cmp(a.lexical_form, b.lexical_form)
    end
    # Both xsd:boolean
    if adt == _SP_XSD_BOOLEAN && bdt == _SP_XSD_BOOLEAN
        ab = a.lexical_form in ("true","1")
        bb = b.lexical_form in ("true","1")
        return cmp(ab, bb)
    end
    # Both xsd:dateTime or date
    if adt == _SP_XSD_DATETIME && bdt == _SP_XSD_DATETIME
        da = _sp_parse_datetime(a.lexical_form)
        db = _sp_parse_datetime(b.lexical_form)
        return cmp(da, db)
    end
    if adt == _SP_XSD_DATE && bdt == _SP_XSD_DATE
        da = _sp_parse_date(a.lexical_form)
        db = _sp_parse_date(b.lexical_form)
        return cmp(da, db)
    end
    # Same datatype, lexicographic on lexical form
    adt == bdt && return cmp(a.lexical_form, b.lexical_form)
    # Different types → error (incomparable for value equality)
    error("Incomparable literal types: $adt vs $bdt")
end

# Date/time parsing helpers
function _sp_parse_datetime(s::String)
    # Parse ISO 8601 datetime — basic support
    try
        # Handle timezone suffix
        s2 = replace(s, r"Z$" => "+00:00")
        # Remove timezone for Dates.DateTime parsing
        s3 = replace(s2, r"[+-]\d{2}:\d{2}$" => "")
        Dates.DateTime(s3, "yyyy-mm-ddTHH:MM:SS")
    catch
        try Dates.DateTime(s[1:19], "yyyy-mm-ddTHH:MM:SS")
        catch; error("Invalid dateTime: $s")
        end
    end
end

function _sp_parse_date(s::String)
    try Dates.Date(s[1:10], "yyyy-mm-dd")
    catch; error("Invalid date: $s")
    end
end

# ── Equality (SPARQL value equality, distinct from term equality) ─────────────

function _sp_value_equal(a::RDFTerm, b::RDFTerm)::Bool
    a isa Literal && b isa Literal && return _sp_literal_value_equal(a, b)
    # SPARQL 1.2: triple terms compare by value, component-wise — so
    # <<( :a :b 123 )>> = <<( :a :b 123.0 )>> is true even though the terms
    # are not sameTerm.
    if a isa TripleTerm && b isa TripleTerm
        return _sp_value_equal(a.subject::RDFTerm, b.subject::RDFTerm) &&
               _sp_value_equal(a.predicate, b.predicate) &&
               _sp_value_equal(a.object::RDFTerm, b.object::RDFTerm)
    end
    return a == b  # IRI/IRI or BNode/BNode identity
end

function _sp_literal_value_equal(a::Literal, b::Literal)::Bool
    adt = a.datatype.value; bdt = b.datatype.value
    if _sp_is_numeric(adt) && _sp_is_numeric(bdt)
        return _sp_compare_literals(a, b) == 0
    end
    adt == bdt || return false
    if adt == _SP_XSD_STRING
        return a.lexical_form == b.lexical_form
    end
    if adt == _SP_RDF_LANGSTRING
        return a.lexical_form == b.lexical_form && a.language_tag == b.language_tag
    end
    if adt == _SP_XSD_BOOLEAN
        normalize_bool(s) = s in ("true","1")
        return normalize_bool(a.lexical_form) == normalize_bool(b.lexical_form)
    end
    # Same non-numeric, non-string, non-boolean type: lexical comparison
    a.lexical_form == b.lexical_form
end

# ── String built-ins ──────────────────────────────────────────────────────────

function _sp_str(t::RDFTerm)::Literal
    t isa Literal && return Literal(t.lexical_form, IRI(_SP_XSD_STRING), "")
    t isa IRI     && return Literal(t.value,        IRI(_SP_XSD_STRING), "")
    error("STR requires an IRI or Literal, got $(typeof(t))")
end

# Split a stored language tag "lang--dir" into (lang, dir); ("lang", "") when
# no base direction is present.
function _sp_split_langdir(tag::String)::Tuple{String,String}
    dd = findfirst("--", tag)
    dd === nothing && return (tag, "")
    (tag[1:first(dd)-1], tag[last(dd)+1:end])
end

function _sp_lang(t::RDFTerm)::Literal
    t isa Literal || error("LANG requires a Literal")
    # SPARQL 1.2: LANG of a directional language-tagged string returns the
    # language tag without the base direction.
    lang, _ = _sp_split_langdir(t.language_tag)
    Literal(lang, IRI(_SP_XSD_STRING), "")
end

# ── SPARQL 1.2: base-direction and triple-term builtins ───────────────────────

function _sp_langdir(t::RDFTerm)::Literal
    t isa Literal || error("LANGDIR requires a Literal")
    _, dir = _sp_split_langdir(t.language_tag)
    Literal(dir, IRI(_SP_XSD_STRING), "")
end

# hasLANG / hasLANGDIR are total predicates over all RDF terms: a non-literal
# (or a literal without the relevant tag) yields false rather than a type error.
function _sp_haslang(t::RDFTerm)::Literal
    _sp_bool_literal(t isa Literal &&
        (t.datatype.value == _SP_RDF_LANGSTRING ||
         t.datatype.value == _SP_RDF_DIRLANGSTRING))
end

function _sp_haslangdir(t::RDFTerm)::Literal
    _sp_bool_literal(t isa Literal && t.datatype.value == _SP_RDF_DIRLANGSTRING)
end

function _sp_strlangdir(lex::RDFTerm, lang::RDFTerm, dir::RDFTerm)::Literal
    (lex isa Literal && lang isa Literal && dir isa Literal) ||
        error("STRLANGDIR(str, lang, dir): need three literals")
    !isempty(lex.language_tag) &&
        error("STRLANGDIR: language-tagged literal is not a simple literal")
    lex.datatype.value == _SP_XSD_STRING ||
        error("STRLANGDIR: first argument must be a simple literal (xsd:string)")
    l = lowercase(lang.lexical_form)
    isempty(l) && error("STRLANGDIR: language tag must not be empty")
    d = dir.lexical_form
    d in ("ltr", "rtl") || error("STRLANGDIR: direction must be 'ltr' or 'rtl', got '$d'")
    Literal(lex.lexical_form, IRI(_SP_RDF_DIRLANGSTRING), l * "--" * d)
end

function _sp_triple_fn(s::RDFTerm, p::RDFTerm, o::RDFTerm)::TripleTerm
    (s isa IRI || s isa BlankNode) ||
        error("TRIPLE: subject must be an IRI or blank node, got $(typeof(s))")
    p isa IRI || error("TRIPLE: predicate must be an IRI, got $(typeof(p))")
    TripleTerm(s, p, o)
end

function _sp_tt_subject(t::RDFTerm)::RDFTerm
    t isa TripleTerm || error("SUBJECT requires a triple term")
    t.subject::RDFTerm
end

function _sp_tt_predicate(t::RDFTerm)::RDFTerm
    t isa TripleTerm || error("PREDICATE requires a triple term")
    t.predicate
end

function _sp_tt_object(t::RDFTerm)::RDFTerm
    t isa TripleTerm || error("OBJECT requires a triple term")
    t.object::RDFTerm
end

function _sp_datatype(t::RDFTerm)::IRI
    t isa Literal || error("DATATYPE requires a Literal")
    t.datatype
end

function _sp_strlen(t::RDFTerm)::Literal
    t isa Literal || error("STRLEN requires a Literal")
    t.datatype.value in (_SP_XSD_STRING, _SP_RDF_LANGSTRING) ||
        error("STRLEN requires a plain/lang string literal")
    n = length(t.lexical_form)  # character count
    Literal(string(n), IRI(_SP_XSD_INTEGER), "")
end

function _sp_ucase(t::RDFTerm)::Literal
    t isa Literal || error("UCASE requires a Literal")
    dt = t.datatype.value
    dt in (_SP_XSD_STRING, _SP_RDF_LANGSTRING) || error("UCASE requires a string literal")
    Literal(uppercase(t.lexical_form), t.datatype, t.language_tag)
end

function _sp_lcase(t::RDFTerm)::Literal
    t isa Literal || error("LCASE requires a Literal")
    dt = t.datatype.value
    dt in (_SP_XSD_STRING, _SP_RDF_LANGSTRING) || error("LCASE requires a string literal")
    Literal(lowercase(t.lexical_form), t.datatype, t.language_tag)
end

function _sp_substr(t::RDFTerm, startarg::RDFTerm, lenarg::Union{RDFTerm,Nothing}=nothing)::Literal
    t isa Literal || error("SUBSTR requires a string literal")
    dt = t.datatype.value
    dt in (_SP_XSD_STRING, _SP_RDF_LANGSTRING) || error("SUBSTR requires a string literal")
    s = t.lexical_form
    startarg isa Literal && _sp_is_numeric(startarg.datatype.value) || error("SUBSTR start must be numeric")
    # 1-based in SPARQL (XPath)
    st = round(Int, _sp_to_float(startarg::Literal))
    chars = collect(s)
    n = length(chars)
    if lenarg !== nothing
        lenarg isa Literal && _sp_is_numeric(lenarg.datatype.value) || error("SUBSTR length must be numeric")
        len = round(Int, _sp_to_float(lenarg::Literal))
        # XPath: end = start + length - 1 (but clamped to string length)
        first_idx = max(1, st)
        last_idx  = min(n, st + len - 1)
        result = first_idx <= last_idx ? String(chars[first_idx:last_idx]) : ""
    else
        first_idx = max(1, st)
        result = first_idx <= n ? String(chars[first_idx:end]) : ""
    end
    Literal(result, t.datatype, t.language_tag)
end

function _sp_contains(t::RDFTerm, pattern::RDFTerm)::Literal
    t isa Literal && pattern isa Literal || error("CONTAINS requires two literals")
    _sp_bool_literal(occursin(pattern.lexical_form, t.lexical_form))
end

function _sp_strstarts(t::RDFTerm, pattern::RDFTerm)::Literal
    t isa Literal && pattern isa Literal || error("STRSTARTS requires two literals")
    _sp_bool_literal(startswith(t.lexical_form, pattern.lexical_form))
end

function _sp_strends(t::RDFTerm, pattern::RDFTerm)::Literal
    t isa Literal && pattern isa Literal || error("STRENDS requires two literals")
    _sp_bool_literal(endswith(t.lexical_form, pattern.lexical_form))
end

function _sp_strbefore(t::RDFTerm, pattern::RDFTerm)::Literal
    t isa Literal && pattern isa Literal || error("STRBEFORE requires two literals")
    t_lit = t::Literal; pat = pattern::Literal
    # arg1 must be a string-type literal (xsd:string or lang-tagged)
    _sp_is_string_literal(t_lit) || error("STRBEFORE: arg1 must be a string literal, got $(t_lit.datatype.value)")
    # arg2 compatibility: simple/xsd:string, or lang-tagged with same language as arg1
    if !isempty(pat.language_tag)
        pat.language_tag == t_lit.language_tag || error("STRBEFORE: incompatible language tags ($(pat.language_tag) vs $(t_lit.language_tag))")
    else
        _sp_is_plain_string(pat) || error("STRBEFORE: arg2 must be a simple/xsd:string literal")
    end
    p = pat.lexical_form
    s = t_lit.lexical_form
    idx = findfirst(p, s)
    # If not found: empty xsd:string (plain, not inheriting arg1 type)
    idx === nothing && return Literal("", IRI(_SP_XSD_STRING), "")
    result = s[1:first(idx)-1]
    # If found: inherit type/lang from arg1
    Literal(result, t_lit.datatype, t_lit.language_tag)
end

function _sp_strafter(t::RDFTerm, pattern::RDFTerm)::Literal
    t isa Literal && pattern isa Literal || error("STRAFTER requires two literals")
    t_lit = t::Literal; pat = pattern::Literal
    _sp_is_string_literal(t_lit) || error("STRAFTER: arg1 must be a string literal, got $(t_lit.datatype.value)")
    # arg2 compatibility: simple/xsd:string, or lang-tagged with same language as arg1
    if !isempty(pat.language_tag)
        pat.language_tag == t_lit.language_tag || error("STRAFTER: incompatible language tags ($(pat.language_tag) vs $(t_lit.language_tag))")
    else
        _sp_is_plain_string(pat) || error("STRAFTER: arg2 must be a simple/xsd:string literal")
    end
    p = pat.lexical_form
    s = t_lit.lexical_form
    idx = findfirst(p, s)
    # If not found: empty xsd:string (plain, not inheriting arg1 type)
    idx === nothing && return Literal("", IRI(_SP_XSD_STRING), "")
    result = s[last(idx)+1:end]
    # If found: inherit type/lang from arg1
    Literal(result, t_lit.datatype, t_lit.language_tag)
end

# True if the literal is a string type (xsd:string, rdf:langString, or
# rdf:dirLangString).
function _sp_is_string_literal(lit::Literal)::Bool
    dt = lit.datatype.value
    dt == _SP_XSD_STRING || dt == _SP_RDF_LANGSTRING || dt == _SP_RDF_DIRLANGSTRING
end

# True if the literal is a plain string (xsd:string, no lang tag)
function _sp_is_plain_string(lit::Literal)::Bool
    isempty(lit.language_tag) && lit.datatype.value == _SP_XSD_STRING
end

function _sp_concat(args::Vector{RDFTerm})::Literal
    isempty(args) && return Literal("", IRI(_SP_XSD_STRING), "")
    parts = String[]
    for a in args
        a isa Literal || error("CONCAT requires literals")
        # Each argument must be a string literal (xsd:string or rdf:langString)
        _sp_is_string_literal(a::Literal) ||
            error("CONCAT: argument must be a string literal, got $(a.datatype.value)")
        push!(parts, a.lexical_form)
    end
    result = join(parts)
    # Type determination: the result keeps a language tag (and base direction)
    # only when every argument carries the *identical* tag — the stored
    # language_tag embeds the direction as "lang--dir", so a plain string
    # comparison captures both.  Otherwise the result is a plain xsd:string.
    if length(args) == 1
        a1 = args[1]::Literal
        return Literal(result, a1.datatype, a1.language_tag)
    end
    first_lang = (args[1]::Literal).language_tag
    if !isempty(first_lang) && all(a -> (a::Literal).language_tag == first_lang, args)
        # dirLangString when the tag carries a base direction ("lang--dir")
        dt = occursin("--", first_lang) ? _SP_RDF_DIRLANGSTRING : _SP_RDF_LANGSTRING
        return Literal(result, IRI(dt), first_lang)
    end
    return Literal(result, IRI(_SP_XSD_STRING), "")
end

function _sp_encode_for_uri(t::RDFTerm)::Literal
    t isa Literal || error("ENCODE_FOR_URI requires a string literal")
    # Percent-encode all characters except unreserved
    result = HTTP_percent_encode(t.lexical_form)
    Literal(result, IRI(_SP_XSD_STRING), "")
end

function HTTP_percent_encode(s::String)::String
    buf = IOBuffer()
    for c in s
        if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
           (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~'
            write(buf, c)
        else
            for b in Vector{UInt8}(string(c))
                write(buf, '%')
                write(buf, uppercase(string(b, base=16, pad=2)))
            end
        end
    end
    String(take!(buf))
end

function _sp_langmatches(lang::RDFTerm, range::RDFTerm)::Literal
    lang isa Literal && range isa Literal || error("LANGMATCHES requires two literals")
    l = lowercase(lang.lexical_form)
    r = lowercase(range.lexical_form)
    r == "*" && return _sp_bool_literal(!isempty(l))
    _sp_bool_literal(l == r || startswith(l, r * "-"))
end

function _sp_build_regex_flags(f::String)::String
    flags = ""
    'i' in f && (flags *= "i")
    's' in f && (flags *= "s")
    'm' in f && (flags *= "m")
    'x' in f && (flags *= "x")
    flags
end

function _sp_regex(text::RDFTerm, pattern::RDFTerm, flags::Union{RDFTerm,Nothing}=nothing)::Literal
    text isa Literal && pattern isa Literal || error("REGEX requires string arguments")
    t = text.lexical_form; p = pattern.lexical_form
    f = flags === nothing ? "" : (flags isa Literal ? flags.lexical_form : "")
    jflags = _sp_build_regex_flags(f)
    re = try Regex(p, jflags) catch err; error("Invalid regex: $p: $err") end
    _sp_bool_literal(occursin(re, t))
end

function _sp_replace(text::RDFTerm, pattern::RDFTerm, replacement::RDFTerm, flags::Union{RDFTerm,Nothing}=nothing)::Literal
    text isa Literal && pattern isa Literal && replacement isa Literal || error("REPLACE requires string arguments")
    # text must be a string literal (xsd:string or rdf:langString)
    _sp_is_string_literal(text::Literal) ||
        error("REPLACE: first argument must be a string literal, got $((text::Literal).datatype.value)")
    t = text.lexical_form; p = pattern.lexical_form; r = replacement.lexical_form
    f = flags === nothing ? "" : (flags isa Literal ? flags.lexical_form : "")
    jflags = _sp_build_regex_flags(f)
    re = try Regex(p, jflags) catch err; error("Invalid regex: $p: $err") end
    # Convert SPARQL $N backreferences to Julia \N format
    r_julia = replace(r, r"\$(\d+)" => m -> "\\" * m[2:end])
    result = replace(t, re => SubstitutionString(r_julia))
    Literal(result, (text::Literal).datatype, (text::Literal).language_tag)
end

# ── Math built-ins ────────────────────────────────────────────────────────────

function _sp_abs(t::RDFTerm)::Literal
    t isa Literal && _sp_is_numeric(t.datatype.value) || error("ABS requires a numeric literal")
    dt = t.datatype.value
    if dt == _SP_XSD_DOUBLE || dt == _SP_XSD_FLOAT
        v = abs(_sp_to_float(t))
        return Literal(_double_lexical(v), _XSD_DOUBLE, "")
    elseif dt == _SP_XSD_DECIMAL
        v = abs(_sp_to_decimal(t))
        return Literal(_sp_decimal_string(v), IRI(_SP_XSD_DECIMAL), "")
    else
        v = abs(parse(BigInt, t.lexical_form))
        return Literal(string(v), IRI(_SP_XSD_INTEGER), "")
    end
end

function _sp_round(t::RDFTerm)::Literal
    t isa Literal && _sp_is_numeric(t.datatype.value) || error("ROUND requires a numeric literal")
    dt = t.datatype.value
    if dt == _SP_XSD_DOUBLE || dt == _SP_XSD_FLOAT
        # SPARQL: round half toward positive infinity (floor(x + 0.5))
        v = floor(_sp_to_float(t) + 0.5)
        return Literal(_double_lexical(v), _XSD_DOUBLE, "")
    elseif dt == _SP_XSD_DECIMAL
        # SPARQL: round half toward positive infinity = floor(r + 1/2)
        r = _sp_to_decimal(t)
        v = Rational{BigInt}(floor(BigInt, r + Rational{BigInt}(1, 2)))
        return Literal(_sp_decimal_string(v; min_places=0), IRI(_SP_XSD_DECIMAL), "")
    else
        return t  # integers: already rounded
    end
end

function _sp_ceil(t::RDFTerm)::Literal
    t isa Literal && _sp_is_numeric(t.datatype.value) || error("CEIL requires a numeric literal")
    dt = t.datatype.value
    if dt == _SP_XSD_DOUBLE || dt == _SP_XSD_FLOAT
        v = ceil(_sp_to_float(t))
        return Literal(_double_lexical(v), _XSD_DOUBLE, "")
    elseif dt == _SP_XSD_DECIMAL
        r = _sp_to_decimal(t)
        v = Rational{BigInt}(ceil(BigInt, r))
        return Literal(_sp_decimal_string(v; min_places=0), IRI(_SP_XSD_DECIMAL), "")
    else
        return t
    end
end

function _sp_floor(t::RDFTerm)::Literal
    t isa Literal && _sp_is_numeric(t.datatype.value) || error("FLOOR requires a numeric literal")
    dt = t.datatype.value
    if dt == _SP_XSD_DOUBLE || dt == _SP_XSD_FLOAT
        v = floor(_sp_to_float(t))
        return Literal(_double_lexical(v), _XSD_DOUBLE, "")
    elseif dt == _SP_XSD_DECIMAL
        r = _sp_to_decimal(t)
        v = Rational{BigInt}(floor(BigInt, r))
        return Literal(_sp_decimal_string(v; min_places=0), IRI(_SP_XSD_DECIMAL), "")
    else
        return t
    end
end

# ── Type casting ──────────────────────────────────────────────────────────────

function _sp_cast(t::RDFTerm, target_iri::String)::Literal
    lex = t isa Literal ? t.lexical_form : (t isa IRI ? t.value : error("Cannot cast blank node"))
    dt = IRI(target_iri)
    if target_iri == _SP_XSD_STRING
        t isa BlankNode && error("Cannot cast blank node to xsd:string")
        t isa IRI && return Literal(t.value, dt, "")
        td = (t::Literal).datatype.value
        if td == _SP_XSD_BOOLEAN
            # Normalize boolean to canonical "true"/"false"
            b = (t::Literal).lexical_form in ("true", "1")
            return Literal(b ? "true" : "false", dt, "")
        elseif td == _SP_XSD_DECIMAL
            # Strip trailing zeros (and decimal point if integer-valued)
            r = _sp_to_decimal(t::Literal)
            return Literal(_sp_decimal_string(r; min_places=0), dt, "")
        elseif td == _SP_XSD_DOUBLE || td == _SP_XSD_FLOAT
            # Convert to decimal notation (no exponent)
            v = _sp_to_float(t::Literal)
            if isnan(v) || isinf(v)
                return Literal((t::Literal).lexical_form, dt, "")
            end
            r = Rational{BigInt}(v)
            return Literal(_sp_decimal_string(r; min_places=0), dt, "")
        else
            return Literal((t::Literal).lexical_form, dt, "")
        end
    elseif target_iri == _SP_XSD_INTEGER || target_iri in _SP_INTEGER_TYPES
        v = if t isa Literal
            td = t.datatype.value
            if td == _SP_XSD_BOOLEAN
                t.lexical_form in ("true","1") ? 1 : 0
            elseif td == _SP_XSD_DOUBLE || td == _SP_XSD_FLOAT || td == _SP_XSD_DECIMAL
                trunc(Int64, _sp_to_float(t))
            else
                parse(BigInt, strip(t.lexical_form))
            end
        else
            error("Cannot cast IRI to integer")
        end
        return Literal(string(v), IRI(_SP_XSD_INTEGER), "")
    elseif target_iri == _SP_XSD_DECIMAL
        t isa IRI && error("Cannot cast IRI to xsd:decimal")
        t isa BlankNode && error("Cannot cast blank node to xsd:decimal")
        td = (t::Literal).datatype.value
        if td == _SP_XSD_STRING
            s = String(strip((t::Literal).lexical_form))  # String() avoids SubString dispatch issues
            # Reject scientific notation (exponent) — not valid xsd:decimal
            occursin(r"[eE]", s) && error("Cannot cast xsd:string with exponent to xsd:decimal: $s")
            r = try _sp_parse_decimal_rational(s) catch; error("Cannot cast xsd:string to xsd:decimal: $s") end
            return Literal(_sp_decimal_string(r; min_places=1), dt, "")
        elseif _sp_is_integer(td)
            r = _sp_to_decimal(t::Literal)
            return Literal(_sp_decimal_string(r; min_places=1), dt, "")
        elseif td == _SP_XSD_DECIMAL
            r = _sp_to_decimal(t::Literal)
            return Literal(_sp_decimal_string(r; min_places=1), dt, "")
        elseif td == _SP_XSD_DOUBLE || td == _SP_XSD_FLOAT
            v = _sp_to_float(t::Literal)
            r = Rational{BigInt}(v)
            return Literal(_sp_decimal_string(r; min_places=1), dt, "")
        elseif td == _SP_XSD_BOOLEAN
            b = (t::Literal).lexical_form in ("true", "1")
            r = b ? Rational{BigInt}(1) : Rational{BigInt}(0)
            return Literal(_sp_decimal_string(r; min_places=1), dt, "")
        else
            error("Cannot cast $td to xsd:decimal")
        end
    elseif target_iri == _SP_XSD_DOUBLE || target_iri == _SP_XSD_FLOAT
        v = if t isa Literal
            td = t.datatype.value
            if td == _SP_XSD_BOOLEAN
                t.lexical_form in ("true","1") ? 1.0 : 0.0
            elseif td == _SP_XSD_STRING
                # Parse plain string as a number; error if not parseable
                v_str = strip(t.lexical_form)
                try parse(Float64, v_str) catch; error("Cannot cast xsd:string to xsd:double: $(t.lexical_form)") end
            else
                _sp_to_float(t)
            end
        else
            error("Cannot cast IRI to double")
        end
        return Literal(_double_lexical(v), IRI(target_iri), "")
    elseif target_iri == _SP_XSD_BOOLEAN
        v = if t isa Literal
            td = t.datatype.value
            if td == _SP_XSD_BOOLEAN
                t.lexical_form in ("true","1")
            elseif _sp_is_numeric(td)
                n = _sp_to_float(t); !isnan(n) && n != 0.0
            elseif td == _SP_XSD_STRING
                # Only "true", "false", "1", "0" are valid xsd:boolean lexical values
                lf = t.lexical_form
                lf in ("true", "1") ? true :
                lf in ("false", "0") ? false :
                error("Cannot cast xsd:string \"$lf\" to xsd:boolean")
            else
                error("Cannot cast $td to boolean")
            end
        else
            error("Cannot cast non-literal to boolean")
        end
        return _sp_bool_literal(v)
    elseif target_iri == _SP_XSD_DATETIME
        # Just validate it parses
        s = t isa Literal ? t.lexical_form : error("Cannot cast to dateTime")
        _sp_parse_datetime(s)  # will error if invalid
        return Literal(s, dt, "")
    elseif target_iri == _SP_XSD_DATE
        s = t isa Literal ? t.lexical_form : error("Cannot cast to date")
        _sp_parse_date(s)
        return Literal(s, dt, "")
    else
        # Unknown target type: just rewrite the datatype
        return Literal(lex, dt, "")
    end
end

# ── IRI / BNODE construction ──────────────────────────────────────────────────

function _sp_iri_fn(t::RDFTerm, base::Union{String,Nothing})::IRI
    s = if t isa IRI
        t.value
    elseif t isa Literal && t.datatype.value == _SP_XSD_STRING
        t.lexical_form
    else
        error("IRI() requires a string literal or IRI")
    end
    # Resolve relative IRIs against base
    if base !== nothing && !occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", s)
        s = _sp_resolve_iri(base, s)  # defined in parser.jl
    end
    IRI(s)
end

# ── Date/time built-ins ───────────────────────────────────────────────────────

function _sp_now()::Literal
    dt = Dates.now(Dates.UTC)
    s = Dates.format(dt, "yyyy-mm-ddTHH:MM:SS") * "Z"
    Literal(s, IRI(_SP_XSD_DATETIME), "")
end

function _sp_year(t::RDFTerm)::Literal
    t isa Literal || error("YEAR requires a dateTime literal")
    dt = _sp_parse_datetime(t.lexical_form)
    Literal(string(Dates.year(dt)), IRI(_SP_XSD_INTEGER), "")
end

function _sp_month(t::RDFTerm)::Literal
    t isa Literal || error("MONTH requires a dateTime literal")
    dt = _sp_parse_datetime(t.lexical_form)
    Literal(string(Dates.month(dt)), IRI(_SP_XSD_INTEGER), "")
end

function _sp_day(t::RDFTerm)::Literal
    t isa Literal || error("DAY requires a dateTime literal")
    dt = _sp_parse_datetime(t.lexical_form)
    Literal(string(Dates.day(dt)), IRI(_SP_XSD_INTEGER), "")
end

function _sp_hours(t::RDFTerm)::Literal
    t isa Literal || error("HOURS requires a dateTime literal")
    dt = _sp_parse_datetime(t.lexical_form)
    Literal(string(Dates.hour(dt)), IRI(_SP_XSD_INTEGER), "")
end

function _sp_minutes(t::RDFTerm)::Literal
    t isa Literal || error("MINUTES requires a dateTime literal")
    dt = _sp_parse_datetime(t.lexical_form)
    Literal(string(Dates.minute(dt)), IRI(_SP_XSD_INTEGER), "")
end

function _sp_seconds(t::RDFTerm)::Literal
    t isa Literal || error("SECONDS requires a dateTime literal")
    s = t.lexical_form
    # Extract seconds (with optional fractional part) directly from the string
    m = match(r"T\d{2}:\d{2}:(\d{2}(?:\.\d+)?)", s)
    sec_str = m !== nothing ? String(m.captures[1]) : string(Dates.second(_sp_parse_datetime(s)))
    v = _sp_parse_decimal_rational(sec_str)
    Literal(_sp_decimal_string(v; min_places=0), IRI(_SP_XSD_DECIMAL), "")
end

function _sp_tz(t::RDFTerm)::Literal
    t isa Literal || error("TZ requires a dateTime/date literal")
    s = t.lexical_form
    m = match(r"([+-]\d{2}:\d{2}|Z)$", s)
    tz = m === nothing ? "" : String(m.match)
    Literal(tz, IRI(_SP_XSD_STRING), "")
end

# xsd:dayTimeDuration — SPARQL TIMEZONE() returns this type
const _SP_XSD_DAY_TIME_DURATION = _SP_XSD * "dayTimeDuration"

function _sp_timezone(t::RDFTerm)::Literal
    t isa Literal || error("TIMEZONE requires a dateTime/date literal")
    s = t.lexical_form
    m = match(r"([+-]\d{2}:\d{2}|Z)$", s)
    m === nothing && error("No timezone in: $s")
    tz_match = String(m.match)
    tz_str = if tz_match == "Z"
        "PT0S"
    else
        h  = parse(Int, tz_match[2:3])
        mn = parse(Int, tz_match[5:6])
        sign = tz_match[1] == '+' ? "" : "-"
        if mn == 0
            "$(sign)PT$(h)H"
        else
            "$(sign)PT$(h)H$(mn)M"
        end
    end
    Literal(tz_str, IRI(_SP_XSD_DAY_TIME_DURATION), "")
end

# ── Hash functions ────────────────────────────────────────────────────────────

function _sp_md5(t::RDFTerm)::Literal
    t isa Literal || error("MD5 requires a plain string literal")
    data = Vector{UInt8}(t.lexical_form)
    h = bytes2hex(MD5.md5(data))
    Literal(lowercase(h), IRI(_SP_XSD_STRING), "")
end

function _sp_sha1(t::RDFTerm)::Literal
    t isa Literal || error("SHA1 requires a plain string literal")
    data = Vector{UInt8}(t.lexical_form)
    h = bytes2hex(SHA.sha1(data))
    Literal(lowercase(h), IRI(_SP_XSD_STRING), "")
end

function _sp_sha256(t::RDFTerm)::Literal
    t isa Literal || error("SHA256 requires a plain string literal")
    data = Vector{UInt8}(t.lexical_form)
    h = bytes2hex(SHA.sha256(data))
    Literal(lowercase(h), IRI(_SP_XSD_STRING), "")
end

function _sp_sha384(t::RDFTerm)::Literal
    t isa Literal || error("SHA384 requires a plain string literal")
    data = Vector{UInt8}(t.lexical_form)
    h = bytes2hex(SHA.sha384(data))
    Literal(lowercase(h), IRI(_SP_XSD_STRING), "")
end

function _sp_sha512(t::RDFTerm)::Literal
    t isa Literal || error("SHA512 requires a plain string literal")
    data = Vector{UInt8}(t.lexical_form)
    h = bytes2hex(SHA.sha512(data))
    Literal(lowercase(h), IRI(_SP_XSD_STRING), "")
end

# ── UUID ─────────────────────────────────────────────────────────────────────

function _sp_uuid()::IRI
    u = string(Base.UUID(rand(UInt128)))
    IRI("urn:uuid:$u")
end

function _sp_struuid()::Literal
    Literal(string(Base.UUID(rand(UInt128))), IRI(_SP_XSD_STRING), "")
end

# ── STRDT / STRLANG ───────────────────────────────────────────────────────────

function _sp_strdt(lex::RDFTerm, dt::RDFTerm)::Literal
    lex isa Literal && dt isa IRI || error("STRDT(str, iri): need literal and IRI")
    # Type error if language-tagged string (RDF 1.1: lang-tagged ≠ simple literal)
    !isempty(lex.language_tag) && error("STRDT: language-tagged literal is not a simple literal")
    # Type error if not a simple string (xsd:string)
    lex.datatype.value == _SP_XSD_STRING ||
        error("STRDT: first argument must be a simple literal (xsd:string), got $(lex.datatype.value)")
    Literal(lex.lexical_form, dt, "")
end

function _sp_strlang(lex::RDFTerm, lang::RDFTerm)::Literal
    lex isa Literal && lang isa Literal || error("STRLANG(str, lang): need two literals")
    # Type error if language-tagged string
    !isempty(lex.language_tag) && error("STRLANG: language-tagged literal is not a simple literal")
    # Type error if not a simple string (xsd:string)
    lex.datatype.value == _SP_XSD_STRING ||
        error("STRLANG: first argument must be a simple literal (xsd:string), got $(lex.datatype.value)")
    l = lowercase(lang.lexical_form)
    isempty(l) && error("STRLANG: language tag must not be empty")
    Literal(lex.lexical_form, IRI(_SP_RDF_LANGSTRING), l)
end

# ── BOUND ────────────────────────────────────────────────────────────────────

# BOUND is handled specially in the evaluator (it takes a variable name, not a value)

# ── SAMETERM ─────────────────────────────────────────────────────────────────

function _sp_sameterm(a::RDFTerm, b::RDFTerm)::Literal
    _sp_bool_literal(a == b)
end

# ── Dispatch table for built-in functions ─────────────────────────────────────

# Maps lowercase function name / IRI to a callable that takes (args::Vector{RDFTerm}) → RDFTerm
# Some functions (BOUND, IF, COALESCE, EXISTS, NOT EXISTS) are handled specially in eval.jl

function _sp_call_builtin(name::String, args::Vector{RDFTerm}, base::Union{String,Nothing},
                          bnode_scope::Union{Dict{String,BlankNode},Nothing}=nothing)::RDFTerm
    n = length(args)
    if name == "str"
        n == 1 || error("STR takes 1 argument")
        return _sp_str(args[1])
    elseif name == "lang"
        n == 1 || error("LANG takes 1 argument")
        return _sp_lang(args[1])
    elseif name == "langdir"
        n == 1 || error("LANGDIR takes 1 argument")
        return _sp_langdir(args[1])
    elseif name == "haslang"
        n == 1 || error("hasLANG takes 1 argument")
        return _sp_haslang(args[1])
    elseif name == "haslangdir"
        n == 1 || error("hasLANGDIR takes 1 argument")
        return _sp_haslangdir(args[1])
    elseif name == "strlangdir"
        n == 3 || error("STRLANGDIR takes 3 arguments")
        return _sp_strlangdir(args[1], args[2], args[3])
    elseif name == "triple"
        n == 3 || error("TRIPLE takes 3 arguments")
        return _sp_triple_fn(args[1], args[2], args[3])
    elseif name == "subject"
        n == 1 || error("SUBJECT takes 1 argument")
        return _sp_tt_subject(args[1])
    elseif name == "predicate"
        n == 1 || error("PREDICATE takes 1 argument")
        return _sp_tt_predicate(args[1])
    elseif name == "object"
        n == 1 || error("OBJECT takes 1 argument")
        return _sp_tt_object(args[1])
    elseif name == "istriple"
        n == 1 || error("isTRIPLE takes 1 argument")
        return _sp_bool_literal(args[1] isa TripleTerm)
    elseif name == "datatype"
        n == 1 || error("DATATYPE takes 1 argument")
        return _sp_datatype(args[1])
    elseif name == "iri" || name == "uri"
        n == 1 || error("IRI takes 1 argument")
        return _sp_iri_fn(args[1], base)
    elseif name == "bnode"
        if n == 0
            return _mint_blank_node()
        elseif n == 1
            args[1] isa Literal || error("BNODE argument must be a literal")
            label = (args[1]::Literal).lexical_form
            # Per-solution scoping: same string in same solution → same blank node
            if bnode_scope !== nothing
                return get!(bnode_scope, label) do
                    _mint_blank_node()
                end
            else
                # Fallback: mint a fresh blank node per call (no scoping available)
                return _mint_blank_node()
            end
        end
    elseif name == "strlen"
        n == 1 || error("STRLEN takes 1 argument")
        return _sp_strlen(args[1])
    elseif name == "ucase"
        n == 1 || error("UCASE takes 1 argument")
        return _sp_ucase(args[1])
    elseif name == "lcase"
        n == 1 || error("LCASE takes 1 argument")
        return _sp_lcase(args[1])
    elseif name == "substr"
        n in (2, 3) || error("SUBSTR takes 2 or 3 arguments")
        return _sp_substr(args[1], args[2], n == 3 ? args[3] : nothing)
    elseif name == "contains"
        n == 2 || error("CONTAINS takes 2 arguments")
        return _sp_contains(args[1], args[2])
    elseif name == "strstarts"
        n == 2 || error("STRSTARTS takes 2 arguments")
        return _sp_strstarts(args[1], args[2])
    elseif name == "strends"
        n == 2 || error("STRENDS takes 2 arguments")
        return _sp_strends(args[1], args[2])
    elseif name == "strbefore"
        n == 2 || error("STRBEFORE takes 2 arguments")
        return _sp_strbefore(args[1], args[2])
    elseif name == "strafter"
        n == 2 || error("STRAFTER takes 2 arguments")
        return _sp_strafter(args[1], args[2])
    elseif name == "concat"
        return _sp_concat(args)
    elseif name == "langmatches"
        n == 2 || error("LANGMATCHES takes 2 arguments")
        return _sp_langmatches(args[1], args[2])
    elseif name == "encode_for_uri"
        n == 1 || error("ENCODE_FOR_URI takes 1 argument")
        return _sp_encode_for_uri(args[1])
    elseif name == "regex"
        n in (2, 3) || error("REGEX takes 2 or 3 arguments")
        return _sp_regex(args[1], args[2], n == 3 ? args[3] : nothing)
    elseif name == "replace"
        n in (3, 4) || error("REPLACE takes 3 or 4 arguments")
        return _sp_replace(args[1], args[2], args[3], n == 4 ? args[4] : nothing)
    elseif name == "abs"
        n == 1 || error("ABS takes 1 argument")
        return _sp_abs(args[1])
    elseif name == "round"
        n == 1 || error("ROUND takes 1 argument")
        return _sp_round(args[1])
    elseif name == "ceil"
        n == 1 || error("CEIL takes 1 argument")
        return _sp_ceil(args[1])
    elseif name == "floor"
        n == 1 || error("FLOOR takes 1 argument")
        return _sp_floor(args[1])
    elseif name == "rand"
        n == 0 || error("RAND takes no arguments")
        return Literal(_double_lexical(rand()), IRI(_SP_XSD_DOUBLE), "")
    elseif name == "now"
        n == 0 || error("NOW takes no arguments")
        return _sp_now()
    elseif name == "year"
        n == 1 || error("YEAR takes 1 argument")
        return _sp_year(args[1])
    elseif name == "month"
        n == 1 || error("MONTH takes 1 argument")
        return _sp_month(args[1])
    elseif name == "day"
        n == 1 || error("DAY takes 1 argument")
        return _sp_day(args[1])
    elseif name == "hours"
        n == 1 || error("HOURS takes 1 argument")
        return _sp_hours(args[1])
    elseif name == "minutes"
        n == 1 || error("MINUTES takes 1 argument")
        return _sp_minutes(args[1])
    elseif name == "seconds"
        n == 1 || error("SECONDS takes 1 argument")
        return _sp_seconds(args[1])
    elseif name == "tz"
        n == 1 || error("TZ takes 1 argument")
        return _sp_tz(args[1])
    elseif name == "timezone"
        n == 1 || error("TIMEZONE takes 1 argument")
        return _sp_timezone(args[1])
    elseif name == "md5"
        n == 1 || error("MD5 takes 1 argument")
        return _sp_md5(args[1])
    elseif name == "sha1"
        n == 1 || error("SHA1 takes 1 argument")
        return _sp_sha1(args[1])
    elseif name == "sha256"
        n == 1 || error("SHA256 takes 1 argument")
        return _sp_sha256(args[1])
    elseif name == "sha384"
        n == 1 || error("SHA384 takes 1 argument")
        return _sp_sha384(args[1])
    elseif name == "sha512"
        n == 1 || error("SHA512 takes 1 argument")
        return _sp_sha512(args[1])
    elseif name == "uuid"
        n == 0 || error("UUID takes no arguments")
        return _sp_uuid()
    elseif name == "struuid"
        n == 0 || error("STRUUID takes no arguments")
        return _sp_struuid()
    elseif name == "strdt"
        n == 2 || error("STRDT takes 2 arguments")
        return _sp_strdt(args[1], args[2])
    elseif name == "strlang"
        n == 2 || error("STRLANG takes 2 arguments")
        return _sp_strlang(args[1], args[2])
    elseif name == "sameterm"
        n == 2 || error("SAMETERM takes 2 arguments")
        return _sp_sameterm(args[1], args[2])
    elseif name == "isiri" || name == "isuri"
        n == 1 || error("ISIRI takes 1 argument")
        return _sp_bool_literal(args[1] isa IRI)
    elseif name == "isblank"
        n == 1 || error("ISBLANK takes 1 argument")
        return _sp_bool_literal(args[1] isa BlankNode)
    elseif name == "isliteral"
        n == 1 || error("ISLITERAL takes 1 argument")
        return _sp_bool_literal(args[1] isa Literal)
    elseif name == "isnumeric"
        n == 1 || error("ISNUMERIC takes 1 argument")
        return _sp_bool_literal(args[1] isa Literal && _sp_is_numeric((args[1]::Literal).datatype.value))
    elseif name == "coalesce"
        # Handled in evaluator (short-circuits on unbound), but provide a fallback
        error("COALESCE should be handled by evaluator")
    else
        # Try as a casting function by XSD IRI
        # e.g. xsd:integer(...), xsd:string(...)
        if startswith(name, _SP_XSD) || startswith(name, "http://")
            n == 1 || error("Casting function $name takes 1 argument")
            return _sp_cast(args[1], name)
        end
        error("Unknown built-in function: $name")
    end
end
