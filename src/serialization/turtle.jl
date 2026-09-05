const _MIME_TTL = MIME"text/turtle"

# RDF vocabulary IRIs used for collection/type shortcuts
const _TTL_RDF_FIRST = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
const _TTL_RDF_REST  = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
const _TTL_RDF_NIL   = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
const _TTL_RDF_TYPE  = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
const _TTL_RDF_REIFIES = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#reifies")

# ── IRI resolution (RFC 3986 §5.2) ───────────────────────────────────────────

# Remove dot segments from a URI path per RFC 3986 §5.2.4.
function _ttl_remove_dots(path::String)::String
    inp = path
    out = ""
    while !isempty(inp)
        if startswith(inp, "../")
            inp = inp[4:end]
        elseif startswith(inp, "./")
            inp = inp[3:end]
        elseif startswith(inp, "/./")
            inp = "/" * inp[4:end]
        elseif inp == "/."
            inp = "/"
        elseif startswith(inp, "/../")
            inp = "/" * inp[5:end]
            idx = findlast('/', out)
            out = idx === nothing ? "" : out[1:idx-1]
        elseif inp == "/.."
            inp = "/"
            idx = findlast('/', out)
            out = idx === nothing ? "" : out[1:idx-1]
        elseif inp == "." || inp == ".."
            inp = ""
        else
            if startswith(inp, "/")
                out *= "/"; inp = inp[2:end]
            end
            ns = findfirst('/', inp)
            if ns === nothing
                out *= inp; inp = ""
            else
                out *= inp[1:ns-1]; inp = inp[ns:end]
            end
        end
    end
    out
end

# Parse a URI into (scheme, authority, path, query, fragment).
# authority is Nothing when "//" is absent, or a String (possibly "") when present.
# fragment is Nothing if '#' is absent, or a String (possibly "") if '#' is present.
function _ttl_parse_uri_comps(uri::String)
    s = uri
    scheme    = ""
    authority = nothing   # Nothing = no "//" present; "" = "//" with empty authority

    # Detect scheme: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"
    i = firstindex(s); lim = lastindex(s)
    j = i
    while j <= lim && isascii(s[j]) &&
          (isletter(s[j]) || isdigit(s[j]) || s[j] in ('+', '-', '.'))
        j = nextind(s, j)
    end
    if j > i && j <= lim && s[j] == ':'
        scheme = s[i:j-1]; s = s[j+1:end]
    end

    # Detect authority: present when "//" follows the scheme (or at the start).
    if startswith(s, "//")
        s = s[3:end]
        ae = findfirst(c -> c == '/' || c == '?' || c == '#', s)
        if ae !== nothing
            authority = s[1:ae-1]; s = s[ae:end]
        else
            authority = s; s = ""
        end
    end

    # Fragment (Nothing = absent, "" = empty fragment after #)
    frag = nothing
    fi = findfirst('#', s)
    if fi !== nothing
        frag = s[fi+1:end]; s = s[1:fi-1]
    end

    # Query
    query = ""
    qi = findfirst('?', s)
    if qi !== nothing
        query = s[qi+1:end]; s = s[1:qi-1]
    end

    (scheme, authority, s, query, frag)
end

function _ttl_build_uri(scheme, authority, path, query, frag)
    r = ""
    !isempty(scheme)    && (r *= scheme * ":")
    authority !== nothing && (r *= "//" * authority)   # preserve empty authority ("")
    r *= path
    !isempty(query)     && (r *= "?" * query)
    frag !== nothing    && (r *= "#" * frag)
    r
end

# Resolve `ref` against `base` per RFC 3986 §5.2.2.
function _ttl_resolve(base::String, ref::String)::String
    # An empty reference resolves to the base with its fragment stripped
    # (RFC 3986 §5.2.2: R has no fragment ⇒ T.fragment = R.fragment = ∅).
    if isempty(ref)
        fi = findfirst('#', base)
        return fi === nothing ? base : base[1:prevind(base, fi)]
    end
    isempty(base) && return ref
    match(r"^[A-Za-z][A-Za-z0-9+\-.]*:", ref) !== nothing && return ref

    (bs, ba, bp, bq, _bf) = _ttl_parse_uri_comps(base)
    (_rs, ra, rp, rq, rf) = _ttl_parse_uri_comps(ref)

    ra !== nothing && return _ttl_build_uri(bs, ra, _ttl_remove_dots(rp), rq, rf)

    if isempty(rp)
        tq = !isempty(rq) || occursin('?', ref) ? rq : bq
        return _ttl_build_uri(bs, ba, bp, tq, rf)
    end

    tp = if startswith(rp, "/")
        _ttl_remove_dots(rp)
    elseif ba !== nothing && isempty(bp)
        # RFC 3986 §5.2.3 merge: authority with empty path ⇒ prepend "/"
        _ttl_remove_dots("/" * rp)
    else
        idx = findlast('/', bp)
        _ttl_remove_dots(idx !== nothing ? bp[1:idx] * rp : rp)
    end
    _ttl_build_uri(bs, ba, tp, rq, rf)
end

# ── Turtle writer ─────────────────────────────────────────────────────────────

