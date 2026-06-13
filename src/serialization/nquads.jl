const _MIME_NQ = MIME"application/n-quads"

# ── Write ─────────────────────────────────────────────────────────────────────

function Base.write(io::IO, ::_MIME_NQ, ds::Dataset)
    # Build/extend the pre-formatted term-string cache, then stream raw ID tuples.
    # Same strategy as the N-Triples writer: the inner loop is four write() calls per
    # quad with zero _resolve() calls, zero Term allocations, and zero formatting work.
    _ensure_nt_cache!()
    cache = _NT_TERM_STRINGS

    # Default graph — no graph name (N-Quads triple line)
    @inbounds for tup in ds.default_graph.store.spo
        write(io, cache[tup[1]]); write(io, 0x20)
        write(io, cache[tup[2]]); write(io, 0x20)
        write(io, cache[tup[3]]); write(io, " .\n")
    end

    # Named graphs — intern the graph name once per graph, then stream triples
    for (name, g) in ds.named_graphs
        g_id = _intern!(name)
        # _intern! may have added new terms; extend the cache to cover them.
        g_id > length(cache) && _ensure_nt_cache!()
        gname_str = @inbounds cache[g_id]
        @inbounds for tup in g.store.spo
            write(io, cache[tup[1]]); write(io, 0x20)
            write(io, cache[tup[2]]); write(io, 0x20)
            write(io, cache[tup[3]]); write(io, 0x20)
            write(io, gname_str);     write(io, " .\n")
        end
    end
end

# ── Read ──────────────────────────────────────────────────────────────────────

function Base.read(io::IO, ::_MIME_NQ, ::Type{Dataset})::Dataset
    ds = Dataset()
    blank_map       = Dict{String, BlankNode}()
    graph_blank_map = Dict{String, BlankNode}()
    lineno = 0

    # Collect interned IDs as we parse, deferring hexastore insertion until the
    # end so all six index arrays can be built with a single sort rather than
    # N individual sorted inserts (O(n log n) vs O(n²)).
    default_tuples   = NTuple{3,UInt32}[]
    named_tuples     = Dict{UInt32, Vector{NTuple{3,UInt32}}}()
    graph_id_to_name = Dict{UInt32, GraphName}()
    default_blanks   = Set{UInt64}()
    named_blanks     = Dict{UInt32, Set{UInt64}}()

    lex_buf = IOBuffer()   # reused across every literal in this parse
    content = String(Base.read(io))
    nb      = ncodeunits(content)
    pos     = 1
    while pos <= nb
        ls = pos
        while pos <= nb && codeunit(content, pos) != UInt8('\n')
            pos += 1
        end
        le = pos - 1
        pos += 1
        lineno += 1
        le >= ls && codeunit(content, le) == UInt8('\r') && (le -= 1)
        le < ls && continue
        while ls <= le && (codeunit(content, ls) == UInt8(' ') ||
                           codeunit(content, ls) == UInt8('\t'))
            ls += 1
        end
        ls > le && continue
        codeunit(content, ls) == UInt8('#') && continue
        line = SubString(content, ls, le)
        q = _parse_nq_line(line, lineno, blank_map, graph_blank_map, lex_buf)
        q === nothing && continue

        s_id = _intern!(q.subject)
        p_id = _intern!(q.predicate)
        o_id = _intern!(q.object)

        if q.graph === nothing
            push!(default_tuples, (s_id, p_id, o_id))
            _collect_blank_ids!(default_blanks, q.subject)
            _collect_blank_ids!(default_blanks, q.object)
        else
            gname = q.graph::GraphName
            g_id  = _intern!(gname)
            graph_id_to_name[g_id] = gname
            v = get!(Vector{NTuple{3,UInt32}}, named_tuples, g_id)
            push!(v, (s_id, p_id, o_id))
            bns = get!(Set{UInt64}, named_blanks, g_id)
            _collect_blank_ids!(bns, q.subject)
            _collect_blank_ids!(bns, q.object)
        end
    end

    # Bulk-insert into each graph
    if !isempty(default_tuples)
        _hexa_bulk_insert!(ds.default_graph.store, default_tuples)
        ds.default_graph._size = length(ds.default_graph.store.spo)
        union!(ds.default_graph.blank_nodes, default_blanks)
    end

    for (g_id, tuples) in named_tuples
        name = graph_id_to_name[g_id]
        if !haskey(ds, name)
            ds[name] = Graph()
        end
        g = ds[name]
        _hexa_bulk_insert!(g.store, tuples)
        g._size = length(g.store.spo)
        haskey(named_blanks, g_id) && union!(g.blank_nodes, named_blanks[g_id])
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
    gbm       = Dict{String, BlankNode}()
    lex_buf   = IOBuffer()
    content   = String(Base.read(io))
    nb        = ncodeunits(content)
    lineno    = 0
    pos       = 1
    while pos <= nb
        ls = pos
        while pos <= nb && codeunit(content, pos) != UInt8('\n')
            pos += 1
        end
        le = pos - 1
        pos += 1
        lineno += 1
        le >= ls && codeunit(content, le) == UInt8('\r') && (le -= 1)
        le < ls && continue
        while ls <= le && (codeunit(content, ls) == UInt8(' ') ||
                           codeunit(content, ls) == UInt8('\t'))
            ls += 1
        end
        ls > le && continue
        codeunit(content, ls) == UInt8('#') && continue
        q = _parse_nq_line(SubString(content, ls, le), lineno, blank_map, gbm, lex_buf)
        q !== nothing && f(q)
    end
