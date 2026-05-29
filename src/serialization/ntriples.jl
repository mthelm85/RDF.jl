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

_write_subject(io, iri::IRI)       = _write_iri(io, iri)
_write_subject(io, bn::BlankNode)  = _write_blank(io, bn)
_write_subject(io, tt::TripleTerm) = _write_triple_term(io, tt)
_write_object(io, iri::IRI)       = _write_iri(io, iri)
_write_object(io, bn::BlankNode)  = _write_blank(io, bn)
_write_object(io, lit::Literal)   = _write_literal(io, lit)
_write_object(io, tt::TripleTerm) = _write_triple_term(io, tt)

function _write_triple_term(io, tt::TripleTerm)
    print(io, "<<(")
    _write_subject(io, tt.subject)
    print(io, ' ')
    _write_iri(io, tt.predicate)
    print(io, ' ')
    _write_object(io, tt.object)
    print(io, ")>>")
end

_write_iri(io, iri::IRI)      = print(io, '<', iri.value, '>')
_write_blank(io, bn::BlankNode) = print(io, "_:b", bn.id)

function _write_literal(io, lit::Literal)
    print(io, '"')
    for c in lit.lexical_form
        if c == '"';  print(io, "\\\"")
        elseif c == '\\'; print(io, "\\\\")
        elseif c == '\n'; print(io, "\\n")
        elseif c == '\r'; print(io, "\\r")
        elseif c == '\t'; print(io, "\\t")
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

    # Collect interned IDs as we parse, deferring hexastore insertion until the
    # end so all six index arrays can be built with a single sort rather than
    # N individual sorted inserts (O(n log n) vs O(n²)).
    tuples = NTuple{3,UInt32}[]

    for line in eachline(io)
        lineno += 1
        line = strip(line)
        (isempty(line) || line[1] == '#') && continue
        t = _parse_nt_line(line, lineno, blank_map)
        t === nothing && continue
        s_id = _intern!(t.subject)
        p_id = _intern!(t.predicate)
        o_id = _intern!(t.object)
        push!(tuples, (s_id, p_id, o_id))
        _collect_blank_ids!(g.blank_nodes, t.subject)
        _collect_blank_ids!(g.blank_nodes, t.object)
    end

    _hexa_bulk_insert!(g.store, tuples)
    g._size = length(g.store.spo)
    g
end

function Base.read(path::AbstractString, ::_MIME_NT, ::Type{Graph})::Graph
    open(path, "r") do io
        read(io, _MIME_NT(), Graph)
    end
end

"""
    parse_triples(f, io, mime)
    parse_triples(io, mime) → iterator

Streaming triple parser. Calls `f(triple)` for each parsed triple without
materializing a `Graph`, minimising allocations for large files.

```julia
# Callback form — processes each triple immediately
parse_triples(io, MIME"application/n-triples"()) do t
    println(t.subject)
end

# Iterator form — lazy, pull-based
for t in parse_triples(io, MIME"application/n-triples"())
    process(t)
end
```

Currently supported MIME types: `application/n-triples`.
"""
function parse_triples(f::Function, io::IO, mime::_MIME_NT)
    blank_map = Dict{String, BlankNode}()
    lineno = 0
    for line in eachline(io)
        lineno += 1
        line = strip(line)
        (isempty(line) || startswith(line, "#")) && continue
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
        (isempty(s) || startswith(s, "#")) && (state = next_state; continue)
        t = _parse_nt_line(s, it.lineno[], it.blank_map)
        t !== nothing && return (t, next_state)
        state = next_state
    end
end

Base.eltype(::Type{<:_NTriplesIterator}) = Triple
Base.IteratorSize(::Type{<:_NTriplesIterator}) = Base.SizeUnknown()

# ── N-Triples line parser ─────────────────────────────────────────────────────

function _strip_inline_comment(s::AbstractString)
    in_iri = false; in_lit = false; escaped = false
    for (i, c) in pairs(s)
        if escaped;            escaped = false
        elseif c == '\\' && in_lit; escaped = true
        elseif c == '<'  && !in_lit; in_iri = true
        elseif c == '>'  && in_iri;  in_iri = false
        elseif c == '"'  && !in_iri; in_lit = !in_lit
        elseif c == '#'  && !in_iri && !in_lit
            return rstrip(s[1:prevind(s, i)])
        end
    end
    s
end

