"""
    Graph()
    Graph(f::Function)

An RDF graph backed by a hexastore index for O(log n) pattern matching on any
combination of subject, predicate, and object.

Supports `push!`, `delete!`, `in`, `length`, `iterate`, `union`, `intersect`,
`setdiff`, and `merge!`. The do-block form yields the graph to `f` and returns it:

```julia
g = Graph() do g
    push!(g, Triple(ex.alice, rdf.type, ex.Person))
    push!(g, Triple(ex.alice, ex.name, Literal("Alice")))
end
```
"""
mutable struct Graph
    store::HexaStore
    blank_nodes::Set{UInt64}  # IDs of blank nodes owned by this graph
    _size::Int
end

Graph() = Graph(HexaStore(), Set{UInt64}(), 0)

function Graph(f::Function)
    g = Graph()
    f(g)
    g
end

# ── Mutation ──────────────────────────────────────────────────────────────────

Base.append!(g::Graph, ts) = (foreach(t -> push!(g, t), ts); g)

function Base.push!(g::Graph, t::Triple)
    s_id = _intern!(t.subject)
    p_id = _intern!(t.predicate)
    o_id = _intern!(t.object)
    if t.subject isa BlankNode
        push!(g.blank_nodes, t.subject.id)
    end
    if t.object isa BlankNode
        push!(g.blank_nodes, (t.object::BlankNode).id)
    end
    if _hexa_insert!(g.store, s_id, p_id, o_id)
        g._size += 1
    end
    g
end

function Base.delete!(g::Graph, t::Triple)
    s_id = get(_type_map(t.subject),    t.subject,    UInt32(0))
    p_id = get(_type_map(t.predicate),  t.predicate,  UInt32(0))
    o_id = get(_type_map(t.object),     t.object,     UInt32(0))
    (s_id == 0 || p_id == 0 || o_id == 0) && return g
    if _hexa_delete!(g.store, s_id, p_id, o_id)
        g._size -= 1
    end
    g
end

# ── Set interface ─────────────────────────────────────────────────────────────

Base.length(g::Graph) = g._size
Base.isempty(g::Graph) = g._size == 0

function Base.in(t::Triple, g::Graph)
    s_id = get(_type_map(t.subject),   t.subject,   UInt32(0))
    p_id = get(_type_map(t.predicate), t.predicate, UInt32(0))
    o_id = get(_type_map(t.object),    t.object,    UInt32(0))
    (s_id == 0 || p_id == 0 || o_id == 0) && return false
    lo, hi = _range_bounds(s_id, p_id, o_id)
    idx = searchsortedfirst(g.store.spo, lo)
    idx <= length(g.store.spo) && g.store.spo[idx] == (s_id, p_id, o_id)
end

function Base.iterate(g::Graph, state=1)
    state > length(g.store.spo) && return nothing
    tup = g.store.spo[state]
    s = _resolve(tup[1])::SubjectTerm
    p = _resolve(tup[2])::IRI
    o = _resolve(tup[3])
    Triple(s, p, o), state + 1
end

# ── Set operations ────────────────────────────────────────────────────────────

function Base.union(g1::Graph, g2::Graph)
    result = Graph()
    for t in g1; push!(result, t); end
    for t in _rename_blanks(g2, result.blank_nodes)
        push!(result, t)
    end
    result
end

function Base.intersect(g1::Graph, g2::Graph)
    result = Graph()
    for t in g1
        t in g2 && push!(result, t)
    end
    result
end

function Base.setdiff(g1::Graph, g2::Graph)
    result = Graph()
    for t in g1
        t ∉ g2 && push!(result, t)
    end
    result
end

"""
    merge!(g1::Graph, g2::Graph) -> g1

Merge all triples from `g2` into `g1` in-place. Blank nodes from `g2` that
collide with blank nodes already in `g1` are renamed to fresh identifiers.
"""
function merge!(g1::Graph, g2::Graph)
    for t in _rename_blanks(g2, g1.blank_nodes)
        push!(g1, t)
    end
    g1
end

const ∪ = Base.union
const ∩ = Base.intersect

# ── Blank node renaming for merge ─────────────────────────────────────────────

function _rename_blanks(g::Graph, existing_ids::Set{UInt64})
    collisions = intersect(g.blank_nodes, existing_ids)
    isempty(collisions) && return g
    mapping = Dict{UInt64, BlankNode}(id => _mint_blank_node() for id in collisions)
    result = Graph()
    for t in g
        push!(result, _remap_triple(t, mapping))
    end
    result
end

function _remap_triple(t::Triple, m::Dict{UInt64, BlankNode})
    s = t.subject isa BlankNode ? get(m, (t.subject::BlankNode).id, t.subject) : t.subject
    o = t.object  isa BlankNode ? get(m, (t.object::BlankNode).id,  t.object)  : t.object
    Triple(s, t.predicate, o)
end

# ── Subgraph and isomorphism ──────────────────────────────────────────────────

"""
    issubgraph(g1::Graph, g2::Graph) -> Bool

Return `true` if every triple in `g1` also appears in `g2`.
"""
function issubgraph(g1::Graph, g2::Graph)
    for t in g1
        t ∉ g2 && return false
    end
    true
end