function Base.write(io::IO, ::_MIME_TTL, g::Graph;
                    prefixes::Dict{String,String}=Dict{String,String}(),
                    emit_prefixes::Bool=true)
    # Emit @prefix declarations. TriG writes one header for the whole dataset
    # and then calls this per graph with emit_prefixes=false, so the prefixes
    # still abbreviate IRIs in each body without being redeclared.
    if emit_prefixes
        for (pn, pi) in sort(collect(prefixes), by=first)
            println(io, "@prefix $pn: <$pi> .")
        end
        !isempty(prefixes) && println(io)
    end

    isempty(g) && return nothing

    # Populate the per-term N-Triples string cache.  N-Triples and Turtle share
    # the same surface syntax for every term type:
    #   IRI       → <http://…>
    #   BlankNode → _:b<id>
    #   Literal   → "…"^^<dt> or "…"@lang
    #   TripleTerm→ <<( … )>>   (RDF 1.2)
    # So cache[id] is always valid Turtle output — no reformatting needed.
    _ensure_nt_cache!()
    cache     = _NT_TERM_STRINGS   # local alias — avoids repeated global lookup
    no_prefix = isempty(prefixes)

    # Intern rdf:type for the "a" shorthand (safe: _TTL_RDF_TYPE is a module constant).
    rdf_type_id = _intern!(_TTL_RDF_TYPE)

    # ── Per-ID write helpers ───────────────────────────────────────────────────
    #
    # When no prefixes are in scope every term comes straight from the cache —
    # zero _resolve() calls, zero allocations per triple.
    # When prefixes are provided, IRIs are abbreviated via a linear scan of the
    # prefix table (same cost as the previous implementation).

    function _write_iri_id(id::UInt32)
        if no_prefix
            @inbounds write(io, cache[id])
        else
            iri = _resolve(id)::IRI
            best_len = 0; best_pn = ""
            for (pn, pi) in prefixes
                if startswith(iri.value, pi) && length(pi) > best_len
                    best_len = length(pi); best_pn = pn
                end
            end
            if best_len > 0
                write(io, best_pn); write(io, ':')
                write(io, iri.value[best_len+1:end])
            else
                @inbounds write(io, cache[id])
            end
        end
    end

    function _write_subj_id(id::UInt32)
        if no_prefix
            @inbounds write(io, cache[id])
        else
            term = _resolve(id)
            term isa IRI ? _write_iri_id(id) : @inbounds write(io, cache[id])
        end
    end

    function _write_pred_id(id::UInt32)
        id == rdf_type_id && (write(io, 'a'); return)
        no_prefix ? (@inbounds write(io, cache[id])) : _write_iri_id(id)
    end

    function _write_obj_id(id::UInt32)
        if no_prefix
            @inbounds write(io, cache[id])
        else
            term = _resolve(id)
            term isa IRI ? _write_iri_id(id) : @inbounds write(io, cache[id])
        end
    end

    # ── Single-pass streaming write ────────────────────────────────────────────
    #
    # The SPO hexastore index is sorted by (s_id, p_id, o_id).  That means all
    # triples for the same subject are contiguous, and within a subject all
    # triples for the same predicate are sub-contiguous.  We exploit this to emit
    # a fully-grouped Turtle serialisation in a single O(n) pass with O(1) extra
    # memory — no Dict accumulation, no Vector-of-pairs, no collect().
    #
    # Output format (same as the previous grouped implementation):
    #
    #   <s1> <p1> <o1>, <o2> ;
    #    <p2> <o3> .
    #   <s2> a <o4> .

    prev_s_id = UInt32(0)
    prev_p_id = UInt32(0)

    for (s_id, p_id, o_id) in eachid(g)
        if s_id != prev_s_id
            # ── New subject block ──────────────────────────────────────────────
            prev_s_id != UInt32(0) && write(io, " .\n")
            _write_subj_id(s_id)
            write(io, ' ')
            _write_pred_id(p_id)
            write(io, ' ')
            _write_obj_id(o_id)
            prev_s_id = s_id
            prev_p_id = p_id
        elseif p_id != prev_p_id
            # ── New predicate within same subject ──────────────────────────────
            write(io, " ;\n ")
            _write_pred_id(p_id)
            write(io, ' ')
            _write_obj_id(o_id)
            prev_p_id = p_id
        else
            # ── Additional object for same (subject, predicate) ────────────────
            write(io, ", ")
            _write_obj_id(o_id)
        end
    end
    prev_s_id != UInt32(0) && write(io, " .\n")
    return nothing
end

# ── Parser struct ─────────────────────────────────────────────────────────────

mutable struct _TurtleParser
    s::String
    pos::Int        # current byte position (valid code-unit start, or len+1 for EOF)
    len::Int        # ncodeunits(s)
    lineno::Int
    base::String
    prefixes::Dict{String,String}
    blank_map::Dict{String,BlankNode}
    triples::Vector{Triple}
end

_TurtleParser(s::String, base::String) =
    _TurtleParser(s, 1, ncodeunits(s), 1, base,
                  Dict{String,String}(), Dict{String,BlankNode}(), Triple[])

@inline _ttl_eof(p::_TurtleParser) = p.pos > p.len

function _ttl_error(p::_TurtleParser, msg::AbstractString)
    throw(ParseError(msg, p.lineno, p.pos, _MIME_TTL()))
end

@inline function _ttl_peek(p::_TurtleParser)::Char
    p.pos > p.len ? '\0' : @inbounds p.s[p.pos]
end

function _ttl_peek_at(p::_TurtleParser, offset::Int)::Char
    pos = p.pos
    for _ in 1:offset
        pos > p.len && return '\0'
        pos = nextind(p.s, pos)
    end
    pos > p.len ? '\0' : @inbounds p.s[pos]
end

function _ttl_advance!(p::_TurtleParser)::Char
    p.pos > p.len && _ttl_error(p, "Unexpected end of input")
    c = @inbounds p.s[p.pos]
    p.pos = nextind(p.s, p.pos)
    c == '\n' && (p.lineno += 1)
    c
end

function _ttl_skip!(p::_TurtleParser)
    while !_ttl_eof(p)
        c = _ttl_peek(p)
        if c == ' ' || c == '\t' || c == '\r' || c == '\n'
            _ttl_advance!(p)
        elseif c == '#'
            while !_ttl_eof(p) && _ttl_peek(p) != '\n'; _ttl_advance!(p); end
        else
            break
        end
    end
end

function _ttl_expect_char!(p::_TurtleParser, c::Char)
    _ttl_eof(p) && _ttl_error(p, "Expected '$c' but got EOF")
    got = _ttl_peek(p)
    got == c || _ttl_error(p, "Expected '$c' but got '$got'")
    _ttl_advance!(p)
end

# ── PN_CHARS ──────────────────────────────────────────────────────────────────

function _is_pn_chars_base(c::AbstractChar)::Bool
    cp = UInt32(c)
    ('A' <= c <= 'Z') || ('a' <= c <= 'z') ||
    (0x00C0 <= cp <= 0x00D6) || (0x00D8 <= cp <= 0x00F6) ||
    (0x00F8 <= cp <= 0x02FF) || (0x0370 <= cp <= 0x037D) ||
    (0x037F <= cp <= 0x1FFF) || (0x200C <= cp <= 0x200D) ||
    (0x2070 <= cp <= 0x218F) || (0x2C00 <= cp <= 0x2FEF) ||
    (0x3001 <= cp <= 0xD7FF) || (0xF900 <= cp <= 0xFDCF) ||
    (0xFDF0 <= cp <= 0xFFFD) || (0x10000 <= cp <= 0xEFFFF)
end

@inline _is_pn_chars_u(c::AbstractChar)::Bool = _is_pn_chars_base(c) || c == '_'

function _is_pn_chars(c::AbstractChar)::Bool
    cp = UInt32(c)
    _is_pn_chars_u(c) || c == '-' || isdigit(c) ||
    cp == 0x00B7 || (0x0300 <= cp <= 0x036F) || (0x203F <= cp <= 0x2040)
end

