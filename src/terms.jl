"""
    RDFTerm

Abstract supertype for all RDF terms: `IRI`, `BlankNode`, `Literal`, and `TripleTerm`.
"""
abstract type RDFTerm end

# ── IRI ──────────────────────────────────────────────────────────────────────

# Scheme regex per RFC 3987: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
const _SCHEME_RE = r"^[A-Za-z][A-Za-z0-9+\-.]*:"

function _validate_iri(s::String)
    isempty(s) && throw(IRIError(s, "IRI must not be empty"))
    if !occursin(_SCHEME_RE, s)
        throw(IRIError(s, "IRI must be absolute (must start with a scheme)"))
    end
    # Spaces are never valid in IRIs without percent-encoding
    if occursin(' ', s)
        throw(IRIError(s, "IRI must not contain unencoded spaces"))
    end
    nothing
end

"""
    IRI(s::AbstractString) <: RDFTerm

An absolute IRI (RFC 3987). Must begin with a scheme (e.g. `http:`) and contain no
unencoded spaces. Use the `iri""` string macro for compile-time validation.

```julia
IRI("http://example.org/Alice")
iri"http://schema.org/Person"
```
"""
struct IRI <: RDFTerm
    value::String
    # Public constructor: validates the string is an absolute IRI.
    function IRI(s::String)
        _validate_iri(s)
        new(s)
    end
    # Internal bypass: skip validation for strings already known to be valid IRIs
    # (e.g., freshly parsed from a <...> token in N-Triples / Turtle / SPARQL).
    # Never call this from user-facing code.
    IRI(s::String, ::Val{:_trusted}) = new(s)
end

# Convenience for AbstractString inputs
IRI(s::AbstractString) = IRI(String(s))

Base.:(==)(a::IRI, b::IRI) = a.value == b.value
Base.hash(a::IRI, h::UInt) = hash(a.value, hash(:IRI, h))

# Treat all RDF terms as scalars in broadcasting (e.g., `df.object .== ex.Person`)
Base.broadcastable(t::RDFTerm) = Ref(t)

"""
    iri"http://example.org/foo"

String macro that constructs an `IRI` and validates the value at compile time.
Equivalent to `IRI(s)` but catches invalid IRIs before the program runs.
"""
macro iri_str(s)
    _validate_iri(s)   # compile-time check for string literals
    :(IRI($s))
end

# ── BlankNode ─────────────────────────────────────────────────────────────────

"""
    BlankNode <: RDFTerm

An RDF blank node identified by an opaque `UInt64` id. Blank nodes should be
created via [`blank!`](@ref) rather than constructed directly, to ensure ids are
unique within the graph.
"""
struct BlankNode <: RDFTerm
    id::UInt64
end

Base.:(==)(a::BlankNode, b::BlankNode) = a.id == b.id
Base.hash(a::BlankNode, h::UInt) = hash(a.id, hash(:BlankNode, h))

# Global atomic counter for minting blank nodes
const _BLANK_NODE_COUNTER = Threads.Atomic{UInt64}(0)

function _mint_blank_node()::BlankNode
    id = Threads.atomic_add!(_BLANK_NODE_COUNTER, UInt64(1))
    BlankNode(id)
end

# ── Literal ───────────────────────────────────────────────────────────────────

"""
    Literal <: RDFTerm

An RDF literal with a lexical form, datatype IRI, and optional language tag.

Common constructors:
- `Literal("hello")` — plain string (`xsd:string`)
- `Literal("hello"; lang="en")` — language-tagged string (`rdf:langString`)
- `Literal("hello"; lang="ar", dir="rtl")` — directional string (`rdf:dirLangString`, RDF 1.2)
- `Literal("hello", IRI("..."))` — explicit datatype
- `Literal(42)` → `xsd:integer`, `Literal(3.14)` → `xsd:double`, `Literal(true)` → `xsd:boolean`
- `Literal(Date(2024,1,1))` → `xsd:date`
"""
struct Literal <: RDFTerm
    lexical_form::String
    datatype::IRI
    language_tag::String   # "" unless rdf:langString; always lowercase
    function Literal(lex::String, dt::IRI, lang::String)
        _LANGSTRING    = "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString"
        _DIR_LANGSTRING = "http://www.w3.org/1999/02/22-rdf-syntax-ns#dirLangString"
        is_lang = dt.value == _LANGSTRING
        is_dir  = dt.value == _DIR_LANGSTRING
        if is_lang && isempty(lang)
            throw(ArgumentError("rdf:langString requires a non-empty language tag"))
        end
        if is_dir && isempty(lang)
            throw(ArgumentError("rdf:dirLangString requires a non-empty language tag"))
        end
        if !is_lang && !is_dir && !isempty(lang)
            throw(ArgumentError("language tag may only be set when datatype is rdf:langString or rdf:dirLangString"))
        end
        new(lex, dt, lang)
    end
