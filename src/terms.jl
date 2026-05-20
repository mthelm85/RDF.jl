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

struct IRI <: RDFTerm
    value::String
    # Inner constructor validates: no default constructor bypasses this
    function IRI(s::String)
        _validate_iri(s)
        new(s)
    end
end

# Convenience for AbstractString inputs
IRI(s::AbstractString) = IRI(String(s))

Base.:(==)(a::IRI, b::IRI) = a.value == b.value
Base.hash(a::IRI, h::UInt) = hash(a.value, hash(:IRI, h))

# Treat all RDF terms as scalars in broadcasting (e.g., `df.object .== ex.Person`)
Base.broadcastable(t::RDFTerm) = Ref(t)

# String macro that validates at macro-expansion time for literal strings
macro iri_str(s)
    _validate_iri(s)   # compile-time check for string literals
    :(IRI($s))
end

# ── BlankNode ─────────────────────────────────────────────────────────────────

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

struct Literal <: RDFTerm
    lexical_form::String
    datatype::IRI
    language_tag::String   # "" unless rdf:langString; always lowercase
    function Literal(lex::String, dt::IRI, lang::String)
        _LANGSTRING = "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString"
        if dt.value == _LANGSTRING && isempty(lang)
            throw(ArgumentError("rdf:langString requires a non-empty language tag"))
        end
        if dt.value != _LANGSTRING && !isempty(lang)
            throw(ArgumentError("language tag may only be set when datatype is rdf:langString"))
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
const _RDF_LANGSTRING = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#langString")

# Literal constructors dispatch on Julia type

# 2-arg form with explicit datatype; enforces lang-tag invariant.
function Literal(s::String, datatype::IRI)
    if datatype == _RDF_LANGSTRING
        throw(ArgumentError("rdf:langString requires a non-empty language tag; use Literal(s; lang=...)"))
    end
    Literal(s, datatype, "")
end

# Unified string constructor: no lang → xsd:string, lang= provided → rdf:langString.
function Literal(x::AbstractString; lang::Union{AbstractString, Nothing}=nothing)
    if lang === nothing
        Literal(String(x), _XSD_STRING, "")
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

function _double_lexical(x::AbstractFloat)
    isnan(x)      && return "NaN"
    isinf(x) && x > 0 && return "INF"
    isinf(x)      && return "-INF"
    string(x)
end

function _float_lexical(x::Float32)
    isnan(x)      && return "NaN"
    isinf(x) && x > 0 && return "INF"
    isinf(x)      && return "-INF"
    string(x)
end

Base.:(==)(a::Literal, b::Literal) =
    a.lexical_form == b.lexical_form &&
    a.datatype == b.datatype &&
    a.language_tag == b.language_tag

Base.hash(a::Literal, h::UInt) =
    hash(a.language_tag, hash(a.datatype, hash(a.lexical_form, hash(:Literal, h))))

# ── Positional type aliases ───────────────────────────────────────────────────

const SubjectTerm   = Union{IRI, BlankNode}
const PredicateTerm = IRI
const ObjectTerm    = Union{IRI, BlankNode, Literal}
const GraphName     = Union{IRI, BlankNode}