# Characters forbidden in IRIREF (both literal and after \u/\U unescape)
function _ttl_iriref_forbidden(c::AbstractChar)::Bool
    cp = UInt32(c)
    cp <= 0x20 || c == '<' || c == '>' || c == '"' ||
    c == '{' || c == '}' || c == '|' || c == '^' || c == '`' || c == '\\'
end

# ── Hex escape ────────────────────────────────────────────────────────────────

function _ttl_parse_hex_escape!(p::_TurtleParser, n::Int)::UInt32
    val = UInt32(0)
    for _ in 1:n
        _ttl_eof(p) && _ttl_error(p, "Incomplete hex escape")
        c = _ttl_peek(p); _ttl_advance!(p)
        isxdigit(c) || _ttl_error(p, "Invalid hex digit '$c'")
        val = val * 16 + (c <= '9' ? UInt32(c) - UInt32('0') :
                          c <= 'F' ? UInt32(c) - UInt32('A') + 10 :
                                     UInt32(c) - UInt32('a') + 10)
    end
    val
end

# ── IRIREF ────────────────────────────────────────────────────────────────────

function _ttl_parse_iriref!(p::_TurtleParser)::IRI
    _ttl_expect_char!(p, '<')
    buf = IOBuffer()
    while true
        _ttl_eof(p) && _ttl_error(p, "Unterminated IRI reference")
        c = _ttl_peek(p)
        if c == '>'
            _ttl_advance!(p); break
        elseif c == '\\'
            _ttl_advance!(p)
            _ttl_eof(p) && _ttl_error(p, "Unterminated escape in IRI")
            e = _ttl_peek(p); _ttl_advance!(p)
            if e == 'u'
                cp = _ttl_parse_hex_escape!(p, 4)
                uc = _ttl_checked_codepoint(p, cp)
                _ttl_iriref_forbidden(uc) &&
                    _ttl_error(p, "Forbidden char U+$(string(cp; base=16, pad=4)) in IRI")
                write(buf, uc)
            elseif e == 'U'
                cp = _ttl_parse_hex_escape!(p, 8)
                uc = _ttl_checked_codepoint(p, cp)
                _ttl_iriref_forbidden(uc) &&
                    _ttl_error(p, "Forbidden char U+$(string(cp; base=16, pad=8)) in IRI")
                write(buf, uc)
            else
                _ttl_error(p, "Invalid IRI escape '\\$e'")
            end
        else
            _ttl_iriref_forbidden(c) && _ttl_error(p, "Forbidden char '$c' in IRI")
            write(buf, c); _ttl_advance!(p)
        end
    end
    raw = String(take!(buf))
    resolved = _ttl_resolve(p.base, raw)
    try
        IRI(resolved)
    catch e
        e isa IRIError && _ttl_error(p, "Invalid IRI '$resolved'")
        rethrow()
    end
end

# ── Prefix name (PN_PREFIX) ───────────────────────────────────────────────────

function _ttl_parse_pname_ns!(p::_TurtleParser)::String
    _ttl_eof(p) && return ""
    _is_pn_chars_base(_ttl_peek(p)) || return ""
    buf = IOBuffer()
    write(buf, _ttl_peek(p)); _ttl_advance!(p)
    while !_ttl_eof(p)
        c = _ttl_peek(p)
        (_is_pn_chars(c) || c == '.') || break
        write(buf, c); _ttl_advance!(p)
    end
    result = String(take!(buf))
    n = length(result) - length(rstrip(result, '.'))
    if n > 0; result = result[1:end-n]; p.pos -= n; end
    result
end

# ── Local name (PN_LOCAL) ─────────────────────────────────────────────────────

function _ttl_parse_pn_local!(p::_TurtleParser)::String
    buf = IOBuffer()
    _ttl_parse_pn_local_char!(p, buf, true) || return ""
    while _ttl_parse_pn_local_char!(p, buf, false); end
    result = String(take!(buf))
    n = length(result) - length(rstrip(result, '.'))
    if n > 0; result = result[1:end-n]; p.pos -= n; end
    result
end

function _ttl_parse_pn_local_char!(p::_TurtleParser, buf::IOBuffer, is_first::Bool)::Bool
    _ttl_eof(p) && return false
    c = _ttl_peek(p)
    if c == '%'
        p2 = nextind(p.s, p.pos); p2 > p.len && return false
        p3 = nextind(p.s, p2);    p3 > p.len && return false
        h1 = @inbounds p.s[p2]; h2 = @inbounds p.s[p3]
        (isxdigit(h1) && isxdigit(h2)) || _ttl_error(p, "Invalid percent-escape in local name")
        write(buf, '%', h1, h2)
        _ttl_advance!(p); _ttl_advance!(p); _ttl_advance!(p)
        return true
    elseif c == '\\'
        p2 = nextind(p.s, p.pos); p2 > p.len && return false
        nc = @inbounds p.s[p2]
        nc in "_~.-!\$&'()*+,;=/?#@%" || return false
        write(buf, nc); _ttl_advance!(p); _ttl_advance!(p)
        return true
    elseif is_first
        (_is_pn_chars_u(c) || c == ':' || isdigit(c)) || return false
        write(buf, c); _ttl_advance!(p); return true
    else
        (_is_pn_chars(c) || c == '.' || c == ':') || return false
        write(buf, c); _ttl_advance!(p); return true
    end
end

# ── Blank node label ──────────────────────────────────────────────────────────

function _ttl_parse_blank_node_label!(p::_TurtleParser)::BlankNode
    _ttl_advance!(p)           # '_'
    _ttl_expect_char!(p, ':')
    _ttl_eof(p) && _ttl_error(p, "Empty blank node label")
    c = _ttl_peek(p)
    (_is_pn_chars_u(c) || isdigit(c)) || _ttl_error(p, "Invalid blank node label start '$c'")
    buf = IOBuffer()
    write(buf, c); _ttl_advance!(p)
    while !_ttl_eof(p)
        c = _ttl_peek(p)
        (_is_pn_chars(c) || c == '.') || break
        write(buf, c); _ttl_advance!(p)
    end
    label = String(take!(buf))
    n = length(label) - length(rstrip(label, '.'))
    if n > 0; label = label[1:end-n]; p.pos -= n; end
    isempty(label) && _ttl_error(p, "Empty blank node label")
    get!(p.blank_map, label) do; _mint_blank_node() end
end

# ── String literal ────────────────────────────────────────────────────────────

