const _MIME_NT = MIME"application/n-triples"

# ── Write ─────────────────────────────────────────────────────────────────────

function Base.write(io::IO, ::_MIME_NT, g::Graph)
    for t in g
        _write_triple(io, t)
    end
end

function _write_triple(io::IO, t::Triple)
    _write_subject(io, t.subject)
    print(io, ' ')
    _write_iri(io, t.predicate)
    print(io, ' ')
    _write_object(io, t.object)
    println(io, " .")
end

_write_subject(io, iri::IRI) = _write_iri(io, iri)
_write_subject(io, bn::BlankNode) = _write_blank(io, bn)
_write_object(io, iri::IRI) = _write_iri(io, iri)
_write_object(io, bn::BlankNode) = _write_blank(io, bn)
_write_object(io, lit::Literal) = _write_literal(io, lit)

_write_iri(io, iri::IRI) = print(io, '<', iri.value, '>')
_write_blank(io, bn::BlankNode) = print(io, "_:b", bn.id)

function _write_literal(io, lit::Literal)
    print(io, '"')
    for c in lit.lexical_form
        if c == '"';  print(io, "\\\"")
        elseif c == '\\'; print(io, "\\\\")
        elseif c == '\n'; print(io, "\\n")
        elseif c == '\r'; print(io, "\\r")
        else
            cp = UInt32(c)
            if cp <= 0x08 || cp == 0x0B || cp == 0x0C || (0x0E <= cp <= 0x1F) || cp == 0x7F
                @printf(io, "\\u%04X", cp)
            elseif cp > 0xFFFF
                @printf(io, "\\U%08X", cp)
            else
                print(io, c)
            end
        end
    end
    print(io, '"')
    if !isempty(lit.language_tag)
        print(io, '@', lit.language_tag)
    else
        print(io, "^^<", lit.datatype.value, '>')
    end
end


# ── Read ──────────────────────────────────────────────────────────────────────

function Base.read(io::IO, ::_MIME_NT, ::Type{Graph})::Graph
    g = Graph()
    blank_map = Dict{String, BlankNode}()
    lineno = 0
    for line in eachline(io)
        lineno += 1
        line = strip(line)
        isempty(line) || line[1] == '#' && continue
        t = _parse_nt_line(line, lineno, blank_map)
        t === nothing && continue
        push!(g, t)
    end
    g
end

function Base.read(path::AbstractString, ::_MIME_NT, ::Type{Graph})::Graph
    open(path, "r") do io
        read(io, _MIME_NT(), Graph)
    end
end

# Streaming parser
function parse_triples(f::Function, io::IO, mime::_MIME_NT)
    blank_map = Dict{String, BlankNode}()
    lineno = 0
    for line in eachline(io)
        lineno += 1
        line = strip(line)
        isempty(line) || startswith(line, "#") && continue
        t = _parse_nt_line(line, lineno, blank_map)
        t !== nothing && f(t)
    end
end

function parse_triples(io::IO, mime::_MIME_NT)
    blank_map = Dict{String, BlankNode}()
    lineno = Ref(0)
    lines = eachline(io)
    _NTriplesIterator(lines, blank_map, lineno)
end

struct _NTriplesIterator{L}
    lines::L
    blank_map::Dict{String, BlankNode}
    lineno::Ref{Int}
end

function Base.iterate(it::_NTriplesIterator, state=nothing)
    while true
        r = state === nothing ? iterate(it.lines) : iterate(it.lines, state)
        r === nothing && return nothing
        line, next_state = r
        it.lineno[] += 1
        s = strip(line)
        isempty(s) || startswith(s, "#") && (state = next_state; continue)
        t = _parse_nt_line(s, it.lineno[], it.blank_map)
        t !== nothing && return (t, next_state)
        state = next_state
    end
end

Base.eltype(::Type{<:_NTriplesIterator}) = Triple
Base.IteratorSize(::Type{<:_NTriplesIterator}) = Base.SizeUnknown()

# ── N-Triples line parser ─────────────────────────────────────────────────────

function _parse_nt_line(line::AbstractString, lineno::Int, blank_map::Dict{String,BlankNode})
    line = strip(line)
    endswith(line, '.') || throw(ParseError("Missing trailing '.'", lineno, length(line), _MIME_NT()))
    line = strip(line[1:end-1])

    pos = 1
    subj, pos = _parse_nt_subject(line, pos, lineno, blank_map)
    pos = _skip_ws(line, pos)
    pred, pos = _parse_nt_iri(line, pos, lineno)
    pos = _skip_ws(line, pos)
    obj, pos  = _parse_nt_object(line, pos, lineno, blank_map)
    Triple(subj, pred, obj)
end

function _skip_ws(s, pos)
    while pos <= length(s) && isspace(s[pos])
        pos += 1
    end
    pos
end

function _parse_nt_iri(s, pos, lineno)
    pos <= length(s) && s[pos] == '<' || throw(ParseError("Expected IRI", lineno, pos, _MIME_NT()))
    close = findnext(==('<') ∘ identity, s, pos)  # wrong, find '>'
    close = _find_close(s, pos + 1, '>')
    close === nothing && throw(ParseError("Unterminated IRI", lineno, pos, _MIME_NT()))
    raw = s[pos+1:close-1]
    iri = IRI(_unescape_iri(raw))
    iri, close + 1
end

function _find_close(s, from, ch)
    i = from
    while i <= length(s)
        if s[i] == '\\' && ch != '\\'
            i += 2
        elseif s[i] == ch
            return i
        else
            i += 1
        end
    end
    nothing
end

