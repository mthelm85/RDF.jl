module RDFTablesExt

using RDF
using Tables

# ── Tables.jl interface for match results ────────────────────────────────────
#
# Both _TripleMatchIterator and _DatasetMatchIterator expose a Tables.jl row
# interface so results can flow directly into DataFrames, CSV, etc.

# ── Triple match (Graph) ──────────────────────────────────────────────────────

Tables.istable(::Type{RDF._TripleMatchIterator}) = true
Tables.rowaccess(::Type{RDF._TripleMatchIterator}) = true
Tables.rows(it::RDF._TripleMatchIterator) = it
Tables.schema(::RDF._TripleMatchIterator) =
    Tables.Schema((:subject, :predicate, :object),
                  (RDF.SubjectTerm, RDF.IRI, RDF.ObjectTerm))

struct _TripleRow
    subject::RDF.SubjectTerm
    predicate::RDF.IRI
    object::RDF.ObjectTerm
end

Tables.columnnames(::_TripleRow) = (:subject, :predicate, :object)
Tables.getcolumn(r::_TripleRow, nm::Symbol) = getfield(r, nm)
Tables.getcolumn(r::_TripleRow, i::Int) = getfield(r, i)

function Base.iterate(it::RDF._TripleMatchIterator, state=nothing)
    r = state === nothing ? invoke(Base.iterate, Tuple{RDF._TripleMatchIterator}, it) :
                            invoke(Base.iterate, Tuple{RDF._TripleMatchIterator, Any}, it, state)
    r === nothing && return nothing
    t, ns = r
    (_TripleRow(t.subject, t.predicate, t.object), ns)
end

# ── Quad match (Dataset) ──────────────────────────────────────────────────────

Tables.istable(::Type{RDF._DatasetMatchIterator}) = true
Tables.rowaccess(::Type{RDF._DatasetMatchIterator}) = true
Tables.rows(it::RDF._DatasetMatchIterator) = it
Tables.schema(::RDF._DatasetMatchIterator) =
    Tables.Schema((:subject, :predicate, :object, :graph),
                  (RDF.SubjectTerm, RDF.IRI, RDF.ObjectTerm, Union{RDF.GraphName, Nothing}))

struct _QuadRow
    subject::RDF.SubjectTerm
    predicate::RDF.IRI
    object::RDF.ObjectTerm
    graph::Union{RDF.GraphName, Nothing}
end

Tables.columnnames(::_QuadRow) = (:subject, :predicate, :object, :graph)
Tables.getcolumn(r::_QuadRow, nm::Symbol) = getfield(r, nm)
Tables.getcolumn(r::_QuadRow, i::Int) = getfield(r, i)

function Base.iterate(it::RDF._DatasetMatchIterator, state=nothing)
    r = state === nothing ? invoke(Base.iterate, Tuple{RDF._DatasetMatchIterator}, it) :
                            invoke(Base.iterate, Tuple{RDF._DatasetMatchIterator, Any}, it, state)
    r === nothing && return nothing
    q, ns = r
    (_QuadRow(q.subject, q.predicate, q.object, q.graph), ns)
end

end # module RDFTablesExt
