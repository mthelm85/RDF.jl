# ── RDF-star annotation ergonomics ─────────────────────────────────────────────
#
# Convenience layer for attaching metadata to individual triples — confidence
# scores, provenance, timestamps — using the standard RDF 1.2 reification
# pattern, which serializes to every RDF 1.2 format and round-trips losslessly:
#
#     :s :p :o .                          (the asserted triple)
#     _:r rdf:reifies <<( :s :p :o )>> .  (a reifier for that triple)
#     _:r :confidence 0.87 .              (annotations hang off the reifier)
#
# This is the primary mechanism for storing LLM-extracted knowledge with its
# extraction metadata.

"""
    anno

The RDF.jl annotation namespace
(`https://mthelm85.github.io/RDF.jl/vocab/annotation#`).  Keyword arguments to
[`annotate!`](@ref) become predicates in this namespace: `confidence=0.9`
attaches `anno.confidence`, `source=doc` attaches `anno.source`, and so on.
Use it directly to query annotations back: `annotations(g, t, anno.confidence)`.
"""
const anno = Namespace("https://mthelm85.github.io/RDF.jl/vocab/annotation#")

# Convert an annotation value to an object term: RDFTerms pass through,
# anything else goes through the Literal constructors (Int, Float64, Bool,
# String, Date, DateTime, …).
_anno_object(x::RDFTerm)::ObjectTerm = x
_anno_object(x)::ObjectTerm = Literal(x)

# First existing reifier of `tt` in SPO order, or nothing.
function _find_reifier(g::Graph, tt::TripleTerm)::Union{SubjectTerm, Nothing}
    for t in match(g; predicate=rdf.reifies, object=tt)
        return t.subject
    end
    nothing
end

"""
    annotate!(g, t::Triple, pred::IRI, obj) -> reifier
    annotate!(g, t::Triple; kwargs...)      -> reifier

Assert triple `t` in `g` (if not already present) and attach an annotation to
it using the RDF 1.2 reification pattern.  Returns the reifier node so further
metadata can be attached to it directly.

Non-`RDFTerm` annotation values are converted with `Literal()`; pass an `IRI`
explicitly to link to a resource.  Repeated calls on the same triple reuse the
same reifier, so all annotations describe one statement occurrence.

In the keyword form, each keyword `k` becomes the predicate `anno.k` in the
exported [`anno`](@ref) namespace:

```julia
# Store an LLM-extracted fact with its extraction metadata
t = Triple(ex.alice, foaf.knows, ex.bob)
annotate!(g, t; confidence=0.92, source=ex.doc7, model=Literal("claude-fable-5"))

# Read it back, filter by confidence
for v in annotations(g, t, anno.confidence)
    value(Float64, v) > 0.9 && println("high-confidence fact")
end
```

See also [`annotations`](@ref).
"""
function annotate!(g::Graph, t::Triple, pred::IRI, obj)
    push!(g, t)
    tt = TripleTerm(t.subject, t.predicate, t.object)
    r  = _find_reifier(g, tt)
    if r === nothing
        r = blank!(g)
        push!(g, Triple(r, rdf.reifies, tt))
    end
    push!(g, Triple(r, pred, _anno_object(obj)))
    r
end

function annotate!(g::Graph, t::Triple; kwargs...)
    isempty(kwargs) &&
        throw(ArgumentError("annotate! requires at least one annotation " *
                            "(keyword or positional pred/obj)"))
    local r
    for (k, v) in kwargs
        r = annotate!(g, t, anno[string(k)], v)
    end
    r
end

"""
    annotations(g, t::Triple)            -> Vector{Pair{IRI, ObjectTerm}}
    annotations(g, t::Triple, pred::IRI) -> Vector{ObjectTerm}

Retrieve the RDF 1.2 annotations attached to triple `t` (across **all** of its
reifiers), as `predicate => object` pairs — or just the values for a single
annotation predicate in the three-argument form.  The `rdf:reifies` link
itself is not reported.  Returns an empty vector when `t` has no annotations.

```julia
annotations(g, t)                   # [anno.confidence => Literal(0.92), …]
annotations(g, t, anno.confidence)  # [Literal(0.92)]
```
"""
function annotations(g::Graph, t::Triple)::Vector{Pair{IRI, ObjectTerm}}
    tt  = TripleTerm(t.subject, t.predicate, t.object)
    out = Pair{IRI, ObjectTerm}[]
    for rt in match(g; predicate=rdf.reifies, object=tt)
        for at in match(g; subject=rt.subject)
            at.predicate == rdf.reifies && continue
            push!(out, at.predicate => at.object)
        end
    end
    out
end

annotations(g::Graph, t::Triple, pred::IRI)::Vector{ObjectTerm} =
    ObjectTerm[o for (p, o) in annotations(g, t) if p == pred]
