# ── SPARQL 1.1 Recursive-Descent Parser ──────────────────────────────────────
#
# Converts a SPARQL 1.1 query/update string into AST nodes defined in ast.jl.
# This file is included into the RDF module; do NOT add a module declaration.
#
# Public entry point:
#   sparql_parse(src::AbstractString) → SpUnit

# ── Parser state ──────────────────────────────────────────────────────────────

mutable struct SpParser
    lex::SpLexer
    base::Union{String, Nothing}
    prefixes::Dict{String, String}   # prefix label → expanded IRI
end

# ── Error helpers ─────────────────────────────────────────────────────────────

function _sp_parse_error(p::SpParser, tok::SpToken, msg::String)
    throw(ParseError(msg, tok.line, tok.col, MIME("application/sparql-query")))
end

function _sp_parse_error_here(p::SpParser, msg::String)
    tok = sp_peek_token(p.lex)
    throw(ParseError(msg, tok.line, tok.col, MIME("application/sparql-query")))
end

# Expect a specific keyword; throw ParseError if not found
function _sp_expect_kw!(p::SpParser, kw::String)::SpToken
    tok = sp_next_token!(p.lex)
    (tok.kind == SP_TOK_KW && tok.value == kw) ||
        _sp_parse_error(p, tok, "Expected keyword '$kw', got $(tok.value == "" ? string(tok.kind) : repr(tok.value))")
    tok
end

# Expect a specific token kind
function _sp_expect!(p::SpParser, kind::SpTokKind)::SpToken
    tok = sp_next_token!(p.lex)
    tok.kind == kind || _sp_parse_error(p, tok,
        "Expected $kind, got $(tok.kind)$(tok.value == "" ? "" : " ($(repr(tok.value)))")")
    tok
end

# Peek at next token kind
@inline function _sp_peek_kind(p::SpParser)::SpTokKind
    sp_peek_token(p.lex).kind
end

# Consume and return the next token
@inline function _sp_next!(p::SpParser)::SpToken
    sp_next_token!(p.lex)
end

# Check if next token is a keyword with given value (without consuming)
@inline function _sp_peek_kw(p::SpParser, kw::String)::Bool
    tok = sp_peek_token(p.lex)
    tok.kind == SP_TOK_KW && tok.value == kw
end

# Consume a keyword if it matches; return whether consumed
function _sp_eat_kw!(p::SpParser, kw::String)::Bool
    if _sp_peek_kw(p, kw)
        _sp_next!(p)
        return true
    end
    return false
end

# Consume a token of given kind if present; return whether consumed
function _sp_eat!(p::SpParser, kind::SpTokKind)::Bool
    if _sp_peek_kind(p) == kind
        _sp_next!(p)
        return true
    end
    return false
end

# ── IRI resolution (RFC 3986) ─────────────────────────────────────────────────

function _sp_resolve_iri(base::Union{String,Nothing}, ref::String)::String
    # If ref has a scheme (letter followed by letter/digit/+/-/. then ://), it's absolute
    if occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", ref)
        return ref
    end
    base === nothing && return ref  # can't resolve without base
    # Simple RFC 3986 resolution
    if startswith(ref, "//")
        # Network-path reference: use base scheme
        m = match(r"^([A-Za-z][A-Za-z0-9+\-.]*):", base)
        m === nothing && return ref
        return m.captures[1] * ":" * ref
    elseif startswith(ref, "/")
        # Absolute-path reference
        m = match(r"^([A-Za-z][A-Za-z0-9+\-.]*://[^/]*)", base)
        m === nothing && return ref
        return m.captures[1] * ref
    elseif startswith(ref, "#")
        # Fragment
        base_no_frag = replace(base, r"#.*$" => "")
        return base_no_frag * ref
    elseif isempty(ref)
        return base
    else
        # Relative path: merge with base
        # Remove fragment from base
        base_no_frag = replace(base, r"#.*$" => "")
        # Remove query from base for path computation, but keep it for ?-refs
        # Remove everything after last '/' in base path
        m = match(r"^(.*/)([^/]*)$", base_no_frag)
        if m !== nothing
            merged = m.captures[1] * ref
        else
            merged = ref
        end
        # Remove dot segments
        merged = _remove_dot_segments(merged)
        return merged
    end
end

function _remove_dot_segments(path::String)::String
    # RFC 3986 Section 5.2.4
    inp = path
    out = IOBuffer()
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
            # Remove last segment from output
            s = String(take!(out))
            idx = findlast('/', s)
            if idx !== nothing
                write(out, s[1:idx-1])
            end
        elseif inp == "/.."
            inp = "/"
            s = String(take!(out))
            idx = findlast('/', s)
            if idx !== nothing
                write(out, s[1:idx-1])
            end
        elseif inp == "." || inp == ".."
            inp = ""
        else
            # Move first path segment (including leading /, if any) to output
            start = startswith(inp, "/") ? 2 : 1
            idx = findnext('/', inp, start)
            if idx === nothing
                write(out, inp)
                inp = ""
            else
                write(out, inp[1:idx-1])
                inp = inp[idx:end]
            end
        end
    end
    return String(take!(out))
end

# ── IRI expansion ─────────────────────────────────────────────────────────────

# Decode PN_LOCAL escape sequences (backslash escapes)
const _PN_LOCAL_ESC_SET = Set{Char}([
    '~', '.', '-', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=',
    '/', '?', '#', '@', '%',
])

function _decode_pn_local(s::String)::String
    occursin('\\', s) || return s
    buf = IOBuffer()
    i = 1
    while i <= ncodeunits(s)
        c, ni = iterate(s, i)
        if c == '\\'
            if ni <= ncodeunits(s)
                ec, nni = iterate(s, ni)
                if ec in _PN_LOCAL_ESC_SET
                    write(buf, ec)
                    i = nni
                else
                    error("Invalid escape character '\\$(ec)' in PN_LOCAL: only _~.-!\$&'()*+,;=/?#@% may be escaped")
                end
            else
                # trailing backslash — invalid
                error("Trailing backslash in PN_LOCAL")
            end
        else
            write(buf, c)
            i = ni
        end
    end
    return String(take!(buf))
end

# Expand an IRIREF token to absolute IRI
function _sp_expand_iriref(p::SpParser, tok::SpToken)::String
    # IRIREF value already has < > stripped by lexer
    iri = tok.value
    # Decode unicode escapes \uXXXX and \UXXXXXXXX in the IRI
    iri = _decode_iri_escapes(iri)
    return _sp_resolve_iri(p.base, iri)
end

function _decode_iri_escapes(s::String)::String
    occursin('\\', s) || return s
    buf = IOBuffer()
    i = 1
    while i <= ncodeunits(s)
        c, ni = iterate(s, i)
        if c == '\\'
            if ni <= ncodeunits(s)
                ec, nni = iterate(s, ni)
                if ec == 'u'
                    # \uXXXX
                    hex = s[nni:min(nni+3*4-1, ncodeunits(s))]  # up to 4 bytes
                    # Actually need 4 hex chars
                    if nni + 3 <= ncodeunits(s)
                        hexstr = s[nni:nni+3]
                        # Check all hex digits
                        if all(c -> isxdigit(c), hexstr)
                            cp = parse(Int, hexstr, base=16)
                            write(buf, Char(cp))
                            i = nni + 4
                            continue
                        end
                    end
                    write(buf, c)
                    i = ni
                elseif ec == 'U'
                    # \UXXXXXXXX
                    if nni + 7 <= ncodeunits(s)
                        hexstr = s[nni:nni+7]
                        if all(c -> isxdigit(c), hexstr)
                            cp = parse(Int, hexstr, base=16)
                            write(buf, Char(cp))
                            i = nni + 8
                            continue
                        end
                    end
                    write(buf, c)
                    i = ni
                else
                    write(buf, c)
                    i = ni
                end
            else
                write(buf, c)
                i = ni
            end
        else
            write(buf, c)
            i = ni
        end
    end
    return String(take!(buf))
end

# Expand a prefixed name token (PNAME_LN or PNAME_NS)
function _sp_expand_pname(p::SpParser, tok::SpToken)::String
    v = tok.value
    colon_idx = findfirst(':', v)
    colon_idx === nothing && _sp_parse_error(p, tok, "Invalid prefixed name: $(repr(v))")
    prefix = v[1:colon_idx-1]
    local_part = v[colon_idx+1:end]
    if !haskey(p.prefixes, prefix)
        _sp_parse_error(p, tok, "Unknown prefix $(repr(prefix)) in $(repr(v))")
    end
    expanded_local = try _decode_pn_local(local_part)
    catch e
        _sp_parse_error(p, tok, "Invalid prefixed name local part in $(repr(v)): $(sprint(showerror, e))")
    end
    return p.prefixes[prefix] * expanded_local
end

# Parse an IRI (IRIREF or prefixed name) and return absolute IRI string
function _sp_parse_iri(p::SpParser)::String
    tok = _sp_next!(p)
    if tok.kind == SP_TOK_IRIREF
        return _sp_expand_iriref(p, tok)
    elseif tok.kind == SP_TOK_PNAME_LN || tok.kind == SP_TOK_PNAME_NS
        return _sp_expand_pname(p, tok)
    else
        _sp_parse_error(p, tok, "Expected IRI, got $(tok.kind)")
    end
end

# Parse an IRI and return as SpIRI node
function _sp_parse_iri_node(p::SpParser)::SpIRI
    SpIRI(_sp_parse_iri(p))
end

# Check if next token can start an IRI
function _sp_next_is_iri(p::SpParser)::Bool
    k = _sp_peek_kind(p)
    k == SP_TOK_IRIREF || k == SP_TOK_PNAME_LN || k == SP_TOK_PNAME_NS
end

# ── String unescaping ─────────────────────────────────────────────────────────

function _unescape_string(s::String)::String
    occursin('\\', s) || return s
    buf = IOBuffer()
    i = 1
    while i <= ncodeunits(s)
        c, ni = iterate(s, i)
        if c == '\\'
            if ni <= ncodeunits(s)
                ec, nni = iterate(s, ni)
                if ec == 'n'
                    write(buf, '\n'); i = nni
                elseif ec == 't'
                    write(buf, '\t'); i = nni
                elseif ec == 'r'
                    write(buf, '\r'); i = nni
                elseif ec == '"'
                    write(buf, '"'); i = nni
                elseif ec == '\''
                    write(buf, '\''); i = nni
                elseif ec == '\\'
                    write(buf, '\\'); i = nni
                elseif ec == 'u'
                    # \uXXXX
                    if nni + 3 <= ncodeunits(s)
                        hexstr = s[nni:nni+3]
                        if all(x -> isxdigit(x), hexstr)
                            cp = parse(Int, hexstr, base=16)
                            # Reject lone surrogate code points (U+D800–U+DFFF)
                            if 0xD800 <= cp <= 0xDFFF
                                throw(ParseError("Illegal surrogate code point U+$(uppercase(string(cp, base=16, pad=4))) in string escape",
                                    0, 0, MIME("application/sparql-query")))
                            end
                            write(buf, Char(cp))
                            i = nni + 4
                            continue
                        end
                    end
                    write(buf, '\\'); write(buf, ec); i = nni
                elseif ec == 'U'
                    # \UXXXXXXXX
                    if nni + 7 <= ncodeunits(s)
                        hexstr = s[nni:nni+7]
                        if all(x -> isxdigit(x), hexstr)
                            cp = parse(Int, hexstr, base=16)
                            if 0xD800 <= cp <= 0xDFFF
                                throw(ParseError("Illegal surrogate code point U+$(uppercase(string(cp, base=16, pad=8))) in string escape",
                                    0, 0, MIME("application/sparql-query")))
                            end
                            write(buf, Char(cp))
                            i = nni + 8
                            continue
                        end
                    end
                    write(buf, '\\'); write(buf, ec); i = nni
                else
                    write(buf, '\\'); write(buf, ec); i = nni
                end
            else
                write(buf, c); i = ni
            end
        else
            write(buf, c); i = ni
        end
    end
    return String(take!(buf))
end

# ── Prologue parsing ──────────────────────────────────────────────────────────

function _sp_parse_prologue!(p::SpParser)::Vector{SpPrefixDecl}
    decls = SpPrefixDecl[]
    while true
        tok = sp_peek_token(p.lex)
        if tok.kind == SP_TOK_KW && tok.value == "base"
            _sp_next!(p)  # consume "base"
            iri_tok = _sp_expect!(p, SP_TOK_IRIREF)
            p.base = _sp_expand_iriref(p, iri_tok)
        elseif tok.kind == SP_TOK_KW && tok.value == "prefix"
            _sp_next!(p)  # consume "prefix"
            ns_tok = _sp_expect!(p, SP_TOK_PNAME_NS)
            iri_tok = _sp_expect!(p, SP_TOK_IRIREF)
            # Extract prefix label (without trailing colon)
            ns_raw = ns_tok.value  # e.g. "rdf:"
            prefix_label = ns_raw[1:end-1]  # remove trailing ':'
            expanded = _sp_expand_iriref(p, iri_tok)
            p.prefixes[prefix_label] = expanded
            push!(decls, SpPrefixDecl(prefix_label, expanded))
        elseif tok.kind == SP_TOK_KW && tok.value == "version"
            # SPARQL 1.2: VERSION "1.2" — advisory; validated and discarded
            _sp_next!(p)  # consume "version"
            v_tok = sp_peek_token(p.lex)
            v_tok.kind in (SP_TOK_STR1, SP_TOK_STR2) ||
                _sp_parse_error(p, v_tok, "Expected a quoted version string after VERSION")
            _sp_next!(p)
        else
            break
        end
    end
    return decls
