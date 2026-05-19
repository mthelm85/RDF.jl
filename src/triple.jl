struct Triple
    subject::SubjectTerm
    predicate::IRI
    object::ObjectTerm
end

struct Quad
    subject::SubjectTerm
    predicate::IRI
    object::ObjectTerm
    graph::Union{GraphName, Nothing}
end

struct GeneralizedTriple
    subject::RDFTerm
    predicate::RDFTerm
    object::RDFTerm
end

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
Quad(t::Triple, graph::Union{GraphName, Nothing}=nothing) =
    Quad(t.subject, t.predicate, t.object, graph)
