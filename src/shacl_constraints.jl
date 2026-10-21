# ── SHACL core constraint components ────────────────────────────────────────────
#
# Each component is checked for a shape against its value nodes (and, for some,
# the focus node).  Violations are appended to ctx.results via _sh_report!.
#
# SHACL 1.0 §2.1.3: "If a shape has multiple values for a parameter, the
# constraint component is applied for each value."  Every parameter is therefore
# iterated (_sh_each / _sh_objects) and checked once per value, so each violated
# value produces its own validation result.  The only parameters still read with
# _sh_one are the ones the spec itself restricts to a single value (sh:path,
# sh:severity) — see the notes at their call sites.

# Component IRIs
_shc(name::String) = _sh(name * "ConstraintComponent")

function _sh_check_constraints(ctx::_ShCtx, shape, focus::RDFTerm,
                               path::Union{RDFTerm,Nothing}, vals::Vector{RDFTerm})
    s = ctx.shapes

    # ── Cardinality (shape-level, on the value-node count) ───────────────────
    for mn in _sh_each(s, shape, _sh("minCount"))
        if mn isa Literal && (m = tryvalue(Int, mn)) !== nothing && length(vals) < m
            _sh_report!(ctx, shape, focus, path, nothing, _shc("MinCount");
                        message="Fewer than $m values")
        end
    end
    for mx in _sh_each(s, shape, _sh("maxCount"))
        if mx isa Literal && (m = tryvalue(Int, mx)) !== nothing && length(vals) > m
            _sh_report!(ctx, shape, focus, path, nothing, _shc("MaxCount");
                        message="More than $m values")
        end
    end

    # ── Value type (per value node) ──────────────────────────────────────────
    for dt in _sh_each(s, shape, _sh("datatype"))
        dt isa IRI || continue
        for v in vals
            ok = v isa Literal && v.datatype == dt && _sh_lexical_ok(v)
            ok || _sh_report!(ctx, shape, focus, path, v, _shc("Datatype");
                              message="Value is not a well-formed $(dt.value)")
        end
    end
    for cls in _sh_each(s, shape, _sh("class"))
        for v in vals
            _sh_is_instance(ctx.data, v, cls) ||
                _sh_report!(ctx, shape, focus, path, v, _shc("Class");
                            message="Value is not an instance of $(_sh_term_str(cls))")
        end
    end
    for nk in _sh_each(s, shape, _sh("nodeKind"))
        nk isa IRI || continue
        for v in vals
            _sh_nodekind_ok(v, nk) ||
                _sh_report!(ctx, shape, focus, path, v, _shc("NodeKind");
                            message="Value does not have node kind $(_sh_term_str(nk))")
        end
    end

    # ── Value range (per value node) ─────────────────────────────────────────
    _sh_range!(ctx, shape, focus, path, vals, "minInclusive", >=, "MinInclusive")
    _sh_range!(ctx, shape, focus, path, vals, "maxInclusive", <=, "MaxInclusive")
    _sh_range!(ctx, shape, focus, path, vals, "minExclusive", >,  "MinExclusive")
    _sh_range!(ctx, shape, focus, path, vals, "maxExclusive", <,  "MaxExclusive")

    # ── String-based ─────────────────────────────────────────────────────────
    for mnl in _sh_each(s, shape, _sh("minLength"))
        (mnl isa Literal && (m = tryvalue(Int, mnl)) !== nothing) || continue
        for v in vals
            # Blank nodes have no string representation → always a violation.
            (!(v isa BlankNode) && length(_sh_lex(v)) >= m) ||
                _sh_report!(ctx, shape, focus, path, v, _shc("MinLength");
                            message="Shorter than $m characters")
        end
    end
    for mxl in _sh_each(s, shape, _sh("maxLength"))
        (mxl isa Literal && (m = tryvalue(Int, mxl)) !== nothing) || continue
        for v in vals
            (!(v isa BlankNode) && length(_sh_lex(v)) <= m) ||
                _sh_report!(ctx, shape, focus, path, v, _shc("MaxLength");
                            message="Longer than $m characters")
        end
    end
    # sh:flags is a parameter of the pattern component, not a per-pattern
    # annotation, and the order of a node's objects carries no meaning — so each
    # pattern is checked against each of the shape's sh:flags values (no
    # sh:flags → no regex options).
    flagvals = nothing   # the shape's sh:flags values, read on first pattern
    for pat in _sh_each(s, shape, _sh("pattern"))
        pat isa Literal || continue
        if flagvals === nothing
            flagvals = String[f.lexical_form for f in _sh_each(s, shape, _sh("flags"))
                              if f isa Literal]
            isempty(flagvals) && push!(flagvals, "")
        end
        for fl in flagvals
            re = _sh_build_regex(pat.lexical_form, fl)
            re === nothing && continue
            for v in vals
                (!(v isa BlankNode) && occursin(re, _sh_lex(v))) ||
                    _sh_report!(ctx, shape, focus, path, v, _shc("Pattern");
                                message="Value does not match pattern $(pat.lexical_form)" *
                                        (isempty(fl) ? "" : " (flags $fl)"))
            end
        end
    end
    for langs in _sh_each(s, shape, _sh("languageIn"))
        allowed = String[(l::Literal).lexical_form for l in _sh_list(s, langs) if l isa Literal]
        for v in vals
            ok = v isa Literal && !isempty(v.language_tag) &&
                 any(a -> _sh_lang_match(v.language_tag, a), allowed)
            ok || _sh_report!(ctx, shape, focus, path, v, _shc("LanguageIn");
                              message="Language tag not in the allowed set " *
                                      "($(_sh_terms_str(allowed)))")
        end
    end
    if _sh_truthy(s, shape, _sh("uniqueLang"))
        seen = Dict{String,Int}()
        for v in vals
            v isa Literal && !isempty(v.language_tag) &&
                (seen[v.language_tag] = get(seen, v.language_tag, 0) + 1)
        end
        for (lang, n) in seen
            n > 1 && _sh_report!(ctx, shape, focus, path, nothing, _shc("UniqueLang");
                                 message="Language $lang used more than once")
        end
    end

    # ── sh:in / sh:hasValue ──────────────────────────────────────────────────
    for inl in _sh_each(s, shape, _sh("in"))
        members = _sh_list(s, inl)
        allowed = Set{RDFTerm}(members)
        for v in vals
            v in allowed ||
                _sh_report!(ctx, shape, focus, path, v, _shc("In");
                            message="Value is not in the allowed list " *
                                    "($(_sh_terms_str(members)))")
        end
    end
    for hv in _sh_each(s, shape, _sh("hasValue"))
        (hv in vals) ||
            _sh_report!(ctx, shape, focus, path, nothing, _shc("HasValue");
                        message="Missing required value $(_sh_term_str(hv))")
    end

    # ── Property-pair ────────────────────────────────────────────────────────
    _sh_pair!(ctx, shape, focus, path, vals)

    # ── Logical ──────────────────────────────────────────────────────────────
    for ns in _sh_each(s, shape, _sh("not"))
        for v in vals
            _sh_node_conforms(ctx, ns, v) &&
                _sh_report!(ctx, shape, focus, path, v, _shc("Not");
                            message="Value conforms to a negated shape")
        end
    end
    # Each sh:and / sh:or / sh:xone value is its own list of shapes, and the
    # message names that list's members so two violated lists on the same shape
    # stay apart in the report.
    for andl in _sh_each(s, shape, _sh("and"))
        subs = _sh_list(s, andl)
        for v in vals
            all(sub -> _sh_node_conforms(ctx, sub, v), subs) ||
                _sh_report!(ctx, shape, focus, path, v, _shc("And");
                            message="Value does not conform to all of $(_sh_terms_str(subs))")
        end
    end
    for orl in _sh_each(s, shape, _sh("or"))
        subs = _sh_list(s, orl)
        for v in vals
            any(sub -> _sh_node_conforms(ctx, sub, v), subs) ||
                _sh_report!(ctx, shape, focus, path, v, _shc("Or");
                            message="Value does not conform to any of $(_sh_terms_str(subs))")
        end
    end
    for xonel in _sh_each(s, shape, _sh("xone"))
        subs = _sh_list(s, xonel)
        for v in vals
            count(sub -> _sh_node_conforms(ctx, sub, v), subs) == 1 ||
                _sh_report!(ctx, shape, focus, path, v, _shc("Xone");
                            message="Value does not conform to exactly one of " *
                                    "$(_sh_terms_str(subs))")
        end
    end

    # ── Shape-based: sh:node / sh:property ───────────────────────────────────
    for ns in _sh_each(s, shape, _sh("node"))
        for v in vals
            _sh_node_conforms(ctx, ns, v) ||
                _sh_report!(ctx, shape, focus, path, v, _shc("Node");
                            message="Value does not conform to node shape $(_sh_term_str(ns))")
        end
    end
    for ps in _sh_each(s, shape, _sh("property"))
        # property shape is validated with each value node as its focus
        for v in vals
            _sh_validate(ctx, ps, v)
        end
    end

    # ── sh:qualifiedValueShape ───────────────────────────────────────────────
    # sh:qualifiedValueShape, sh:qualifiedMinCount and sh:qualifiedMaxCount are
    # parameters of the same two components, so every (shape, count) pair is a
    # constraint of its own.
    for qvs in _sh_each(s, shape, _sh("qualifiedValueShape"))
        nconf = count(v -> _sh_node_conforms(ctx, qvs, v), vals)
        for qmin in _sh_each(s, shape, _sh("qualifiedMinCount"))
            if qmin isa Literal && (m = tryvalue(Int, qmin)) !== nothing && nconf < m
                _sh_report!(ctx, shape, focus, path, nothing, _shc("QualifiedMinCount");
                            message="Fewer than $m values conform to the qualified " *
                                    "shape $(_sh_term_str(qvs))")
            end
        end
        for qmax in _sh_each(s, shape, _sh("qualifiedMaxCount"))
            if qmax isa Literal && (m = tryvalue(Int, qmax)) !== nothing && nconf > m
                _sh_report!(ctx, shape, focus, path, nothing, _shc("QualifiedMaxCount");
                            message="More than $m values conform to the qualified " *
                                    "shape $(_sh_term_str(qvs))")
            end
        end
    end

    # ── sh:closed ────────────────────────────────────────────────────────────
    if _sh_truthy(s, shape, _sh("closed"))
        _sh_closed!(ctx, shape, focus)
    end