end

function parse_triples(io::IO, mime::_MIME_NQ)
    blank_map = Dict{String, BlankNode}()
    gbm = Dict{String, BlankNode}()
    lineno = Ref(0)
    _NQuadsIterator(eachline(io), blank_map, gbm, lineno, IOBuffer())
end

struct _NQuadsIterator{L}
    lines::L
    blank_map::Dict{String, BlankNode}
    graph_blank_map::Dict{String, BlankNode}
    lineno::Ref{Int}
    lex_buf::IOBuffer   # reused across literals; take!() resets it after each use
end

function Base.iterate(it::_NQuadsIterator, state=nothing)
    while true
        r = state === nothing ? iterate(it.lines) : iterate(it.lines, state)
        r === nothing && return nothing
        line, next_state = r
        it.lineno[] += 1
        s = strip(line)
        (isempty(s) || startswith(s, "#")) && (state = next_state; continue)
        q = _parse_nq_line(s, it.lineno[], it.blank_map, it.graph_blank_map, it.lex_buf)
        q !== nothing && return (q, next_state)
        state = next_state
    end
end

Base.eltype(::Type{<:_NQuadsIterator}) = Quad
Base.IteratorSize(::Type{<:_NQuadsIterator}) = Base.SizeUnknown()

# ── N-Quads line parser ───────────────────────────────────────────────────────

function _parse_nq_line(line::AbstractString, lineno::Int,
                        blank_map::Dict{String,BlankNode},
                        gbm::Dict{String,BlankNode},
                        lex_buf::IOBuffer)
    line = _strip_inline_comment(strip(line))
    endswith(line, '.') || throw(ParseError("Missing trailing '.'", lineno, length(line), _MIME_NQ()))
    line = strip(line[1:end-1])

    pos = 1
    subj, pos = _parse_nt_subject(line, pos, lineno, blank_map)
    pos = _skip_ws(line, pos)
    pred, pos = _parse_nt_iri(line, pos, lineno)
    pos = _skip_ws(line, pos)
    obj, pos  = _parse_nt_object(line, pos, lineno, blank_map, lex_buf)
    pos = _skip_ws(line, pos)

    # Optional graph name
    if pos > lastindex(line)
        return Quad(subj, pred, obj, nothing)
    end

    graph_name, pos = _parse_graph_name(line, pos, lineno, gbm)
    pos = _skip_ws(line, pos)
    pos <= lastindex(line) && throw(ParseError("Unexpected content after graph name", lineno, pos, _MIME_NQ()))
    Quad(subj, pred, obj, graph_name)
end

function _parse_graph_name(s, pos, lineno, gbm)
    pos <= lastindex(s) || return nothing, pos
    s[pos] == '<' && return _parse_nt_iri(s, pos, lineno)
    startswith(s[pos:end], "_:") && return _parse_nt_blank(s, pos, lineno, gbm)
    return nothing, pos
end
