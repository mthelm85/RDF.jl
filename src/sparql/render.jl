# ── SPARQL AST → query-text rendering ─────────────────────────────────────────
#
# Serializes parsed graph patterns back to SPARQL 1.1 text.  Used by SERVICE
# evaluation: the inner pattern of `SERVICE <ep> { … }` is rendered into a
# `SELECT * WHERE { … }` query and shipped to the remote endpoint.
#
# All IRIs in the AST are already absolute (prefix expansion happens at parse
# time), so the rendered text needs no PREFIX prologue.  Round-trip property:
# parsing the rendered text yields a pattern with identical evaluation
# semantics.

# ── Terms and literals ─────────────────────────────────────────────────────────

function _sp_render_string_escape(io::IO, s::AbstractString)
    for c in s
        if     c == '\\'; print(io, "\\\\")
        elseif c == '"';  print(io, "\\\"")
        elseif c == '\n'; print(io, "\\n")
        elseif c == '\r'; print(io, "\\r")
        elseif c == '\t'; print(io, "\\t")
        else;             print(io, c)
        end
    end
end

function _sp_render_literal(io::IO, lexical::AbstractString,
                            datatype::AbstractString, lang::AbstractString)
    print(io, '"')
    _sp_render_string_escape(io, lexical)
    print(io, '"')
    if !isempty(lang)
        print(io, '@', lang)
    elseif datatype != _SP_XSD_STRING && !isempty(datatype)
        print(io, "^^<", datatype, '>')
    end
end

"""Render a concrete RDFTerm as SPARQL/N-Triples text (IRI, Literal, BlankNode)."""
function _sp_render_rdfterm(io::IO, t::RDFTerm)
    if t isa IRI
        print(io, '<', t.value, '>')
    elseif t isa Literal
        _sp_render_literal(io, t.lexical_form, t.datatype.value, t.language_tag)
    elseif t isa BlankNode
        print(io, "_:b", t.id)
    else
        error("Cannot render term of type $(typeof(t)) as SPARQL text")
    end
end

# ── Expressions ────────────────────────────────────────────────────────────────

const _SP_RENDER_BINOP = Dict{Symbol,String}(
    :add => "+",  :sub => "-",  :mul => "*",  :div => "/",
    :eq  => "=",  :neq => "!=", :lt  => "<",  :le  => "<=",
    :gt  => ">",  :ge  => ">=", :and => "&&", :or  => "||",
)

function _sp_render_expr(io::IO, e::SpExpr)
    if e isa SpVar
        print(io, '?', e.name)
    elseif e isa SpIRI
        print(io, '<', e.value, '>')
    elseif e isa SpLiteral
        _sp_render_literal(io, e.lexical, e.datatype, e.lang)
    elseif e isa SpBNode
        print(io, "_:", e.label)
    elseif e isa SpAnonBNode
        # A fresh, uniquely-labelled blank node is semantically equivalent to []
        print(io, "_:anon", e.id)
    elseif e isa SpConst
        _sp_render_rdfterm(io, e.term)
    elseif e isa SpTripleTerm
        print(io, "<<( ")
        _sp_render_expr(io, e.subject);   print(io, ' ')
        _sp_render_expr(io, e.predicate); print(io, ' ')
        _sp_render_expr(io, e.object)
        print(io, " )>>")
    elseif e isa SpUnary
        op = e.op === :not ? "!" : e.op === :neg ? "-" : "+"
        print(io, op, '(')
        _sp_render_expr(io, e.arg)
        print(io, ')')
    elseif e isa SpBinary
        print(io, '(')
        _sp_render_expr(io, e.left)
        print(io, ' ', _SP_RENDER_BINOP[e.op], ' ')
        _sp_render_expr(io, e.right)
        print(io, ')')
    elseif e isa SpCall
        # `func` is either a lowercase built-in keyword or an absolute IRI
        occursin(':', e.func) ? print(io, '<', e.func, '>') : print(io, uppercase(e.func))
        print(io, '(')
        for (i, a) in enumerate(e.args)
            i > 1 && print(io, ", ")
            _sp_render_expr(io, a)
        end
        print(io, ')')
    elseif e isa SpAggregate
        print(io, uppercase(string(e.func)), '(')
        e.distinct && print(io, "DISTINCT ")
        if e.arg === nothing
            print(io, '*')
        else
            _sp_render_expr(io, e.arg)
        end
        if e.separator !== nothing
            print(io, "; SEPARATOR=\"")
            _sp_render_string_escape(io, e.separator)
            print(io, '"')
        end
        print(io, ')')
    elseif e isa SpExists
        print(io, "EXISTS ")
        _sp_render_pattern(io, e.pattern)
    elseif e isa SpNotExists
        print(io, "NOT EXISTS ")
        _sp_render_pattern(io, e.pattern)
    elseif e isa SpIn
        print(io, '(')
        _sp_render_expr(io, e.expr)
        print(io, e.negated ? " NOT IN (" : " IN (")
        for (i, a) in enumerate(e.list)
            i > 1 && print(io, ", ")
            _sp_render_expr(io, a)
        end
        print(io, "))")
    elseif e isa SpIf
        print(io, "IF(")
        _sp_render_expr(io, e.cond);  print(io, ", ")
        _sp_render_expr(io, e.then_); print(io, ", ")
        _sp_render_expr(io, e.else_)
        print(io, ')')
    elseif e isa SpCoalesce
        print(io, "COALESCE(")
        for (i, a) in enumerate(e.args)
            i > 1 && print(io, ", ")
            _sp_render_expr(io, a)
        end
        print(io, ')')
    else
        error("Cannot render SPARQL expression of type $(typeof(e))")
    end
