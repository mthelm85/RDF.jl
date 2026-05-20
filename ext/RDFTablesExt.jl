module RDFTablesExt

using RDF
using Tables

# ── Tables.jl interface for match results ────────────────────────────────────
#
# We use wrapper types to avoid overriding Base.iterate on the match iterators,
# which would cause infinite recursion via invoke.

# ── Triple row ────────────────────────────────────────────────────────────────

struct _TripleRow
    subject::RDF.SubjectTerm
    predicate::RDF.IRI
    object::RDF.ObjectTerm
end

Tables.columnnames(::_TripleRow) = (:subject, :predicate, :object)
Tables.getcolumn(r::_TripleRow, nm::Symbol) = getfield(r, nm)
Tables.getcolumn(r::_TripleRow, i::Int) = getfield(r, i)

# ── Triple table wrapper ──────────────────────────────────────────────────────

struct _TripleTableIter
    inner::RDF._TripleMatchIterator
end

Tables.istable(::Type{_TripleTableIter}) = true
Tables.rowaccess(::Type{_TripleTableIter}) = true
Tables.rows(it::_TripleTableIter) = it
Tables.schema(::_TripleTableIter) =
    Tables.Schema((:subject, :predicate, :object),
                  (RDF.SubjectTerm, RDF.IRI, RDF.ObjectTerm))

function Base.iterate(it::_TripleTableIter, state=nothing)
    r = state === nothing ? iterate(it.inner) : iterate(it.inner, state)
    r === nothing && return nothing
    t, ns = r
    (_TripleRow(t.subject, t.predicate, t.object), ns)
end

Base.eltype(::Type{_TripleTableIter}) = _TripleRow
Base.IteratorSize(::Type{_TripleTableIter}) = Base.SizeUnknown()

# ── Register _TripleMatchIterator as a table ──────────────────────────────────

Tables.istable(::Type{RDF._TripleMatchIterator}) = true
Tables.rowaccess(::Type{RDF._TripleMatchIterator}) = true
Tables.rows(it::RDF._TripleMatchIterator) = _TripleTableIter(it)
Tables.schema(::RDF._TripleMatchIterator) =
    Tables.Schema((:subject, :predicate, :object),
                  (RDF.SubjectTerm, RDF.IRI, RDF.ObjectTerm))

# ── Quad row ──────────────────────────────────────────────────────────────────

struct _QuadRow
    subject::RDF.SubjectTerm
    predicate::RDF.IRI
    object::RDF.ObjectTerm
    graph::Union{RDF.GraphName, Nothing}
end

Tables.columnnames(::_QuadRow) = (:subject, :predicate, :object, :graph)
Tables.getcolumn(r::_QuadRow, nm::Symbol) = getfield(r, nm)
Tables.getcolumn(r::_QuadRow, i::Int) = getfield(r, i)

# ── Dataset table wrapper ─────────────────────────────────────────────────────

struct _QuadTableIter
    inner::RDF._DatasetMatchIterator
end

Tables.istable(::Type{_QuadTableIter}) = true
Tables.rowaccess(::Type{_QuadTableIter}) = true
Tables.rows(it::_QuadTableIter) = it
Tables.schema(::_QuadTableIter) =
    Tables.Schema((:subject, :predicate, :object, :graph),
                  (RDF.SubjectTerm, RDF.IRI, RDF.ObjectTerm, Union{RDF.GraphName, Nothing}))

function Base.iterate(it::_QuadTableIter, state=nothing)
    r = state === nothing ? iterate(it.inner) : iterate(it.inner, state)
    r === nothing && return nothing
    q, ns = r
    (_QuadRow(q.subject, q.predicate, q.object, q.graph), ns)
end

Base.eltype(::Type{_QuadTableIter}) = _QuadRow
Base.IteratorSize(::Type{_QuadTableIter}) = Base.SizeUnknown()

# ── Register _DatasetMatchIterator as a table ─────────────────────────────────

Tables.istable(::Type{RDF._DatasetMatchIterator}) = true
Tables.rowaccess(::Type{RDF._DatasetMatchIterator}) = true
Tables.rows(it::RDF._DatasetMatchIterator) = _QuadTableIter(it)
Tables.schema(::RDF._DatasetMatchIterator) =
    Tables.Schema((:subject, :predicate, :object, :graph),
                  (RDF.SubjectTerm, RDF.IRI, RDF.ObjectTerm, Union{RDF.GraphName, Nothing}))

end # module RDFTablesExt
