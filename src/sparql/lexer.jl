# ── SPARQL 1.1 Lexer ──────────────────────────────────────────────────────────
#
# Tokenises a SPARQL 1.1 query/update string into a flat stream of SpToken
# values.  This file is included into the RDF module; do NOT add a module
# declaration here.
#
# Token consumption model
# ─────────────────────────
#   sp_next_token!(lex)  – advance and return the next token
#   sp_peek_token(lex)   – return the next token without consuming it

# ── Token kind enum ───────────────────────────────────────────────────────────

@enum SpTokKind begin
    # Structural
    SP_TOK_EOF

    # Literals & terms
    SP_TOK_IRIREF       # <...>
    SP_TOK_PNAME_LN     # prefix:local
    SP_TOK_PNAME_NS     # prefix:  (no local part)
    SP_TOK_BLANK_LABEL  # _:name
    SP_TOK_ANON         # []
    SP_TOK_NIL          # ()
    SP_TOK_VAR          # ?name or $name
    SP_TOK_INTEGER      # 123 or -123
    SP_TOK_DECIMAL      # 1.5
    SP_TOK_DOUBLE       # 1.5e3
    SP_TOK_STR1         # "..."
    SP_TOK_STR2         # '...'
    SP_TOK_STR_LONG1    # """..."""
    SP_TOK_STR_LONG2    # '''...'''
    SP_TOK_LANGTAG      # @en or @en-US
    SP_TOK_KW           # any keyword (stored lowercase)
    SP_TOK_A            # literal 'a' used as rdf:type

    # Punctuation
    SP_TOK_LBRACE
    SP_TOK_RBRACE
    SP_TOK_LPAREN
    SP_TOK_RPAREN
    SP_TOK_LBRACKET
    SP_TOK_RBRACKET
    SP_TOK_DOT
    SP_TOK_SEMI
    SP_TOK_COMMA
    SP_TOK_PIPE
    SP_TOK_SLASH
    SP_TOK_CARET
    SP_TOK_BANG
    SP_TOK_STAR
    SP_TOK_PLUS
    SP_TOK_MINUS_TOK    # hyphen-minus

    # Operators
    SP_TOK_EQ           # =
    SP_TOK_NEQ          # !=
    SP_TOK_LT           # <  (not part of IRI)
    SP_TOK_LE           # <=
    SP_TOK_GT           # >
    SP_TOK_GE           # >=
    SP_TOK_AND          # &&
    SP_TOK_OR           # ||
    SP_TOK_HATHAT       # ^^
    SP_TOK_QUEST        # ? (path ZeroOrOne modifier, not followed by identifier)

    # RDF-star (embedded triple terms)
    SP_TOK_TT_OPEN   # <<(  — start of an embedded triple term
    SP_TOK_TT_CLOSE  # )>>  — end of an embedded triple term

    # SPARQL 1.2 (reified triples, reifiers, annotation blocks)
    SP_TOK_RT_OPEN   # <<  — start of a reified triple
    SP_TOK_RT_CLOSE  # >>  — end of a reified triple
    SP_TOK_TILDE     # ~   — reifier
    SP_TOK_ANN_OPEN  # {|  — start of an annotation block
    SP_TOK_ANN_CLOSE # |}  — end of an annotation block
end

# ── Token struct ──────────────────────────────────────────────────────────────

struct SpToken
    kind::SpTokKind
    value::String   # lexeme; for keywords: lowercase canonical form
    line::Int
    col::Int
end

# ── Lexer struct ──────────────────────────────────────────────────────────────

mutable struct SpLexer
    src::String
    pos::Int        # current byte index (1-based Julia indexing)
    line::Int
    col::Int
    peeked::Union{SpToken, Nothing}
end

SpLexer(src::String) = SpLexer(src, 1, 1, 1, nothing)

# ── SPARQL format MIME constant ───────────────────────────────────────────────

const _SPARQL_MIME = MIME("application/sparql-query")

# ── Internal helpers ──────────────────────────────────────────────────────────

@inline _sp_at_end(lex::SpLexer)::Bool = lex.pos > ncodeunits(lex.src)

# Peek at the character at byte offset `offset` past lex.pos (default 0 = current).
# Returns '\0' if past end.
function _sp_peek_char(lex::SpLexer, offset::Int = 0)::Char
    p = lex.pos + offset
    p > ncodeunits(lex.src) && return '\0'
    # Fast path for ASCII
    b = codeunit(lex.src, p)
    if b < 0x80
        return Char(b)
    end
    # Multi-byte: find the start of the code-point (p + offset may land mid-sequence)
    # We need the char starting at byte p.
    c, _ = iterate(lex.src, p)
    return c
end