function _ttl_unescape_char!(p::_TurtleParser, buf::IOBuffer)
    _ttl_eof(p) && _ttl_error(p, "Unterminated escape")
    e = _ttl_peek(p); _ttl_advance!(p)
    if     e == 't';  write(buf, '\t')
    elseif e == 'b';  write(buf, '\b')
    elseif e == 'n';  write(buf, '\n')
    elseif e == 'r';  write(buf, '\r')
    elseif e == 'f';  write(buf, '\f')
    elseif e == '"';  write(buf, '"')
    elseif e == '\''; write(buf, '\'')
    elseif e == '\\'; write(buf, '\\')
    elseif e == 'u';  write(buf, _ttl_checked_codepoint(p, _ttl_parse_hex_escape!(p, 4)))
    elseif e == 'U';  write(buf, _ttl_checked_codepoint(p, _ttl_parse_hex_escape!(p, 8)))
    else   _ttl_error(p, "Unknown string escape '\\$e'")
    end
end

# Surrogate code points (U+D800–U+DFFF) are not Unicode scalar values and are
# forbidden in \\u/\\U escapes — including "paired" surrogates (Turtle is not
# UTF-16; supplementary characters use \\U or direct UTF-8).
function _ttl_checked_codepoint(p::_TurtleParser, cp::UInt32)::Char
    0xD800 <= cp <= 0xDFFF &&
        _ttl_error(p, "Surrogate code point U+$(string(cp, base=16, pad=4)) is not allowed in string escapes")
    cp > 0x10FFFF &&
        _ttl_error(p, "Code point out of Unicode range in string escape")
    Char(cp)
end

function _ttl_parse_short_string!(p::_TurtleParser, delim::Char)::String
    _ttl_advance!(p)
    buf = IOBuffer()
    while true
        _ttl_eof(p) && _ttl_error(p, "Unterminated string literal")
        c = _ttl_peek(p)
        if   c == delim;            _ttl_advance!(p); break
        elseif c == '\\';          _ttl_advance!(p); _ttl_unescape_char!(p, buf)
        elseif c == '\n' || c == '\r'
            _ttl_error(p, "Newline not allowed in short string literal")
        else write(buf, c); _ttl_advance!(p)
        end
    end
    String(take!(buf))
end

function _ttl_parse_long_string!(p::_TurtleParser, delim::Char)::String
    _ttl_advance!(p); _ttl_advance!(p); _ttl_advance!(p)   # opening triple
    buf = IOBuffer()
    while true
        _ttl_eof(p) && _ttl_error(p, "Unterminated long string literal")
        c = _ttl_peek(p)
        if c == delim
            _ttl_advance!(p)
            if !_ttl_eof(p) && _ttl_peek(p) == delim
                _ttl_advance!(p)
                if !_ttl_eof(p) && _ttl_peek(p) == delim
                    _ttl_advance!(p); break        # closing triple
                else
                    write(buf, delim, delim)       # two-quote sequence in content
                end
            else
                write(buf, delim)                  # single quote in content
            end
        elseif c == '\\'
            _ttl_advance!(p); _ttl_unescape_char!(p, buf)
        else
            write(buf, c); _ttl_advance!(p)
        end
    end
    String(take!(buf))
end

function _ttl_parse_literal!(p::_TurtleParser)::Literal
    c = _ttl_peek(p)
    lexical = if c == '"'
        _ttl_peek_at(p,1) == '"' && _ttl_peek_at(p,2) == '"' ?
            _ttl_parse_long_string!(p, '"') : _ttl_parse_short_string!(p, '"')
    elseif c == '\''
        _ttl_peek_at(p,1) == '\'' && _ttl_peek_at(p,2) == '\'' ?
            _ttl_parse_long_string!(p, '\'') : _ttl_parse_short_string!(p, '\'')
    else
        _ttl_error(p, "Expected string literal")
    end

    c2 = _ttl_peek(p)
    if c2 == '@'
        _ttl_advance!(p)
        (!_ttl_eof(p) && isletter(_ttl_peek(p))) || _ttl_error(p, "Invalid language tag")
        buf = IOBuffer()
        while !_ttl_eof(p)
            c3 = _ttl_peek(p)
            (isletter(c3) || isdigit(c3) || c3 == '-') || break
            write(buf, c3); _ttl_advance!(p)
        end
        tag = String(take!(buf))
        isempty(tag) && _ttl_error(p, "Empty language tag")
        # RDF 1.2 directional language tag: lang--dir, dir ∈ {ltr, rtl}
        # (lowercase only, per the LANG_DIR production)
        dd = findfirst("--", tag)
        if dd !== nothing
            lang = tag[1:first(dd)-1]
            dir  = tag[last(dd)+1:end]
            isempty(lang) && _ttl_error(p, "Empty language part in directional language tag")
            dir in ("ltr", "rtl") ||
                _ttl_error(p, "Base direction must be 'ltr' or 'rtl' (lowercase), got '$dir'")
            Literal(lexical; lang=lang, dir=dir)
        else
            Literal(lexical; lang=tag)
        end
    elseif c2 == '^' && _ttl_peek_at(p,1) == '^'
        _ttl_advance!(p); _ttl_advance!(p)
        _ttl_skip!(p)
        dt = _ttl_peek(p) == '<' ? _ttl_parse_iriref!(p) : _ttl_parse_prefixed_name!(p)
        (dt == _RDF_LANGSTRING || dt == _RDF_DIR_LANGSTRING) &&
            _ttl_error(p, "rdf:langString/dirLangString cannot be used with ^^")
        Literal(lexical, dt)
    else
        Literal(lexical, _XSD_STRING, "")
    end
end

# ── Numeric literal ───────────────────────────────────────────────────────────