end

# Forward-declare XSD and RDF IRI constants used by Literal constructors.
# They are defined in vocabulary modules loaded after this file.
# We use string literals here to break the circular dependency.
const _XSD_STRING    = IRI("http://www.w3.org/2001/XMLSchema#string")
const _XSD_INTEGER   = IRI("http://www.w3.org/2001/XMLSchema#integer")
const _XSD_DOUBLE    = IRI("http://www.w3.org/2001/XMLSchema#double")
const _XSD_BOOLEAN   = IRI("http://www.w3.org/2001/XMLSchema#boolean")
const _XSD_DATE      = IRI("http://www.w3.org/2001/XMLSchema#date")
const _XSD_DATETIME  = IRI("http://www.w3.org/2001/XMLSchema#dateTime")
const _XSD_DECIMAL   = IRI("http://www.w3.org/2001/XMLSchema#decimal")
const _XSD_FLOAT     = IRI("http://www.w3.org/2001/XMLSchema#float")
const _RDF_LANGSTRING    = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#langString")
const _RDF_DIR_LANGSTRING = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#dirLangString")

# Literal constructors dispatch on Julia type

# 2-arg form with explicit datatype; enforces lang-tag invariant.
function Literal(s::String, datatype::IRI)
    if datatype == _RDF_LANGSTRING
        throw(ArgumentError("rdf:langString requires a non-empty language tag; use Literal(s; lang=...)"))
    end
    if datatype == _RDF_DIR_LANGSTRING
        throw(ArgumentError("rdf:dirLangString requires language and direction; use Literal(s; lang=..., dir=...)"))
    end
    Literal(s, datatype, "")
end

# Unified string constructor: no lang → xsd:string, lang= → rdf:langString, lang+dir= → rdf:dirLangString.
function Literal(x::AbstractString; lang::Union{AbstractString, Nothing}=nothing,
                                    dir::Union{AbstractString, Nothing}=nothing)
    if dir !== nothing && lang === nothing
        throw(ArgumentError("dir= requires lang= to be set"))
    end
    if lang === nothing
        Literal(String(x), _XSD_STRING, "")
    elseif dir !== nothing
        lt = lowercase(String(lang))
        dt = lowercase(String(dir))
        isempty(lt) && throw(ArgumentError("language tag must not be empty"))
        dt in ("ltr", "rtl") || throw(ArgumentError("direction must be \"ltr\" or \"rtl\""))
        Literal(String(x), _RDF_DIR_LANGSTRING, "$lt--$dt")
    else
        lt = lowercase(String(lang))
        isempty(lt) && throw(ArgumentError("language tag must not be empty"))
        Literal(String(x), _RDF_LANGSTRING, lt)
    end
end
Literal(x::Bool)               = Literal(x ? "true" : "false", _XSD_BOOLEAN, "")
Literal(x::Integer)            = Literal(string(x), _XSD_INTEGER, "")
Literal(x::Float32)            = Literal(_float_lexical(x), _XSD_FLOAT, "")
Literal(x::AbstractFloat)      = Literal(_double_lexical(x), _XSD_DOUBLE, "")
Literal(x::Dates.Date)         = Literal(string(x), _XSD_DATE, "")
Literal(x::Dates.DateTime)     = Literal(string(x), _XSD_DATETIME, "")

# Convert a decimal-notation or e-notation string to XSD double canonical form.
# XSD doubles must use scientific notation: e.g. "3.21E4", "4.0E-1", "2.0E-1".
function _dec_to_xsd_double_str(s::String)::String
    neg = startswith(s, "-")
    ns  = neg ? s[2:end] : s
    pfx = neg ? "-" : ""

    # Already has E notation (from repr on large/small values)
    ei = findfirst(c -> c == 'e' || c == 'E', ns)
    if ei !== nothing
        mant = ns[1:ei-1]
        exp  = parse(Int, ns[ei+1:end])
        # Ensure at least one decimal digit in mantissa
        '.' in mant || (mant = mant * ".0")
        mant = rstrip(mant, '0')
        endswith(mant, '.') && (mant *= "0")
        return pfx * mant * "E" * string(exp)
    end

    # Decimal notation: e.g. "32100.0", "0.4", "0.0002"
    dot_i = findfirst('.', ns)
    int_s  = dot_i === nothing ? ns        : ns[1:dot_i-1]
    frac_s = dot_i === nothing ? ""        : ns[dot_i+1:end]

    all_digits = int_s * frac_s
    first_nz   = findfirst(c -> c != '0', all_digits)
    first_nz === nothing && return pfx * "0.0E0"

    n_int      = length(int_s)
    exp        = n_int - first_nz       # e.g. "32100" → 5-1=4, "0" → 1-2=-1
    sig        = rstrip(all_digits[first_nz:end], '0')
    isempty(sig) && (sig = "0")
    mant       = length(sig) == 1 ? sig * ".0" : sig[1:1] * "." * sig[2:end]
    return pfx * mant * "E" * string(exp)