function _parse_nt_line(line::AbstractString, lineno::Int, blank_map::Dict{String,BlankNode})
    line = _strip_inline_comment(strip(line))
    endswith(line, '.') || throw(ParseError("Missing trailing '.'", lineno, length(line), _MIME_NT()))
    line = strip(line[1:end-1])

    pos = 1
    subj, pos = _parse_nt_subject(line, pos, lineno, blank_map)
    pos = _skip_ws(line, pos)
    pred, pos = _parse_nt_iri(line, pos, lineno)
    pos = _skip_ws(line, pos)
    obj, pos  = _parse_nt_object(line, pos, lineno, blank_map)
    pos = _skip_ws(line, pos)
    pos <= lastindex(line) && throw(ParseError("Unexpected content after object", lineno, pos, _MIME_NT()))
    Triple(subj, pred, obj)
end

function _skip_ws(s, pos)
    while pos <= lastindex(s) && isspace(s[pos])
        pos += 1
    end
    pos
end

function _parse_nt_iri(s, pos, lineno)
    pos <= lastindex(s) && s[pos] == '<' || throw(ParseError("Expected IRI", lineno, pos, _MIME_NT()))
    close = _find_close(s, pos + 1, '>')
    close === nothing && throw(ParseError("Unterminated IRI", lineno, pos, _MIME_NT()))
    raw = s[pos+1:prevind(s, close)]
    iri = try
        IRI(_unescape_iri(raw))
    catch e
        e isa IRIError && throw(ParseError("Invalid IRI: $(e.value)", lineno, pos, _MIME_NT()))
        rethrow()
    end
    iri, close + 1
end

function _find_close(s, from, ch)
    i = from
    lim = lastindex(s)
    while i <= lim
        if s[i] == '\\' && ch != '\\'
            i += 2
        elseif s[i] == ch
            return i
        else
            i = nextind(s, i)
        end
    end
    nothing
end

function _parse_nt_subject(s, pos, lineno, blank_map)
    pos <= lastindex(s) || throw(ParseError("Unexpected end of line", lineno, pos, _MIME_NT()))
    # RDF 1.2 N-Triples: subject must be IRI or blank node — TripleTerm (<<( )>>) is
    # only valid in object position.
    s[pos] == '<' && return _parse_nt_iri(s, pos, lineno)
    s[pos] == '_' && return _parse_nt_blank(s, pos, lineno, blank_map)
    throw(ParseError("Expected subject (IRI or blank node)", lineno, pos, _MIME_NT()))
end

function _parse_nt_object(s, pos, lineno, blank_map)
    pos <= lastindex(s) || throw(ParseError("Unexpected end of line", lineno, pos, _MIME_NT()))
    if s[pos] == '<'
        if pos + 1 <= lastindex(s) && s[pos+1] == '<'
            # RDF 1.2 triple term: must use <<( ... )>> syntax
            pos + 2 <= lastindex(s) && s[pos+2] == '(' ||
                throw(ParseError("Invalid triple term syntax; RDF 1.2 requires <<( ... )>>", lineno, pos, _MIME_NT()))
            return _parse_nt_triple_term(s, pos, lineno, blank_map)
        end
        return _parse_nt_iri(s, pos, lineno)
    end
    s[pos] == '_' && return _parse_nt_blank(s, pos, lineno, blank_map)
    s[pos] == '"' && return _parse_nt_literal(s, pos, lineno, blank_map)
    throw(ParseError("Expected object (IRI, blank node, or literal)", lineno, pos, _MIME_NT()))
end

function _parse_nt_triple_term(s, pos, lineno, blank_map)
    # Expects <<( at current pos
    (pos + 2 <= lastindex(s) && s[pos] == '<' && s[pos+1] == '<' && s[pos+2] == '(') ||
        throw(ParseError("Expected '<<('", lineno, pos, _MIME_NT()))
    pos += 3  # skip '<<('
    pos = _skip_ws(s, pos)

    # Subject: IRI, BlankNode, or nested TripleTerm
    subj, pos = _parse_nt_subject(s, pos, lineno, blank_map)
    pos = _skip_ws(s, pos)

    # Predicate: IRI only
    pred, pos = _parse_nt_iri(s, pos, lineno)
    pos = _skip_ws(s, pos)

    # Object: IRI, BlankNode, Literal, or nested TripleTerm
    obj, pos = _parse_nt_object(s, pos, lineno, blank_map)
    pos = _skip_ws(s, pos)

    # Closing ')>>'
    (pos + 2 <= lastindex(s) && s[pos] == ')' && s[pos+1] == '>' && s[pos+2] == '>') ||
        throw(ParseError("Expected ')>>'", lineno, pos, _MIME_NT()))
    pos += 3

    TripleTerm(subj, pred, obj), pos
end