function _ttl_parse_numeric!(p::_TurtleParser)::Literal
    buf = IOBuffer()
    c = _ttl_peek(p)
    if c == '+' || c == '-'
        write(buf, c); _ttl_advance!(p)
        c = _ttl_eof(p) ? '\0' : _ttl_peek(p)
        (isdigit(c) || (c == '.' && isdigit(_ttl_peek_at(p,1)))) ||
            _ttl_error(p, "Expected digit after sign in numeric literal")
    end

    is_decimal = false; is_double = false

    while !_ttl_eof(p) && isdigit(_ttl_peek(p))
        write(buf, _ttl_peek(p)); _ttl_advance!(p)
    end

    c = _ttl_eof(p) ? '\0' : _ttl_peek(p)
    # Enter decimal/double branch if dot is followed by a digit OR an exponent marker
    # (e.g. 123.E+1 is a valid double with zero fractional digits)
    nc1 = _ttl_peek_at(p, 1)
    if c == '.' && (isdigit(nc1) || nc1 == 'e' || nc1 == 'E')
        write(buf, '.'); _ttl_advance!(p); is_decimal = true
        while !_ttl_eof(p) && isdigit(_ttl_peek(p))
            write(buf, _ttl_peek(p)); _ttl_advance!(p)
        end
        c = _ttl_eof(p) ? '\0' : _ttl_peek(p)
    end

    if c == 'e' || c == 'E'
        write(buf, c); _ttl_advance!(p); is_double = true; is_decimal = false
        c = _ttl_eof(p) ? '\0' : _ttl_peek(p)
        if c == '+' || c == '-'
            write(buf, c); _ttl_advance!(p)
        end
        (!_ttl_eof(p) && isdigit(_ttl_peek(p))) ||
            _ttl_error(p, "Expected digit in exponent")
        while !_ttl_eof(p) && isdigit(_ttl_peek(p))
            write(buf, _ttl_peek(p)); _ttl_advance!(p)
        end
    end

    # Reject trailing alphabetic chars (e.g., 123abc, 0x1)
    !_ttl_eof(p) && isletter(_ttl_peek(p)) &&
        _ttl_error(p, "Unexpected character after numeric literal")

    lexical = String(take!(buf))
    if is_double;   Literal(lexical, _XSD_DOUBLE,  "")
    elseif is_decimal; Literal(lexical, _XSD_DECIMAL, "")
    else;           Literal(lexical, _XSD_INTEGER, "")
    end
end

# ── Prefixed name (prefix:local) ──────────────────────────────────────────────

function _ttl_parse_prefixed_name!(p::_TurtleParser)::IRI
    pname = _ttl_parse_pname_ns!(p)
    _ttl_peek(p) == ':' || _ttl_error(p,
        isempty(pname) ? "Expected ':' for default prefix" :
                         "Expected ':' after prefix '$pname'")
    _ttl_advance!(p)
    local_part = _ttl_parse_pn_local!(p)
    haskey(p.prefixes, pname) ||
        _ttl_error(p, isempty(pname) ? "Default prefix ':' not declared" :
                                       "Prefix '$pname' not declared")
    IRI(p.prefixes[pname] * local_part)
end

# ── Blank node property list ──────────────────────────────────────────────────

function _ttl_parse_bnode_proplist!(p::_TurtleParser)::BlankNode
    _ttl_expect_char!(p, '[')
    _ttl_skip!(p)
    bn = _mint_blank_node()
    if _ttl_peek(p) != ']'
        _ttl_parse_po_list!(p, bn)
        _ttl_skip!(p)
    end
    _ttl_expect_char!(p, ']')
    bn
end

# ── Collection ────────────────────────────────────────────────────────────────

function _ttl_parse_collection!(p::_TurtleParser)::Union{IRI,BlankNode}
    _ttl_expect_char!(p, '(')
    _ttl_skip!(p)
    if _ttl_peek(p) == ')'; _ttl_advance!(p); return _TTL_RDF_NIL; end

    head = _mint_blank_node(); cur = head
    while true
        item = _ttl_parse_object_term!(p)
        push!(p.triples, Triple(cur, _TTL_RDF_FIRST, item))
        _ttl_skip!(p)
        if _ttl_peek(p) == ')'
            push!(p.triples, Triple(cur, _TTL_RDF_REST, _TTL_RDF_NIL)); break
        else
            nxt = _mint_blank_node()
            push!(p.triples, Triple(cur, _TTL_RDF_REST, nxt))
            cur = nxt
        end
    end
    _ttl_advance!(p)   # ')'
    head
end

# ── Object term ───────────────────────────────────────────────────────────────

function _ttl_parse_object_term!(p::_TurtleParser)::ObjectTerm
    _ttl_skip!(p)
    c = _ttl_peek(p)
    if c == '<'
        if _ttl_peek_at(p, 1) == '<'
            # '<<(' → triple term; '<<' → reified triple (RDF 1.2)
            return _ttl_peek_at(p, 2) == '(' ?
                _ttl_parse_triple_term!(p) : _ttl_parse_reified_triple!(p)
        end
        return _ttl_parse_iriref!(p)
    elseif c == '"' || c == '\''
        return _ttl_parse_literal!(p)
    elseif c == '_' && _ttl_peek_at(p,1) == ':'
        return _ttl_parse_blank_node_label!(p)
    elseif c == '['
        return _ttl_parse_bnode_proplist!(p)
    elseif c == '('
        return _ttl_parse_collection!(p)
    elseif c == 't' && _ttl_check_keyword(p, "true")
        for _ in 1:4; _ttl_advance!(p); end
        return Literal("true",  _XSD_BOOLEAN, "")
    elseif c == 'f' && _ttl_check_keyword(p, "false")
        for _ in 1:5; _ttl_advance!(p); end
        return Literal("false", _XSD_BOOLEAN, "")
    elseif c == '+' || c == '-' || isdigit(c)
        return _ttl_parse_numeric!(p)
    elseif c == '.'
        isdigit(_ttl_peek_at(p,1)) || _ttl_error(p, "Unexpected '.'")
        return _ttl_parse_numeric!(p)
    else
        return _ttl_parse_prefixed_name!(p)
    end
end

# ── Keyword check ─────────────────────────────────────────────────────────────

function _ttl_check_keyword(p::_TurtleParser, kw::String)::Bool
    for (i, kc) in enumerate(kw)
        _ttl_peek_at(p, i-1) == kc || return false
    end
    c_after = _ttl_peek_at(p, length(kw))
    !(_is_pn_chars(c_after) || c_after == ':')
end

# ── Predicate ────────────────────────────────────────────────────────────────

function _ttl_is_type_keyword(p::_TurtleParser)::Bool
    c2 = _ttl_peek_at(p, 1)
    !(_is_pn_chars(c2) || c2 == ':' || c2 == '.')
end

function _ttl_parse_predicate!(p::_TurtleParser)::IRI
    c = _ttl_peek(p)
    if c == 'a' && _ttl_is_type_keyword(p)
        _ttl_advance!(p); return _TTL_RDF_TYPE
    elseif c == '<'
        return _ttl_parse_iriref!(p)
    else
        return _ttl_parse_prefixed_name!(p)
    end
end

# ── Triple term (RDF 1.2) ─────────────────────────────────────────────────────
#
# tripleTerm ::= '<<(' ttSubject verb ttObject ')>>'
# ttSubject  ::= iri | BlankNode
# ttObject   ::= iri | BlankNode | literal | tripleTerm