end

# ── Helpers ──────────────────────────────────────────────────────────────────

_sh_term_str(t::RDFTerm) = t isa IRI ? t.value : sprint(show, t)

# Render a parameter's list of terms for a message, abbreviated when long.  Used
# to tell apart two violated values of the same parameter (two sh:or lists, say).
function _sh_terms_str(ts::AbstractVector; limit::Int=5)::String
    shown = join((t isa AbstractString ? t : _sh_term_str(t) for t in first(ts, limit)), ", ")
    length(ts) > limit ? shown * ", …" : shown
end

function _sh_lex(t::RDFTerm)::String
    t isa Literal && return t.lexical_form
    t isa IRI     && return t.value
    ""
end

function _sh_nodekind_ok(v::RDFTerm, kind::IRI)::Bool
    k = kind.value
    isiri = v isa IRI; isbn = v isa BlankNode; islit = v isa Literal
    k == _SH * "IRI"               && return isiri
    k == _SH * "BlankNode"         && return isbn
    k == _SH * "Literal"           && return islit
    k == _SH * "BlankNodeOrIRI"    && return isbn || isiri
    k == _SH * "BlankNodeOrLiteral"&& return isbn || islit
    k == _SH * "IRIOrLiteral"      && return isiri || islit
    false
end

function _sh_build_regex(pat::String, flags::String)
    opts = ""
    occursin('i', flags) && (opts *= "i")
    occursin('s', flags) && (opts *= "s")
    occursin('m', flags) && (opts *= "m")
    occursin('x', flags) && (opts *= "x")
    try
        isempty(opts) ? Regex(pat) : Regex(pat, opts)
    catch
        nothing
    end
