# Global term registry — shared across all graphs/datasets.
# Split into three concrete-type tables to eliminate abstract dispatch in hash/isequal.

const _IRI_TO_ID          = RobinDict{IRI,         UInt32}()
const _BNODE_TO_ID        = RobinDict{BlankNode,    UInt32}()
const _LITERAL_TO_ID      = RobinDict{Literal,      UInt32}()
const _TRIPLE_TERM_TO_ID  = RobinDict{TripleTerm,   UInt32}()
const _ID_TO_TERM    = RDFTerm[]
const _NUMERIC_CACHE = Float64[]   # NaN for non-numeric/un-cacheable terms; indexed by term ID
const _REGISTRY_LOCK = ReentrantLock()

# Return the per-type map for dispatch without abstract keys
@inline _type_map(::IRI)        = _IRI_TO_ID
@inline _type_map(::BlankNode)  = _BNODE_TO_ID
@inline _type_map(::Literal)    = _LITERAL_TO_ID
@inline _type_map(::TripleTerm) = _TRIPLE_TERM_TO_ID

# Numeric XSD datatypes for the cache
const _NUMERIC_DTS = Set{String}((
    "http://www.w3.org/2001/XMLSchema#integer",
    "http://www.w3.org/2001/XMLSchema#decimal",
    "http://www.w3.org/2001/XMLSchema#double",
    "http://www.w3.org/2001/XMLSchema#float",
    "http://www.w3.org/2001/XMLSchema#int",
    "http://www.w3.org/2001/XMLSchema#long",
    "http://www.w3.org/2001/XMLSchema#short",
    "http://www.w3.org/2001/XMLSchema#byte",
    "http://www.w3.org/2001/XMLSchema#unsignedInt",
    "http://www.w3.org/2001/XMLSchema#unsignedLong",
    "http://www.w3.org/2001/XMLSchema#unsignedShort",
    "http://www.w3.org/2001/XMLSchema#unsignedByte",
    "http://www.w3.org/2001/XMLSchema#positiveInteger",
    "http://www.w3.org/2001/XMLSchema#negativeInteger",
    "http://www.w3.org/2001/XMLSchema#nonPositiveInteger",
    "http://www.w3.org/2001/XMLSchema#nonNegativeInteger",
))

# Compute the Float64 value for a just-interned term (NaN if not numeric)
function _compute_numeric(term::RDFTerm)::Float64
    term isa Literal || return NaN
    dt = term.datatype.value
    dt in _NUMERIC_DTS || return NaN
    s = term.lexical_form
    s in ("INF", "+INF") && return Inf
    s == "-INF"           && return -Inf
    s == "NaN"            && return NaN
    r = Parsers.tryparse(Float64, s)
    r === nothing ? NaN : r
end

function _intern!(term::RDFTerm)::UInt32
    # Always acquire the lock: RobinDict is not safe for concurrent reads
    # during a write (Robin Hood hashing moves existing entries on insert,
    # so a lockless read can return a false miss or corrupt probe sequence).
    # ReentrantLock is uncontested in the single-threaded case (~5 ns overhead).
    lock(_REGISTRY_LOCK) do
        tmap = _type_map(term)
        id = get(tmap, term, UInt32(0))
        id != 0 && return id
        new_id = UInt32(length(_ID_TO_TERM) + 1)
        push!(_ID_TO_TERM, term)
        push!(_NUMERIC_CACHE, _compute_numeric(term))
        tmap[term] = new_id
        new_id
    end
end

@inline _resolve(id::UInt32)::RDFTerm = @inbounds _ID_TO_TERM[id]

# Fast numeric value lookup by term ID — NaN if term is not a numeric literal
@inline _numeric_float(id::UInt32)::Float64 = @inbounds _NUMERIC_CACHE[id]

# ── Hexastore ─────────────────────────────────────────────────────────────────