# '[' WS* ']' — an anonymous blank node (ANON); non-empty property lists are
# not allowed in triple-term / reified-triple positions.
function _ttl_parse_anon_bnode!(p::_TurtleParser)::BlankNode
    _ttl_expect_char!(p, '[')
    _ttl_skip!(p)
    _ttl_peek(p) == ']' ||
        _ttl_error(p, "Only an empty blank node [] is allowed here (no property list)")
    _ttl_advance!(p)
    _mint_blank_node()
end

function _ttl_parse_tt_subject!(p::_TurtleParser)::SubjectTerm
    c = _ttl_peek(p)
    if c == '<'
        _ttl_peek_at(p, 1) == '<' && _ttl_error(p,
            "Only an IRI or blank node is allowed as a triple-term subject")
        return _ttl_parse_iriref!(p)
    elseif c == '_' && _ttl_peek_at(p, 1) == ':'
        return _ttl_parse_blank_node_label!(p)
    elseif c == '['
        return _ttl_parse_anon_bnode!(p)
    elseif c == '('
        _ttl_error(p, "Only an IRI or blank node is allowed as a triple-term subject")
    else
        return _ttl_parse_prefixed_name!(p)
    end
end

function _ttl_parse_tt_object!(p::_TurtleParser)::ObjectTerm
    c = _ttl_peek(p)
    if c == '<'
        if _ttl_peek_at(p, 1) == '<'
            _ttl_peek_at(p, 2) == '(' ||
                _ttl_error(p, "Reified triples are not allowed inside triple terms")
            return _ttl_parse_triple_term!(p)
        end
        return _ttl_parse_iriref!(p)
    elseif c == '"' || c == '\''
        return _ttl_parse_literal!(p)
    elseif c == '_' && _ttl_peek_at(p, 1) == ':'
        return _ttl_parse_blank_node_label!(p)
    elseif c == '['
        return _ttl_parse_anon_bnode!(p)
    elseif c == '('
        _ttl_error(p, "Collections are not allowed inside triple terms")
    elseif c == 't' && _ttl_check_keyword(p, "true")
        for _ in 1:4; _ttl_advance!(p); end
        return Literal("true",  _XSD_BOOLEAN, "")
    elseif c == 'f' && _ttl_check_keyword(p, "false")
        for _ in 1:5; _ttl_advance!(p); end
        return Literal("false", _XSD_BOOLEAN, "")
    elseif c == '+' || c == '-' || isdigit(c) ||
           (c == '.' && isdigit(_ttl_peek_at(p, 1)))
        return _ttl_parse_numeric!(p)
    else
        return _ttl_parse_prefixed_name!(p)
    end
end

function _ttl_parse_triple_term!(p::_TurtleParser)::TripleTerm
    # Consume '<<('
    _ttl_expect_char!(p, '<')
    _ttl_expect_char!(p, '<')
    _ttl_expect_char!(p, '(')
    _ttl_skip!(p)
    subj = _ttl_parse_tt_subject!(p)
    _ttl_skip!(p)
    pred = _ttl_parse_predicate!(p)
    _ttl_skip!(p)
    obj  = _ttl_parse_tt_object!(p)
    _ttl_skip!(p)
    # Consume ')>>'
    _ttl_expect_char!(p, ')')
    _ttl_expect_char!(p, '>')
    _ttl_expect_char!(p, '>')
    TripleTerm(subj, pred, obj)
end

# ── Reified triple (RDF 1.2) ──────────────────────────────────────────────────
#
# reifiedTriple ::= '<<' rtSubject verb rtObject reifier? '>>'
# rtSubject     ::= iri | BlankNode | reifiedTriple
# rtObject      ::= iri | BlankNode | literal | tripleTerm | reifiedTriple
# reifier       ::= '~' (iri | BlankNode)?
#
# `<< s p o ~r >>` emits  r rdf:reifies <<( s p o )>>  and evaluates to r
# (a fresh blank node when no explicit reifier is given).

function _ttl_parse_rt_subject!(p::_TurtleParser)::SubjectTerm
    c = _ttl_peek(p)
    if c == '<'
        if _ttl_peek_at(p, 1) == '<'
            _ttl_peek_at(p, 2) == '(' && _ttl_error(p,
                "Triple terms are not allowed as reified-triple subjects")
            return _ttl_parse_reified_triple!(p)
        end
        return _ttl_parse_iriref!(p)
    elseif c == '_' && _ttl_peek_at(p, 1) == ':'
        return _ttl_parse_blank_node_label!(p)
    elseif c == '['
        return _ttl_parse_anon_bnode!(p)
    elseif c == '('
        _ttl_error(p, "Collections are not allowed in reified triples")
    else
        return _ttl_parse_prefixed_name!(p)
    end
end

function _ttl_parse_rt_object!(p::_TurtleParser)::ObjectTerm
    c = _ttl_peek(p)
    if c == '<'
        if _ttl_peek_at(p, 1) == '<'
            return _ttl_peek_at(p, 2) == '(' ?
                _ttl_parse_triple_term!(p) : _ttl_parse_reified_triple!(p)
        end
        return _ttl_parse_iriref!(p)
    elseif c == '"' || c == '\''
        return _ttl_parse_literal!(p)
    elseif c == '_' && _ttl_peek_at(p, 1) == ':'
        return _ttl_parse_blank_node_label!(p)
    elseif c == '['
        return _ttl_parse_anon_bnode!(p)
    elseif c == '('
        _ttl_error(p, "Collections are not allowed in reified triples")
    elseif c == 't' && _ttl_check_keyword(p, "true")
        for _ in 1:4; _ttl_advance!(p); end
        return Literal("true",  _XSD_BOOLEAN, "")
    elseif c == 'f' && _ttl_check_keyword(p, "false")
        for _ in 1:5; _ttl_advance!(p); end
        return Literal("false", _XSD_BOOLEAN, "")
    elseif c == '+' || c == '-' || isdigit(c) ||
           (c == '.' && isdigit(_ttl_peek_at(p, 1)))
        return _ttl_parse_numeric!(p)
    else
        return _ttl_parse_prefixed_name!(p)
    end
end

# Parse the optional node after '~'.  Returns a fresh blank node when the next
# token cannot start an IRI or blank node (bare '~').
function _ttl_parse_reifier_node!(p::_TurtleParser)::SubjectTerm
    c = _ttl_peek(p)
    if c == '<' && _ttl_peek_at(p, 1) != '<'
        return _ttl_parse_iriref!(p)
    elseif c == '_' && _ttl_peek_at(p, 1) == ':'
        return _ttl_parse_blank_node_label!(p)
    elseif c == '[' && begin
            # '[]' (anon blank node) is allowed as a reifier
            save = p.pos
            _ttl_advance!(p); _ttl_skip!(p)
            ok = _ttl_peek(p) == ']'
            ok ? (_ttl_advance!(p); true) : (p.pos = save; false)
        end
        return _mint_blank_node()
    elseif _is_pn_chars_base(c) || c == ':'
        return _ttl_parse_prefixed_name!(p)
    else
        return _mint_blank_node()   # bare '~'
    end