# Advance past one character, updating line/col.  Returns the consumed char.
function _sp_advance!(lex::SpLexer)::Char
    _sp_at_end(lex) && return '\0'
    c, next_pos = iterate(lex.src, lex.pos)
    lex.pos = next_pos
    if c == '\n'
        lex.line += 1
        lex.col   = 1
    else
        lex.col  += 1
    end
    return c
end

# Throw a ParseError using the lexer's current position.
function _sp_error(lex::SpLexer, msg::String)
    throw(ParseError(msg, lex.line, lex.col, _SPARQL_MIME))
end

# Throw a ParseError using a captured position.
function _sp_error_at(line::Int, col::Int, msg::String)
    throw(ParseError(msg, line, col, _SPARQL_MIME))
end

# Skip whitespace (space, tab, CR, LF) and # comments.
function _sp_skip_ws!(lex::SpLexer)
    while !_sp_at_end(lex)
        c = _sp_peek_char(lex)
        if c == ' ' || c == '\t' || c == '\r' || c == '\n'
            _sp_advance!(lex)
        elseif c == '#'
            # comment – skip to end of line
            while !_sp_at_end(lex) && _sp_peek_char(lex) != '\n'
                _sp_advance!(lex)
            end
        else
            break
        end
    end
end

# ── PN_CHARS helpers (SPARQL grammar) ─────────────────────────────────────────

# Returns true if c can start a PN_CHARS_BASE (letter / non-ASCII code point)
@inline function _is_pn_chars_base(c::Char)::Bool
    c >= 'A' && c <= 'Z'   && return true
    c >= 'a' && c <= 'z'   && return true
    c >= 'À' && c <= 'Ö' && return true
    c >= 'Ø' && c <= 'ö' && return true
    c >= 'ø' && c <= '˿' && return true
    c >= 'Ͱ' && c <= 'ͽ' && return true
    c >= 'Ϳ' && c <= '῿' && return true
    c >= '‌' && c <= '‍' && return true
    c >= '⁰' && c <= '↏' && return true
    c >= 'Ⰰ' && c <= '⿯' && return true
    c >= '、' && c <= '퟿' && return true
    c >= '豈' && c <= '﷏' && return true
    c >= 'ﷰ' && c <= '�' && return true
    c >= '\U00010000' && c <= '\U000EFFFF' && return true
    return false
end

@inline function _is_pn_chars_u(c::Char)::Bool
    c == '_' && return true
    return _is_pn_chars_base(c)
end

# PN_CHARS: PN_CHARS_U | '-' | digit | '·' | [̀-ͯ] | [‿-⁀]
@inline function _is_pn_chars(c::Char)::Bool
    _is_pn_chars_u(c)    && return true
    c == '-'              && return true
    c >= '0' && c <= '9' && return true
    c == '·'         && return true
    c >= '̀' && c <= 'ͯ' && return true
    c >= '‿' && c <= '⁀' && return true
    return false
end

# ── Read PN_LOCAL (local part of a prefixed name, after the colon) ─────────────
#
# PN_LOCAL ::= (PN_CHARS_U | ':' | [0-9] | PLX)
#              ((PN_CHARS | '.' | ':' | PLX)* (PN_CHARS | ':' | PLX))?
#
# PLX ::= PERCENT | PN_LOCAL_ESC
# PERCENT ::= '%' HEX HEX
# PN_LOCAL_ESC ::= '\' ( '~' | '.' | '-' | '!' | '$' | '&' | "'" | '(' | ')' |
#                        '*' | '+' | ',' | ';' | '=' | '/' | '?' | '#' | '@' | '%' )
#
# We store the raw lexeme (no unescaping).

const _PN_LOCAL_ESC_CHARS = Set{Char}([
    '~', '.', '-', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=',
    '/', '?', '#', '@', '%',
])

function _read_pn_local!(lex::SpLexer)::String
    buf = IOBuffer()
    # First char: PN_CHARS_U | ':' | digit | PLX
    c = _sp_peek_char(lex)
    if _is_pn_chars_u(c) || c == ':' || (c >= '0' && c <= '9')
        write(buf, _sp_advance!(lex))
    elseif c == '%'
        _read_percent!(lex, buf)
    elseif c == '\\'
        _read_pn_local_esc!(lex, buf)
    else
        return ""  # empty local part
    end

    # Remaining chars: collect greedily, stripping trailing dots
    while !_sp_at_end(lex)
        c = _sp_peek_char(lex)
        if _is_pn_chars(c) || c == ':' || c == '.'
            write(buf, _sp_advance!(lex))
        elseif c == '%'
            _read_percent!(lex, buf)
        elseif c == '\\'
            _read_pn_local_esc!(lex, buf)
        else
            break
        end
    end

    # Trim trailing '.' — but NOT if it is part of a '\.' escape sequence.
    s = String(take!(buf))
    while !isempty(s) && s[end] == '.'
        # A trailing dot that was the second char of '\.' must not be trimmed.
        # Index by character, not byte: the char before the dot may be
        # multi-byte (e.g. a kanji local name), and s[end-1] lands inside it.
        if length(s) >= 2 && s[prevind(s, lastindex(s))] == '\\'
            break
        end
        s = chop(s)
        # Return one byte back to the lexer (the dot we consumed)
        # We need to walk back lex.pos by 1 byte; col too.
        lex.pos -= 1
        lex.col -= 1
    end
    return s