"""
    isomorphic(g1::Graph, g2::Graph) -> Bool
    isomorphic(ds1::Dataset, ds2::Dataset) -> Bool
    g1 ≅ g2

Return `true` if `g1` and `g2` are RDF-isomorphic: there exists a bijection on
blank node identifiers such that mapping `g1`'s blank nodes produces exactly the
same set of triples as `g2`.
"""
function isomorphic(g1::Graph, g2::Graph)
    length(g1) != length(g2) && return false
    # Collect ground triples (no blank nodes) and blank-containing triples
    ground1, bnode1 = _split_ground(g1)
    ground2, bnode2 = _split_ground(g2)
    ground1 != ground2 && return false
    length(bnode1) != length(bnode2) && return false
    isempty(bnode1) && return true
    _isomorphic_bnode_search(bnode1, bnode2)
end

function _split_ground(g::Graph)
    ground = Set{Triple}()
    bnode  = Triple[]
    for t in g
        if t.subject isa BlankNode || t.object isa BlankNode
            push!(bnode, t)
        else
            push!(ground, t)
        end
    end
    ground, bnode
end

function _isomorphic_bnode_search(ts1::Vector{Triple}, ts2::Vector{Triple})
    # Collect all blank node IDs from ts1 and ts2
    ids1 = Set{UInt64}(b.id for t in ts1 for b in _blanks_in(t))
    ids2 = Set{UInt64}(b.id for t in ts2 for b in _blanks_in(t))
    length(ids1) != length(ids2) && return false
    _try_bijection(collect(ids1), collect(ids2), ts1, ts2, Dict{UInt64,UInt64}())
end

function _blanks_in(t::Triple)
    result = BlankNode[]
    t.subject isa BlankNode && push!(result, t.subject::BlankNode)
    t.object  isa BlankNode && push!(result, t.object::BlankNode)
    result
end

function _try_bijection(ids1, ids2, ts1, ts2, mapping::Dict{UInt64,UInt64})
    isempty(ids1) && return _check_mapping(ts1, ts2, mapping)
    id1 = ids1[1]
    rest1 = ids1[2:end]
    for id2 in ids2
        hasvalue(mapping, id2) && continue
        mapping[id1] = id2
        new_ids2 = filter(!=(id2), ids2)
        _try_bijection(rest1, new_ids2, ts1, ts2, mapping) && return true
        delete!(mapping, id1)
    end
    false
end

hasvalue(d::Dict, v) = v in values(d)

function _check_mapping(ts1, ts2, mapping::Dict{UInt64,UInt64})
    mapped = Set{Triple}()
    for t in ts1
        s = t.subject isa BlankNode ? BlankNode(mapping[(t.subject::BlankNode).id]) : t.subject
        o = t.object  isa BlankNode ? BlankNode(mapping[(t.object::BlankNode).id])  : t.object
        push!(mapped, Triple(s, t.predicate, o))
    end
    mapped == Set{Triple}(ts2)
end

# ── Skolemization ─────────────────────────────────────────────────────────────

"""
    skolemize(g::Graph; base::String) -> Graph

Return a new graph with all blank nodes replaced by IRIs of the form
`base * string(id)`. The `base` string should end with `/` or `#`.

```julia
skolemize(g; base="http://example.org/.well-known/genid/")
```
"""
function skolemize(g::Graph; base::String)
    result = Graph()
    mapping = Dict{UInt64, IRI}()
    for t in g
        push!(result, _skolem_triple(t, base, mapping))
    end
    result
end

function _skolem_triple(t::Triple, base::String, m::Dict{UInt64,IRI})
    s = _skolem_term(t.subject, base, m)
    o = _skolem_term(t.object,  base, m)
    Triple(s, t.predicate, o)
end

function _skolem_term(term, base::String, m::Dict{UInt64,IRI})
    term isa BlankNode || return term
    get!(m, term.id) do
        IRI(base * string(term.id))
    end
end

"""
    deskolemize(g::Graph; base::String) -> Graph

Reverse of [`skolemize`](@ref): replace IRIs whose value starts with `base`
with fresh blank nodes.
"""
function deskolemize(g::Graph; base::String)
    result = Graph()
    for t in g
        push!(result, _deskolem_triple(t, base))
    end
    result
end

function _deskolem_triple(t::Triple, base::String)
    s = _deskolem_term(t.subject, base)
    o = _deskolem_term(t.object, base)
    Triple(s, t.predicate, o)
end

function _deskolem_term(term, base::String)
    term isa IRI && startswith(term.value, base) || return term
    suffix = term.value[length(base)+1:end]
    id = tryparse(UInt64, suffix)
    id === nothing ? term : BlankNode(id)
end

# ── Blank node minting ────────────────────────────────────────────────────────

"""
    blank!(g::Graph) -> BlankNode
    blank!(g::Graph, n::Int) -> Vector{BlankNode}

Mint one or more fresh blank nodes registered to graph `g`.
"""
function blank!(g::Graph)::BlankNode
    bn = _mint_blank_node()
    push!(g.blank_nodes, bn.id)
    bn
end

function blank!(g::Graph, n::Int)::Vector{BlankNode}
    [blank!(g) for _ in 1:n]
end

"""
    blank_nodes(g::Graph) -> Set{BlankNode}

Return the set of blank nodes owned by `g`.
"""
blank_nodes(g::Graph) = Set{BlankNode}(BlankNode(id) for id in g.blank_nodes)

# Operator aliases
Base.:(==)(g1::Graph, g2::Graph) = length(g1) == length(g2) && issubgraph(g1, g2)
Base.:(⊆)(g1::Graph, g2::Graph) = issubgraph(g1, g2)
Base.:\(g1::Graph, g2::Graph) = setdiff(g1, g2)
≅(g1::Graph, g2::Graph) = isomorphic(g1, g2)