end

function _double_lexical(x::AbstractFloat)
    isnan(x)      && return "NaN"
    isinf(x) && x > 0 && return "INF"
    isinf(x)      && return "-INF"
    x == 0.0      && return signbit(x) ? "-0.0E0" : "0.0E0"
    _dec_to_xsd_double_str(repr(Float64(x)))
end

function _float_lexical(x::Float32)
    isnan(x)      && return "NaN"
    isinf(x) && x > 0 && return "INF"
    isinf(x)      && return "-INF"
    x == 0.0f0    && return signbit(x) ? "-0.0E0" : "0.0E0"
    _dec_to_xsd_double_str(repr(Float64(x)))
end

Base.:(==)(a::Literal, b::Literal) =
    a.lexical_form == b.lexical_form &&
    a.datatype == b.datatype &&
    a.language_tag == b.language_tag

Base.hash(a::Literal, h::UInt) =
    hash(a.language_tag, hash(a.datatype, hash(a.lexical_form, hash(:Literal, h))))

# ── TripleTerm (RDF-star embedded triple reference) ───────────────────────────

"""
    TripleTerm(subject, predicate, object) <: RDFTerm

An RDF-star triple term — an embedded triple used as an RDF term in either
subject or object position. Enables statement-level annotations (e.g. via
`rdf:reifies`) without blank-node reification.

The subject may be an `IRI`, `BlankNode`, or nested `TripleTerm`; the
predicate must be an `IRI`; the object may be any `ObjectTerm`.

```julia
tt = TripleTerm(iri"http://example.org/bob", rdf.type, iri"http://example.org/Person")

# As object (most common — rdf:reifies annotation)
push!(g, Triple(iri"http://example.org/claim", rdf.reifies, tt))

# As subject
push!(g, Triple(tt, iri"http://example.org/certainty", Literal(0.9)))
```
"""
struct TripleTerm <: RDFTerm
    # Both subject and object are Any because Julia doesn't support recursive
    # immutable structs; the inner constructor enforces the correct types.
    subject::Any   # Union{IRI, BlankNode, TripleTerm}
    predicate::IRI
    object::Any    # Union{IRI, BlankNode, Literal, TripleTerm}
    function TripleTerm(s, p::IRI, o)
        s isa IRI || s isa BlankNode || s isa TripleTerm ||
            throw(ArgumentError("TripleTerm subject must be IRI, BlankNode, or TripleTerm"))
        o isa IRI || o isa BlankNode || o isa Literal || o isa TripleTerm ||
            throw(ArgumentError("TripleTerm object must be IRI, BlankNode, Literal, or TripleTerm"))
        new(s, p, o)
    end
end

Base.:(==)(a::TripleTerm, b::TripleTerm) =
    a.subject == b.subject && a.predicate == b.predicate && a.object == b.object
Base.hash(a::TripleTerm, h::UInt) =
    hash(a.object, hash(a.predicate, hash(a.subject, hash(:TripleTerm, h))))

# ── Positional type aliases ───────────────────────────────────────────────────

"""
    SubjectTerm

Union type for valid RDF subject positions: `IRI`, `BlankNode`, or `TripleTerm`
(RDF-star embedded triple).
"""
const SubjectTerm   = Union{IRI, BlankNode, TripleTerm}

"""
    PredicateTerm

Alias for `IRI`; only IRIs are valid in the predicate position.
"""
const PredicateTerm = IRI

"""
    ObjectTerm

Union type for valid RDF object positions: `IRI`, `BlankNode`, `Literal`, or `TripleTerm`.
"""
const ObjectTerm    = Union{IRI, BlankNode, Literal, TripleTerm}

"""
    GraphName

Union type for RDF graph names: `IRI` or `BlankNode`.
"""
const GraphName     = Union{IRI, BlankNode}