end

function _read_percent!(lex::SpLexer, buf::IOBuffer)
    write(buf, _sp_advance!(lex))  # '%'
    for _ in 1:2
        _sp_at_end(lex) && return
        hc = _sp_peek_char(lex)
        if isxdigit(hc)
            write(buf, _sp_advance!(lex))
        end
    end
end

function _read_pn_local_esc!(lex::SpLexer, buf::IOBuffer)
    write(buf, _sp_advance!(lex))  # '\'
    !_sp_at_end(lex) || return
    c = _sp_peek_char(lex)
    if c in _PN_LOCAL_ESC_CHARS
        write(buf, _sp_advance!(lex))
    end
end

# ── Read IRI reference <...> ──────────────────────────────────────────────────

@inline function _sp_hex_val(lex::SpLexer, sline::Int, scol::Int, c::Char)::UInt32
    c >= '0' && c <= '9' && return UInt32(c) - UInt32('0')
    c >= 'a' && c <= 'f' && return UInt32(c) - UInt32('a') + 0x0a
    c >= 'A' && c <= 'F' && return UInt32(c) - UInt32('A') + 0x0a
    _sp_error_at(sline, scol, "Invalid hex digit '$c' in escape")
end

# Surrogate code points (U+D800–U+DFFF) are not Unicode scalar values and are
# forbidden in IRI \\u/\\U escapes.
@inline function _sp_check_iri_codepoint(lex::SpLexer, sline::Int, scol::Int, cp::Integer)
    0xD800 <= cp <= 0xDFFF &&
        _sp_error_at(sline, scol,
            "Surrogate code point U+$(uppercase(string(cp, base=16, pad=4))) is not allowed in an IRI escape")
    nothing
end

function _read_iriref!(lex::SpLexer, sline::Int, scol::Int)::SpToken
    # '<' already consumed by caller
    buf = IOBuffer()
    while true
        _sp_at_end(lex) &&
            _sp_error_at(sline, scol, "Unterminated IRI reference")
        c = _sp_peek_char(lex)
        if c == '>'
            _sp_advance!(lex)
            break
        elseif c == '\\'
            # Only \uXXXX and \UXXXXXXXX are allowed
            _sp_advance!(lex)
            esc = _sp_peek_char(lex)
            if esc == 'u'
                write(buf, '\\')
                write(buf, _sp_advance!(lex))  # 'u'
                cp = UInt32(0)
                for _ in 1:4
                    _sp_at_end(lex) && _sp_error_at(sline, scol, "Unterminated \\u escape in IRI")
                    hc = _sp_advance!(lex); write(buf, hc)
                    cp = cp * 16 + _sp_hex_val(lex, sline, scol, hc)
                end
                _sp_check_iri_codepoint(lex, sline, scol, cp)
            elseif esc == 'U'
                write(buf, '\\')
                write(buf, _sp_advance!(lex))  # 'U'
                cp = UInt32(0)
                for _ in 1:8
                    _sp_at_end(lex) && _sp_error_at(sline, scol, "Unterminated \\U escape in IRI")
                    hc = _sp_advance!(lex); write(buf, hc)
                    cp = cp * 16 + _sp_hex_val(lex, sline, scol, hc)
                end
                _sp_check_iri_codepoint(lex, sline, scol, cp)
            else
                _sp_error_at(sline, scol, "Invalid escape '\\$(esc)' inside IRI reference")
            end
        elseif c == '<' || c == '"' || c == '{' || c == '}' || c == '|' ||
               c == '^' || c == '`'
            _sp_error_at(sline, scol, "Forbidden character '$(c)' inside IRI reference")
        else
            write(buf, _sp_advance!(lex))
        end
    end
    return SpToken(SP_TOK_IRIREF, String(take!(buf)), sline, scol)
end

# ── Read string literals ───────────────────────────────────────────────────────

