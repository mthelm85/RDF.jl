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

# ── TripleTerm (RDF 1.2 reified triple reference) ─────────────────────────────

"""
    TripleTerm(subject, predicate, object) <: RDFTerm

An RDF 1.2 triple term (RDF-star), representing a triple used as an RDF term.
The subject must be an `IRI` or `BlankNode`; the predicate must be an `IRI`;
the object may be any `ObjectTerm` (including a nested `TripleTerm`).

```julia
tt = TripleTerm(iri"http://example.org/bob", rdf.type, iri"http://example.org/Person")
push!(g, Triple(iri"http://example.org/alice", iri"http://example.org/knows", tt))
```
"""
# Julia does not support recursive immutable structs, so object is typed Any
# and validated at construction time.
struct TripleTerm <: RDFTerm
    subject::Union{IRI, BlankNode}
    predicate::IRI
    object::Any   # Union{IRI, BlankNode, Literal, TripleTerm} enforced below
    function TripleTerm(s::Union{IRI, BlankNode}, p::IRI, o)
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

"""    SubjectTerm\nUnion type for valid RDF subject positions: `IRI` or `BlankNode`."""
const SubjectTerm   = Union{IRI, BlankNode}

"""    PredicateTerm\nAlias for `IRI`; only IRIs are valid in the predicate position."""
const PredicateTerm = IRI

"""    ObjectTerm\nUnion type for valid RDF object positions: `IRI`, `BlankNode`, `Literal`, or `TripleTerm`."""
const ObjectTerm    = Union{IRI, BlankNode, Literal, TripleTerm}

"""    GraphName\nUnion type for RDF graph names: `IRI` or `BlankNode`."""
const GraphName     = Union{IRI, BlankNode}