end

# Basic-language-range match (RFC 4647): exact or prefix before '-'.
function _sh_lang_match(tag::String, range::String)::Bool
    lt = lowercase(tag); lr = lowercase(range)
    lr == "*" && return !isempty(lt)
    lt == lr || startswith(lt, lr * "-")
end

# Value-range comparison: numbers numerically, otherwise by SPARQL term compare.
function _sh_range!(ctx::_ShCtx, shape, focus, path, vals, param::String,
                    op::Function, comp::String)
    for bound in _sh_each(ctx.shapes, shape, _sh(param))
        bound isa Literal || continue
        for v in vals
            ok = false
            if v isa Literal
                c = _sh_num_cmp(v, bound)
                ok = c === nothing ? false : op(c, 0)
            end
            ok || _sh_report!(ctx, shape, focus, path, v, _shc(comp);
                              message="Value out of range ($param $(bound.lexical_form))")
        end
    end
end

# Compare two literals by value; returns -1/0/1 or nothing if not comparable.
# Handles numbers, xsd:dateTime, xsd:date, and (lexicographically) strings.
function _sh_num_cmp(a::Literal, b::Literal)::Union{Int,Nothing}
    av = tryvalue(a); bv = tryvalue(b)
    av === nothing && return nothing
    bv === nothing && return nothing
    comparable = (av isa Real && bv isa Real) ||
                 (av isa Dates.AbstractDateTime && bv isa Dates.AbstractDateTime) ||
                 (av isa Dates.Date && bv isa Dates.Date) ||
                 (av isa AbstractString && bv isa AbstractString)
    comparable || return nothing
    av < bv ? -1 : av > bv ? 1 : 0