# Characters valid in \X single-char escape sequences
function _sp_string_escape_char!(lex::SpLexer, buf::IOBuffer, sline::Int, scol::Int)
    _sp_at_end(lex) && _sp_error_at(sline, scol, "Unterminated string escape")
    esc = _sp_peek_char(lex)
    write(buf, '\\')
    if esc == '"' || esc == '\'' || esc == '\\' ||
       esc == 'n' || esc == 't'  || esc == 'r'
        write(buf, _sp_advance!(lex))
    elseif esc == 'u'
        write(buf, _sp_advance!(lex))  # 'u'
        for _ in 1:4
            _sp_at_end(lex) && _sp_error_at(sline, scol, "Unterminated \\u escape in string")
            write(buf, _sp_advance!(lex))
        end
    elseif esc == 'U'
        write(buf, _sp_advance!(lex))  # 'U'
        for _ in 1:8
            _sp_at_end(lex) && _sp_error_at(sline, scol, "Unterminated \\U escape in string")
            write(buf, _sp_advance!(lex))
        end
    else
        # Pass through unrecognised escapes raw (parser may validate further)
        write(buf, _sp_advance!(lex))
    end
end

# Long string: triple-quoted; may contain newlines.
function _read_str_long!(lex::SpLexer, delim::Char, sline::Int, scol::Int)::SpToken
    kind = delim == '"' ? SP_TOK_STR_LONG1 : SP_TOK_STR_LONG2
    buf  = IOBuffer()
    while true
        _sp_at_end(lex) &&
            _sp_error_at(sline, scol, "Unterminated long string literal")
        c = _sp_peek_char(lex)
        if c == delim
            # Check for triple close
            _sp_advance!(lex)
            if _sp_peek_char(lex) == delim
                _sp_advance!(lex)
                if _sp_peek_char(lex) == delim
                    _sp_advance!(lex)
                    break  # closing triple-quote
                else
                    # Two delimiters then something else – emit two delims into content
                    write(buf, delim); write(buf, delim)
                end
            else
                write(buf, delim)
            end
        elseif c == '\\'
            _sp_advance!(lex)
            _sp_string_escape_char!(lex, buf, sline, scol)
        else
            write(buf, _sp_advance!(lex))
        end
    end
    return SpToken(kind, String(take!(buf)), sline, scol)
end

# Short string: single-line; error on unescaped newline or EOF.
function _read_str_short!(lex::SpLexer, delim::Char, sline::Int, scol::Int)::SpToken
    kind = delim == '"' ? SP_TOK_STR1 : SP_TOK_STR2
    buf  = IOBuffer()
    while true
        if _sp_at_end(lex)
            _sp_error_at(sline, scol, "Unterminated string literal")
        end
        c = _sp_peek_char(lex)
        if c == delim
            _sp_advance!(lex)
            break
        elseif c == '\n' || c == '\r'
            _sp_error_at(sline, scol, "Newline inside string literal")
        elseif c == '\\'
            _sp_advance!(lex)
            _sp_string_escape_char!(lex, buf, sline, scol)
        else
            write(buf, _sp_advance!(lex))
        end
    end
    return SpToken(kind, String(take!(buf)), sline, scol)
end

# ── Read blank node label _:xxx ───────────────────────────────────────────────

function _read_blank_label!(lex::SpLexer, sline::Int, scol::Int)::SpToken
    # '_' and ':' already consumed
    buf = IOBuffer()
    # First char must be PN_CHARS_U or digit
    _sp_at_end(lex) &&
        _sp_error_at(sline, scol, "Expected blank node label after '_:'")
    c = _sp_peek_char(lex)
    (_is_pn_chars_u(c) || (c >= '0' && c <= '9')) ||
        _sp_error_at(sline, scol, "Invalid blank node label character '$(c)'")
    write(buf, _sp_advance!(lex))

    # Middle/trailing chars: PN_CHARS | '.'
    while !_sp_at_end(lex)
        c = _sp_peek_char(lex)
        if _is_pn_chars(c) || c == '.'
            write(buf, _sp_advance!(lex))
        else
            break
        end
    end

    # Strip trailing dots
    s = String(take!(buf))
    while !isempty(s) && s[end] == '.'
        s = chop(s)   # character-wise: the label may end in a multi-byte char
        lex.pos -= 1
        lex.col -= 1
    end
    return SpToken(SP_TOK_BLANK_LABEL, s, sline, scol)
end

# ── Read a number ─────────────────────────────────────────────────────────────