function _parse_nt_blank(s, pos, lineno, blank_map)
    startswith(s[pos:end], "_:") || throw(ParseError("Expected blank node", lineno, pos, _MIME_NT()))
    # '_' and ':' are ASCII so pos+2 is a valid character boundary
    i = pos + 2
    while i <= lastindex(s)
        c = s[i]
        (isspace(c) || c == '.' || c == '<' || c == '>' || c == '"' ||
         c == '^' || c == ',' || c == ';' || c == '#' || c == ')') && break
        i = nextind(s, i)   # character-safe advance (blank node labels may contain non-ASCII)
    end
    label_end = i > lastindex(s) ? lastindex(s) : prevind(s, i)
    label = s[pos+2:label_end]
    isempty(label) && throw(ParseError("Empty blank node label", lineno, pos, _MIME_NT()))
    fc = label[1]
    (isletter(fc) || isdigit(fc) || fc == '_' || UInt32(fc) > 0x7F) ||
        throw(ParseError("Invalid blank node label: $label", lineno, pos, _MIME_NT()))
    any(c -> c == ':' || c == ';' || c == ',', label) &&
        throw(ParseError("Invalid blank node label: $label", lineno, pos, _MIME_NT()))
    bn = get!(blank_map, label) do; _mint_blank_node() end
    bn, i
end

function _parse_nt_literal(s, pos, lineno, blank_map)
    s[pos] == '"' || throw(ParseError("Expected literal", lineno, pos, _MIME_NT()))
    i = pos + 1
    buf = IOBuffer()
    while i <= lastindex(s)
        c = s[i]
        if c == '\\'
            i += 1
            i > lastindex(s) && throw(ParseError("Unexpected end after escape", lineno, i, _MIME_NT()))
            e = s[i]
            if e == 'n';  write(buf, '\n')
            elseif e == 'r'; write(buf, '\r')
            elseif e == 't'; write(buf, '\t')
            elseif e == 'b'; write(buf, '\b')
            elseif e == 'f'; write(buf, '\f')
            elseif e == '"'; write(buf, '"')
            elseif e == '\''; write(buf, '\'')
            elseif e == '\\'; write(buf, '\\')
            elseif e == 'u'
                i + 4 > lastindex(s) && throw(ParseError("Bad \\u escape", lineno, i, _MIME_NT()))
                hex = s[i+1:i+4]; i += 4
                write(buf, Char(parse(UInt16, hex; base=16)))
            elseif e == 'U'
                i + 8 > lastindex(s) && throw(ParseError("Bad \\U escape", lineno, i, _MIME_NT()))
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
        i = nextind(s, i)
    end
    i > lastindex(s) && throw(ParseError("Unterminated literal", lineno, pos, _MIME_NT()))
    lexical = String(take!(buf))
    i = nextind(s, i)  # move past '"'
    # Skip optional whitespace (RDF 1.2 allows whitespace before @lang or ^^)
    i = _skip_ws(s, i)
    # Parse suffix: @lang[--dir] or ^^<iri>
    if i <= lastindex(s) && s[i] == '@'
        j = i + 1
        while j <= lastindex(s) && !isspace(s[j]) && s[j] != '.'
            j = nextind(s, j)
        end
        tag = s[i+1:prevind(s, j)]
        isempty(tag) && throw(ParseError("Empty language tag", lineno, i, _MIME_NT()))
        isletter(tag[1]) || throw(ParseError("Invalid language tag: $tag", lineno, i, _MIME_NT()))
        # RDF 1.2: check for directional tag lang--dir
        dash_range = findfirst("--", tag)
        if dash_range !== nothing
            lang_part = tag[1:first(dash_range)-1]
            dir_part  = tag[last(dash_range)+1:end]
            dir_part in ("ltr", "rtl") ||
                throw(ParseError("Invalid direction '$dir_part'; must be 'ltr' or 'rtl'", lineno, i, _MIME_NT()))
            _validate_lang_primary(lang_part, lineno, i)
            return Literal(lexical, _RDF_DIR_LANGSTRING, lowercase(tag)), j
        else
            _validate_lang_primary(tag, lineno, i)
            return Literal(lexical; lang=tag), j
        end
    elseif i + 1 <= lastindex(s) && s[i] == '^' && s[i+1] == '^'
        iri_start = _skip_ws(s, i + 2)
        iri, next_pos = _parse_nt_iri(s, iri_start, lineno)
        # rdf:langString and rdf:dirLangString cannot be used as explicit datatypes
        iri == _RDF_LANGSTRING &&
            throw(ParseError("rdf:langString requires @lang syntax, not ^^", lineno, i, _MIME_NT()))
        iri == _RDF_DIR_LANGSTRING &&
            throw(ParseError("rdf:dirLangString requires @lang--dir syntax, not ^^", lineno, i, _MIME_NT()))
        return Literal(lexical, iri), next_pos
    else
        return Literal(lexical, _XSD_STRING), i
    end