end

# ── Variable parsing ──────────────────────────────────────────────────────────

function _sp_parse_var(p::SpParser)::SpVar
    tok = _sp_expect!(p, SP_TOK_VAR)
    SpVar(Symbol(tok.value))
end

# ── VarOrIri ──────────────────────────────────────────────────────────────────

function _sp_parse_var_or_iri(p::SpParser)::SpExpr
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_VAR
        _sp_next!(p)
        return SpVar(Symbol(tok.value))
    elseif _sp_next_is_iri(p)
        return _sp_parse_iri_node(p)
    else
        _sp_parse_error(p, tok, "Expected variable or IRI")
    end
end

# ── Dataset clauses ───────────────────────────────────────────────────────────

function _sp_parse_dataset_clauses(p::SpParser)::Vector{SpDatasetClause}
    clauses = SpDatasetClause[]
    while _sp_peek_kw(p, "from")
        _sp_next!(p)  # consume "from"
        named = _sp_eat_kw!(p, "named")
        iri = _sp_parse_iri(p)
        push!(clauses, SpDatasetClause(named, iri))
    end
    return clauses
end

# ── Literal parsing ───────────────────────────────────────────────────────────

function _sp_parse_rdf_literal(p::SpParser)::SpLiteral
    tok = _sp_next!(p)
    is_str = tok.kind in (SP_TOK_STR1, SP_TOK_STR2, SP_TOK_STR_LONG1, SP_TOK_STR_LONG2)
    is_str || _sp_parse_error(p, tok, "Expected string literal")
    lexval = _unescape_string(tok.value)

    next = sp_peek_token(p.lex)
    if next.kind == SP_TOK_HATHAT
        _sp_next!(p)  # consume ^^
        dt_iri = _sp_parse_iri(p)
        return SpLiteral(lexval, dt_iri, "")
    elseif next.kind == SP_TOK_LANGTAG
        _sp_next!(p)  # consume lang tag
        tag = next.value
        dd  = findfirst("--", tag)
        if dd !== nothing
            # RDF 1.2 directional language tag: lang--dir, dir ∈ {ltr, rtl}
            lang = lowercase(tag[1:first(dd)-1])
            dir  = tag[last(dd)+1:end]
            dir in ("ltr", "rtl") || _sp_parse_error(p, next,
                "Base direction must be 'ltr' or 'rtl', got '$dir'")
            return SpLiteral(lexval,
                "http://www.w3.org/1999/02/22-rdf-syntax-ns#dirLangString",
                lang * "--" * dir)
        end
        lang = lowercase(tag)
        return SpLiteral(lexval, "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString", lang)
    else
        return SpLiteral(lexval, "http://www.w3.org/2001/XMLSchema#string", "")
    end
end

function _sp_parse_numeric_literal(p::SpParser)::SpLiteral
    tok = _sp_next!(p)
    if tok.kind == SP_TOK_INTEGER
        return SpLiteral(tok.value, "http://www.w3.org/2001/XMLSchema#integer", "")
    elseif tok.kind == SP_TOK_DECIMAL
        return SpLiteral(tok.value, "http://www.w3.org/2001/XMLSchema#decimal", "")
    elseif tok.kind == SP_TOK_DOUBLE
        return SpLiteral(tok.value, "http://www.w3.org/2001/XMLSchema#double", "")
    else
        _sp_parse_error(p, tok, "Expected numeric literal")
    end
end

function _sp_parse_boolean_literal(p::SpParser)::SpLiteral
    tok = _sp_next!(p)
    (tok.kind == SP_TOK_KW && (tok.value == "true" || tok.value == "false")) ||
        _sp_parse_error(p, tok, "Expected 'true' or 'false'")
    SpLiteral(tok.value, "http://www.w3.org/2001/XMLSchema#boolean", "")
end

# Returns true if next token can start an RDF literal
function _sp_next_is_literal(p::SpParser)::Bool
    k = _sp_peek_kind(p)
    k in (SP_TOK_STR1, SP_TOK_STR2, SP_TOK_STR_LONG1, SP_TOK_STR_LONG2)
end

function _sp_next_is_numeric(p::SpParser)::Bool
    k = _sp_peek_kind(p)
    k in (SP_TOK_INTEGER, SP_TOK_DECIMAL, SP_TOK_DOUBLE)
end

function _sp_next_is_boolean(p::SpParser)::Bool
    tok = sp_peek_token(p.lex)
    tok.kind == SP_TOK_KW && (tok.value == "true" || tok.value == "false")
end

# ── Property path parsing ─────────────────────────────────────────────────────

# PathPrimary: 'a' | IRI | '!' PathNegatedPropertySet | '(' Path ')'
function _sp_parse_path_primary(p::SpParser)::SpPath
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_A
        _sp_next!(p)
        return SpPathA()
    elseif _sp_next_is_iri(p)
        iri = _sp_parse_iri(p)
        return SpPathIRI(iri)
    elseif tok.kind == SP_TOK_BANG
        _sp_next!(p)  # consume '!'
        return _sp_parse_path_negated_property_set(p)
    elseif tok.kind == SP_TOK_LPAREN
        _sp_next!(p)  # consume '('
        path = _sp_parse_path(p)
        _sp_expect!(p, SP_TOK_RPAREN)
        return path
    else
        _sp_parse_error(p, tok, "Expected path primary (IRI, 'a', '!', or '(')")
    end
end

function _sp_parse_path_one_in_property_set(p::SpParser)::SpPath
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_CARET
        _sp_next!(p)  # consume '^'
        tok2 = sp_peek_token(p.lex)
        if tok2.kind == SP_TOK_A
            _sp_next!(p)
            return SpPathInverse(SpPathA())
        elseif _sp_next_is_iri(p)
            iri = _sp_parse_iri(p)
            return SpPathInverse(SpPathIRI(iri))
        else
            _sp_parse_error(p, tok2, "Expected IRI or 'a' after '^' in path")
        end
    elseif tok.kind == SP_TOK_A
        _sp_next!(p)
        return SpPathA()
    elseif _sp_next_is_iri(p)
        iri = _sp_parse_iri(p)
        return SpPathIRI(iri)
    else
        _sp_parse_error(p, tok, "Expected path property in negated set")
    end
end

function _sp_parse_path_negated_property_set(p::SpParser)::SpPathNeg
    tok = sp_peek_token(p.lex)
    elements = SpPath[]
    if tok.kind == SP_TOK_LPAREN
        _sp_next!(p)  # consume '('
        if sp_peek_token(p.lex).kind != SP_TOK_RPAREN
            push!(elements, _sp_parse_path_one_in_property_set(p))
            while _sp_peek_kind(p) == SP_TOK_PIPE
                _sp_next!(p)  # consume '|'
                push!(elements, _sp_parse_path_one_in_property_set(p))
            end
        end
        _sp_expect!(p, SP_TOK_RPAREN)
    else
        push!(elements, _sp_parse_path_one_in_property_set(p))
    end
    return SpPathNeg(elements)
end

# PathMod: '?' | '*' | '+' | (handled inline in PathElt)
function _sp_parse_path_elt(p::SpParser)::SpPath
    primary = _sp_parse_path_primary(p)
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_STAR
        _sp_next!(p)
        return SpPathZeroOrMore(primary)
    elseif tok.kind == SP_TOK_PLUS
        _sp_next!(p)
        return SpPathOneOrMore(primary)
    elseif tok.kind == SP_TOK_QUEST
        _sp_next!(p)
        return SpPathZeroOrOne(primary)
    elseif tok.kind == SP_TOK_LBRACE
        _sp_next!(p)  # consume '{'
        # Parse {n} or {n,} or {n,m} or {,m}
        min_v = 0
        max_v::Union{Int,Nothing} = nothing
        if _sp_peek_kind(p) == SP_TOK_INTEGER
            min_v = parse(Int, _sp_next!(p).value)
        end
        if _sp_eat!(p, SP_TOK_COMMA)
            if _sp_peek_kind(p) == SP_TOK_INTEGER
                max_v = parse(Int, _sp_next!(p).value)
            end
        else
            max_v = min_v  # exact count
        end
        _sp_expect!(p, SP_TOK_RBRACE)
        return SpPathRange(primary, min_v, max_v)
    end
    return primary
end

function _sp_parse_path_elt_or_inverse(p::SpParser)::SpPath
    if sp_peek_token(p.lex).kind == SP_TOK_CARET
        _sp_next!(p)  # consume '^'
        elt = _sp_parse_path_elt(p)
        return SpPathInverse(elt)
    else
        return _sp_parse_path_elt(p)
    end
end

function _sp_parse_path_sequence(p::SpParser)::SpPath
    left = _sp_parse_path_elt_or_inverse(p)
    while _sp_peek_kind(p) == SP_TOK_SLASH
        _sp_next!(p)  # consume '/'
        right = _sp_parse_path_elt_or_inverse(p)
        left = SpPathSeq(left, right)
    end
    return left
end

function _sp_parse_path(p::SpParser)::SpPath
    left = _sp_parse_path_sequence(p)
    while _sp_peek_kind(p) == SP_TOK_PIPE
        _sp_next!(p)  # consume '|'
        right = _sp_parse_path_sequence(p)
        left = SpPathAlt(left, right)
    end
    return left
end

# ── Triple pattern term helpers ────────────────────────────────────────────────

# Predicate inside a triple term / reified triple: IRI, 'a', or variable
function _sp_parse_tt_verb(p::SpParser)::SpExpr
    pred_tok = sp_peek_token(p.lex)
    if pred_tok.kind == SP_TOK_A
        _sp_next!(p)
        return SpIRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    elseif pred_tok.kind == SP_TOK_VAR
        _sp_next!(p)
        return SpVar(Symbol(pred_tok.value))
    elseif _sp_next_is_iri(p)
        return _sp_parse_iri_node(p)
    else
        _sp_parse_error(p, pred_tok,
            "Expected IRI, 'a', or variable as predicate in triple term")
    end
end

# Common simple node forms shared by every triple-term / reified-triple slot:
# Var, IRI, blank node label, '[]' anon.  Blank nodes are rejected in
# expression context (BIND), where fresh blank nodes are not permitted.
# Returns nothing if the next token is none of these (caller handles the rest).
function _sp_parse_tt_simple_node(p::SpParser, in_expr::Bool)::Union{SpExpr, Nothing}
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_VAR
        _sp_next!(p)
        return SpVar(Symbol(tok.value))
    elseif _sp_next_is_iri(p)
        return _sp_parse_iri_node(p)
    elseif tok.kind == SP_TOK_BLANK_LABEL
        in_expr && _sp_parse_error(p, tok,
            "Blank nodes are not allowed in a triple term used in an expression")
        _sp_next!(p)
        return SpBNode(tok.value)
    elseif tok.kind == SP_TOK_ANON
        in_expr && _sp_parse_error(p, tok,
            "Blank nodes are not allowed in a triple term used in an expression")
        _sp_next!(p)
        return SpAnonBNode()
    end
    return nothing
end

# ttSubject ::= Var | iri | BlankNode | TripleTerm   (no reified triple, no literal)
# In expression / data-block (VALUES) context a nested triple term is NOT
# allowed as the subject (only as the object).
function _sp_parse_tt_subject(p::SpParser; in_expr::Bool=false)::SpExpr
    if _sp_peek_kind(p) == SP_TOK_TT_OPEN
        in_expr && _sp_parse_error(p, sp_peek_token(p.lex),
            "A triple term is not allowed as the subject of a triple term in " *
            "an expression or VALUES clause")
        return _sp_parse_triple_term_expr(p; in_expr=in_expr)
    end
    n = _sp_parse_tt_simple_node(p, in_expr)
    n !== nothing && return n
    _sp_parse_error(p, sp_peek_token(p.lex),
        "Expected variable, IRI, blank node, or triple term as triple-term subject")
end

# ttObject ::= ttSubject forms ∪ { RDFLiteral | NumericLiteral | BooleanLiteral }
function _sp_parse_tt_object(p::SpParser; in_expr::Bool=false)::SpExpr
    if _sp_peek_kind(p) == SP_TOK_TT_OPEN
        return _sp_parse_triple_term_expr(p; in_expr=in_expr)
    end
    n = _sp_parse_tt_simple_node(p, in_expr)
    n !== nothing && return n
    if _sp_next_is_literal(p);  return _sp_parse_rdf_literal(p);     end
    if _sp_next_is_numeric(p);  return _sp_parse_numeric_literal(p); end
    if _sp_next_is_boolean(p);  return _sp_parse_boolean_literal(p); end
    _sp_parse_error(p, sp_peek_token(p.lex),
        "Expected term as triple-term object")
end

# Parse an embedded triple term <<( ttSubject verb ttObject )>>
# Caller must have already peeked SP_TOK_TT_OPEN but NOT consumed it.
function _sp_parse_triple_term_expr(p::SpParser; in_expr::Bool=false)::SpTripleTerm
    _sp_expect!(p, SP_TOK_TT_OPEN)   # consume '<<('
    s    = _sp_parse_tt_subject(p; in_expr=in_expr)
    pred = _sp_parse_tt_verb(p)
    o    = _sp_parse_tt_object(p; in_expr=in_expr)
    _sp_expect!(p, SP_TOK_TT_CLOSE)  # consume ')>>'
    SpTripleTerm(s, pred, o)
end

# ── SPARQL 1.2 reified triples and annotations ────────────────────────────────