# Entry: first char already known to be a digit, or sign followed by digit,
# or '.' followed by digit.  The caller has NOT consumed any chars yet.
function _read_number!(lex::SpLexer, sline::Int, scol::Int)::SpToken
    buf = IOBuffer()

    # Optional sign (only reach here if next is digit or '.' or sign+digit)
    c = _sp_peek_char(lex)
    if c == '+' || c == '-'
        write(buf, _sp_advance!(lex))
    end

    # Integer digits before optional '.'
    while !_sp_at_end(lex) && (c2 = _sp_peek_char(lex); c2 >= '0' && c2 <= '9')
        write(buf, _sp_advance!(lex))
    end

    has_dot = false
    if !_sp_at_end(lex) && _sp_peek_char(lex) == '.'
        # Look-ahead: next after '.' must be a digit
        if !_sp_at_end(lex) && (nc = _sp_peek_char(lex, 1); nc >= '0' && nc <= '9')
            write(buf, _sp_advance!(lex))  # '.'
            has_dot = true
            while !_sp_at_end(lex) && (c3 = _sp_peek_char(lex); c3 >= '0' && c3 <= '9')
                write(buf, _sp_advance!(lex))
            end
        end
    end

    has_exp = false
    if !_sp_at_end(lex)
        e = _sp_peek_char(lex)
        if e == 'e' || e == 'E'
            write(buf, _sp_advance!(lex))  # 'e'/'E'
            has_exp = true
            if !_sp_at_end(lex)
                sg = _sp_peek_char(lex)
                if sg == '+' || sg == '-'
                    write(buf, _sp_advance!(lex))
                end
            end
            while !_sp_at_end(lex) && (c4 = _sp_peek_char(lex); c4 >= '0' && c4 <= '9')
                write(buf, _sp_advance!(lex))
            end
        end
    end

    s = String(take!(buf))
    kind = has_exp ? SP_TOK_DOUBLE : (has_dot ? SP_TOK_DECIMAL : SP_TOK_INTEGER)
    return SpToken(kind, s, sline, scol)
end

# ── Read prefixed name after the namespace part has been collected ─────────────
#
# `ns` is the namespace identifier already consumed; the next char is ':'.

function _make_pname!(lex::SpLexer, ns::String, sline::Int, scol::Int)::SpToken
    _sp_advance!(lex)   # consume ':'
    local_part = _read_pn_local!(lex)
    if isempty(local_part)
        return SpToken(SP_TOK_PNAME_NS, ns * ":", sline, scol)
    else
        return SpToken(SP_TOK_PNAME_LN, ns * ":" * local_part, sline, scol)
    end
end

# ── Read identifier / keyword ──────────────────────────────────────────────────
#
# Entry: first char is a letter, or '_' NOT followed by ':'.

function _read_ident_or_kw!(lex::SpLexer, sline::Int, scol::Int)::SpToken
    buf = IOBuffer()
    # Consume the name: PN_CHARS_U chars, digits, dots (not at end), hyphens
    while !_sp_at_end(lex)
        c = _sp_peek_char(lex)
        if _is_pn_chars_u(c) || (c >= '0' && c <= '9') || c == '-'
            write(buf, _sp_advance!(lex))
        elseif c == '.'
            # Dot continues ident only if followed by letter/digit/_
            nc = _sp_peek_char(lex, 1)
            if _is_pn_chars_base(nc) || nc == '_' || (nc >= '0' && nc <= '9')
                write(buf, _sp_advance!(lex))
            else
                break
            end
        else
            break
        end
    end
    name = String(take!(buf))

    # If followed by ':', this is a prefixed name namespace
    if !_sp_at_end(lex) && _sp_peek_char(lex) == ':'
        return _make_pname!(lex, name, sline, scol)
    end

    lower = lowercase(name)

    # Special: 'a' is rdf:type shorthand
    if lower == "a"
        return SpToken(SP_TOK_A, "a", sline, scol)
    end

    # Keyword or generic identifier → SP_TOK_KW
    return SpToken(SP_TOK_KW, lower, sline, scol)
end

# ── Peek-ahead for NIL/ANON patterns ─────────────────────────────────────────

# Look past whitespace in the source and return the first non-ws char (no advance).
function _sp_peek_nonws(lex::SpLexer)::Char
    p = lex.pos
    n = ncodeunits(lex.src)
    while p <= n
        b = codeunit(lex.src, p)
        c = b < 0x80 ? Char(b) : begin cc, _ = iterate(lex.src, p); cc end
        if c != ' ' && c != '\t' && c != '\r' && c != '\n'
            return c
        end
        # advance p by one character
        if b < 0x80
            p += 1
        else
            _, np = iterate(lex.src, p)
            p = np
        end
    end
    return '\0'
end

# Consume whitespace AND the expected close char (']' or ')').
# Assumes we already peeked and know it's there.
function _sp_skip_to_close!(lex::SpLexer, close::Char)
    while !_sp_at_end(lex)
        c = _sp_peek_char(lex)
        if c == ' ' || c == '\t' || c == '\r' || c == '\n'
            _sp_advance!(lex)
        elseif c == close
            _sp_advance!(lex)
            return
        else
            return  # shouldn't happen if caller used _sp_peek_nonws
        end
    end
