# Global term registry — shared across all graphs/datasets.
# Split into three concrete-type tables to eliminate abstract dispatch in hash/isequal.

const _IRI_TO_ID          = RobinDict{IRI,         UInt32}()
const _BNODE_TO_ID        = RobinDict{BlankNode,    UInt32}()
const _LITERAL_TO_ID      = RobinDict{Literal,      UInt32}()
const _TRIPLE_TERM_TO_ID  = RobinDict{TripleTerm,   UInt32}()
const _ID_TO_TERM    = RDFTerm[]
const _NUMERIC_CACHE = Float64[]   # NaN for non-numeric/un-cacheable terms; indexed by term ID
# Pre-formatted N-Triples serialization for each interned term (indexed by term ID).
# Populated lazily by _ensure_nt_cache!() in ntriples.jl before any write operation.
# Enables the fast write path: write(io, _NT_TERM_STRINGS[id]) × 3 per triple with no
# _resolve(), no Triple allocation, and no formatting work on the hot path.
const _NT_TERM_STRINGS = String[]
# String-keyed IRI lookup table.  Mirrors _IRI_TO_ID but keyed by the raw IRI value
# string rather than the IRI struct.  A SubString can be looked up here without first
# allocating a String (Julia's Dict uses hash/isequal on content, and SubString and
# String with identical content are equal and share the same hash).  This lets the
# N-Triples / N-Quads parsers skip the String + IRI struct allocations entirely for
# any IRI that has already been interned (predicates, datatype IRIs, repeated objects).
const _IRI_STR_TO_ID = Dict{String, UInt32}()
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
    # Use lock/try/finally rather than lock(lk) do...end so no closure is heap-
    # allocated on every call.
    lock(_REGISTRY_LOCK)
    try
        tmap = _type_map(term)
        id = get(tmap, term, UInt32(0))
        id != 0 && return id
        new_id = UInt32(length(_ID_TO_TERM) + 1)
        push!(_ID_TO_TERM, term)
        push!(_NUMERIC_CACHE, _compute_numeric(term))
        tmap[term] = new_id
        return new_id
    finally
        unlock(_REGISTRY_LOCK)
    end
end

# Specialised intern for IRI: also populates _IRI_STR_TO_ID so the parser can
# do SubString dedup lookups without constructing a temporary IRI struct.
function _intern!(iri::IRI)::UInt32
    lock(_REGISTRY_LOCK)
    try
        # String-keyed fast path: same lookup the parser uses.
        id = get(_IRI_STR_TO_ID, iri.value, UInt32(0))
        id != 0 && return id
        # Fallback to the RobinDict (handles IRIs interned before this method
        # existed, e.g. during vocabulary module init).
        id = get(_IRI_TO_ID, iri, UInt32(0))
        if id != 0
            _IRI_STR_TO_ID[iri.value] = id   # backfill for future parser dedup
            return id
        end
        # New IRI — register in both tables.
        new_id = UInt32(length(_ID_TO_TERM) + 1)
        push!(_ID_TO_TERM, iri)
        push!(_NUMERIC_CACHE, NaN)            # IRIs are never numeric literals
        _IRI_TO_ID[iri]           = new_id
        _IRI_STR_TO_ID[iri.value] = new_id
        return new_id
    finally
        unlock(_REGISTRY_LOCK)
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

# ── Bulk insertion ────────────────────────────────────────────────────────────
#
# Insert many (s,p,o) ID tuples at once via a single sort-and-merge pass.
# O(n log n) overall rather than O(n²) for repeated _hexa_insert! calls.
#
# The `tuples` vector may be mutated (sorted/deduplicated in the fast path
# for an empty store).  Returns the number of net new triples added.

function _hexa_bulk_insert!(h::HexaStore, tuples::Vector{NTuple{3,UInt32}})
    isempty(tuples) && return 0

    # Build the complete deduplicated SPO set.
    # Fast path: empty store — sort and dedup in place, no extra allocation.
    spo_all = if isempty(h.spo)
        sort!(unique!(tuples))
    else
        combined = vcat(h.spo, tuples)
        sort!(unique!(combined))
    end

    n     = length(spo_all)
    added = n - length(h.spo)   # computed before we overwrite h.spo

    # SPO — already in the correct order
    resize!(h.spo, n)
    copyto!(h.spo, spo_all)

    # Reuse one temporary buffer for all five remaining permutations
    tmp = Vector{NTuple{3,UInt32}}(undef, n)

    # SOP (1,3,2)
    @inbounds for i in 1:n; t = spo_all[i]; tmp[i] = (t[1], t[3], t[2]); end
    sort!(tmp); resize!(h.sop, n); copyto!(h.sop, tmp)

    # PSO (2,1,3)
    @inbounds for i in 1:n; t = spo_all[i]; tmp[i] = (t[2], t[1], t[3]); end
    sort!(tmp); resize!(h.pso, n); copyto!(h.pso, tmp)

    # POS (2,3,1)
    @inbounds for i in 1:n; t = spo_all[i]; tmp[i] = (t[2], t[3], t[1]); end
    sort!(tmp); resize!(h.pos, n); copyto!(h.pos, tmp)

    # OSP (3,1,2)
    @inbounds for i in 1:n; t = spo_all[i]; tmp[i] = (t[3], t[1], t[2]); end
    sort!(tmp); resize!(h.osp, n); copyto!(h.osp, tmp)

    # OPS (3,2,1)
    @inbounds for i in 1:n; t = spo_all[i]; tmp[i] = (t[3], t[2], t[1]); end
    sort!(tmp); resize!(h.ops, n); copyto!(h.ops, tmp)

    added
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
