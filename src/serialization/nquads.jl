const _MIME_NQ = MIME"application/n-quads"

# ── Write ─────────────────────────────────────────────────────────────────────

function Base.write(io::IO, ::_MIME_NQ, ds::Dataset)
    for t in ds.default_graph
        _write_triple(io, t)           # default graph — no graph name
    end
    for (name, g) in ds.named_graphs
        for t in g
            _write_quad(io, t, name)
        end
    end
end

function _write_quad(io::IO, t::Triple, graph::GraphName)
    _write_subject(io, t.subject)
    print(io, ' ')
    _write_iri(io, t.predicate)
    print(io, ' ')
    _write_object(io, t.object)
    print(io, ' ')
    _write_subject(io, graph)          # graph name: IRI or blank
    println(io, " .")
end


# ── Read ──────────────────────────────────────────────────────────────────────

function Base.read(io::IO, ::_MIME_NQ, ::Type{Dataset})::Dataset
    ds = Dataset()
    blank_map = Dict{String, BlankNode}()
    graph_blank_map = Dict{String, BlankNode}()
    lineno = 0
    for line in eachline(io)
        lineno += 1
        line = strip(line)
        (isempty(line) || startswith(line, "#")) && continue
        q = _parse_nq_line(line, lineno, blank_map, graph_blank_map)
        q === nothing && continue
        if q.graph === nothing
            push!(ds.default_graph, Triple(q))
        else
            name = q.graph::GraphName
            if !haskey(ds, name)
                ds[name] = Graph()
            end
            push!(ds[name], Triple(q))
        end
    end
    ds
end

function Base.read(path::AbstractString, ::_MIME_NQ, ::Type{Dataset})::Dataset
    open(path, "r") do io
        read(io, _MIME_NQ(), Dataset)
    end
end

function parse_triples(f::Function, io::IO, mime::_MIME_NQ)
    blank_map = Dict{String, BlankNode}()
    gbm = Dict{String, BlankNode}()
    lineno = 0
    for line in eachline(io)
        lineno += 1
        line = strip(line)
        (isempty(line) || startswith(line, "#")) && continue
        q = _parse_nq_line(line, lineno, blank_map, gbm)
        q !== nothing && f(q)
    end
end

function parse_triples(io::IO, mime::_MIME_NQ)
    blank_map = Dict{String, BlankNode}()
    gbm = Dict{String, BlankNode}()
    lineno = Ref(0)
    _NQuadsIterator(eachline(io), blank_map, gbm, lineno)
end

struct _NQuadsIterator{L}
    lines::L
    blank_map::Dict{String, BlankNode}
    graph_blank_map::Dict{String, BlankNode}
    lineno::Ref{Int}
end

function Base.iterate(it::_NQuadsIterator, state=nothing)
    while true
        r = state === nothing ? iterate(it.lines) : iterate(it.lines, state)
        r === nothing && return nothing
        line, next_state = r
        it.lineno[] += 1
        s = strip(line)
        (isempty(s) || startswith(s, "#")) && (state = next_state; continue)
        q = _parse_nq_line(s, it.lineno[], it.blank_map, it.graph_blank_map)
        q !== nothing && return (q, next_state)
        state = next_state
    end
end

Base.eltype(::Type{<:_NQuadsIterator}) = Quad
Base.IteratorSize(::Type{<:_NQuadsIterator}) = Base.SizeUnknown()

# ── N-Quads line parser ───────────────────────────────────────────────────────

function _parse_nq_line(line::AbstractString, lineno::Int,
                        blank_map::Dict{String,BlankNode},
                        gbm::Dict{String,BlankNode})
    line = _strip_inline_comment(strip(line))
    endswith(line, '.') || throw(ParseError("Missing trailing '.'", lineno, length(line), _MIME_NQ()))
    line = strip(line[1:end-1])

    pos = 1
    subj, pos = _parse_nt_subject(line, pos, lineno, blank_map)
    pos = _skip_ws(line, pos)
    pred, pos = _parse_nt_iri(line, pos, lineno)
    pos = _skip_ws(line, pos)
    obj, pos  = _parse_nt_object(line, pos, lineno, blank_map)
    pos = _skip_ws(line, pos)

    # Optional graph name
    if pos > length(line)
        return Quad(subj, pred, obj, nothing)
    end

    graph_name, pos = _parse_graph_name(line, pos, lineno, gbm)
    pos = _skip_ws(line, pos)
    pos <= length(line) && throw(ParseError("Unexpected content after graph name", lineno, pos, _MIME_NQ()))
    Quad(subj, pred, obj, graph_name)
end

function _parse_graph_name(s, pos, lineno, gbm)
    pos <= length(s) || return nothing, pos
    s[pos] == '<' && return _parse_nt_iri(s, pos, lineno)
    startswith(s[pos:end], "_:") && return _parse_nt_blank(s, pos, lineno, gbm)
    return nothing, pos
end