# Each Graph owns six sorted Vector{NTuple{3,UInt32}} arrays.
struct HexaStore
    spo::Vector{NTuple{3,UInt32}}
    sop::Vector{NTuple{3,UInt32}}
    pso::Vector{NTuple{3,UInt32}}
    pos::Vector{NTuple{3,UInt32}}
    osp::Vector{NTuple{3,UInt32}}
    ops::Vector{NTuple{3,UInt32}}
end

HexaStore() = HexaStore(
    NTuple{3,UInt32}[], NTuple{3,UInt32}[],
    NTuple{3,UInt32}[], NTuple{3,UInt32}[],
    NTuple{3,UInt32}[], NTuple{3,UInt32}[],
)

function _hexa_insert!(h::HexaStore, s::UInt32, p::UInt32, o::UInt32)::Bool
    tup = (s, p, o)
    idx = searchsortedfirst(h.spo, tup)
    idx <= length(h.spo) && h.spo[idx] == tup && return false  # duplicate
    insert!(h.spo, idx, tup)
    _sorted_insert!(h.sop, (s, o, p))
    _sorted_insert!(h.pso, (p, s, o))
    _sorted_insert!(h.pos, (p, o, s))
    _sorted_insert!(h.osp, (o, s, p))
    _sorted_insert!(h.ops, (o, p, s))
    true
end

function _hexa_delete!(h::HexaStore, s::UInt32, p::UInt32, o::UInt32)::Bool
    idx = searchsortedfirst(h.spo, (s, p, o))
    (idx > length(h.spo) || h.spo[idx] != (s, p, o)) && return false
    deleteat!(h.spo, idx)
    _sorted_delete!(h.sop, (s, o, p))
    _sorted_delete!(h.pso, (p, s, o))
    _sorted_delete!(h.pos, (p, o, s))
    _sorted_delete!(h.osp, (o, s, p))
    _sorted_delete!(h.ops, (o, p, s))
    true
end

function _sorted_insert!(v::Vector{NTuple{3,UInt32}}, t::NTuple{3,UInt32})
    insert!(v, searchsortedfirst(v, t), t)
end

function _sorted_delete!(v::Vector{NTuple{3,UInt32}}, t::NTuple{3,UInt32})
    idx = searchsortedfirst(v, t)
    if idx <= length(v) && v[idx] == t
        deleteat!(v, idx)
    end
end

# ── Index-selection for pattern matching ──────────────────────────────────────
#
# Select the index whose leading positions are all bound, yielding the most
# selective prefix scan.  Returns (index_vector, a, b, c) where (a,b,c) are
# the permuted IDs (Nothing for unbound positions).

function _select_index(h::HexaStore, s, p, o)
    bs = s !== nothing
    bp = p !== nothing
    bo = o !== nothing
    if bs && bp && bo
        # SPO — full lookup in spo
        return (h.spo, UInt32(s), UInt32(p), UInt32(o), :spo)
    elseif bs && bp
        return (h.spo, UInt32(s), UInt32(p), nothing, :spo)
    elseif bs && bo
        return (h.sop, UInt32(s), UInt32(o), nothing, :sop)
    elseif bp && bo
        return (h.pos, UInt32(p), UInt32(o), nothing, :pos)
    elseif bs
        return (h.spo, UInt32(s), nothing, nothing, :spo)
    elseif bp
        return (h.pso, UInt32(p), nothing, nothing, :pso)
    elseif bo
        return (h.osp, UInt32(o), nothing, nothing, :osp)
    else
        return (h.spo, nothing, nothing, nothing, :spo)
    end
end

# Lower/upper bound tuples for range search in a permuted index
function _range_bounds(a, b, c)
    lo_a = a !== nothing ? a : UInt32(0)
    lo_b = b !== nothing ? b : UInt32(0)
    lo_c = c !== nothing ? c : UInt32(0)
    hi_a = a !== nothing ? a : typemax(UInt32)
    hi_b = b !== nothing ? b : typemax(UInt32)
    hi_c = c !== nothing ? c : typemax(UInt32)
    (lo_a, lo_b, lo_c), (hi_a, hi_b, hi_c)
end