end

# Property-pair constraints (equals / disjoint / lessThan / lessThanOrEquals).
function _sh_pair!(ctx::_ShCtx, shape, focus, path, vals)
    s = ctx.shapes
    for eqp in _sh_each(s, shape, _sh("equals"))
        eqp isa IRI || continue
        other = Set{RDFTerm}(_sh_path_values(ctx.data, focus, eqp))
        vs = Set{RDFTerm}(vals)
        for v in setdiff(vs, other)
            _sh_report!(ctx, shape, focus, path, v, _shc("Equals");
                        message="Value not equal to $(eqp.value)")
        end
        for v in setdiff(other, vs)
            _sh_report!(ctx, shape, focus, path, v, _shc("Equals");
                        message="Missing value present at $(eqp.value)")
        end
    end
    for dis in _sh_each(s, shape, _sh("disjoint"))
        dis isa IRI || continue
        other = Set{RDFTerm}(_sh_path_values(ctx.data, focus, dis))
        for v in vals
            v in other && _sh_report!(ctx, shape, focus, path, v, _shc("Disjoint");
                                      message="Value also present at $(dis.value)")
        end
    end
    for lt in _sh_each(s, shape, _sh("lessThan"))
        lt isa IRI || continue
        others = _sh_path_values(ctx.data, focus, lt)
        for v in vals, o in others
            c = (v isa Literal && o isa Literal) ? _sh_num_cmp(v, o) : nothing
            (c !== nothing && c < 0) ||
                _sh_report!(ctx, shape, focus, path, v, _shc("LessThan");
                            message="Value not less than $(lt.value)")
        end
    end
    for lte in _sh_each(s, shape, _sh("lessThanOrEquals"))
        lte isa IRI || continue
        others = _sh_path_values(ctx.data, focus, lte)
        for v in vals, o in others
            c = (v isa Literal && o isa Literal) ? _sh_num_cmp(v, o) : nothing
            (c !== nothing && c <= 0) ||
                _sh_report!(ctx, shape, focus, path, v, _shc("LessThanOrEquals");
                            message="Value not <= $(lte.value)")
        end
    end
end