end

# ── Property paths ─────────────────────────────────────────────────────────────

function _sp_render_path(io::IO, p::SpPath)
    if p isa SpPathIRI
        print(io, '<', p.value, '>')
    elseif p isa SpPathA
        print(io, 'a')
    elseif p isa SpPathSeq
        print(io, '(')
        _sp_render_path(io, p.left)
        print(io, '/')
        _sp_render_path(io, p.right)
        print(io, ')')
    elseif p isa SpPathAlt
        print(io, '(')
        _sp_render_path(io, p.left)
        print(io, '|')
        _sp_render_path(io, p.right)
        print(io, ')')
    elseif p isa SpPathInverse
        print(io, "^(")
        _sp_render_path(io, p.child)
        print(io, ')')
    elseif p isa SpPathZeroOrMore
        print(io, '(')
        _sp_render_path(io, p.child)
        print(io, ")*")
    elseif p isa SpPathOneOrMore
        print(io, '(')
        _sp_render_path(io, p.child)
        print(io, ")+")
    elseif p isa SpPathZeroOrOne
        print(io, '(')
        _sp_render_path(io, p.child)
        print(io, ")?")
    elseif p isa SpPathRange
        print(io, '(')
        _sp_render_path(io, p.child)
        print(io, "){", p.min_)
        p.max_ === nothing ? print(io, ",}") :
            (p.max_ == p.min_ ? print(io, '}') : print(io, ',', p.max_, '}'))
    elseif p isa SpPathNeg
        print(io, "!(")
        for (i, el) in enumerate(p.elements)
            i > 1 && print(io, '|')
            if el isa SpPathInverse
                print(io, '^')
                _sp_render_path(io, el.child)
            else
                _sp_render_path(io, el)
            end
        end
        print(io, ')')
    else
        error("Cannot render property path of type $(typeof(p))")
    end
end

# ── Triples and patterns ───────────────────────────────────────────────────────

function _sp_render_triple(io::IO, t::SpTriple)
    _sp_render_expr(io, t.subject)
    print(io, ' ')
    if t.predicate isa SpPath
        _sp_render_path(io, t.predicate::SpPath)
    else
        _sp_render_expr(io, t.predicate::SpExpr)
    end
    print(io, ' ')
    _sp_render_expr(io, t.object)
end