const _SP_RDF_REIFIES_IRI = "http://www.w3.org/1999/02/22-rdf-syntax-ns#reifies"

# rtSubject ::= Var | iri | BlankNode | ReifiedTriple | TripleTerm  (no literal)
function _sp_parse_rt_subject(p::SpParser, triples::Vector{SpTriple})::SpExpr
    k = _sp_peek_kind(p)
    k == SP_TOK_TT_OPEN && return _sp_parse_triple_term_expr(p)
    k == SP_TOK_RT_OPEN && return _sp_parse_reified_triple!(p, triples)
    n = _sp_parse_tt_simple_node(p, false)
    n !== nothing && return n
    _sp_parse_error(p, sp_peek_token(p.lex),
        "Expected variable, IRI, blank node, reified triple, or triple term as reified-triple subject")
end

# rtObject ::= rtSubject forms ∪ { literal }   (note: NIL '()' is NOT allowed)
function _sp_parse_rt_object(p::SpParser, triples::Vector{SpTriple})::SpExpr
    k = _sp_peek_kind(p)
    k == SP_TOK_TT_OPEN && return _sp_parse_triple_term_expr(p)
    k == SP_TOK_RT_OPEN && return _sp_parse_reified_triple!(p, triples)
    n = _sp_parse_tt_simple_node(p, false)
    n !== nothing && return n
    if _sp_next_is_literal(p);  return _sp_parse_rdf_literal(p);     end
    if _sp_next_is_numeric(p);  return _sp_parse_numeric_literal(p); end
    if _sp_next_is_boolean(p);  return _sp_parse_boolean_literal(p); end
    _sp_parse_error(p, sp_peek_token(p.lex),
        "Expected term as reified-triple object")
end

# Parse the optional node after '~' (the '~' is already consumed):
# Var | iri | BlankNode, or a fresh anonymous blank node for a bare '~'.
function _sp_parse_reifier_node(p::SpParser)::SpExpr
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_VAR
        _sp_next!(p)
        return SpVar(Symbol(tok.value))
    elseif _sp_next_is_iri(p)
        return _sp_parse_iri_node(p)
    elseif tok.kind == SP_TOK_BLANK_LABEL
        _sp_next!(p)
        return SpBNode(tok.value)
    elseif tok.kind == SP_TOK_ANON
        _sp_next!(p)
        return SpAnonBNode()
    else
        return SpAnonBNode()   # bare '~'
    end
end

# reifiedTriple ::= '<<' rtSubject verb rtObject reifier? '>>'
# Emits the pattern triple  reifier rdf:reifies <<( s p o )>>  into `triples`
# and returns the reifier expression (the value of the reified triple).
function _sp_parse_reified_triple!(p::SpParser, triples::Vector{SpTriple})::SpExpr
    _sp_expect!(p, SP_TOK_RT_OPEN)   # consume '<<'
    s    = _sp_parse_rt_subject(p, triples)
    pred = _sp_parse_tt_verb(p)
    o    = _sp_parse_rt_object(p, triples)
    reifier = if _sp_peek_kind(p) == SP_TOK_TILDE
        _sp_next!(p)
        _sp_parse_reifier_node(p)
    else
        SpAnonBNode()
    end
    _sp_expect!(p, SP_TOK_RT_CLOSE)  # consume '>>'
    push!(triples, SpTriple(reifier, SpIRI(_SP_RDF_REIFIES_IRI), SpTripleTerm(s, pred, o)))
    reifier
end

# Convert the verb of an annotated object back to a plain predicate expression.
# Only a simple IRI ('a' included) or variable verb can be annotated.
function _sp_annotation_pred(p::SpParser, verb::Union{SpExpr, SpPath})::SpExpr
    verb isa SpPathIRI && return SpIRI(verb.value)
    verb isa SpPathA   && return SpIRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    verb isa SpVar     && return verb
    verb isa SpIRI     && return verb
    _sp_parse_error_here(p, "Annotations cannot be attached to property-path predicates")
end

# annotation ::= (reifier | annotationBlock)*       (SPARQL 1.2)
# Parsed after an object in an object list; appends the reifier and annotation
# pattern triples to `triples`.
function _sp_parse_annotation!(p::SpParser, subject::SpExpr,
                               verb::Union{SpExpr, SpPath},
                               obj::SpExpr, triples::Vector{SpTriple})
    cur_reifier = nothing
    while true
        k = _sp_peek_kind(p)
        if k == SP_TOK_TILDE
            _sp_next!(p)
            r = _sp_parse_reifier_node(p)
            pred = _sp_annotation_pred(p, verb)
            push!(triples, SpTriple(r, SpIRI(_SP_RDF_REIFIES_IRI),
                                    SpTripleTerm(subject, pred, obj)))
            cur_reifier = r
        elseif k == SP_TOK_ANN_OPEN
            _sp_next!(p)
            r = cur_reifier
            if r === nothing
                r = SpAnonBNode()
                pred = _sp_annotation_pred(p, verb)
                push!(triples, SpTriple(r, SpIRI(_SP_RDF_REIFIES_IRI),
                                        SpTripleTerm(subject, pred, obj)))
            end
            _sp_parse_property_list_path_not_empty!(p, r, triples)
            _sp_expect!(p, SP_TOK_ANN_CLOSE)
            cur_reifier = nothing
        else
            break
        end
    end
end

# Parse a VarOrTerm (used in triple subject/object contexts)
function _sp_parse_var_or_term(p::SpParser)::SpExpr
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_VAR
        _sp_next!(p)
        return SpVar(Symbol(tok.value))
    elseif _sp_next_is_iri(p)
        return _sp_parse_iri_node(p)
    elseif tok.kind == SP_TOK_BLANK_LABEL
        _sp_next!(p)
        return SpBNode(tok.value)
    elseif tok.kind == SP_TOK_ANON
        _sp_next!(p)
        return SpAnonBNode()
    elseif tok.kind == SP_TOK_NIL
        _sp_next!(p)
        return SpIRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
    elseif _sp_next_is_literal(p)
        return _sp_parse_rdf_literal(p)
    elseif _sp_next_is_numeric(p)
        return _sp_parse_numeric_literal(p)
    elseif _sp_next_is_boolean(p)
        return _sp_parse_boolean_literal(p)
    elseif tok.kind == SP_TOK_TT_OPEN
        return _sp_parse_triple_term_expr(p)
    else
        _sp_parse_error(p, tok, "Expected term (variable, IRI, literal, blank node, or embedded triple term)")
    end
end

# ── Triple pattern parsing (property paths) ────────────────────────────────────

# Check if next token could be a path verb (IRI, 'a', '!', '(', '^', VAR for VerbSimple)
function _sp_next_is_verb(p::SpParser)::Bool
    tok = sp_peek_token(p.lex)
    tok.kind == SP_TOK_A ||
    tok.kind == SP_TOK_VAR ||
    tok.kind == SP_TOK_IRIREF || tok.kind == SP_TOK_PNAME_LN || tok.kind == SP_TOK_PNAME_NS ||
    tok.kind == SP_TOK_BANG ||
    tok.kind == SP_TOK_LPAREN ||
    tok.kind == SP_TOK_CARET ||
    tok.kind == SP_TOK_PLUS || tok.kind == SP_TOK_STAR  # for paths
end

# Parse verb path or simple verb
# Returns Union{SpExpr, SpPath} — SpVar for VerbSimple, SpPath for VerbPath
function _sp_parse_verb_path_or_simple(p::SpParser)::Union{SpExpr, SpPath}
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_A
        _sp_next!(p)
        return SpPathA()
    elseif tok.kind == SP_TOK_VAR
        _sp_next!(p)
        return SpVar(Symbol(tok.value))
    else
        return _sp_parse_path(p)
    end
end

# Parse triples for a given subject, collecting into `triples`
# subject is already parsed
function _sp_parse_property_list_path_not_empty!(
    p::SpParser, subject::SpExpr, triples::Vector{SpTriple}
)
    while true
        verb = _sp_parse_verb_path_or_simple(p)
        # Parse ObjectListPath
        _sp_parse_object_list_path!(p, subject, verb, triples)

        # Check for ';' to continue property list
        if _sp_peek_kind(p) == SP_TOK_SEMI
            _sp_next!(p)  # consume ';'
            # After ';', may have another predicate-object pair, or end
            if !_sp_next_is_verb(p)
                break
            end
            # continue loop
        else
            break
        end
    end
end

function _sp_parse_object_list_path!(
    p::SpParser, subject::SpExpr, verb::Union{SpExpr, SpPath}, triples::Vector{SpTriple}
)
    # Parse first object
    _sp_parse_graph_node_path!(p, subject, verb, triples)
    # Parse additional objects separated by ','
    while _sp_peek_kind(p) == SP_TOK_COMMA
        _sp_next!(p)  # consume ','
        _sp_parse_graph_node_path!(p, subject, verb, triples)
    end
end

function _sp_parse_graph_node_path!(
    p::SpParser, subject::SpExpr, verb::Union{SpExpr, SpPath}, triples::Vector{SpTriple}
)
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_LBRACKET
        # Blank node property list path
        _sp_next!(p)  # consume '['
        bnode = SpAnonBNode()
        push!(triples, SpTriple(subject, verb, bnode))
        if _sp_next_is_verb(p)
            _sp_parse_property_list_path_not_empty!(p, bnode, triples)
        end
        _sp_expect!(p, SP_TOK_RBRACKET)
        _sp_parse_annotation!(p, subject, verb, bnode, triples)
    elseif tok.kind == SP_TOK_LPAREN
        # Collection path
        obj = _sp_parse_collection_path!(p, triples)
        push!(triples, SpTriple(subject, verb, obj))
        _sp_parse_annotation!(p, subject, verb, obj, triples)
    elseif tok.kind == SP_TOK_NIL
        _sp_next!(p)
        obj = SpIRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
        push!(triples, SpTriple(subject, verb, obj))
        _sp_parse_annotation!(p, subject, verb, obj, triples)
    elseif tok.kind == SP_TOK_RT_OPEN
        # SPARQL 1.2: reified triple as object — its value is the reifier
        obj = _sp_parse_reified_triple!(p, triples)
        push!(triples, SpTriple(subject, verb, obj))
        _sp_parse_annotation!(p, subject, verb, obj, triples)
    else
        obj = _sp_parse_var_or_term(p)
        push!(triples, SpTriple(subject, verb, obj))
        _sp_parse_annotation!(p, subject, verb, obj, triples)
    end
end

# Parse an RDF collection: ( item+ )
# Returns the head node; also adds the rdf:first/rdf:rest triples
function _sp_parse_collection_path!(p::SpParser, triples::Vector{SpTriple})::SpExpr
    _sp_expect!(p, SP_TOK_LPAREN)
    rdf_first = SpIRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
    rdf_rest  = SpIRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
    rdf_nil   = SpIRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
    rdf_type  = SpIRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")

    nodes = SpExpr[]
    while _sp_peek_kind(p) != SP_TOK_RPAREN
        item_bnode = SpAnonBNode()
        push!(nodes, item_bnode)
        tok = sp_peek_token(p.lex)
        item_val = if tok.kind == SP_TOK_LPAREN
            _sp_parse_collection_path!(p, triples)
        elseif tok.kind == SP_TOK_LBRACKET
            _sp_next!(p)
            inner_bnode = SpAnonBNode()
            if _sp_next_is_verb(p)
                _sp_parse_property_list_path_not_empty!(p, inner_bnode, triples)
            end
            _sp_expect!(p, SP_TOK_RBRACKET)
            inner_bnode
        elseif tok.kind == SP_TOK_NIL
            _sp_next!(p)
            rdf_nil
        elseif tok.kind == SP_TOK_RT_OPEN
            # SPARQL 1.2: reified triple as a collection item
            _sp_parse_reified_triple!(p, triples)
        else
            _sp_parse_var_or_term(p)
        end
        push!(triples, SpTriple(item_bnode, rdf_first, item_val))
    end
    _sp_expect!(p, SP_TOK_RPAREN)

    # Chain the nodes with rdf:rest
    isempty(nodes) && return rdf_nil
    for i in 1:length(nodes)-1
        push!(triples, SpTriple(nodes[i], rdf_rest, nodes[i+1]))
    end
    push!(triples, SpTriple(nodes[end], rdf_rest, rdf_nil))

    return nodes[1]
end

# Parse TriplesSameSubjectPath — returns list of triples
function _sp_parse_triples_same_subject_path(p::SpParser)::Vector{SpTriple}
    triples = SpTriple[]
    tok = sp_peek_token(p.lex)

    if tok.kind == SP_TOK_LBRACKET
        # BlankNodePropertyListPath — blank node is both subject and returned
        _sp_next!(p)  # consume '['
        bnode = SpAnonBNode()
        if _sp_next_is_verb(p)
            _sp_parse_property_list_path_not_empty!(p, bnode, triples)
        end
        _sp_expect!(p, SP_TOK_RBRACKET)
        # The blank node may itself have properties
        if _sp_next_is_verb(p)
            _sp_parse_property_list_path_not_empty!(p, bnode, triples)
        end
    elseif tok.kind == SP_TOK_LPAREN
        # CollectionPath as subject
        subject = _sp_parse_collection_path!(p, triples)
        if _sp_next_is_verb(p)
            _sp_parse_property_list_path_not_empty!(p, subject, triples)
        end
    elseif tok.kind == SP_TOK_NIL
        _sp_next!(p)
        subject = SpIRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
        if _sp_next_is_verb(p)
            _sp_parse_property_list_path_not_empty!(p, subject, triples)
        end
    elseif tok.kind == SP_TOK_RT_OPEN
        # SPARQL 1.2: reified triple as subject (property list optional —
        # the reified triple already contributes its rdf:reifies pattern)
        subject = _sp_parse_reified_triple!(p, triples)
        if _sp_next_is_verb(p)
            _sp_parse_property_list_path_not_empty!(p, subject, triples)
        end
    elseif tok.kind == SP_TOK_TT_OPEN
        # SPARQL 1.2: triple term as subject
        subject = _sp_parse_triple_term_expr(p)
        _sp_parse_property_list_path_not_empty!(p, subject, triples)
    else
        subject = _sp_parse_var_or_term(p)
        _sp_parse_property_list_path_not_empty!(p, subject, triples)
    end
    return triples
