# Global term registry — shared across all graphs/datasets.
# Maps every distinct RDFTerm to a UInt32 ID and back.
const _TERM_TO_ID = Dict{RDFTerm, UInt32}()
const _ID_TO_TERM = RDFTerm[]
const _REGISTRY_LOCK = ReentrantLock()

function _intern!(term::RDFTerm)::UInt32
    # Fast path — no lock
    id = get(_TERM_TO_ID, term, UInt32(0))
    id != 0 && return id
    # Slow path — acquire lock and insert
    lock(_REGISTRY_LOCK) do
        id2 = get(_TERM_TO_ID, term, UInt32(0))
        id2 != 0 && return id2
        new_id = UInt32(length(_ID_TO_TERM) + 1)
        push!(_ID_TO_TERM, term)
        _TERM_TO_ID[term] = new_id
        new_id
    end
end

@inline _resolve(id::UInt32)::RDFTerm = @inbounds _ID_TO_TERM[id]

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
