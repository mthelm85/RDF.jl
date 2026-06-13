# ── Subgraph extraction + LLM context rendering ────────────────────────────────
#
# The GraphRAG primitives: pull a focused subgraph out of a large knowledge
# graph (cbd, ego_graph) and render it as compact, token-budgeted text for an
# LLM context window (to_context).

"""
    cbd(g, node; include_annotations=true) -> Graph

The **Concise Bounded Description** of `node`: every triple whose subject is
`node`, plus — recursively — the CBD of every blank node that appears in
object position of an included triple.  This is the standard "everything this
graph says about X" subgraph.

When `include_annotations=true` (the default), the RDF 1.2 annotations of
every included triple (its reifiers and their properties — confidence scores,
provenance, …) are included as well, so extraction metadata travels with the
facts.

```julia
profile = cbd(g, ex.alice)
println(to_context(profile))
```

See also [`ego_graph`](@ref), [`to_context`](@ref).
"""
function cbd(g::Graph, node::RDFTerm; include_annotations::Bool=true)::Graph
    out  = Graph()
    node isa SubjectTerm || return out
    seen      = Set{SubjectTerm}()
    queue     = SubjectTerm[node]
    collected = Triple[]
    while !isempty(queue)
        n = pop!(queue)
        n in seen && continue
        push!(seen, n)
        for t in match(g; subject=n)
            push!(out, t)
            push!(collected, t)
            o = t.object
            o isa BlankNode && !(o in seen) && push!(queue, o)
        end
    end
    if include_annotations
        for t in collected
            tt = TripleTerm(t.subject, t.predicate, t.object)
            for rt in match(g; predicate=rdf.reifies, object=tt)
                push!(out, rt)
                for at in match(g; subject=rt.subject)
                    push!(out, at)
                end
            end
        end
    end
    out
end

"""
    ego_graph(g, seeds; hops=1, through_types=false) -> Graph

The `hops`-hop neighbourhood subgraph around `seeds` (a single term or a
collection): all triples incident — as subject *or* object — to the seed
nodes, expanded hop by hop through IRI and blank-node neighbours.  Literals
and predicates are never expanded through.

Class nodes reached as the object of `rdf:type` are included but **not**
expanded through by default — classes are schema-level hubs, and expanding
through them would pull in every co-typed instance in the graph.  Pass
`through_types=true` to expand through them anyway.

This is the standard retrieval step in GraphRAG pipelines: resolve a user
query to seed entities, expand, then render with [`to_context`](@ref):

```julia
sub = ego_graph(g, [ex.julia, ex.bezanson]; hops=2)
prompt_context = to_context(sub; budget=2000)
```
"""
function ego_graph(g::Graph, seeds; hops::Int=1, through_types::Bool=false)::Graph
    out      = Graph()
    seedvec  = seeds isa RDFTerm ? RDFTerm[seeds] : collect(RDFTerm, seeds)
    frontier = Set{RDFTerm}(seedvec)
    visited  = Set{RDFTerm}()
    for _ in 1:hops
        isempty(frontier) && break
        next = Set{RDFTerm}()
        for n in frontier
            n in visited && continue
            push!(visited, n)
            # Outgoing edges (n in subject position)
            if n isa SubjectTerm
                for t in match(g; subject=n)
                    push!(out, t)
                    o = t.object
                    if (o isa IRI || o isa BlankNode) && !(o in visited)
                        (through_types || t.predicate != rdf.type) && push!(next, o)
                    end
                end
            end
            # Incoming edges (n in object position)
            if n isa ObjectTerm
                for t in match(g; object=n)
                    push!(out, t)
                    s = t.subject
                    (s isa IRI || s isa BlankNode) && !(s in visited) && push!(next, s)
                end
            end
        end
        frontier = next
    end
    out
end

# Render a set of triples as Turtle text with the given prefixes.
function _ctx_render(triples::Vector{Triple},
                     prefixes::Dict{String,String})::String
    sub = Graph()
    for t in triples
        push!(sub, t)
    end
    buf = IOBuffer()
    write(buf, MIME"text/turtle"(), sub; prefixes=prefixes)
    String(take!(buf))
end

"""
    to_context(g; budget=nothing, prefixes=Dict()) -> String

Render `g` as compact, subject-grouped Turtle text suitable for an LLM context
window.

`budget` is an approximate **token** budget (estimated at 4 UTF-8 bytes per
token).  When set, whole subject blocks are included greedily — most-connected
subjects first, where a subject's score is its number of outgoing triples plus
the number of triples that reference it — and the rendered output is
guaranteed not to exceed `4 × budget` bytes.  Without a budget the entire
graph is rendered.

`prefixes` (`Dict{String,String}` of prefix → IRI base) substantially compacts
the output and is strongly recommended for token efficiency:

```julia
ctx = to_context(sub; budget=2000,
                 prefixes=Dict("ex" => "http://example.org/",
                               "foaf" => "http://xmlns.com/foaf/0.1/"))
prompt = "Answer using only this knowledge:\\n\$ctx\\n\\nQuestion: …"
```

See also [`cbd`](@ref), [`ego_graph`](@ref).
"""
function to_context(g::Graph;
                    budget::Union{Int, Nothing}=nothing,
                    prefixes::Dict{String,String}=Dict{String,String}())::String
    isempty(g) && return ""

    if budget === nothing
        buf = IOBuffer()
        write(buf, MIME"text/turtle"(), g; prefixes=prefixes)
        return String(take!(buf))
    end
    char_budget = 4 * budget

    # Group triples by subject (contiguous in SPO order) and score each block:
    # out-degree + in-degree of the subject node.
    subjects = SubjectTerm[]
    blocks   = Vector{Triple}[]
    prev_sid = UInt32(0)
    for (s_id, p_id, o_id) in eachid(g)
        if s_id != prev_sid
            push!(subjects, resolve_term(s_id)::SubjectTerm)
            push!(blocks, Triple[])
            prev_sid = s_id
        end
        push!(blocks[end], Triple(resolve_term(s_id)::SubjectTerm,
                                  resolve_term(p_id)::IRI,
                                  resolve_term(o_id)::ObjectTerm))
    end
    scores = [length(blocks[i]) +
              _count_ids(g, nothing, nothing, term_id(subjects[i]))
              for i in eachindex(subjects)]

    # Most-connected subjects first; stable on ties (original SPO order).
    order = sort(eachindex(subjects); by=i -> (-scores[i], i))

    # Greedy: add whole blocks while the rendered output stays within budget.
    selected = Triple[]
    best     = ""
    for i in order
        candidate = vcat(selected, blocks[i])
        text = _ctx_render(candidate, prefixes)
        if ncodeunits(text) <= char_budget
            selected = candidate
            best     = text
        end
    end
    best
end