end

# ── TriplesBlock parsing ───────────────────────────────────────────────────────

# Check if next token could start a triples block
function _sp_next_starts_triples(p::SpParser)::Bool
    k = _sp_peek_kind(p)
    k == SP_TOK_VAR ||
    k == SP_TOK_IRIREF || k == SP_TOK_PNAME_LN || k == SP_TOK_PNAME_NS ||
    k == SP_TOK_BLANK_LABEL || k == SP_TOK_ANON || k == SP_TOK_NIL ||
    k == SP_TOK_STR1 || k == SP_TOK_STR2 || k == SP_TOK_STR_LONG1 || k == SP_TOK_STR_LONG2 ||
    k == SP_TOK_INTEGER || k == SP_TOK_DECIMAL || k == SP_TOK_DOUBLE ||
    k == SP_TOK_LBRACKET || k == SP_TOK_LPAREN ||
    k == SP_TOK_TT_OPEN ||   # rejected later with a clear error (not a legal subject)
    k == SP_TOK_RT_OPEN ||   # SPARQL 1.2: reified triple as subject
    (k == SP_TOK_KW && (sp_peek_token(p.lex).value == "true" || sp_peek_token(p.lex).value == "false"))
end

function _sp_parse_triples_block(p::SpParser)::Vector{SpTriple}
    all_triples = SpTriple[]
    while _sp_next_starts_triples(p)
        triples = _sp_parse_triples_same_subject_path(p)
        append!(all_triples, triples)
        if _sp_peek_kind(p) == SP_TOK_DOT
            _sp_next!(p)  # consume '.'
            # continue loop if more triples
        else
            break
        end
    end
    return all_triples
end

# ── Expression parsing ────────────────────────────────────────────────────────

# Forward declarations (handled via mutual recursion in Julia since all functions
# are defined before module finalization)

function _sp_parse_expression(p::SpParser)::SpExpr
    _sp_parse_conditional_or(p)
end

function _sp_parse_conditional_or(p::SpParser)::SpExpr
    left = _sp_parse_conditional_and(p)
    while _sp_peek_kind(p) == SP_TOK_OR
        _sp_next!(p)
        right = _sp_parse_conditional_and(p)
        left = SpBinary(:or, left, right)
    end
    return left
end

function _sp_parse_conditional_and(p::SpParser)::SpExpr
    left = _sp_parse_relational(p)
    while _sp_peek_kind(p) == SP_TOK_AND
        _sp_next!(p)
        right = _sp_parse_relational(p)
        left = SpBinary(:and, left, right)
    end
    return left
end

function _sp_parse_relational(p::SpParser)::SpExpr
    left = _sp_parse_additive(p)
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_EQ
        _sp_next!(p)
        right = _sp_parse_additive(p)
        return SpBinary(:eq, left, right)
    elseif tok.kind == SP_TOK_NEQ
        _sp_next!(p)
        right = _sp_parse_additive(p)
        return SpBinary(:neq, left, right)
    elseif tok.kind == SP_TOK_LT
        _sp_next!(p)
        right = _sp_parse_additive(p)
        return SpBinary(:lt, left, right)
    elseif tok.kind == SP_TOK_LE
        _sp_next!(p)
        right = _sp_parse_additive(p)
        return SpBinary(:le, left, right)
    elseif tok.kind == SP_TOK_GT
        _sp_next!(p)
        right = _sp_parse_additive(p)
        return SpBinary(:gt, left, right)
    elseif tok.kind == SP_TOK_GE
        _sp_next!(p)
        right = _sp_parse_additive(p)
        return SpBinary(:ge, left, right)
    elseif tok.kind == SP_TOK_KW && tok.value == "in"
        _sp_next!(p)
        list = _sp_parse_expression_list(p)
        return SpIn(left, list, false)
    elseif tok.kind == SP_TOK_KW && tok.value == "not"
        _sp_next!(p)
        _sp_expect_kw!(p, "in")
        list = _sp_parse_expression_list(p)
        return SpIn(left, list, true)
    end
    return left
end

function _sp_parse_expression_list(p::SpParser)::Vector{SpExpr}
    # NIL token "()" represents an empty expression list
    if _sp_peek_kind(p) == SP_TOK_NIL
        _sp_next!(p)
        return SpExpr[]
    end
    _sp_expect!(p, SP_TOK_LPAREN)
    exprs = SpExpr[]
    if _sp_peek_kind(p) != SP_TOK_RPAREN
        push!(exprs, _sp_parse_expression(p))
        while _sp_eat!(p, SP_TOK_COMMA)
            push!(exprs, _sp_parse_expression(p))
        end
    end
    _sp_expect!(p, SP_TOK_RPAREN)
    return exprs
end

function _sp_parse_additive(p::SpParser)::SpExpr
    left = _sp_parse_multiplicative(p)
    while true
        tok = sp_peek_token(p.lex)
        if tok.kind == SP_TOK_PLUS
            _sp_next!(p)
            right = _sp_parse_multiplicative(p)
            left = SpBinary(:add, left, right)
        elseif tok.kind == SP_TOK_MINUS_TOK
            _sp_next!(p)
            right = _sp_parse_multiplicative(p)
            left = SpBinary(:sub, left, right)
        elseif tok.kind == SP_TOK_INTEGER || tok.kind == SP_TOK_DECIMAL || tok.kind == SP_TOK_DOUBLE
            # Signed numeric literal in additive continuation position per SPARQL grammar:
            # AdditiveExpression ::= MultiplicativeExpression
            #   ( ... | NumericLiteralPositive (...) | NumericLiteralNegative (...) )*
            # e.g. ?o+10 or ?o-10 means ?o + (10) or ?o + (-10)
            v = tok.value
            if startswith(v, "+") || startswith(v, "-")
                _sp_next!(p)
                dt = tok.kind == SP_TOK_INTEGER ? "http://www.w3.org/2001/XMLSchema#integer" :
                     tok.kind == SP_TOK_DECIMAL ? "http://www.w3.org/2001/XMLSchema#decimal" :
                                                  "http://www.w3.org/2001/XMLSchema#double"
                lit::SpExpr = SpLiteral(v, dt, "")
                # Per grammar: after the signed literal, optional * / continuations apply to it
                while true
                    tok2 = sp_peek_token(p.lex)
                    if tok2.kind == SP_TOK_STAR
                        _sp_next!(p)
                        r2 = _sp_parse_unary(p)
                        lit = SpBinary(:mul, lit, r2)
                    elseif tok2.kind == SP_TOK_SLASH
                        _sp_next!(p)
                        r2 = _sp_parse_unary(p)
                        lit = SpBinary(:div, lit, r2)
                    else
                        break
                    end
                end
                left = SpBinary(:add, left, lit)
            else
                break  # Unsigned literal — not a continuation
            end
        else
            break
        end
    end
    return left
end

function _sp_parse_multiplicative(p::SpParser)::SpExpr
    left = _sp_parse_unary(p)
    while true
        tok = sp_peek_token(p.lex)
        if tok.kind == SP_TOK_STAR
            _sp_next!(p)
            right = _sp_parse_unary(p)
            left = SpBinary(:mul, left, right)
        elseif tok.kind == SP_TOK_SLASH
            _sp_next!(p)
            right = _sp_parse_unary(p)
            left = SpBinary(:div, left, right)
        else
            break
        end
    end
    return left
end

function _sp_parse_unary(p::SpParser)::SpExpr
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_BANG
        # SPARQL 1.2 allows '!' to stack (e.g. !!?v); recurse into UnaryExpression.
        _sp_next!(p)
        arg = _sp_parse_unary(p)
        return SpUnary(:not, arg)
    elseif tok.kind == SP_TOK_PLUS
        _sp_next!(p)
        arg = _sp_parse_primary(p)
        return SpUnary(:pos, arg)
    elseif tok.kind == SP_TOK_MINUS_TOK
        _sp_next!(p)
        arg = _sp_parse_primary(p)
        return SpUnary(:neg, arg)
    else
        return _sp_parse_primary(p)
    end
end

# Built-in call names (lowercase)
const _SP_BUILTINS_1 = Set{String}([
    "str", "lang", "datatype", "iri", "uri", "bnode", "abs", "ceil", "floor",
    "round", "strlen", "ucase", "lcase", "encode_for_uri", "year", "month",
    "day", "hours", "minutes", "seconds", "timezone", "tz", "md5", "sha1",
    "sha256", "sha384", "sha512", "uuid", "struuid", "rand", "now",
    # SPARQL 1.2
    "langdir", "haslang", "haslangdir", "istriple", "subject", "predicate",
    "object",
])

const _SP_BUILTINS_2 = Set{String}([
    "langmatches", "contains", "strstarts", "strends", "strbefore", "strafter",
    "strlang", "strdt", "sameterm", "isiri", "isuri", "isblank", "isliteral",
    "isnumeric", "bound",
])

const _SP_BUILTINS_3 = Set{String}([
    "regex", "substr", "replace", "if",
    # SPARQL 1.2
    "triple", "strlangdir",
])

function _sp_parse_primary(p::SpParser)::SpExpr
    tok = sp_peek_token(p.lex)

    # SPARQL 1.2: triple term in expression position — <<( s p o )>>
    # (blank nodes are not allowed here)
    if tok.kind == SP_TOK_TT_OPEN
        return _sp_parse_triple_term_expr(p; in_expr=true)
    end

    # Bracketed expression
    if tok.kind == SP_TOK_LPAREN
        _sp_next!(p)
        expr = _sp_parse_expression(p)
        _sp_expect!(p, SP_TOK_RPAREN)
        return expr

    # Variable
    elseif tok.kind == SP_TOK_VAR
        _sp_next!(p)
        return SpVar(Symbol(tok.value))

    # RDF Literal
    elseif _sp_next_is_literal(p)
        return _sp_parse_rdf_literal(p)

    # Numeric literal
    elseif _sp_next_is_numeric(p)
        return _sp_parse_numeric_literal(p)

    # Boolean literal
    elseif _sp_next_is_boolean(p)
        return _sp_parse_boolean_literal(p)

    # IRI or function call
    elseif _sp_next_is_iri(p)
        iri = _sp_parse_iri(p)
        # Check for function call
        if _sp_peek_kind(p) == SP_TOK_LPAREN || _sp_peek_kind(p) == SP_TOK_NIL
            args = _sp_parse_arg_list(p)
            return SpCall(iri, args)
        end
        return SpIRI(iri)

    # Built-in calls and keywords
    elseif tok.kind == SP_TOK_KW
        kw = tok.value

        # Aggregate functions
        if kw in ("count", "sum", "min", "max", "avg", "sample", "group_concat")
            return _sp_parse_aggregate(p)
        end

        # EXISTS / NOT EXISTS
        if kw == "exists"
            _sp_next!(p)
            pat = _sp_parse_group_graph_pattern(p)
            return SpExists(pat)
        elseif kw == "not"
            _sp_next!(p)
            _sp_expect_kw!(p, "exists")
            pat = _sp_parse_group_graph_pattern(p)
            return SpNotExists(pat)
        end

        # IF
        if kw == "if"
            _sp_next!(p)
            _sp_expect!(p, SP_TOK_LPAREN)
            cond = _sp_parse_expression(p)
            _sp_expect!(p, SP_TOK_COMMA)
            then_ = _sp_parse_expression(p)
            _sp_expect!(p, SP_TOK_COMMA)
            else_ = _sp_parse_expression(p)
            _sp_expect!(p, SP_TOK_RPAREN)
            return SpIf(cond, then_, else_)
        end

        # COALESCE
        if kw == "coalesce"
            _sp_next!(p)
            args = SpExpr[]
            if _sp_peek_kind(p) == SP_TOK_NIL
                _sp_next!(p)   # consume "()" — zero args COALESCE
            else
                _sp_expect!(p, SP_TOK_LPAREN)
                if _sp_peek_kind(p) != SP_TOK_RPAREN
                    push!(args, _sp_parse_expression(p))
                    while _sp_eat!(p, SP_TOK_COMMA)
                        push!(args, _sp_parse_expression(p))
                    end
                end
                _sp_expect!(p, SP_TOK_RPAREN)
            end
            return SpCoalesce(args)
        end

        # CONCAT
        if kw == "concat"
            _sp_next!(p)
            args = _sp_parse_arg_list(p)
            return SpCall("concat", args)
        end

        # Built-in functions with parenthesized args
        if kw in _SP_BUILTINS_1 || kw in _SP_BUILTINS_2 || kw in _SP_BUILTINS_3
            _sp_next!(p)
            args = _sp_parse_arg_list(p)
            return SpCall(kw, args)
        end

        # REGEX (special: 2 or 3 args)
        if kw == "regex"
            _sp_next!(p)
            args = _sp_parse_arg_list(p)
            return SpCall("regex", args)
        end

        # SUBSTR (special: 2 or 3 args)
        if kw == "substr"
            _sp_next!(p)
            args = _sp_parse_arg_list(p)
            return SpCall("substr", args)
        end

        # REPLACE
        if kw == "replace"
            _sp_next!(p)
            args = _sp_parse_arg_list(p)
            return SpCall("replace", args)
        end

        _sp_parse_error(p, tok, "Unexpected keyword $(repr(kw)) in expression")

    elseif tok.kind == SP_TOK_A
        # 'a' as rdf:type in expressions is unusual, but handle it
        _sp_next!(p)
        return SpIRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")

    else
        _sp_parse_error(p, tok, "Expected expression, got $(tok.kind)")
    end
