module RDFTablesExt

using RDF
using Tables

# ── Tables.jl interface for match results ────────────────────────────────────
#
# Both _TripleMatchIterator and _DatasetMatchIterator expose a Tables.jl row
# interface so results can flow directly into DataFrames, CSV, etc.

# ── Triple match (Graph) ──────────────────────────────────────────────────────

struct _TripleRow
    subject::RDF.SubjectTerm
    predicate::RDF.IRI
    object::RDF.ObjectTerm
end

Tables.columnnames(::_TripleRow) = (:subject, :predicate, :object)
Tables.getcolumn(r::_TripleRow, nm::Symbol) = getfield(r, nm)
Tables.getcolumn(r::_TripleRow, i::Int) = getfield(r, i)

struct _TripleRows
    it::RDF._TripleMatchIterator
end

Tables.istable(::Type{_TripleRows}) = true
Tables.rowaccess(::Type{_TripleRows}) = true
Tables.rows(r::_TripleRows) = r
Tables.schema(::_TripleRows) =
    Tables.Schema((:subject, :predicate, :object),
                  (RDF.SubjectTerm, RDF.IRI, RDF.ObjectTerm))

function Base.iterate(r::_TripleRows, state=nothing)
    result = state === nothing ? iterate(r.it) : iterate(r.it, state)
    result === nothing && return nothing
    t, ns = result
    (_TripleRow(t.subject, t.predicate, t.object), ns)
end
Base.eltype(::Type{_TripleRows}) = _TripleRow
Base.IteratorSize(::Type{_TripleRows}) = Base.SizeUnknown()

Tables.istable(::Type{RDF._TripleMatchIterator}) = true
Tables.rowaccess(::Type{RDF._TripleMatchIterator}) = true
Tables.rows(it::RDF._TripleMatchIterator) = _TripleRows(it)
Tables.schema(it::RDF._TripleMatchIterator) = Tables.schema(_TripleRows(it))

# ── Quad match (Dataset) ──────────────────────────────────────────────────────

struct _QuadRow
    subject::RDF.SubjectTerm
    predicate::RDF.IRI
    object::RDF.ObjectTerm
    graph::Union{RDF.GraphName, Nothing}
end

Tables.columnnames(::_QuadRow) = (:subject, :predicate, :object, :graph)
Tables.getcolumn(r::_QuadRow, nm::Symbol) = getfield(r, nm)
Tables.getcolumn(r::_QuadRow, i::Int) = getfield(r, i)

struct _QuadRows
    it::RDF._DatasetMatchIterator
end

Tables.istable(::Type{_QuadRows}) = true
Tables.rowaccess(::Type{_QuadRows}) = true
Tables.rows(r::_QuadRows) = r
Tables.schema(::_QuadRows) =
    Tables.Schema((:subject, :predicate, :object, :graph),
                  (RDF.SubjectTerm, RDF.IRI, RDF.ObjectTerm, Union{RDF.GraphName, Nothing}))

function Base.iterate(r::_QuadRows, state=nothing)
    result = state === nothing ? iterate(r.it) : iterate(r.it, state)
    result === nothing && return nothing
    q, ns = result
    (_QuadRow(q.subject, q.predicate, q.object, q.graph), ns)
end
Base.eltype(::Type{_QuadRows}) = _QuadRow
Base.IteratorSize(::Type{_QuadRows}) = Base.SizeUnknown()

Tables.istable(::Type{RDF._DatasetMatchIterator}) = true
Tables.rowaccess(::Type{RDF._DatasetMatchIterator}) = true
Tables.rows(it::RDF._DatasetMatchIterator) = _QuadRows(it)
Tables.schema(it::RDF._DatasetMatchIterator) = Tables.schema(_QuadRows(it))


# ── SolutionSet (SPARQL SELECT results) ──────────────────────────────────────
#
# Column-access interface: each projected SPARQL variable becomes a Tables
# column of type `Union{RDF.RDFTerm, Missing}`, where `missing` represents an
# unbound variable (OPTIONAL bindings).  This lets `DataFrame(sol)` work without
# any extra conversion.

Tables.istable(::Type{RDF.SolutionSet})     = true
Tables.columnaccess(::Type{RDF.SolutionSet}) = true
Tables.columns(ss::RDF.SolutionSet) = ss

Tables.columnnames(ss::RDF.SolutionSet) = ss.variables

function Tables.getcolumn(ss::RDF.SolutionSet, nm::Symbol)
    idx = get(ss._var_idx, nm, 0)
    idx == 0 && throw(ArgumentError("SolutionSet has no variable $(nm)"))
    # Map nothing (unbound) → missing for Tables.jl consumers
    Union{RDF.RDFTerm, Missing}[
        x === nothing ? missing : x for x in ss._cols[idx]
    ]
end

function Tables.getcolumn(ss::RDF.SolutionSet, i::Int)
    Tables.getcolumn(ss, ss.variables[i])
end

Tables.schema(ss::RDF.SolutionSet) =
    Tables.Schema(ss.variables,
                  fill(Union{RDF.RDFTerm, Missing}, length(ss.variables)))

end # module RDFTablesExt
