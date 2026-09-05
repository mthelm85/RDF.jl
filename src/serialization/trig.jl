# TriG 1.2 — the RDF Dataset serialization
#
# TriG is Turtle plus graph blocks, so the whole term-level grammar (IRIs,
# prefixed names, literals, collections, blank node property lists, and the
# RDF 1.2 additions — triple terms, reified triples, annotations) is reused from
# turtle.jl. What TriG adds on top:
#
#   <g> { … }          triples in the named graph <g>
#   GRAPH <g> { … }    the same, with the SPARQL-style keyword
#   { … }              triples in the default graph
#   <s> <p> <o> .      triples in the default graph, exactly as in Turtle
#
# The '.' after a graph block is optional, and so is the one after the last
# triple *inside* a block.
#
# Blank node labels are scoped to the document, not to a graph, so `_:a` in two
# different graphs denotes the same node. That falls out of sharing the Turtle
# parser's blank_map across blocks.

const _MIME_TRIG = MIME"application/trig"

# ── Parsing ───────────────────────────────────────────────────────────────────

# Parse `{ … }` and return the triples it contains. The parser's triple sink is
# swapped for the duration so every existing production keeps pushing into
# `p.triples` without knowing about graphs.
function _trig_parse_wrapped_graph!(p::_TurtleParser)::Vector{Triple}
    _ttl_expect_char!(p, '{')
    saved = p.triples
    p.triples = Triple[]
    while true
        _ttl_skip!(p)
        _ttl_eof(p) && _ttl_error(p, "Unterminated graph block: expected '}'")
        _ttl_peek(p) == '}' && break
        _ttl_parse_triples!(p)
        _ttl_skip!(p)
        if !_ttl_eof(p) && _ttl_peek(p) == '.'
            _ttl_advance!(p)
        elseif _ttl_eof(p) || _ttl_peek(p) != '}'
            _ttl_error(p, "Expected '.' or '}' in graph block")
        end
    end
    _ttl_advance!(p)   # '}'
    collected = p.triples
    p.triples = saved
    return collected
end

# A graph label is an IRI or a blank node (TriG's `labelOrSubject`).
function _trig_parse_label!(p::_TurtleParser)::GraphName
    _ttl_skip!(p)
    c = _ttl_peek(p)
    if c == '['
        return _ttl_parse_anon_bnode!(p)
    elseif c == '_'
        return _ttl_parse_blank_node_label!(p)
    elseif c == '<'
        return _ttl_parse_iriref!(p)
    else
        return _ttl_parse_prefixed_name!(p)
    end
end

function _trig_add!(named::Dict{GraphName, Vector{Triple}}, label::GraphName,
                    triples::Vector{Triple})
    # A graph may be named more than once in a document; the blocks accumulate.
    append!(get!(() -> Triple[], named, label), triples)
    return nothing
end

function _trig_parse_document!(p::_TurtleParser,
                               default_triples::Vector{Triple},
                               named::Dict{GraphName, Vector{Triple}})
    while true
        _ttl_skip!(p)
        _ttl_eof(p) && break
        c = _ttl_peek(p)

        if c == '@'
            _ttl_advance!(p)
            _ttl_parse_at_directive!(p)

        elseif c == '{'
            # Anonymous block → default graph.
            append!(default_triples, _trig_parse_wrapped_graph!(p))

        elseif isletter(c)
            # PREFIX / BASE / VERSION / GRAPH, or a prefixed name starting a
            # statement or naming a graph. Read the word and decide.
            pos_save    = p.pos
            lineno_save = p.lineno
            name  = _ttl_read_name!(p)
            uname = uppercase(name)
            nxt   = _ttl_eof(p) ? '\0' : _ttl_peek(p)

            if (uname == "PREFIX" || uname == "BASE" || uname == "VERSION") &&
               (nxt in (' ', '\t', '\n', '\r', '<') ||
                (uname == "VERSION" && (nxt == '"' || nxt == '\'')))
                _ttl_parse_sparql_directive!(p, name)

            elseif uname == "GRAPH" && (nxt in (' ', '\t', '\n', '\r', '<', '_', '['))
                label = _trig_parse_label!(p)
                _ttl_skip!(p)
                _trig_add!(named, label, _trig_parse_wrapped_graph!(p))

            else
                p.pos    = pos_save
                p.lineno = lineno_save
                _trig_parse_block_or_triples!(p, default_triples, named)
            end

        else
            _trig_parse_block_or_triples!(p, default_triples, named)
        end
    end
end