end

function _sp_parse_arg_list(p::SpParser)::Vector{SpExpr}
    args = SpExpr[]
    if _sp_peek_kind(p) == SP_TOK_NIL
        _sp_next!(p)
        return args
    end
    _sp_expect!(p, SP_TOK_LPAREN)
    if _sp_peek_kind(p) != SP_TOK_RPAREN
        push!(args, _sp_parse_expression(p))
        while _sp_eat!(p, SP_TOK_COMMA)
            push!(args, _sp_parse_expression(p))
        end
    end
    _sp_expect!(p, SP_TOK_RPAREN)
    return args
end

function _sp_parse_aggregate(p::SpParser)::SpAggregate
    tok = _sp_next!(p)
    kw = tok.value
    func_sym = Symbol(kw)
    _sp_expect!(p, SP_TOK_LPAREN)
    distinct = _sp_eat_kw!(p, "distinct")

    if func_sym == :count
        if _sp_peek_kind(p) == SP_TOK_STAR
            _sp_next!(p)
            _sp_expect!(p, SP_TOK_RPAREN)
            return SpAggregate(:count, distinct, nothing, nothing)
        else
            arg = _sp_parse_expression(p)
            _sp_reject_nested_aggregate(p, arg)
            _sp_expect!(p, SP_TOK_RPAREN)
            return SpAggregate(:count, distinct, arg, nothing)
        end
    elseif func_sym == :group_concat
        arg = _sp_parse_expression(p)
        _sp_reject_nested_aggregate(p, arg)
        sep::Union{String,Nothing} = nothing
        if _sp_peek_kind(p) == SP_TOK_SEMI
            _sp_next!(p)
            _sp_expect_kw!(p, "separator")
            _sp_expect!(p, SP_TOK_EQ)
            str_tok = _sp_next!(p)
            (str_tok.kind in (SP_TOK_STR1, SP_TOK_STR2, SP_TOK_STR_LONG1, SP_TOK_STR_LONG2)) ||
                _sp_parse_error(p, str_tok, "Expected string for SEPARATOR")
            sep = _unescape_string(str_tok.value)
        end
        _sp_expect!(p, SP_TOK_RPAREN)
        return SpAggregate(:group_concat, distinct, arg, sep)
    else
        arg = _sp_parse_expression(p)
        _sp_reject_nested_aggregate(p, arg)
        _sp_expect!(p, SP_TOK_RPAREN)
        return SpAggregate(func_sym, distinct, arg, nothing)
    end
end

# An aggregate's argument expression may not itself contain an aggregate
# (e.g. COUNT(SUM(?x)) is a static error).
function _sp_contains_aggregate(e::SpExpr)::Bool
    e isa SpAggregate && return true
    e isa SpUnary     && return _sp_contains_aggregate(e.arg)
    e isa SpBinary    && return _sp_contains_aggregate(e.left) || _sp_contains_aggregate(e.right)
    (e isa SpCall || e isa SpCoalesce) && return any(_sp_contains_aggregate, e.args)
    e isa SpIn        && return _sp_contains_aggregate(e.expr) || any(_sp_contains_aggregate, e.list)
    e isa SpIf        && return _sp_contains_aggregate(e.cond) ||
                                _sp_contains_aggregate(e.then_) || _sp_contains_aggregate(e.else_)
    return false
end

function _sp_reject_nested_aggregate(p::SpParser, arg::SpExpr)
    _sp_contains_aggregate(arg) &&
        _sp_parse_error_here(p, "Aggregate functions may not be nested")
    nothing
end

# ── Graph pattern helpers ─────────────────────────────────────────────────────

# Returns true if next token can start a GraphPatternNotTriples
function _sp_next_starts_graph_pattern_not_triples(p::SpParser)::Bool
    tok = sp_peek_token(p.lex)
    tok.kind == SP_TOK_LBRACE && return true  # GroupOrUnionGraphPattern
    tok.kind != SP_TOK_KW && return false
    kw = tok.value
    kw in ("optional", "minus", "graph", "service", "filter", "bind", "values")
end

# ── InlineData / VALUES ───────────────────────────────────────────────────────

function _sp_parse_data_block_value(p::SpParser)::Union{SpExpr, Nothing}
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_KW && tok.value == "undef"
        _sp_next!(p)
        return nothing
    elseif _sp_next_is_iri(p)
        return _sp_parse_iri_node(p)
    elseif _sp_next_is_literal(p)
        return _sp_parse_rdf_literal(p)
    elseif _sp_next_is_numeric(p)
        return _sp_parse_numeric_literal(p)
    elseif _sp_next_is_boolean(p)
        return _sp_parse_boolean_literal(p)
    elseif tok.kind == SP_TOK_TT_OPEN
        # SPARQL 1.2: ground triple term as a data-block value (no blank nodes)
        return _sp_parse_triple_term_expr(p; in_expr=true)
    else
        _sp_parse_error(p, tok, "Expected data block value (IRI, literal, triple term, or UNDEF)")
    end
end

function _sp_parse_inline_data(p::SpParser)::SpValues
    # VALUES DataBlock
    tok = sp_peek_token(p.lex)

    if tok.kind == SP_TOK_VAR
        # InlineDataOneVar
        var = _sp_parse_var(p)
        _sp_expect!(p, SP_TOK_LBRACE)
        rows = Vector{Union{SpExpr, Nothing}}[]
        while _sp_peek_kind(p) != SP_TOK_RBRACE
            val = _sp_parse_data_block_value(p)
            push!(rows, Union{SpExpr, Nothing}[val])
        end
        _sp_expect!(p, SP_TOK_RBRACE)
        return SpValues([var], rows)
    elseif tok.kind == SP_TOK_NIL
        # InlineDataFull with NIL variables
        _sp_next!(p)  # consume NIL
        _sp_expect!(p, SP_TOK_LBRACE)
        rows = Vector{Union{SpExpr, Nothing}}[]
        while _sp_peek_kind(p) != SP_TOK_RBRACE
            if _sp_peek_kind(p) == SP_TOK_NIL
                _sp_next!(p)
                push!(rows, Union{SpExpr, Nothing}[])
            else
                _sp_parse_error_here(p, "Expected NIL row in InlineDataFull with no variables")
            end
        end
        _sp_expect!(p, SP_TOK_RBRACE)
        return SpValues(SpVar[], rows)
    elseif tok.kind == SP_TOK_LPAREN
        # InlineDataFull: '(' Var* ')' '{' ... '}'
        _sp_next!(p)  # consume '('
        vars = SpVar[]
        seen_vars = Set{Symbol}()
        while _sp_peek_kind(p) == SP_TOK_VAR
            vtok = sp_peek_token(p.lex)
            v = _sp_parse_var(p)
            v.name in seen_vars &&
                _sp_parse_error(p, vtok, "Duplicate variable '?$(v.name)' in VALUES clause")
            push!(seen_vars, v.name)
            push!(vars, v)
        end
        _sp_expect!(p, SP_TOK_RPAREN)
        _sp_expect!(p, SP_TOK_LBRACE)
        rows = Vector{Union{SpExpr, Nothing}}[]
        while _sp_peek_kind(p) != SP_TOK_RBRACE
            if _sp_peek_kind(p) == SP_TOK_NIL
                _sp_next!(p)
                push!(rows, Union{SpExpr, Nothing}[])
            else
                _sp_expect!(p, SP_TOK_LPAREN)
                row = Union{SpExpr, Nothing}[]
                while _sp_peek_kind(p) != SP_TOK_RPAREN
                    val = _sp_parse_data_block_value(p)
                    push!(row, val)
                end
                _sp_expect!(p, SP_TOK_RPAREN)
                length(row) == length(vars) ||
                    _sp_parse_error_here(p, "VALUES row has $(length(row)) values but $(length(vars)) variables were declared")
                push!(rows, row)
            end
        end
        _sp_expect!(p, SP_TOK_RBRACE)
        return SpValues(vars, rows)
    else
        _sp_parse_error(p, tok, "Expected variable, NIL, or '(' in VALUES data block")
    end
end

# ── GroupGraphPattern parsing ─────────────────────────────────────────────────

function _sp_parse_group_graph_pattern(p::SpParser)::SpPat
    _sp_expect!(p, SP_TOK_LBRACE)
    # Check if it's a SubSelect
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_KW && tok.value == "select"
        subq = _sp_parse_select_query(p)
        _sp_expect!(p, SP_TOK_RBRACE)
        return SpSubQuery(subq)
    else
        result = _sp_parse_group_graph_pattern_sub(p)
        _sp_expect!(p, SP_TOK_RBRACE)
        return result
    end
end

function _sp_parse_group_graph_pattern_sub(p::SpParser)::SpPat
    elements = SpPat[]

    # Accumulate triples for BGP
    current_triples = SpTriple[]

    function flush_bgp!()
        if !isempty(current_triples)
            push!(elements, SpBGP(copy(current_triples)))
            empty!(current_triples)
        end
    end

    # Optional leading TriplesBlock
    if _sp_next_starts_triples(p)
        append!(current_triples, _sp_parse_triples_block(p))
    end

    while true
        tok = sp_peek_token(p.lex)
        if tok.kind == SP_TOK_RBRACE
            break
        elseif tok.kind == SP_TOK_EOF
            break
        elseif _sp_next_starts_graph_pattern_not_triples(p)
            flush_bgp!()
            gpnt = _sp_parse_graph_pattern_not_triples(p)
            push!(elements, gpnt)
            # Optional '.' after
            _sp_eat!(p, SP_TOK_DOT)
            # Optional TriplesBlock after
            if _sp_next_starts_triples(p)
                append!(current_triples, _sp_parse_triples_block(p))
            end
        elseif tok.kind == SP_TOK_DOT
            _sp_next!(p)  # consume stray '.'
            if _sp_next_starts_triples(p)
                append!(current_triples, _sp_parse_triples_block(p))
            end
        else
            break
        end
    end

    flush_bgp!()

    if isempty(elements)
        return SpBGP()
    elseif length(elements) == 1
        return elements[1]
    else
        return SpGroup(elements)
    end
end

function _sp_parse_graph_pattern_not_triples(p::SpParser)::SpPat
    tok = sp_peek_token(p.lex)

    if tok.kind == SP_TOK_LBRACE
        # GroupOrUnionGraphPattern
        left = _sp_parse_group_graph_pattern(p)
        while _sp_peek_kw(p, "union")
            _sp_next!(p)  # consume 'union'
            right = _sp_parse_group_graph_pattern(p)
            left = SpUnion(left, right)
        end
        # If the nested { } block unwrapped to a bare BIND, re-wrap in SpGroup
        # so that BIND scope validation sees it as a nested sub-scope, not a
        # direct element of the outer group (SPARQL spec: BIND in { BIND(...) }
        # is in the subgroup's scope, not the enclosing group's scope).
        if left isa SpBind
            left = SpGroup(SpPat[left])
        end
        return left
    elseif tok.kind == SP_TOK_KW
        kw = tok.value
        if kw == "optional"
            _sp_next!(p)
            pat = _sp_parse_group_graph_pattern(p)
            return SpOptional(pat)
        elseif kw == "minus"
            _sp_next!(p)
            pat = _sp_parse_group_graph_pattern(p)
            return SpMinus(pat)
        elseif kw == "graph"
            _sp_next!(p)
            name = _sp_parse_var_or_iri(p)
            pat = _sp_parse_group_graph_pattern(p)
            return SpGraph(name, pat)
        elseif kw == "service"
            _sp_next!(p)
            silent = _sp_eat_kw!(p, "silent")
            endpoint = _sp_parse_var_or_iri(p)
            pat = _sp_parse_group_graph_pattern(p)
            return SpService(silent, endpoint, pat)
        elseif kw == "filter"
            _sp_next!(p)
            constraint = _sp_parse_constraint(p)
            return SpFilter(constraint)
        elseif kw == "bind"
            _sp_next!(p)
            _sp_expect!(p, SP_TOK_LPAREN)
            expr = _sp_parse_expression(p)
            _sp_expect_kw!(p, "as")
            var = _sp_parse_var(p)
            _sp_expect!(p, SP_TOK_RPAREN)
            return SpBind(expr, var)
        elseif kw == "values"
            _sp_next!(p)
            return _sp_parse_inline_data(p)
        else
            _sp_parse_error(p, tok, "Unexpected keyword $(repr(kw)) in graph pattern")
        end
    else
        _sp_parse_error(p, tok, "Expected graph pattern element")
    end
end

function _sp_parse_constraint(p::SpParser)::SpExpr
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_LPAREN
        _sp_next!(p)
        expr = _sp_parse_expression(p)
        _sp_expect!(p, SP_TOK_RPAREN)
        return expr
    elseif tok.kind == SP_TOK_KW && tok.value in ("exists", "not")
        return _sp_parse_primary(p)
    else
        # Bracketed expression is required for FILTER; but SPARQL also allows
        # BuiltInCall which may start with a keyword
        return _sp_parse_primary(p)
    end