end

function _ttl_parse_reified_triple!(p::_TurtleParser)::SubjectTerm
    # Consume '<<'  (caller guarantees the next char is not '(')
    _ttl_expect_char!(p, '<')
    _ttl_expect_char!(p, '<')
    _ttl_skip!(p)
    subj = _ttl_parse_rt_subject!(p)
    _ttl_skip!(p)
    pred = _ttl_parse_predicate!(p)
    _ttl_skip!(p)
    obj  = _ttl_parse_rt_object!(p)
    _ttl_skip!(p)
    reifier = if _ttl_peek(p) == '~'
        _ttl_advance!(p); _ttl_skip!(p)
        _ttl_parse_reifier_node!(p)
    else
        _mint_blank_node()
    end
    _ttl_skip!(p)
    _ttl_expect_char!(p, '>')
    _ttl_expect_char!(p, '>')
    push!(p.triples, Triple(reifier, _TTL_RDF_REIFIES, TripleTerm(subj, pred, obj)))
    reifier
end

# ── Annotation syntax (RDF 1.2) ───────────────────────────────────────────────
#
# annotation      ::= (reifier | annotationBlock)*
# annotationBlock ::= '{|' predicateObjectList '|}'
#
# Appears after an object in an objectList.  Each '~r' emits
# r rdf:reifies <<( s p o )>>; an annotation block attaches its
# predicate-object list to the preceding reifier (or a fresh one).

function _ttl_parse_annotation!(p::_TurtleParser, subj::SubjectTerm,
                                pred::IRI, obj::ObjectTerm)
    tt          = nothing            # built lazily, shared by all reifiers
    cur_reifier = nothing            # set by '~', consumed by the next block
    while true
        _ttl_skip!(p)
        c = _ttl_peek(p)
        if c == '~'
            _ttl_advance!(p); _ttl_skip!(p)
            r = _ttl_parse_reifier_node!(p)
            tt === nothing && (tt = TripleTerm(subj, pred, obj))
            push!(p.triples, Triple(r, _TTL_RDF_REIFIES, tt))
            cur_reifier = r
        elseif c == '{' && _ttl_peek_at(p, 1) == '|'
            _ttl_advance!(p); _ttl_advance!(p)
            r = cur_reifier
            if r === nothing
                r = _mint_blank_node()
                tt === nothing && (tt = TripleTerm(subj, pred, obj))
                push!(p.triples, Triple(r, _TTL_RDF_REIFIES, tt))
            end
            _ttl_skip!(p)
            _ttl_peek(p) == '|' && _ttl_peek_at(p, 1) == '}' &&
                _ttl_error(p, "Annotation block must contain at least one predicate-object pair")
            _ttl_parse_po_list!(p, r)
            _ttl_skip!(p)
            _ttl_expect_char!(p, '|')
            _ttl_expect_char!(p, '}')
            cur_reifier = nothing    # each further bare block gets a fresh reifier
        else
            break
        end
    end
end

# ── Subject ───────────────────────────────────────────────────────────────────

function _ttl_parse_subject!(p::_TurtleParser)::SubjectTerm
    c = _ttl_peek(p)
    if c == '<'
        if _ttl_peek_at(p, 1) == '<'
            # RDF 1.2: '<<' starts a reified triple; '<<(' (a triple term) is
            # not a legal subject.
            _ttl_peek_at(p, 2) == '(' && _ttl_error(p,
                "Triple terms are not allowed in subject position; " *
                "use a reified triple << s p o >> instead")
            return _ttl_parse_reified_triple!(p)
        end
        return _ttl_parse_iriref!(p)
    elseif c == '_' && _ttl_peek_at(p,1) == ':'
        return _ttl_parse_blank_node_label!(p)
    else
        return _ttl_parse_prefixed_name!(p)
    end
end

# ── Predicate-object list ─────────────────────────────────────────────────────

function _ttl_parse_po_list!(p::_TurtleParser, subj::SubjectTerm)
    while true
        _ttl_skip!(p)
        pred = _ttl_parse_predicate!(p)
        _ttl_skip!(p)
        obj = _ttl_parse_object_term!(p)
        push!(p.triples, Triple(subj, pred, obj))
        _ttl_parse_annotation!(p, subj, pred, obj)   # RDF 1.2: ~r / {| … |}
        _ttl_skip!(p)
        while _ttl_peek(p) == ','
            _ttl_advance!(p); _ttl_skip!(p)
            obj = _ttl_parse_object_term!(p)
            push!(p.triples, Triple(subj, pred, obj))
            _ttl_parse_annotation!(p, subj, pred, obj)
            _ttl_skip!(p)
        end
        _ttl_peek(p) == ';' || break
        while _ttl_peek(p) == ';'; _ttl_advance!(p); _ttl_skip!(p); end
        c = _ttl_peek(p)
        # '}' closes a TriG graph block, so it terminates a predicate-object
        # list exactly as '.' does: `{ <s> <p> <o> ; }` is legal TriG. Accepting
        # it here costs Turtle nothing — a '}' in a Turtle document still fails
        # at the mandatory '.' that follows.
        (c == '.' || c == ']' || c == '|' || c == '}' || _ttl_eof(p)) && break
    end
end

# ── Directives ────────────────────────────────────────────────────────────────

function _ttl_parse_at_directive!(p::_TurtleParser)
    buf = IOBuffer()
    while !_ttl_eof(p) && isletter(_ttl_peek(p))
        write(buf, _ttl_peek(p)); _ttl_advance!(p)
    end
    name = String(take!(buf))

    if name == "prefix"
        _ttl_skip!(p)
        pn = _ttl_parse_pname_ns!(p)
        _ttl_expect_char!(p, ':')
        _ttl_skip!(p)
        iri = _ttl_parse_iriref!(p)
        p.prefixes[pn] = _ttl_resolve(p.base, iri.value)
        _ttl_skip!(p)
        _ttl_expect_char!(p, '.')
    elseif name == "base"
        _ttl_skip!(p)
        iri = _ttl_parse_iriref!(p)
        p.base = _ttl_resolve(p.base, iri.value)
        _ttl_skip!(p)
        _ttl_expect_char!(p, '.')
    elseif name == "version"
        _ttl_skip!(p)
        _ttl_parse_version_specifier!(p)
        _ttl_skip!(p)
        _ttl_expect_char!(p, '.')
    else
        _ttl_error(p, "Unknown directive '@$name' (must be lowercase '@prefix', '@base', or '@version')")
    end