# sh:closed — focus may only use predicates declared by the shape's property
# shapes (predicate paths), plus sh:ignoredProperties.
function _sh_closed!(ctx::_ShCtx, shape, focus::RDFTerm)
    focus isa SubjectTerm || return
    allowed = Set{IRI}()
    for ps in _sh_objects(ctx.shapes, shape, _sh("property"))
        # sh:path is single-valued by definition (a property shape with several
        # paths is ill-formed), so _sh_one is right here.
        p = _sh_one(ctx.shapes, ps, _sh("path"))
        p isa IRI && push!(allowed, p)
    end
    # sh:ignoredProperties is a parameter of the same component as sh:closed, so
    # each of its values is a constraint in its own right: a predicate has to be
    # ignored by every one of the lists (no list → nothing is ignored).
    ignlists = _sh_objects(ctx.shapes, shape, _sh("ignoredProperties"))
    isempty(ignlists) && return _sh_closed_check!(ctx, shape, focus, allowed)
    for ign in ignlists
        ignored = copy(allowed)
        for p in _sh_list(ctx.shapes, ign); p isa IRI && push!(ignored, p); end
        _sh_closed_check!(ctx, shape, focus, ignored)
    end
end

function _sh_closed_check!(ctx::_ShCtx, shape, focus::RDFTerm, allowed::Set{IRI})
    for t in match(ctx.data; subject=focus)
        t.predicate in allowed ||
            _sh_report!(ctx, shape, focus, t.predicate, t.object, _shc("Closed");
                        message="Predicate $(t.predicate.value) not allowed (closed shape)")
    end
end

# Does a single node conform to a shape?  (Runs the shape on the node in an
# isolated sub-context so its results don't pollute the report.)
function _sh_node_conforms(ctx::_ShCtx, shape, node::RDFTerm)::Bool
    sub = _ShCtx(ctx.data, ctx.shapes, ValidationResult[])
    _sh_validate(sub, shape, node)
    isempty(sub.results)
end

# ── AI ergonomics: report → prompt, and validate-before-commit ──────────────────

"""
    to_prompt(report::ValidationReport; max_results=20) -> String

Render a SHACL [`ValidationReport`](@ref) as terse text an LLM can act on — the
validation-side analog of the schema [`to_prompt`](@ref).  A conforming report
returns a short positive message; otherwise each violation is listed with its
focus node, path, offending value, and reason, so a model can correct the data
it produced and retry.

```julia
report = validate_shapes(extracted, shapes)
report.conforms || retry_with(llm, prompt * "\\n\\n" * to_prompt(report))
```
"""
function to_prompt(report::ValidationReport; max_results::Int=20)::String
    report.conforms && return "The data conforms to all shapes."
    io = IOBuffer()
    n = length(report.results)
    print(io, "The data has $n SHACL violation", n == 1 ? "" : "s", ":")
    for r in first(report.results, max_results)
        print(io, "\n- ", _sh_term_str(r.focus_node))
        r.path  !== nothing && print(io, " ", _sh_term_str(r.path))
        r.value !== nothing && print(io, " = ", sprint(show, r.value))
        comp = replace(r.component.value, _SH => "", "ConstraintComponent" => "")
        print(io, ": ", isempty(r.message) ? comp : r.message, " (", comp, ")")
    end
    n > max_results && print(io, "\n… and $(n - max_results) more.")
    String(take!(io))
end

"""
    conforming(data::Graph, shapes::Graph) -> Graph

Return a copy of `data` with every triple belonging to a non-conforming focus
node removed, so the result [`conforms`](@ref) to `shapes`.  Intended as an
extraction guardrail: keep the facts an LLM produced that pass validation and
drop the rest before committing.

```julia
trusted = conforming(llm_extracted, shapes)   # only valid facts survive
```

A focus node is dropped wholesale (all triples with it as subject) when it has
any violation; this is a deliberately conservative filter.
"""
function conforming(data::Graph, shapes::Graph)::Graph
    report = validate_shapes(data, shapes)
    bad = Set{RDFTerm}(r.focus_node for r in report.results)
    out = Graph()
    for t in data
        t.subject in bad || push!(out, t)
    end
    out
end
