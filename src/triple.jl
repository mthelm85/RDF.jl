"""
    Triple(subject, predicate, object)

An RDF triple. `subject` must be a `SubjectTerm` (`IRI` or `BlankNode`),
`predicate` must be an `IRI`, and `object` may be any `ObjectTerm`.

```julia
ex = Namespace("http://example.org/")
Triple(ex.alice, rdf.type, ex.Person)
Triple(ex.alice, ex.age, Literal(30))
```
"""
struct Triple
    subject::SubjectTerm
    predicate::IRI
    object::ObjectTerm
end

"""
    Quad(subject, predicate, object, graph)
    Quad(triple; graph=nothing)
    Quad(triple, graph)

An RDF quad (triple plus a named graph). `graph` is a `GraphName` (`IRI` or
`BlankNode`) or `nothing` for the default graph.
"""
struct Quad
    subject::SubjectTerm
    predicate::IRI
    object::ObjectTerm
    graph::Union{GraphName, Nothing}
end

"""
    GeneralizedTriple(subject, predicate, object)

A generalized RDF triple where any position may hold any `RDFTerm`, including
literals in subject/predicate position. Used for non-standard graph formats.
"""
struct GeneralizedTriple
    subject::RDFTerm
    predicate::RDFTerm
    object::RDFTerm
end

"""
    TriplePattern(; subject=nothing, predicate=nothing, object=nothing)

A triple pattern for use with [`match`](@ref). `nothing` in any position acts
as a wildcard that matches any term.
"""
struct TriplePattern
    subject::Union{SubjectTerm, Nothing}
    predicate::Union{IRI, Nothing}
    object::Union{ObjectTerm, Nothing}
end

TriplePattern(; subject=nothing, predicate=nothing, object=nothing) =
    TriplePattern(subject, predicate, object)

Base.:(==)(a::Triple, b::Triple) =
    a.subject == b.subject && a.predicate == b.predicate && a.object == b.object
Base.hash(a::Triple, h::UInt) =
    hash(a.object, hash(a.predicate, hash(a.subject, hash(:Triple, h))))

Base.:(==)(a::Quad, b::Quad) =
    a.subject == b.subject && a.predicate == b.predicate &&
    a.object == b.object && a.graph == b.graph
Base.hash(a::Quad, h::UInt) =
    hash(a.graph, hash(a.object, hash(a.predicate, hash(a.subject, hash(:Quad, h)))))

# Convenience: convert Triple to Quad in default graph
Triple(q::Quad) = Triple(q.subject, q.predicate, q.object)
Quad(t::Triple, graph::Union{GraphName, Nothing}) =
    Quad(t.subject, t.predicate, t.object, graph)
Quad(t::Triple; graph::Union{GraphName, Nothing}=nothing) =
    Quad(t.subject, t.predicate, t.object, graph)