function _parse_nt_subject(s, pos, lineno, blank_map)
    pos <= length(s) || throw(ParseError("Unexpected end of line", lineno, pos, _MIME_NT()))
    s[pos] == '<' && return _parse_nt_iri(s, pos, lineno)
    s[pos] == '_' && return _parse_nt_blank(s, pos, lineno, blank_map)
    throw(ParseError("Expected subject (IRI or blank node)", lineno, pos, _MIME_NT()))
end

function _parse_nt_object(s, pos, lineno, blank_map)
    pos <= length(s) || throw(ParseError("Unexpected end of line", lineno, pos, _MIME_NT()))
    s[pos] == '<' && return _parse_nt_iri(s, pos, lineno)
    s[pos] == '_' && return _parse_nt_blank(s, pos, lineno, blank_map)
    s[pos] == '"' && return _parse_nt_literal(s, pos, lineno, blank_map)
    throw(ParseError("Expected object (IRI, blank node, or literal)", lineno, pos, _MIME_NT()))
end

function _parse_nt_blank(s, pos, lineno, blank_map)
    startswith(s[pos:end], "_:") || throw(ParseError("Expected blank node", lineno, pos, _MIME_NT()))
    i = pos + 2
    while i <= length(s) && !isspace(s[i]) && s[i] != '.'
        i += 1
    end
    label = s[pos+2:i-1]
    isempty(label) && throw(ParseError("Empty blank node label", lineno, pos, _MIME_NT()))
    bn = get!(blank_map, label) do; _mint_blank_node() end
    bn, i
end

function _parse_nt_literal(s, pos, lineno, blank_map)
    s[pos] == '"' || throw(ParseError("Expected literal", lineno, pos, _MIME_NT()))
    # Find closing quote, respecting escapes
    i = pos + 1
    buf = IOBuffer()
    while i <= length(s)
        c = s[i]
        if c == '\\'
            i += 1
            i > length(s) && throw(ParseError("Unexpected end after escape", lineno, i, _MIME_NT()))
            e = s[i]
            if e == 'n';  write(buf, '\n')
            elseif e == 'r'; write(buf, '\r')
            elseif e == 't'; write(buf, '\t')
            elseif e == '"'; write(buf, '"')
            elseif e == '\\'; write(buf, '\\')
            elseif e == 'u'
                i + 4 > length(s) && throw(ParseError("Bad \\u escape", lineno, i, _MIME_NT()))
                hex = s[i+1:i+4]; i += 4
                write(buf, Char(parse(UInt16, hex; base=16)))
            elseif e == 'U'
                i + 8 > length(s) && throw(ParseError("Bad \\U escape", lineno, i, _MIME_NT()))
                hex = s[i+1:i+8]; i += 8
                write(buf, Char(parse(UInt32, hex; base=16)))
            else
                throw(ParseError("Unknown escape \\$e", lineno, i, _MIME_NT()))
            end
        elseif c == '"'
            break
        else
            write(buf, c)
        end
        i += 1
    end
    i > length(s) && throw(ParseError("Unterminated literal", lineno, pos, _MIME_NT()))
    # i now points at closing quote
    lexical = String(take!(buf))
    i += 1  # move past '"'
    # Parse suffix: @lang or ^^<iri>
    if i <= length(s) && s[i] == '@'
        j = i + 1
        while j <= length(s) && !isspace(s[j]) && s[j] != '.'
            j += 1
        end
        lang = s[i+1:j-1]
        return Literal(lexical; lang=lang), j
    elseif i + 1 <= length(s) && s[i] == '^' && s[i+1] == '^'
        iri, next_pos = _parse_nt_iri(s, i + 2, lineno)
        # Simple literal with xsd:string datatype is already the default,
        # but parsers MUST normalize simple literals to xsd:string per spec.
        dt = iri == _XSD_STRING ? _XSD_STRING : iri
        return Literal(lexical, dt), next_pos
    else
        # Plain literal → xsd:string per RDF 1.1
        return Literal(lexical, _XSD_STRING), i
    end
end

function _unescape_iri(s::AbstractString)
    # IRIs in N-Triples: only \uXXXX and \UXXXXXXXX escapes allowed
    occursin('\\', s) || return String(s)
    buf = IOBuffer()
    i = firstindex(s)
    while i <= lastindex(s)
        c = s[i]
        if c == '\\' && i < lastindex(s)
            ni = nextind(s, i)
            e = s[ni]
            if e == 'u' && ni + 4 <= lastindex(s)
                hex = s[ni+1:ni+4]; i = ni + 4
                write(buf, Char(parse(UInt16, hex; base=16)))
            elseif e == 'U' && ni + 8 <= lastindex(s)
                hex = s[ni+1:ni+8]; i = ni + 8
                write(buf, Char(parse(UInt32, hex; base=16)))
            else
                write(buf, c); i = ni - 1  # will be advanced below
            end
        else
            write(buf, c)
        end
        i = i <= lastindex(s) ? nextind(s, i) : i + 1
    end
    String(take!(buf))
end

# File convenience — format detected from extension.
# Named rdf_read to avoid shadowing Base.read(path) which Julia uses internally.
function rdf_read(path::AbstractString)::Union{Graph, Dataset}
    if endswith(path, ".nt")
        return open(io -> Base.read(io, _MIME_NT(), Graph), path)
    elseif endswith(path, ".nq")
        return open(io -> Base.read(io, MIME"application/n-quads"(), Dataset), path)
    end
    error("Cannot detect RDF format from extension: $path")
end

function rdf_write(path::AbstractString, g::Graph)
    open(path, "w") do io; Base.write(io, _MIME_NT(), g); end
end

function rdf_write(path::AbstractString, ds::Dataset)
    open(path, "w") do io; Base.write(io, MIME"application/n-quads"(), ds); end
end