end

function _validate_lang_primary(tag::AbstractString, lineno::Int, pos::Int)
    primary = let h = findfirst('-', tag)
        h === nothing ? tag : tag[1:h-1]
    end
    1 <= length(primary) <= 8 ||
        throw(ParseError("Invalid BCP47 language subtag '$primary' (must be 1–8 chars)", lineno, pos, _MIME_NT()))
end

function _unescape_iri(s::AbstractString)
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
                throw(IRIError(String(s), "Invalid escape sequence \\$e in IRI"))
            end
        else
            write(buf, c)
        end
        i = i <= lastindex(s) ? nextind(s, i) : i + 1
    end
    String(take!(buf))
end


# ── Convenience I/O ───────────────────────────────────────────────────────────

"""
    rdf_read(path::AbstractString) → Graph | Dataset

Read an RDF file from `path`, choosing the parser by file extension:

| Extension | Format | Return type |
|-----------|--------|-------------|
| `.nt` | N-Triples | `Graph` |
| `.ttl` | Turtle 1.1 | `Graph` |
| `.nq` | N-Quads | `Dataset` |
| `.jsonld`, `.json-ld` | JSON-LD 1.1 | `Dataset` |

For fine-grained control (streaming, base IRI, etc.) use `Base.read(io, mime, T)`
directly.
"""
function rdf_read(path::AbstractString)::Union{Graph, Dataset}
    if endswith(path, ".nt")
        return open(io -> Base.read(io, _MIME_NT(), Graph), path)
    elseif endswith(path, ".nq")
        return open(io -> Base.read(io, MIME"application/n-quads"(), Dataset), path)
    elseif endswith(path, ".ttl")
        return open(io -> Base.read(io, MIME"text/turtle"(), Graph), path)
    elseif endswith(path, ".jsonld") || endswith(path, ".json-ld")
        return open(io -> Base.read(io, MIME"application/ld+json"(), Dataset), path)
    end
    error("Cannot detect RDF format from extension: $path")
end

"""
    rdf_write(path::AbstractString, g::Graph)
    rdf_write(path::AbstractString, ds::Dataset)

Write `g` or `ds` to `path`, choosing the serializer by file extension:

| Extension | Format |
|-----------|--------|
| `.ttl` | Turtle 1.1 |
| `.jsonld`, `.json-ld` | JSON-LD 1.1 |
| anything else | N-Triples (Graph) or N-Quads (Dataset) |
"""
function rdf_write(path::AbstractString, g::Graph)
    if endswith(path, ".ttl")
        open(path, "w") do io; Base.write(io, MIME"text/turtle"(), g); end
    elseif endswith(path, ".jsonld") || endswith(path, ".json-ld")
        open(path, "w") do io; Base.write(io, MIME"application/ld+json"(), g); end
    else
        open(path, "w") do io; Base.write(io, _MIME_NT(), g); end
    end
end

function rdf_write(path::AbstractString, ds::Dataset)
    if endswith(path, ".jsonld") || endswith(path, ".json-ld")
        open(path, "w") do io; Base.write(io, MIME"application/ld+json"(), ds); end
    else
        open(path, "w") do io; Base.write(io, MIME"application/n-quads"(), ds); end
    end
end

# IO-level dispatch: write(io, g) → N-Triples; write(io, ds) → N-Quads.
Base.write(io::IO, g::Graph)    = Base.write(io, _MIME_NT(), g)
Base.write(io::IO, ds::Dataset) = Base.write(io, MIME"application/n-quads"(), ds)

# Path-based writes — explicit so Graph always → N-Triples, Dataset always → N-Quads.
Base.write(path::AbstractString, g::Graph) =
    open(io -> Base.write(io, _MIME_NT(), g), path, "w")
Base.write(path::AbstractString, ds::Dataset) =
    open(io -> Base.write(io, MIME"application/n-quads"(), ds), path, "w")

# Typed path-based reads.
Base.read(path::AbstractString, ::Type{Graph}) =
    open(io -> Base.read(io, _MIME_NT(), Graph), path)
Base.read(path::AbstractString, ::Type{Dataset}) =
    open(io -> Base.read(io, MIME"application/n-quads"(), Dataset), path)

function _read_by_extension(path::AbstractString)
    endswith(path, ".nt") && return Base.read(path, Graph)
    endswith(path, ".nq") && return Base.read(path, Dataset)
    open(io -> Base.read(io), path)
end