# Render one group element (without enclosing braces).
function _sp_render_element(io::IO, pat::SpPat)
    if pat isa SpBGP
        for (i, t) in enumerate(pat.triples)
            i > 1 && print(io, ' ')
            _sp_render_triple(io, t)
            print(io, " .")
        end
    elseif pat isa SpGroup
        _sp_render_pattern(io, pat)
    elseif pat isa SpFilter
        print(io, "FILTER(")
        _sp_render_expr(io, pat.expr)
        print(io, ')')
    elseif pat isa SpOptional
        print(io, "OPTIONAL ")
        _sp_render_pattern(io, pat.pattern)
    elseif pat isa SpUnion
        _sp_render_pattern(io, pat.left)
        print(io, " UNION ")
        _sp_render_pattern(io, pat.right)
    elseif pat isa SpMinus
        print(io, "MINUS ")
        _sp_render_pattern(io, pat.pattern)
    elseif pat isa SpGraph
        print(io, "GRAPH ")
        _sp_render_expr(io, pat.name)
        print(io, ' ')
        _sp_render_pattern(io, pat.pattern)
    elseif pat isa SpService
        print(io, "SERVICE ")
        pat.silent && print(io, "SILENT ")
        _sp_render_expr(io, pat.endpoint)
        print(io, ' ')
        _sp_render_pattern(io, pat.pattern)
    elseif pat isa SpBind
        print(io, "BIND(")
        _sp_render_expr(io, pat.expr)
        print(io, " AS ?", pat.var.name, ')')
    elseif pat isa SpValues
        print(io, "VALUES (")
        for (i, v) in enumerate(pat.vars)
            i > 1 && print(io, ' ')
            print(io, '?', v.name)
        end
        print(io, ") { ")
        for row in pat.rows
            print(io, '(')
            for (i, v) in enumerate(row)
                i > 1 && print(io, ' ')
                v === nothing ? print(io, "UNDEF") : _sp_render_expr(io, v)
            end
            print(io, ") ")
        end
        print(io, '}')
    elseif pat isa SpSubQuery
        print(io, "{ ")
        _sp_render_select(io, pat.query::SpSelectQuery)
        print(io, " }")
    else
        error("Cannot render graph pattern of type $(typeof(pat))")
    end
end

"""
    _sp_render_pattern(pat::SpPat) -> String

Render a parsed graph pattern back to SPARQL text as a brace-wrapped group
graph pattern (`{ … }`).  All IRIs are emitted in absolute `<…>` form, so the
result is self-contained — no PREFIX prologue required.
"""
function _sp_render_pattern(io::IO, pat::SpPat)
    print(io, "{ ")
    if pat isa SpGroup
        for (i, el) in enumerate(pat.elements)
            i > 1 && print(io, ' ')
            _sp_render_element(io, el)
        end
    else
        _sp_render_element(io, pat)
    end
    print(io, " }")
end

_sp_render_pattern(pat::SpPat) = sprint(_sp_render_pattern, pat)

# ── SELECT query rendering (for subqueries inside rendered patterns) ──────────

function _sp_render_select(io::IO, q::SpSelectQuery)
    print(io, "SELECT ")
    q.distinct && print(io, "DISTINCT ")
    q.reduced  && print(io, "REDUCED ")
    if q.star
        print(io, "* ")
    else
        for col in q.columns
            if col.as_var === nothing
                _sp_render_expr(io, col.expr)
            else
                print(io, '(')
                _sp_render_expr(io, col.expr)
                print(io, " AS ?", col.as_var.name, ')')
            end
            print(io, ' ')
        end
    end
    print(io, "WHERE ")
    _sp_render_pattern(io, q.pattern)
    if !isempty(q.group_by)
        print(io, " GROUP BY")
        for gc in q.group_by
            print(io, ' ')
            if gc.var !== nothing
                print(io, '(')
                _sp_render_expr(io, gc.expr)
                print(io, " AS ?", gc.var.name, ')')
            else
                _sp_render_expr(io, gc.expr)
            end
        end
    end
    for h in q.having
        print(io, " HAVING(")
        _sp_render_expr(io, h)
        print(io, ')')
    end
    if !isempty(q.order_by)
        print(io, " ORDER BY")
        for oc in q.order_by
            print(io, oc.ascending ? " ASC(" : " DESC(")
            _sp_render_expr(io, oc.expr)
            print(io, ')')
        end
    end
    q.limit  !== nothing && print(io, " LIMIT ",  q.limit)
    q.offset !== nothing && print(io, " OFFSET ", q.offset)
    if q.values !== nothing
        print(io, ' ')
        _sp_render_element(io, q.values)
    end
    nothing
end