# `<g> { … }` and `<s> <p> <o> .` share a prefix: both open with a term. Read it,
# then look at the next character to see which production this is.
function _trig_parse_block_or_triples!(p::_TurtleParser,
                                       default_triples::Vector{Triple},
                                       named::Dict{GraphName, Vector{Triple}})
    c = _ttl_peek(p)

    # A collection can only ever be a subject, never a graph label.
    if c == '('
        _ttl_parse_triples!(p)
        _ttl_expect_char!(p, '.')
        return nothing
    end

    if c == '['
        # `[] { … }` labels a graph with a fresh blank node; `[ :p :o ] …` is a
        # blank node property list subject. _ttl_parse_bnode_proplist! handles
        # both shapes, so parse it and then look ahead. Whether it emitted any
        # triples is what tells them apart: `labelOrSubject` admits a blank node,
        # but not a blankNodePropertyList carrying properties, so
        # `[:p1 :o1] { … }` is a syntax error.
        ntriples_before = length(p.triples)
        subj = _ttl_parse_bnode_proplist!(p)
        _ttl_skip!(p)
        if !_ttl_eof(p) && _ttl_peek(p) == '{'
            length(p.triples) == ntriples_before ||
                _ttl_error(p, "A blank node property list cannot label a graph")
            _trig_add!(named, subj, _trig_parse_wrapped_graph!(p))
            return nothing
        end
        if !_ttl_eof(p) && _ttl_peek(p) != '.'
            _ttl_parse_po_list!(p, subj)
            _ttl_skip!(p)
        end
        _ttl_expect_char!(p, '.')
        return nothing
    end

    is_reified = c == '<' && _ttl_peek_at(p, 1) == '<' && _ttl_peek_at(p, 2) != '('
    subj = _ttl_parse_subject!(p)
    _ttl_skip!(p)

    if !_ttl_eof(p) && _ttl_peek(p) == '{'
        subj isa GraphName ||
            _ttl_error(p, "A graph label must be an IRI or blank node")
        _trig_add!(named, subj::GraphName, _trig_parse_wrapped_graph!(p))
        return nothing
    end

    if !(is_reified && !_ttl_eof(p) && _ttl_peek(p) == '.')
        _ttl_parse_po_list!(p, subj)
        _ttl_skip!(p)
    end
    _ttl_expect_char!(p, '.')
    return nothing
end

function _trig_parse(s::String, base::String)::Dataset
    p = _TurtleParser(s, base)
    default_triples = Triple[]
    named = Dict{GraphName, Vector{Triple}}()
    _trig_parse_document!(p, default_triples, named)
    # Triples written Turtle-style outside any block accumulate in the parser's
    # own sink; a `{ … }` block hands its own vector back instead. Both belong
    # to the default graph.
    append!(default_triples, p.triples)

    ds = Dataset(; default_graph = bulk_load!(Graph(), default_triples))
    for (label, triples) in named
        ds[label] = bulk_load!(Graph(), triples)
    end
    ds
end

"""
    Base.read(io::IO, ::MIME"application/trig", ::Type{Dataset}) -> Dataset
    Base.read(io::IO, ::MIME"application/trig", ::Type{Dataset}, base) -> Dataset

Parse a TriG document into a `Dataset`. Triples outside any block, and those in
an anonymous `{ … }` block, go to the default graph.
"""
Base.read(io::IO, ::_MIME_TRIG, ::Type{Dataset})::Dataset =
    _trig_parse(String(Base.read(io)), "")

Base.read(io::IO, ::_MIME_TRIG, ::Type{Dataset}, base::AbstractString)::Dataset =
    _trig_parse(String(Base.read(io)), String(base))

"""
    Base.read(io::IO, ::MIME"application/trig", ::Type{Graph}) -> Graph

Parse a TriG document and merge every graph into one `Graph`, discarding the
graph names. Use the `Dataset` form to keep them.
"""
function Base.read(io::IO, ::_MIME_TRIG, ::Type{Graph})::Graph
    _dataset_to_graph(_trig_parse(String(Base.read(io)), ""))
end

function Base.read(io::IO, ::_MIME_TRIG, ::Type{Graph}, base::AbstractString)::Graph
    _dataset_to_graph(_trig_parse(String(Base.read(io)), String(base)))
end

# ── Writing ───────────────────────────────────────────────────────────────────

# Graph labels are written with the same surface syntax as any other term, so
# the N-Triples cache serves, with prefix abbreviation applied on top.
function _trig_label_string(name::GraphName, prefixes::Dict{String,String})::String
    if name isa IRI
        v = name.value
        # Longest matching prefix wins, as in the Turtle writer.
        best_len = 0; best_pn = ""
        for (pn, pi) in prefixes
            if startswith(v, pi) && length(pi) > best_len
                best_len = length(pi); best_pn = pn
            end
        end
        best_len > 0 && return "$best_pn:$(v[best_len+1:end])"
        return "<$v>"
    end
    return "_:b$(name.id)"
end

"""
    Base.write(io::IO, ::MIME"application/trig", ds::Dataset; prefixes=Dict())

Serialize a `Dataset` to TriG. Default-graph triples are written at the top
level; each named graph follows in a `label { … }` block. An empty named graph
is written as `label {}` — TriG can represent it, unlike N-Quads.
"""
function Base.write(io::IO, ::_MIME_TRIG, ds::Dataset;
                    prefixes::Dict{String,String}=Dict{String,String}())
    for (pn, pi) in sort(collect(prefixes), by=first)
        println(io, "@prefix $pn: <$pi> .")
    end
    !isempty(prefixes) && println(io)

    if !isempty(ds.default_graph)
        write(io, _MIME_TTL(), ds.default_graph; prefixes=prefixes,
              emit_prefixes=false)
        println(io)
    end

    # Sorted by label so output is stable across runs.
    for name in sort(collect(keys(ds.named_graphs)), by=_trig_sort_key)
        g = ds.named_graphs[name]
        label = _trig_label_string(name, prefixes)
        if isempty(g)
            println(io, label, " {}")
        else
            println(io, label, " {")
            write(io, _MIME_TTL(), g; prefixes=prefixes, emit_prefixes=false)
            println(io, "}")
        end
        println(io)
    end
    return nothing
end

_trig_sort_key(n::GraphName) = n isa IRI ? (0, n.value) : (1, string(n.id))