end

# ── Main tokeniser ────────────────────────────────────────────────────────────

function _sp_scan!(lex::SpLexer)::SpToken
    _sp_skip_ws!(lex)

    sline = lex.line
    scol  = lex.col

    if _sp_at_end(lex)
        return SpToken(SP_TOK_EOF, "", sline, scol)
    end

    c = _sp_peek_char(lex)

    # ── String literals (check long before short) ────────────────────────────
    if c == '"'
        _sp_advance!(lex)
        if _sp_peek_char(lex) == '"' && _sp_peek_char(lex, 1) == '"'
            _sp_advance!(lex); _sp_advance!(lex)
            return _read_str_long!(lex, '"', sline, scol)
        else
            return _read_str_short!(lex, '"', sline, scol)
        end
    elseif c == '\''
        _sp_advance!(lex)
        if _sp_peek_char(lex) == '\'' && _sp_peek_char(lex, 1) == '\''
            _sp_advance!(lex); _sp_advance!(lex)
            return _read_str_long!(lex, '\'', sline, scol)
        else
            return _read_str_short!(lex, '\'', sline, scol)
        end

    # ── IRI reference or less-than ────────────────────────────────────────────
    elseif c == '<'
        _sp_advance!(lex)
        nc = _sp_peek_char(lex)
        if nc == '='
            # <=
            _sp_advance!(lex)
            return SpToken(SP_TOK_LE, "<=", sline, scol)
        elseif nc == ' ' || nc == '\t' || nc == '\r' || nc == '\n' || nc == '\0'
            # bare '<' in an expression context
            return SpToken(SP_TOK_LT, "<", sline, scol)
        elseif nc == '<'
            # Check for '<<(' — RDF-star embedded triple term opening
            if _sp_peek_char(lex, 1) == '('
                _sp_advance!(lex)  # consume second '<'
                _sp_advance!(lex)  # consume '('
                return SpToken(SP_TOK_TT_OPEN, "<<(", sline, scol)
            end
            # '<<' — SPARQL 1.2 reified triple opening
            _sp_advance!(lex)  # consume second '<'
            return SpToken(SP_TOK_RT_OPEN, "<<", sline, scol)
        else
            # Everything else: treat as start of an IRI reference
            return _read_iriref!(lex, sline, scol)
        end

    # ── ^^ and ^ ─────────────────────────────────────────────────────────────
    elseif c == '^'
        _sp_advance!(lex)
        if _sp_peek_char(lex) == '^'
            _sp_advance!(lex)
            return SpToken(SP_TOK_HATHAT, "^^", sline, scol)
        end
        return SpToken(SP_TOK_CARET, "^", sline, scol)

    # ── Two-char operators ────────────────────────────────────────────────────
    elseif c == '!'
        _sp_advance!(lex)
        if _sp_peek_char(lex) == '='
            _sp_advance!(lex)
            return SpToken(SP_TOK_NEQ, "!=", sline, scol)
        end
        return SpToken(SP_TOK_BANG, "!", sline, scol)

    elseif c == '>'
        _sp_advance!(lex)
        if _sp_peek_char(lex) == '='
            _sp_advance!(lex)
            return SpToken(SP_TOK_GE, ">=", sline, scol)
        elseif _sp_peek_char(lex) == '>'
            # '>>' — SPARQL 1.2 reified triple closing
            _sp_advance!(lex)
            return SpToken(SP_TOK_RT_CLOSE, ">>", sline, scol)
        end
        return SpToken(SP_TOK_GT, ">", sline, scol)

    elseif c == '&'
        _sp_advance!(lex)
        if _sp_peek_char(lex) == '&'
            _sp_advance!(lex)
            return SpToken(SP_TOK_AND, "&&", sline, scol)
        end
        _sp_error_at(sline, scol, "Unexpected character '&' (did you mean '&&'?)")

    elseif c == '|'
        _sp_advance!(lex)
        if _sp_peek_char(lex) == '|'
            _sp_advance!(lex)
            return SpToken(SP_TOK_OR, "||", sline, scol)
        elseif _sp_peek_char(lex) == '}'
            # '|}' — SPARQL 1.2 annotation block closing
            _sp_advance!(lex)
            return SpToken(SP_TOK_ANN_CLOSE, "|}", sline, scol)
        end
        return SpToken(SP_TOK_PIPE, "|", sline, scol)

    elseif c == '='
        _sp_advance!(lex)
        return SpToken(SP_TOK_EQ, "=", sline, scol)

    # ── Punctuation ────────────────────────────────────────────────────────────
    elseif c == '{'
        _sp_advance!(lex)
        if _sp_peek_char(lex) == '|'
            # '{|' — SPARQL 1.2 annotation block opening
            _sp_advance!(lex)
            return SpToken(SP_TOK_ANN_OPEN, "{|", sline, scol)
        end
        return SpToken(SP_TOK_LBRACE, "{", sline, scol)
    elseif c == '~'
        _sp_advance!(lex); return SpToken(SP_TOK_TILDE, "~", sline, scol)
    elseif c == '}'
        _sp_advance!(lex); return SpToken(SP_TOK_RBRACE, "}", sline, scol)
    elseif c == ')'
        _sp_advance!(lex)
        # Check for ')>>' — RDF-star embedded triple term closing
        if _sp_peek_char(lex) == '>' && _sp_peek_char(lex, 1) == '>'
            _sp_advance!(lex)  # consume first '>'
            _sp_advance!(lex)  # consume second '>'
            return SpToken(SP_TOK_TT_CLOSE, ")>>", sline, scol)
        end
        return SpToken(SP_TOK_RPAREN, ")", sline, scol)
    elseif c == ']'
        _sp_advance!(lex); return SpToken(SP_TOK_RBRACKET, "]", sline, scol)
    # ── Bare colon: empty prefix PNAME_NS/PNAME_LN ──────────────────────────
    elseif c == ':'
        _sp_advance!(lex)   # consume ':'
        local_part = _read_pn_local!(lex)
        if isempty(local_part)
            return SpToken(SP_TOK_PNAME_NS, ":", sline, scol)
        else
            return SpToken(SP_TOK_PNAME_LN, ":" * local_part, sline, scol)
        end

    elseif c == ';'
        _sp_advance!(lex); return SpToken(SP_TOK_SEMI, ";", sline, scol)
    elseif c == ','
        _sp_advance!(lex); return SpToken(SP_TOK_COMMA, ",", sline, scol)
    elseif c == '/'
        _sp_advance!(lex); return SpToken(SP_TOK_SLASH, "/", sline, scol)
    elseif c == '*'
        _sp_advance!(lex); return SpToken(SP_TOK_STAR, "*", sline, scol)
    elseif c == '+'
        _sp_advance!(lex)
        # Could start a number: +digits or +.digits
        nc2 = _sp_peek_char(lex)
        if nc2 >= '0' && nc2 <= '9'
            # Put back the '+' conceptually by adjusting buf in _read_number!
            # But we already advanced past it; easiest: call _read_number! with
            # a pre-seeded sign character.  Rewind by one byte.
            lex.pos -= 1
            lex.col -= 1
            return _read_number!(lex, sline, scol)
        elseif nc2 == '.' && (nd = _sp_peek_char(lex, 1); nd >= '0' && nd <= '9')
            lex.pos -= 1
            lex.col -= 1
            return _read_number!(lex, sline, scol)
        end
        return SpToken(SP_TOK_PLUS, "+", sline, scol)

    elseif c == '-'
        _sp_advance!(lex)
        nc2 = _sp_peek_char(lex)
        if nc2 >= '0' && nc2 <= '9'
            lex.pos -= 1
            lex.col -= 1
            return _read_number!(lex, sline, scol)
        elseif nc2 == '.' && (nd = _sp_peek_char(lex, 1); nd >= '0' && nd <= '9')
            lex.pos -= 1
            lex.col -= 1
            return _read_number!(lex, sline, scol)
        end
        return SpToken(SP_TOK_MINUS_TOK, "-", sline, scol)

    # ── ( and NIL ────────────────────────────────────────────────────────────
    elseif c == '('
        _sp_advance!(lex)
        if _sp_peek_nonws(lex) == ')'
            _sp_skip_to_close!(lex, ')')
            return SpToken(SP_TOK_NIL, "()", sline, scol)
        end
        return SpToken(SP_TOK_LPAREN, "(", sline, scol)

    # ── [ and ANON ────────────────────────────────────────────────────────────
    elseif c == '['
        _sp_advance!(lex)
        if _sp_peek_nonws(lex) == ']'
            _sp_skip_to_close!(lex, ']')
            return SpToken(SP_TOK_ANON, "[]", sline, scol)
        end
        return SpToken(SP_TOK_LBRACKET, "[", sline, scol)

    # ── Dot: may start a decimal ─────────────────────────────────────────────
    elseif c == '.'
        nc = _sp_peek_char(lex, 1)
        if nc >= '0' && nc <= '9'
            return _read_number!(lex, sline, scol)
        end
        _sp_advance!(lex)
        return SpToken(SP_TOK_DOT, ".", sline, scol)

    # ── Variables ────────────────────────────────────────────────────────────
    elseif c == '?' || c == '$'
        _sp_advance!(lex)   # consume '?' or '$'
        buf = IOBuffer()
        while !_sp_at_end(lex)
            vc = _sp_peek_char(lex)
            if _is_pn_chars_u(vc) || (vc >= '0' && vc <= '9') || vc == '-'
                write(buf, _sp_advance!(lex))
            elseif vc == '.'
                nc = _sp_peek_char(lex, 1)
                if _is_pn_chars_base(nc) || nc == '_' || (nc >= '0' && nc <= '9')
                    write(buf, _sp_advance!(lex))
                else
                    break
                end
            else
                break
            end
        end
        vname = String(take!(buf))
        if isempty(vname)
            # Bare '?' not followed by an identifier: ZeroOrOne path modifier
            # ('$' without identifier is a syntax error)
            c == '?' || _sp_error_at(sline, scol, "Empty variable name after '\$'")
            return SpToken(SP_TOK_QUEST, "?", sline, scol)
        end
        return SpToken(SP_TOK_VAR, vname, sline, scol)

    # ── @ language tag ───────────────────────────────────────────────────────
    elseif c == '@'
        _sp_advance!(lex)
        buf = IOBuffer()
        # First segment: [a-zA-Z]+
        while !_sp_at_end(lex)
            lc = _sp_peek_char(lex)
            if (lc >= 'a' && lc <= 'z') || (lc >= 'A' && lc <= 'Z')
                write(buf, _sp_advance!(lex))
            else
                break
            end
        end
        if position(buf) == 0
            _sp_error_at(sline, scol, "Expected language tag after '@'")
        end
        # Optional subtags: (-[a-zA-Z0-9]+)*
        while !_sp_at_end(lex) && _sp_peek_char(lex) == '-'
            nc = _sp_peek_char(lex, 1)
            if (nc >= 'a' && nc <= 'z') || (nc >= 'A' && nc <= 'Z') || (nc >= '0' && nc <= '9')
                write(buf, _sp_advance!(lex))  # '-'
                while !_sp_at_end(lex)
                    sc2 = _sp_peek_char(lex)
                    if (sc2 >= 'a' && sc2 <= 'z') || (sc2 >= 'A' && sc2 <= 'Z') || (sc2 >= '0' && sc2 <= '9')
                        write(buf, _sp_advance!(lex))
                    else
                        break
                    end
                end
            else
                break
            end
        end
        # RDF 1.2 base direction: '--' [a-z]+  (lowercase only, per LANG_DIR)
        if !_sp_at_end(lex) && _sp_peek_char(lex) == '-' && _sp_peek_char(lex, 1) == '-'
            dc = _sp_peek_char(lex, 2)
            if dc >= 'a' && dc <= 'z'
                write(buf, _sp_advance!(lex))   # '-'
                write(buf, _sp_advance!(lex))   # '-'
                while !_sp_at_end(lex)
                    dc2 = _sp_peek_char(lex)
                    (dc2 >= 'a' && dc2 <= 'z') || break
                    write(buf, _sp_advance!(lex))
                end
            end
        end
        return SpToken(SP_TOK_LANGTAG, String(take!(buf)), sline, scol)

    # ── Blank node _: ────────────────────────────────────────────────────────
    elseif c == '_'
        # Peek: is next char ':'?
        if _sp_peek_char(lex, 1) == ':'
            _sp_advance!(lex)  # '_'
            _sp_advance!(lex)  # ':'
            return _read_blank_label!(lex, sline, scol)
        end
        # Otherwise treat as identifier start (e.g. _foo as a pname namespace)
        return _read_ident_or_kw!(lex, sline, scol)

    # ── Numbers starting with digit ───────────────────────────────────────────
    elseif c >= '0' && c <= '9'
        return _read_number!(lex, sline, scol)

    # ── Identifiers and keywords ──────────────────────────────────────────────
    elseif _is_pn_chars_base(c)
        return _read_ident_or_kw!(lex, sline, scol)

    else
        _sp_advance!(lex)
        _sp_error_at(sline, scol, "Unexpected character '$(c)'")
    end

    # Unreachable — Julia requires a return value but _sp_error throws
    return SpToken(SP_TOK_EOF, "", sline, scol)
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    sp_next_token!(lex::SpLexer) -> SpToken

Advance past the next token and return it.
"""
function sp_next_token!(lex::SpLexer)::SpToken
    if lex.peeked !== nothing
        tok = lex.peeked
        lex.peeked = nothing
        return tok
    end
    return _sp_scan!(lex)
end

"""
    sp_peek_token(lex::SpLexer) -> SpToken

Return the next token without consuming it.  Subsequent calls return the same
token until `sp_next_token!` is called.
"""
function sp_peek_token(lex::SpLexer)::SpToken
    if lex.peeked === nothing
        lex.peeked = _sp_scan!(lex)
    end
    return lex.peeked
end