end

# ── WhereClause ───────────────────────────────────────────────────────────────

function _sp_parse_where_clause(p::SpParser)::SpPat
    _sp_eat_kw!(p, "where")  # optional WHERE keyword
    _sp_parse_group_graph_pattern(p)
end

# ── Solution modifiers ────────────────────────────────────────────────────────

struct _SpSolutionMods
    group_by::Vector{SpGroupCond}
    having::Vector{SpExpr}
    order_by::Vector{SpOrderCond}
    limit::Union{Int,Nothing}
    offset::Union{Int,Nothing}
end

function _sp_parse_solution_modifier(p::SpParser)::_SpSolutionMods
    group_by = SpGroupCond[]
    having   = SpExpr[]
    order_by = SpOrderCond[]
    limit    = nothing
    offset   = nothing

    # GROUP BY
    if _sp_peek_kw(p, "group")
        tok = _sp_next!(p)  # consume 'group'
        _sp_expect_kw!(p, "by")
        while _sp_next_is_group_condition(p)
            push!(group_by, _sp_parse_group_condition(p))
        end
    end

    # HAVING
    if _sp_peek_kw(p, "having")
        _sp_next!(p)
        while _sp_next_is_having_condition(p)
            push!(having, _sp_parse_expression(p))
        end
    end

    # ORDER BY
    if _sp_peek_kw(p, "order")
        _sp_next!(p)
        _sp_expect_kw!(p, "by")
        while _sp_next_is_order_condition(p)
            push!(order_by, _sp_parse_order_condition(p))
        end
    end

    # LIMIT / OFFSET (in either order)
    if _sp_peek_kw(p, "limit")
        _sp_next!(p)
        tok = _sp_expect!(p, SP_TOK_INTEGER)
        limit = parse(Int, tok.value)
        if _sp_peek_kw(p, "offset")
            _sp_next!(p)
            tok2 = _sp_expect!(p, SP_TOK_INTEGER)
            offset = parse(Int, tok2.value)
        end
    elseif _sp_peek_kw(p, "offset")
        _sp_next!(p)
        tok = _sp_expect!(p, SP_TOK_INTEGER)
        offset = parse(Int, tok.value)
        if _sp_peek_kw(p, "limit")
            _sp_next!(p)
            tok2 = _sp_expect!(p, SP_TOK_INTEGER)
            limit = parse(Int, tok2.value)
        end
    end

    return _SpSolutionMods(group_by, having, order_by, limit, offset)
end

function _sp_next_is_group_condition(p::SpParser)::Bool
    tok = sp_peek_token(p.lex)
    tok.kind == SP_TOK_LPAREN ||
    tok.kind == SP_TOK_VAR ||
    (tok.kind == SP_TOK_KW && tok.value in ("asc", "desc")) ||
    _sp_next_is_iri(p)
end

function _sp_parse_group_condition(p::SpParser)::SpGroupCond
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_LPAREN
        _sp_next!(p)
        expr = _sp_parse_expression(p)
        var::Union{SpVar,Nothing} = nothing
        if _sp_eat_kw!(p, "as")
            var = _sp_parse_var(p)
        end
        _sp_expect!(p, SP_TOK_RPAREN)
        return SpGroupCond(expr, var)
    elseif tok.kind == SP_TOK_VAR
        v = _sp_parse_var(p)
        return SpGroupCond(v, nothing)
    elseif _sp_next_is_iri(p)
        # Built-in call with IRI
        expr = _sp_parse_primary(p)
        return SpGroupCond(expr, nothing)
    else
        expr = _sp_parse_primary(p)
        return SpGroupCond(expr, nothing)
    end
end

function _sp_next_is_having_condition(p::SpParser)::Bool
    tok = sp_peek_token(p.lex)
    # HAVING conditions are expressions; they end at ORDER/LIMIT/OFFSET/HAVING or EOF
    tok.kind == SP_TOK_EOF && return false
    tok.kind == SP_TOK_RBRACE && return false
    tok.kind == SP_TOK_KW && tok.value in ("order", "limit", "offset", "having", "values",
        "select", "where", "group") && return false
    return true
end

function _sp_next_is_order_condition(p::SpParser)::Bool
    tok = sp_peek_token(p.lex)
    tok.kind == SP_TOK_EOF && return false
    tok.kind == SP_TOK_RBRACE && return false
    tok.kind == SP_TOK_KW && tok.value in ("limit", "offset", "values", "select",
        "where", "group", "having") && return false
    return true
end

function _sp_parse_order_condition(p::SpParser)::SpOrderCond
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_KW && tok.value == "asc"
        _sp_next!(p)
        _sp_expect!(p, SP_TOK_LPAREN)
        expr = _sp_parse_expression(p)
        _sp_expect!(p, SP_TOK_RPAREN)
        return SpOrderCond(true, expr)
    elseif tok.kind == SP_TOK_KW && tok.value == "desc"
        _sp_next!(p)
        _sp_expect!(p, SP_TOK_LPAREN)
        expr = _sp_parse_expression(p)
        _sp_expect!(p, SP_TOK_RPAREN)
        return SpOrderCond(false, expr)
    elseif tok.kind == SP_TOK_LPAREN
        # bracketed expression: ascending
        _sp_next!(p)
        expr = _sp_parse_expression(p)
        _sp_expect!(p, SP_TOK_RPAREN)
        return SpOrderCond(true, expr)
    else
        # Variable or IRI: ascending
        expr = _sp_parse_primary(p)
        return SpOrderCond(true, expr)
    end
end

# ── ValuesClause ──────────────────────────────────────────────────────────────

function _sp_parse_values_clause(p::SpParser)::Union{SpValues, Nothing}
    if _sp_peek_kw(p, "values")
        _sp_next!(p)
        return _sp_parse_inline_data(p)
    end
    return nothing
end

# ── SELECT semantic validation helpers ────────────────────────────────────────

# Returns true if an expression contains an aggregate function.
function _sp_expr_is_aggregate(e::SpExpr)::Bool
    e isa SpAggregate && return true
    e isa SpCall && return false   # extension function, not aggregate
    e isa SpBinary && return _sp_expr_is_aggregate(e.left) || _sp_expr_is_aggregate(e.right)
    e isa SpUnary  && return _sp_expr_is_aggregate(e.arg)
    e isa SpIf     && return _sp_expr_is_aggregate(e.cond) || _sp_expr_is_aggregate(e.then_) || _sp_expr_is_aggregate(e.else_)
    e isa SpCoalesce && return any(_sp_expr_is_aggregate, e.args)
    e isa SpIn     && return _sp_expr_is_aggregate(e.expr)
    return false
end

# Check that a SELECT column is valid in a GROUP BY context.
function _sp_check_grouped_column(p::SpParser, col::SpSelectColumn, gb_vars::Set{Symbol})
    if col.as_var !== nothing
        # (expr AS ?var): if expr is not an aggregate and references non-grouped vars, error
        # We accept anything that is an aggregate expression
        _sp_expr_is_aggregate(col.expr) && return
        # If it's a constant (literal, IRI) → OK
        col.expr isa SpLiteral && return
        col.expr isa SpIRI     && return
        # If it references a variable not in GROUP BY → error
        _sp_check_expr_grouped(p, col.expr, gb_vars)
    else
        # Plain variable: must be in GROUP BY
        if col.expr isa SpVar
            v = (col.expr::SpVar).name
            if v ∉ gb_vars
                _sp_parse_error_here(p, "Variable '?$v' appears in SELECT but is not in GROUP BY and is not an aggregate")
            end
        else
            # Should not happen for non-AS columns, but be safe
            _sp_expr_is_aggregate(col.expr) || _sp_check_expr_grouped(p, col.expr, gb_vars)
        end
    end
end

# Check that an expression only references grouped variables (or is aggregate-contained).
function _sp_check_expr_grouped(p::SpParser, e::SpExpr, gb_vars::Set{Symbol})
    e isa SpVar     && (e.name ∉ gb_vars && _sp_parse_error_here(p, "Variable '?$(e.name)' is not in GROUP BY"); return)
    e isa SpLiteral && return
    e isa SpIRI     && return
    e isa SpBNode   && return
    e isa SpAggregate && return   # aggregate: OK
    e isa SpBinary  && (_sp_check_expr_grouped(p, e.left, gb_vars); _sp_check_expr_grouped(p, e.right, gb_vars))
    e isa SpUnary   && _sp_check_expr_grouped(p, e.arg, gb_vars)
    e isa SpCall    && foreach(a -> _sp_check_expr_grouped(p, a, gb_vars), e.args)
    e isa SpIf      && (_sp_check_expr_grouped(p, e.cond, gb_vars); _sp_check_expr_grouped(p, e.then_, gb_vars); _sp_check_expr_grouped(p, e.else_, gb_vars))
    e isa SpCoalesce && foreach(a -> _sp_check_expr_grouped(p, a, gb_vars), e.args)
    e isa SpIn      && _sp_check_expr_grouped(p, e.expr, gb_vars)
    nothing
end

# Collect the variables projected by a pattern's immediate subqueries.
function _sp_subquery_projected_vars(pat::SpPat)::Set{Symbol}
    vars = Set{Symbol}()
    _sp_collect_subq_vars!(pat, vars)
    vars
end

function _sp_collect_subq_vars!(pat::SpPat, vars::Set{Symbol})
    if pat isa SpSubQuery
        sq = pat.query
        if sq isa SpSelectQuery
            if sq.star
                # Would project everything visible — we can't easily enumerate; skip
            else
                for col in sq.columns
                    if col.as_var !== nothing
                        push!(vars, col.as_var.name)
                    elseif col.expr isa SpVar
                        push!(vars, (col.expr::SpVar).name)
                    end
                end
            end
        end
    elseif pat isa SpGroup
        for e in pat.elements; _sp_collect_subq_vars!(e, vars); end
    elseif pat isa SpOptional; _sp_collect_subq_vars!(pat.pattern, vars)
    elseif pat isa SpUnion;    _sp_collect_subq_vars!(pat.left, vars); _sp_collect_subq_vars!(pat.right, vars)
    elseif pat isa SpGraph;    _sp_collect_subq_vars!(pat.pattern, vars)
    elseif pat isa SpService;  _sp_collect_subq_vars!(pat.pattern, vars)
    end
    nothing
end

# Check that no AS ?var alias collides with a variable already in scope (from subqueries).
function _sp_check_select_scope(p::SpParser, columns::Vector{SpSelectColumn}, pattern::SpPat)
    in_scope = _sp_subquery_projected_vars(pattern)
    isempty(in_scope) && return
    for col in columns
        if col.as_var !== nothing
            if col.as_var.name in in_scope
                _sp_parse_error_here(p, "Variable '?$(col.as_var.name)' is already in scope from a subquery; cannot rebind with AS")
            end
        end
    end
end

# ── SELECT query ──────────────────────────────────────────────────────────────

function _sp_parse_select_query(p::SpParser)::SpSelectQuery
    _sp_expect_kw!(p, "select")

    distinct = false
    reduced  = false
    if _sp_peek_kw(p, "distinct")
        _sp_next!(p); distinct = true
    elseif _sp_peek_kw(p, "reduced")
        _sp_next!(p); reduced = true
    end

    star = false
    columns = SpSelectColumn[]

    if _sp_peek_kind(p) == SP_TOK_STAR
        _sp_next!(p)
        star = true
    else
        # Parse one or more: ?var or (expr AS ?var)
        alias_tok = sp_peek_token(p.lex)   # save for error location
        used_aliases = Set{Symbol}()
        while true
            tok = sp_peek_token(p.lex)
            if tok.kind == SP_TOK_VAR
                v = _sp_parse_var(p)
                push!(columns, SpSelectColumn(v, nothing))
            elseif tok.kind == SP_TOK_LPAREN
                _sp_next!(p)
                expr = _sp_parse_expression(p)
                _sp_expect_kw!(p, "as")
                as_tok = sp_peek_token(p.lex)
                var = _sp_parse_var(p)
                if var.name in used_aliases
                    _sp_parse_error(p, as_tok, "Duplicate variable binding '?$(var.name)' in SELECT")
                end
                push!(used_aliases, var.name)
                _sp_expect!(p, SP_TOK_RPAREN)
                push!(columns, SpSelectColumn(expr, var))
            else
                break
            end
        end
        isempty(columns) && _sp_parse_error_here(p, "SELECT requires at least one variable or '*'")
    end

    datasets = _sp_parse_dataset_clauses(p)
    pattern  = _sp_parse_where_clause(p)
    mods     = _sp_parse_solution_modifier(p)
    values   = _sp_parse_values_clause(p)

    # ── Semantic validation ──────────────────────────────────────────────
    if !isempty(mods.group_by)
        # SELECT * is not allowed when GROUP BY is present
        if star
            _sp_parse_error_here(p, "SELECT * is not allowed when GROUP BY is present")
        end
        # Each non-aggregate column must be in the GROUP BY list
        gb_vars = Set{Symbol}()
        for gc in mods.group_by
            if gc.expr isa SpVar
                push!(gb_vars, (gc.expr::SpVar).name)
            end
            if gc.var !== nothing
                push!(gb_vars, gc.var.name)
            end
        end
        for col in columns
            _sp_check_grouped_column(p, col, gb_vars)
            # A SELECT (expr AS ?v) must introduce a fresh variable: ?v may not
            # already be a GROUP BY key / alias that is in scope.
            if col.as_var !== nothing && col.as_var.name in gb_vars
                _sp_parse_error_here(p,
                    "Variable '?$(col.as_var.name)' is already in scope from " *
                    "GROUP BY; cannot rebind it with AS")
            end
        end
    end

    # Check that AS ?var aliases don't conflict with subquery projections
    _sp_check_select_scope(p, columns, pattern)

    return SpSelectQuery(
        distinct, reduced, star, columns, datasets, pattern,
        mods.group_by, mods.having, mods.order_by, mods.limit, mods.offset, values
    )