end

# RDF 1.2: VersionSpecifier ::= STRING_LITERAL_QUOTE | STRING_LITERAL_SINGLE_QUOTE
# The value is advisory; it is validated as a plain quoted string and discarded.
function _ttl_parse_version_specifier!(p::_TurtleParser)
    c = _ttl_peek(p)
    (c == '"' || c == '\'') ||
        _ttl_error(p, "Expected a quoted version string after version directive")
    # Long strings (\"\"\"…\"\"\") are not allowed by the grammar
    (_ttl_peek_at(p, 1) == c && _ttl_peek_at(p, 2) == c) &&
        _ttl_error(p, "Version specifier must be a single-quoted or double-quoted string")
    c == '"' ? _ttl_parse_short_string!(p, '"') : _ttl_parse_short_string!(p, '\'')
    nothing
end

function _ttl_parse_sparql_directive!(p::_TurtleParser, name::String)
    uname = uppercase(name)
    if uname == "PREFIX"
        _ttl_skip!(p)
        pn = _ttl_parse_pname_ns!(p)
        _ttl_expect_char!(p, ':')
        _ttl_skip!(p)
        iri = _ttl_parse_iriref!(p)
        p.prefixes[pn] = _ttl_resolve(p.base, iri.value)
    elseif uname == "BASE"
        _ttl_skip!(p)
        iri = _ttl_parse_iriref!(p)
        p.base = _ttl_resolve(p.base, iri.value)
    elseif uname == "VERSION"
        _ttl_skip!(p)
        _ttl_parse_version_specifier!(p)
    else
        _ttl_error(p, "Unknown SPARQL directive '$name'")
    end
end

# ── Statement ─────────────────────────────────────────────────────────────────

# One `triples` production — subject plus its predicate-object list, stopping
# before the terminating '.'. Factored out of _ttl_parse_statement! so TriG can
# reuse it inside a graph block, where the final '.' before '}' is optional.
#
# `subj0` lets a caller that has already consumed the subject hand it over. TriG
# needs that: `<g> { … }` and `<s> <p> <o> .` are only distinguishable after the
# subject term has been read and the next character looked at.
function _ttl_parse_triples!(p::_TurtleParser,
                             subj0::Union{SubjectTerm, Nothing}=nothing)
    if subj0 !== nothing
        _ttl_parse_po_list!(p, subj0)
        _ttl_skip!(p)
        return nothing
    end
    c = _ttl_peek(p)
    if c == '['
        subj = _ttl_parse_bnode_proplist!(p)
        _ttl_skip!(p)
        # A blank node property list can stand alone as a whole statement, in
        # which case what follows is the terminator rather than a predicate:
        # '.' in Turtle, and also '}' at the end of a TriG graph block.
        if _ttl_peek(p) != '.' && _ttl_peek(p) != '}'
            _ttl_parse_po_list!(p, subj)
            _ttl_skip!(p)
        end
    elseif c == '('
        subj = _ttl_parse_collection!(p)
        _ttl_skip!(p)
        _ttl_parse_po_list!(p, subj)
        _ttl_skip!(p)
    else
        # RDF 1.2: a reified triple used as subject may stand alone
        # (`<< s p o >> .`) — its predicateObjectList is optional.
        is_reified = c == '<' && _ttl_peek_at(p, 1) == '<' && _ttl_peek_at(p, 2) != '('
        subj = _ttl_parse_subject!(p)
        _ttl_skip!(p)
        if !(is_reified && _ttl_peek(p) == '.')
            _ttl_parse_po_list!(p, subj)
            _ttl_skip!(p)
        end
    end
    return nothing
end

function _ttl_parse_statement!(p::_TurtleParser)
    _ttl_parse_triples!(p)
    _ttl_expect_char!(p, '.')
end

# ── Document ──────────────────────────────────────────────────────────────────

function _ttl_read_name!(p::_TurtleParser)::String
    buf = IOBuffer()
    while !_ttl_eof(p) && isletter(_ttl_peek(p))
        write(buf, _ttl_peek(p)); _ttl_advance!(p)
    end
    String(take!(buf))
end

function _ttl_parse_document!(p::_TurtleParser)
    while true
        _ttl_skip!(p)
        _ttl_eof(p) && break
        c = _ttl_peek(p)

        if c == '@'
            _ttl_advance!(p)
            _ttl_parse_at_directive!(p)
        elseif isletter(c)
            # Peek: might be SPARQL PREFIX/BASE keyword
            pos_save    = p.pos
            lineno_save = p.lineno
            name = _ttl_read_name!(p)
            uname = uppercase(name)
            # Treat as SPARQL directive if name is PREFIX/BASE/VERSION and the
            # next character can start its argument
            if (uname == "PREFIX" || uname == "BASE" || uname == "VERSION") &&
               (!_ttl_eof(p)) &&
               (_ttl_peek(p) == ' ' || _ttl_peek(p) == '\t' ||
                _ttl_peek(p) == '\n' || _ttl_peek(p) == '\r' ||
                _ttl_peek(p) == '<' ||
                (uname == "VERSION" && (_ttl_peek(p) == '"' || _ttl_peek(p) == '\'')))
                _ttl_parse_sparql_directive!(p, name)
            else
                p.pos    = pos_save
                p.lineno = lineno_save
                _ttl_parse_statement!(p)
            end
        else
            _ttl_parse_statement!(p)
        end
    end
end

# ── Top-level ─────────────────────────────────────────────────────────────────

function _ttl_parse(s::String, base::String)::Vector{Triple}
    p = _TurtleParser(s, base)
    _ttl_parse_document!(p)
    p.triples
end

function Base.read(io::IO, ::_MIME_TTL, ::Type{Graph})::Graph
    bulk_load!(Graph(), _ttl_parse(String(Base.read(io)), ""))
end

function Base.read(io::IO, ::_MIME_TTL, ::Type{Graph}, base::AbstractString)::Graph
    bulk_load!(Graph(), _ttl_parse(String(Base.read(io)), String(base)))
end

function Base.read(io::IO, ::_MIME_TTL, ::Type{Vector{Triple}})::Vector{Triple}
    _ttl_parse(String(Base.read(io)), "")
end

function Base.read(io::IO, ::_MIME_TTL, ::Type{Vector{Triple}}, base::AbstractString)::Vector{Triple}
    _ttl_parse(String(Base.read(io)), String(base))
end