end

# ── CONSTRUCT query ───────────────────────────────────────────────────────────

function _sp_parse_construct_query(p::SpParser)::SpConstructQuery
    _sp_expect_kw!(p, "construct")

    template::Union{Vector{SpTriple}, Nothing} = nothing
    datasets = SpDatasetClause[]
    pattern::SpPat = SpBGP()

    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_LBRACE
        # CONSTRUCT { template } ... WHERE { pattern }
        template = _sp_parse_construct_template(p)
        datasets = _sp_parse_dataset_clauses(p)
        pattern  = _sp_parse_where_clause(p)
    else
        # CONSTRUCT FROM? WHERE { TriplesTemplate }
        datasets = _sp_parse_dataset_clauses(p)
        _sp_expect_kw!(p, "where")
        _sp_expect!(p, SP_TOK_LBRACE)
        triples = SpTriple[]
        if _sp_next_starts_triples(p)
            triples = _sp_parse_triples_template(p)
        end
        _sp_expect!(p, SP_TOK_RBRACE)
        # template = nothing for this short form
        template = nothing
        pattern = SpBGP(triples)
    end

    mods   = _sp_parse_solution_modifier(p)
    values = _sp_parse_values_clause(p)

    return SpConstructQuery(
        template, datasets, pattern,
        mods.group_by, mods.having, mods.order_by, mods.limit, mods.offset, values
    )
end

function _sp_parse_construct_template(p::SpParser)::Vector{SpTriple}
    _sp_expect!(p, SP_TOK_LBRACE)
    triples = SpTriple[]
    if _sp_next_starts_triples(p)
        triples = _sp_parse_triples_template(p)
    end
    _sp_expect!(p, SP_TOK_RBRACE)
    return triples
end

# TriplesTemplate: like TriplesBlock but no property paths (only VerbSimple)
# For simplicity we reuse TriplesBlock (path-capable) here; the semantics are
# equivalent for ground templates.
function _sp_parse_triples_template(p::SpParser)::Vector{SpTriple}
    _sp_parse_triples_block(p)
end

# ── ASK query ─────────────────────────────────────────────────────────────────

function _sp_parse_ask_query(p::SpParser)::SpAskQuery
    _sp_expect_kw!(p, "ask")
    datasets = _sp_parse_dataset_clauses(p)
    pattern  = _sp_parse_where_clause(p)
    values   = _sp_parse_values_clause(p)
    return SpAskQuery(datasets, pattern, values)
end

# ── DESCRIBE query ────────────────────────────────────────────────────────────

function _sp_parse_describe_query(p::SpParser)::SpDescribeQuery
    _sp_expect_kw!(p, "describe")

    resources = SpExpr[]
    star = false

    if _sp_peek_kind(p) == SP_TOK_STAR
        _sp_next!(p)
        star = true
    else
        while true
            tok = sp_peek_token(p.lex)
            if tok.kind == SP_TOK_VAR
                push!(resources, SpVar(Symbol(_sp_next!(p).value)))
            elseif _sp_next_is_iri(p)
                push!(resources, _sp_parse_iri_node(p))
            else
                break
            end
        end
        isempty(resources) && _sp_parse_error_here(p, "DESCRIBE requires resources or '*'")
    end

    datasets = _sp_parse_dataset_clauses(p)
    pattern::Union{SpPat, Nothing} = nothing
    if _sp_peek_kw(p, "where") || _sp_peek_kind(p) == SP_TOK_LBRACE
        pattern = _sp_parse_where_clause(p)
    end
    mods   = _sp_parse_solution_modifier(p)
    values = _sp_parse_values_clause(p)

    return SpDescribeQuery(
        resources, star, datasets, pattern,
        mods.group_by, mods.having, mods.order_by, mods.limit, mods.offset, values
    )
end

# ── Query dispatch ────────────────────────────────────────────────────────────

function _sp_parse_query(p::SpParser)::SpQueryForm
    tok = sp_peek_token(p.lex)
    (tok.kind == SP_TOK_KW) || _sp_parse_error(p, tok, "Expected SELECT, CONSTRUCT, ASK, or DESCRIBE")
    kw = tok.value
    if kw == "select"
        return _sp_parse_select_query(p)
    elseif kw == "construct"
        return _sp_parse_construct_query(p)
    elseif kw == "ask"
        return _sp_parse_ask_query(p)
    elseif kw == "describe"
        return _sp_parse_describe_query(p)
    else
        _sp_parse_error(p, tok, "Expected SELECT, CONSTRUCT, ASK, or DESCRIBE, got $(repr(kw))")
    end
end

# ── UPDATE operations ─────────────────────────────────────────────────────────

# Parse QuadData: '{' Quads '}'  (ground triples only, no variables)
# Returns SpQuadBlock
function _sp_parse_quad_data(p::SpParser)::SpQuadBlock
    _sp_expect!(p, SP_TOK_LBRACE)
    result = _sp_parse_quads(p)
    _sp_expect!(p, SP_TOK_RBRACE)
    return result
end

function _sp_parse_quad_pattern(p::SpParser)::SpQuadBlock
    _sp_expect!(p, SP_TOK_LBRACE)
    result = _sp_parse_quads(p)
    _sp_expect!(p, SP_TOK_RBRACE)
    return result
end

function _sp_parse_quads(p::SpParser)::SpQuadBlock
    result = SpQuadBlock()
    default_triples = SpTriple[]

    if _sp_next_starts_triples(p)
        tt = _sp_parse_triples_template(p)
        append!(default_triples, tt)
        _sp_eat!(p, SP_TOK_DOT)
    end

    while _sp_peek_kw(p, "graph")
        if !isempty(default_triples)
            push!(result, nothing => copy(default_triples))
            empty!(default_triples)
        end
        _sp_next!(p)  # consume 'graph'
        graph_iri = _sp_parse_iri(p)
        _sp_expect!(p, SP_TOK_LBRACE)
        triples = SpTriple[]
        if _sp_next_starts_triples(p)
            triples = _sp_parse_triples_template(p)
        end
        _sp_expect!(p, SP_TOK_RBRACE)
        _sp_eat!(p, SP_TOK_DOT)
        push!(result, graph_iri => triples)

        if _sp_next_starts_triples(p)
            tt2 = _sp_parse_triples_template(p)
            append!(default_triples, tt2)
            _sp_eat!(p, SP_TOK_DOT)
        end
    end

    if !isempty(default_triples)
        push!(result, nothing => default_triples)
    end

    return result
end

# Parse GraphRefAll
# ── Update data validation helpers ────────────────────────────────────────────

# Validate that a quad block contains no variables (for DELETE DATA / INSERT DATA)
function _sp_validate_no_vars!(p::SpParser, quads::SpQuadBlock, context::String)
    for (_, triples) in quads
        for t in triples
            _sp_validate_term_no_var(p, t.subject, context)
            _sp_validate_term_no_var(p, t.object, context)
            if t.predicate isa SpExpr
                _sp_validate_term_no_var(p, t.predicate::SpExpr, context)
            end
        end
    end
end

function _sp_validate_term_no_var(p::SpParser, e::SpExpr, context::String)
    if e isa SpVar
        _sp_parse_error_here(p, "Variables are not allowed in $context (found '?$(e.name)')")
    end
end

# Validate that a quad block contains no blank nodes (for DELETE DATA / DELETE templates)
function _sp_validate_no_bnodes!(p::SpParser, quads::SpQuadBlock, context::String)
    for (_, triples) in quads
        for t in triples
            _sp_validate_term_no_bnode(p, t.subject, context)
            _sp_validate_term_no_bnode(p, t.object, context)
        end
    end
end

function _sp_validate_term_no_bnode(p::SpParser, e::SpExpr, context::String)
    if e isa SpBNode || e isa SpAnonBNode
        _sp_parse_error_here(p, "Blank nodes are not allowed in $context")
    end
end

# Convert a SpQuadBlock (from DELETE WHERE's quad-pattern) to a SpPat that
# preserves GRAPH context.  Default-graph triples become a SpBGP; named-graph
# triples are wrapped in SpGraph nodes, all gathered into a SpGroup.
function _sp_quads_to_pattern(quads::SpQuadBlock)::SpPat
    elements = SpPat[]
    for (graph_iri, triples) in quads
        isempty(triples) && continue
        bgp = SpBGP(triples)
        if graph_iri === nothing
            push!(elements, bgp)
        else
            push!(elements, SpGraph(SpIRI(graph_iri), bgp))
        end
    end
    isempty(elements)        && return SpBGP(SpTriple[])
    length(elements) == 1   && return elements[1]
    return SpGroup(elements)
end

# Validate a pattern for DELETE WHERE — no blank nodes allowed
function _sp_validate_pattern_no_bnodes!(p::SpParser, pat::SpPat, context::String)
    if pat isa SpBGP
        for t in pat.triples
            _sp_validate_term_no_bnode(p, t.subject, context)
            _sp_validate_term_no_bnode(p, t.object, context)
        end
    elseif pat isa SpGroup
        for e in pat.elements; _sp_validate_pattern_no_bnodes!(p, e, context); end
    elseif pat isa SpOptional; _sp_validate_pattern_no_bnodes!(p, pat.pattern, context)
    elseif pat isa SpUnion
        _sp_validate_pattern_no_bnodes!(p, pat.left, context)
        _sp_validate_pattern_no_bnodes!(p, pat.right, context)
    elseif pat isa SpGraph; _sp_validate_pattern_no_bnodes!(p, pat.pattern, context)
    end
end

function _sp_parse_graph_ref_all(p::SpParser)::SpGraphRef
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_KW
        if tok.value == "default"
            _sp_next!(p)
            return SpGraphRefDefault()
        elseif tok.value == "named"
            _sp_next!(p)
            return SpGraphRefNamed()
        elseif tok.value == "all"
            _sp_next!(p)
            return SpGraphRefAll()
        elseif tok.value == "graph"
            _sp_next!(p)
            iri = _sp_parse_iri(p)
            return SpGraphRefIRI(iri)
        else
            _sp_parse_error(p, tok, "Expected DEFAULT, NAMED, ALL, or GRAPH in graph reference")
        end
    else
        _sp_parse_error(p, tok, "Expected graph reference")
    end
end

# Parse GraphOrDefault
function _sp_parse_graph_or_default(p::SpParser)::SpGraphRef
    tok = sp_peek_token(p.lex)
    if tok.kind == SP_TOK_KW && tok.value == "default"
        _sp_next!(p)
        return SpGraphRefDefault()
    elseif tok.kind == SP_TOK_KW && tok.value == "graph"
        _sp_next!(p)
        iri = _sp_parse_iri(p)
        return SpGraphRefIRI(iri)
    elseif _sp_next_is_iri(p)
        iri = _sp_parse_iri(p)
        return SpGraphRefIRI(iri)
    else
        _sp_parse_error(p, tok, "Expected DEFAULT or graph IRI")
    end
end

function _sp_parse_update_op(p::SpParser)::SpUpdateOp
    tok = sp_peek_token(p.lex)
    (tok.kind == SP_TOK_KW) || _sp_parse_error(p, tok, "Expected update operation keyword")
    kw = tok.value

    if kw == "insert"
        _sp_next!(p)
        tok2 = sp_peek_token(p.lex)
        if tok2.kind == SP_TOK_KW && tok2.value == "data"
            _sp_next!(p)
            quads = _sp_parse_quad_data(p)
            _sp_validate_no_vars!(p, quads, "INSERT DATA")
            return SpInsertData(quads)
        else
            # INSERT { quads } (part of Modify, handled below via with-less path)
            # Actually this is INSERT without WITH — still a Modify
            insert_quads = _sp_parse_quad_pattern(p)
            usings = _sp_parse_using_clauses(p)
            _sp_expect_kw!(p, "where")
            pat = _sp_parse_group_graph_pattern(p)
            return SpModify(nothing, SpQuadBlock(), insert_quads, usings, pat)
        end

    elseif kw == "delete"
        _sp_next!(p)
        tok2 = sp_peek_token(p.lex)
        if tok2.kind == SP_TOK_KW && tok2.value == "data"
            _sp_next!(p)
            quads = _sp_parse_quad_data(p)
            _sp_validate_no_vars!(p, quads, "DELETE DATA")
            _sp_validate_no_bnodes!(p, quads, "DELETE DATA")
            return SpDeleteData(quads)
        elseif tok2.kind == SP_TOK_KW && tok2.value == "where"
            _sp_next!(p)
            pat = _sp_parse_quad_pattern(p)
            # Convert quad pattern to a graph pattern, preserving GRAPH context.
            # Triples in named graphs become SpGraph nodes; default-graph triples
            # stay as SpBGP.
            delete_pat = _sp_quads_to_pattern(pat)
            _sp_validate_pattern_no_bnodes!(p, delete_pat, "DELETE WHERE")
            return SpDeleteWhere(delete_pat)
        else
            # DELETE { quads } (part of Modify)
            delete_quads = _sp_parse_quad_pattern(p)
            _sp_validate_no_bnodes!(p, delete_quads, "DELETE template")
            insert_quads = SpQuadBlock()
            if _sp_peek_kw(p, "insert")
                _sp_next!(p)
                insert_quads = _sp_parse_quad_pattern(p)
            end
            usings = _sp_parse_using_clauses(p)
            _sp_expect_kw!(p, "where")
            pat = _sp_parse_group_graph_pattern(p)
            return SpModify(nothing, delete_quads, insert_quads, usings, pat)
        end

    elseif kw == "with"
        # WITH iri DELETE/INSERT ... WHERE
        _sp_next!(p)
        with_iri = _sp_parse_iri(p)
        delete_quads = SpQuadBlock()
        insert_quads = SpQuadBlock()
        tok3 = sp_peek_token(p.lex)
        if tok3.kind == SP_TOK_KW && tok3.value == "delete"
            _sp_next!(p)
            delete_quads = _sp_parse_quad_pattern(p)
            _sp_validate_no_bnodes!(p, delete_quads, "DELETE template")
            if _sp_peek_kw(p, "insert")
                _sp_next!(p)
                insert_quads = _sp_parse_quad_pattern(p)
            end
        elseif tok3.kind == SP_TOK_KW && tok3.value == "insert"
            _sp_next!(p)
            insert_quads = _sp_parse_quad_pattern(p)
        else
            _sp_parse_error(p, tok3, "Expected DELETE or INSERT after WITH <iri>")
        end
        usings = _sp_parse_using_clauses(p)
        _sp_expect_kw!(p, "where")
        pat = _sp_parse_group_graph_pattern(p)
        return SpModify(with_iri, delete_quads, insert_quads, usings, pat)

    elseif kw == "load"
        _sp_next!(p)
        silent = _sp_eat_kw!(p, "silent")
        source = _sp_parse_iri(p)
        into_graph::Union{String, Nothing} = nothing
        if _sp_peek_kw(p, "into")
            _sp_next!(p)
            _sp_expect_kw!(p, "graph")
            into_graph = _sp_parse_iri(p)
        end
        return SpLoad(silent, source, into_graph)

    elseif kw == "clear"
        _sp_next!(p)
        silent = _sp_eat_kw!(p, "silent")
        target = _sp_parse_graph_ref_all(p)
        return SpClear(silent, target)

    elseif kw == "drop"
        _sp_next!(p)
        silent = _sp_eat_kw!(p, "silent")
        target = _sp_parse_graph_ref_all(p)
        return SpDrop(silent, target)

    elseif kw == "create"
        _sp_next!(p)
        silent = _sp_eat_kw!(p, "silent")
        _sp_expect_kw!(p, "graph")
        iri = _sp_parse_iri(p)
        return SpCreate(silent, iri)

    elseif kw == "add"
        _sp_next!(p)
        silent = _sp_eat_kw!(p, "silent")
        src = _sp_parse_graph_or_default(p)
        _sp_expect_kw!(p, "to")
        dst = _sp_parse_graph_or_default(p)
        return SpAdd(silent, src, dst)

    elseif kw == "move"
        _sp_next!(p)
        silent = _sp_eat_kw!(p, "silent")
        src = _sp_parse_graph_or_default(p)
        _sp_expect_kw!(p, "to")
        dst = _sp_parse_graph_or_default(p)
        return SpMove(silent, src, dst)

    elseif kw == "copy"
        _sp_next!(p)
        silent = _sp_eat_kw!(p, "silent")
        src = _sp_parse_graph_or_default(p)
        _sp_expect_kw!(p, "to")
        dst = _sp_parse_graph_or_default(p)
        return SpCopy(silent, src, dst)

    else
        _sp_parse_error(p, tok, "Unknown update operation: $(repr(kw))")
    end
end

function _sp_parse_using_clauses(p::SpParser)::Vector{SpDatasetClause}
    clauses = SpDatasetClause[]
    while _sp_peek_kw(p, "using")
        _sp_next!(p)
        named = _sp_eat_kw!(p, "named")
        iri = _sp_parse_iri(p)
        push!(clauses, SpDatasetClause(named, iri))
    end
    return clauses
end

# ── Top-level parse ───────────────────────────────────────────────────────────

const _SP_QUERY_KEYWORDS = Set{String}(["select", "construct", "ask", "describe"])
const _SP_UPDATE_KEYWORDS = Set{String}([
    "insert", "delete", "load", "clear", "drop", "create", "add", "move", "copy", "with"
])

function _sp_parse_unit(p::SpParser)::SpUnit
    decls = _sp_parse_prologue!(p)
    collected_decls = copy(decls)

    tok = sp_peek_token(p.lex)

    # Decide: query or update?
    if tok.kind == SP_TOK_EOF
        # Empty input: return empty update
        return SpUpdateUnit(p.base, collected_decls, SpUpdateOp[])
    end

    is_query = (tok.kind == SP_TOK_KW && tok.value in _SP_QUERY_KEYWORDS)

    if is_query
        # Save prologue info
        base_iri = p.base
        query = _sp_parse_query(p)
        # Expect EOF
        etok = sp_peek_token(p.lex)
        if etok.kind != SP_TOK_EOF
            _sp_parse_error(p, etok, "Unexpected content after query: $(etok.kind)")
        end
        return SpQueryUnit(base_iri, collected_decls, query)
    else
        # Parse update sequence
        ops = SpUpdateOp[]
        base_iri = p.base

        # Parse first update op (may be absent if input is just a prologue)
        tok2 = sp_peek_token(p.lex)
        if tok2.kind == SP_TOK_KW && tok2.value in _SP_UPDATE_KEYWORDS
            push!(ops, _sp_parse_update_op(p))
        elseif tok2.kind == SP_TOK_SEMI
            # leading semicolon with no preceding op is a syntax error
            _sp_parse_error(p, tok2, "Unexpected ';' with no preceding update operation")
        elseif tok2.kind != SP_TOK_EOF
            _sp_parse_error(p, tok2, "Expected update operation, got $(tok2.kind)")
        end

        # Additional operations separated by ';'
        while _sp_peek_kind(p) == SP_TOK_SEMI
            semi_tok = sp_peek_token(p.lex)
            _sp_next!(p)  # consume ';'
            # Each semicolon may be followed by more prologue declarations
            more_decls = _sp_parse_prologue!(p)
            append!(collected_decls, more_decls)
            tok3 = sp_peek_token(p.lex)
            if tok3.kind == SP_TOK_EOF
                break   # trailing semicolon at end is OK (common in generated SPARQL)
            elseif tok3.kind == SP_TOK_SEMI
                # Empty update operation between two semicolons is a syntax error
                _sp_parse_error(p, tok3, "Empty update operation between consecutive ';' separators")
            elseif tok3.kind == SP_TOK_KW && tok3.value in _SP_UPDATE_KEYWORDS
                push!(ops, _sp_parse_update_op(p))
            else
                _sp_parse_error(p, tok3, "Expected update operation after ';', got $(tok3.kind)")
            end
        end

        etok = sp_peek_token(p.lex)
        if etok.kind != SP_TOK_EOF
            _sp_parse_error(p, etok, "Unexpected content after update: $(etok.kind)")
        end

        return SpUpdateUnit(base_iri, collected_decls, ops)
    end
end

# ── Post-parse static validation ──────────────────────────────────────────────

# Collect all variables introduced by a pattern element (for BIND scope checking).
function _sp_collect_pattern_vars!(pat, vars::Set{Symbol})
    if pat isa SpBGP
        for tp in pat.triples
            for part in (tp.subject, tp.predicate, tp.object)
                part isa SpVar && push!(vars, part.name)
            end
        end
    elseif pat isa SpGroup
        for elem in pat.elements
            elem isa SpPat && _sp_collect_pattern_vars!(elem, vars)
        end
    elseif pat isa SpBind
        push!(vars, pat.var.name)
    elseif pat isa SpOptional
        _sp_collect_pattern_vars!(pat.pattern, vars)
    elseif pat isa SpUnion
        _sp_collect_pattern_vars!(pat.left, vars)
        _sp_collect_pattern_vars!(pat.right, vars)
    elseif pat isa SpGraph
        _sp_collect_pattern_vars!(pat.pattern, vars)
    elseif pat isa SpMinus
        _sp_collect_pattern_vars!(pat.pattern, vars)
    elseif pat isa SpSubQuery
        # Subquery doesn't propagate its internal vars to outer scope during BIND check
    end
end

# Validate BIND scope within a GroupGraphPattern:
# A BIND variable must not already be in scope from earlier elements in the SAME group.
function _sp_validate_bind_scope(pat::SpPat)
    if pat isa SpGroup
        in_scope = Set{Symbol}()
        for elem in pat.elements
            if elem isa SpBind
                if elem.var.name in in_scope
                    throw(ParseError("BIND variable ?$(elem.var.name) is already in scope in this group", 0, 0, MIME("application/sparql-query")))
                end
                push!(in_scope, elem.var.name)
            else
                elem isa SpPat && _sp_collect_pattern_vars!(elem, in_scope)
                elem isa SpPat && _sp_validate_bind_scope(elem)
            end
        end
    elseif pat isa SpOptional
        _sp_validate_bind_scope(pat.pattern)
    elseif pat isa SpUnion
        _sp_validate_bind_scope(pat.left)
        _sp_validate_bind_scope(pat.right)
    elseif pat isa SpGraph
        _sp_validate_bind_scope(pat.pattern)
    elseif pat isa SpMinus
        _sp_validate_bind_scope(pat.pattern)
    end
end

# Collect blank node labels used in update graph templates (SpQuadBlock format)
function _sp_collect_bnode_labels!(quads::SpQuadBlock, labels::Set{String})
    for (_, triples) in quads
        for tp in triples
            for part in (tp.subject, tp.object)
                if part isa SpBNode; push!(labels, part.label)
                elseif part isa SpAnonBNode; push!(labels, "_anon_$(objectid(part))") end
            end
        end
    end
end

# Validate the parsed unit for static semantic errors
function _sp_validate_unit(unit::SpUnit)
    if unit isa SpQueryUnit
        q = unit.query
        if q isa SpSelectQuery
            # Validate BIND scope
            _sp_validate_bind_scope(q.pattern)
            # COUNT 10 style: aggregate in SELECT without GROUP BY with non-agg variable columns
            has_agg = any(col -> _sp_expr_contains_aggregate(col.expr), q.columns)
            if has_agg && isempty(q.group_by)
                group_by_vars = Symbol[]  # empty without GROUP BY
                for col in q.columns
                    if !_sp_expr_contains_aggregate(col.expr)
                        # Any non-aggregate column with a plain variable reference
                        if col.as_var === nothing && col.expr isa SpVar
                            throw(ParseError("Non-aggregate variable ?$((col.expr::SpVar).name) in SELECT with aggregate but no GROUP BY", 0, 0, MIME("application/sparql-query")))
                        end
                    end
                end
            end
        elseif q isa SpConstructQuery
            _sp_validate_bind_scope(q.pattern)
        elseif q isa SpAskQuery
            _sp_validate_bind_scope(q.pattern)
        elseif q isa SpDescribeQuery
            # DESCRIBE is the only query form whose WHERE clause is optional
            # (SPARQL 1.1 §16.4: `DESCRIBE <iri>` is legal on its own), so
            # `pattern` is the only one that can be `nothing`. There is no
            # scope to validate when there is no pattern.
            q.pattern !== nothing && _sp_validate_bind_scope(q.pattern)
        end
    elseif unit isa SpUpdateUnit
        # Validate blank nodes not shared across INSERT DATA operations
        insert_data_bnode_sets = Vector{Set{String}}()
        for op in unit.ops
            if op isa SpInsertData
                labels = Set{String}()
                _sp_collect_bnode_labels!(op.quads, labels)
                if !isempty(labels)
                    for prev_labels in insert_data_bnode_sets
                        shared = intersect(labels, prev_labels)
                        if !isempty(shared)
                            throw(ParseError("Blank node label(s) $(join(shared, ", ")) shared across multiple INSERT DATA operations", 0, 0, MIME("application/sparql-query")))
                        end
                    end
                    push!(insert_data_bnode_sets, labels)
                end
            end
        end
    end
end

# Check if an expression contains any aggregate (recursively)
function _sp_expr_contains_aggregate(expr::SpExpr)::Bool
    if expr isa SpAggregate; return true
    elseif expr isa SpBinary
        return _sp_expr_contains_aggregate(expr.left) || _sp_expr_contains_aggregate(expr.right)
    elseif expr isa SpUnary; return _sp_expr_contains_aggregate(expr.arg)
    elseif expr isa SpCall; return any(_sp_expr_contains_aggregate, expr.args)
    elseif expr isa SpIf
        return _sp_expr_contains_aggregate(expr.cond) ||
               _sp_expr_contains_aggregate(expr.then_) ||
               _sp_expr_contains_aggregate(expr.else_)
    elseif expr isa SpCoalesce; return any(_sp_expr_contains_aggregate, expr.args)
    else; return false
    end
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    sparql_parse(src::AbstractString) → SpUnit

Parse a SPARQL 1.1 query or update string and return the AST.
Returns `SpQueryUnit` for queries and `SpUpdateUnit` for updates.
Throws `ParseError` on syntax errors.
"""
function sparql_parse(src::AbstractString)::SpUnit
    p = SpParser(SpLexer(String(src)), nothing, Dict{String,String}())
    unit = _sp_parse_unit(p)
    _sp_validate_unit(unit)
    unit
end
