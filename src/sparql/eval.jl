# ── SPARQL 1.1 Query Evaluator ────────────────────────────────────────────────
#
# Implements the SPARQL 1.1 evaluation semantics over Graph / Dataset.
# Included into the RDF module; no module declaration.
#
# Reference: https://www.w3.org/TR/sparql11-query/
#
# Evaluation model:
#   A "solution" (μ) is a Dict{Symbol, RDFTerm} mapping variable names to terms.
#   Pattern evaluation returns a Vector of solutions (a multiset).
#
# Error handling: SPARQL errors (type errors in FILTER, unbound vars in expressions)
#   are represented by catching Julia exceptions. FILTER propagates errors as false.
#   SELECT columns propagate errors as unbound (nothing).

# ── Solution type alias ───────────────────────────────────────────────────────

const _SpSolution = Dict{Symbol, RDFTerm}

# Create a copy of a solution
_sp_copy_sol(μ::_SpSolution) = copy(μ)

# Merge two compatible solutions (no conflict check here)
function _sp_merge_sol(μ1::_SpSolution, μ2::_SpSolution)::_SpSolution
    result = copy(μ1)
    for (k, v) in μ2
        result[k] = v
    end
    result
end

# Check if two solutions are compatible (agree on shared variables)
function _sp_compatible(μ1::_SpSolution, μ2::_SpSolution)::Bool
    for (k, v) in μ1
        haskey(μ2, k) && μ2[k] != v && return false
    end
    true
end

# ── Evaluation context ────────────────────────────────────────────────────────

mutable struct _SpEvalCtx
    dataset::Dataset
    active_graph::Graph    # the graph currently being matched against
    base::Union{String, Nothing}
    blank_node_scope::Dict{String, BlankNode}  # per-BGP blank node mapping
    bnode_solution_scope::Dict{String, BlankNode}  # per-solution BNODE(str) mapping
end

function _SpEvalCtx(ds::Dataset, base::Union{String,Nothing})
    _SpEvalCtx(ds, ds.default_graph, base, Dict{String, BlankNode}(), Dict{String, BlankNode}())
end

function _SpEvalCtx(g::Graph, base::Union{String,Nothing})
    ds = Dataset(default_graph=g)
    _SpEvalCtx(ds, g, base, Dict{String, BlankNode}(), Dict{String, BlankNode}())
end

# Create a derived context with a different active graph
function _sp_with_graph(ctx::_SpEvalCtx, g::Graph)
    _SpEvalCtx(ctx.dataset, g, ctx.base, Dict{String, BlankNode}(), ctx.bnode_solution_scope)
end

# ── Columnar BindingTable for zero-copy BGP evaluation ────────────────────────
#
# During BGP matching, solutions are stored column-wise as parallel Vector{UInt32}
# arrays (one per variable, 0 = unbound) rather than as Vector{Dict{Symbol,…}}.
# Each join extends the table by appending to (or adding) columns, with no Dict
# allocation per intermediate result.  Only at BGP output do we materialise back
# to Vector{_SpSolution} for the rest of the evaluator.
#
# Key design decisions:
#   • IDs come straight from the hexastore via _match_ids (no _resolve, no Triple).
#   • SpBNode / SpAnonBNode are treated as regular variables (synthetic Symbol keys).
#   • Property-path triples fall back to per-solution evaluation mid-BGP.

struct _BT
    vars::Vector{Symbol}
    var_idx::Dict{Symbol, Int}
    cols::Vector{Vector{UInt32}}
    nrows::Int   # explicit row count — handles the 0-column initial case correctly
end

# Constructors
_BT() = _BT(Symbol[], Dict{Symbol,Int}(), Vector{UInt32}[], 0)

function _BT(vars::Vector{Symbol}, nrows::Int=0)
    _BT(vars,
        Dict{Symbol,Int}(v => i for (i,v) in enumerate(vars)),
        [sizehint!(UInt32[], nrows) for _ in vars],
        nrows)
end

# When building with pre-filled columns:
function _BT(vars::Vector{Symbol}, var_idx::Dict{Symbol,Int}, cols::Vector{Vector{UInt32}})
    nr = isempty(cols) ? 0 : length(cols[1])
    _BT(vars, var_idx, cols, nr)
end

_bt_nrows(bt::_BT) = bt.nrows
_bt_ncols(bt::_BT) = length(bt.vars)

# Convert Vector{_SpSolution} → _BT.
function _solutions_to_bt(sols::Vector{_SpSolution})::_BT
    isempty(sols) && return _BT()

    # Collect union of variable names across all solutions (preserve insertion order).
    vars     = Symbol[]
    var_seen = Set{Symbol}()
    for μ in sols
        for k in keys(μ)
            k in var_seen || (push!(var_seen, k); push!(vars, k))
        end
    end

    nv      = length(vars)
    n       = length(sols)
    var_idx = Dict{Symbol,Int}(v => i for (i,v) in enumerate(vars))
    cols    = [Vector{UInt32}(undef, n) for _ in 1:nv]

    for (j, μ) in enumerate(sols)
        for i in 1:nv
            t = get(μ, vars[i], nothing)
            # _intern! ensures all terms (including BIND-computed values) have a
            # valid ID — get() alone would return 0 for terms not yet in the registry.
            cols[i][j] = t === nothing ? UInt32(0) : _intern!(t)
        end
    end

    _BT(vars, var_idx, cols, n)
end

# Convert _BT → Vector{_SpSolution}.
function _bt_to_solutions(bt::_BT)::Vector{_SpSolution}
    n = bt.nrows
    n == 0 && return _SpSolution[]
    nv   = _bt_ncols(bt)
    sols = Vector{_SpSolution}(undef, n)
    for j in 1:n
        d = _SpSolution()
        for i in 1:nv
            id = @inbounds bt.cols[i][j]
            id != 0 && (d[@inbounds bt.vars[i]] = _resolve(id))
        end
        sols[j] = d
    end
    sols
end

# Variable symbol for a triple-pattern position (nothing for constants).
@inline function _bt_var_sym(expr::SpExpr)::Union{Symbol, Nothing}
    expr isa SpVar       && return expr.name
    expr isa SpBNode     && return Symbol("_sp_bnode_", expr.label)
    expr isa SpAnonBNode && return Symbol("_sp_anon_", expr.id)
    nothing
end

# Return (is_constant, id) for a triple-pattern position.
# id == 0 means the constant is not in the term registry → no matches possible.
@inline function _bt_const_id(expr::SpExpr, ctx::_SpEvalCtx)::Tuple{Bool, UInt32}
    if expr isa SpIRI
        iri_str = expr.value
        if ctx.base !== nothing && !occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", iri_str)
            iri_str = _sp_resolve_iri(ctx.base, iri_str)
        end
        return (true, get(_IRI_TO_ID, IRI(iri_str), UInt32(0)))
    elseif expr isa SpLiteral
        term = try
            isempty(expr.lang) ? Literal(expr.lexical, IRI(expr.datatype), "") :
                                 Literal(expr.lexical, IRI(expr.datatype), expr.lang)
        catch
            return (true, UInt32(0))
        end
        return (true, get(_LITERAL_TO_ID, term, UInt32(0)))
    elseif expr isa SpTripleTerm
        # Constant only when every inner position is itself constant
        s_is_c, s_id = _bt_const_id(expr.subject,   ctx)
        s_is_c || return (false, UInt32(0))
        p_is_c, p_id = _bt_const_id(expr.predicate, ctx)
        p_is_c || return (false, UInt32(0))
        o_is_c, o_id = _bt_const_id(expr.object,    ctx)
        o_is_c || return (false, UInt32(0))
        # All constant — any missing from registry means no match possible
        (s_id == 0 || p_id == 0 || o_id == 0) && return (true, UInt32(0))
        s_term = _resolve(s_id)
        p_term = _resolve(p_id)
        o_term = _resolve(o_id)
        p_term isa IRI || return (true, UInt32(0))
        s_term isa SubjectTerm || return (true, UInt32(0))
        tt = try TripleTerm(s_term, p_term::IRI, o_term) catch; return (true, UInt32(0)) end
        return (true, get(_TRIPLE_TERM_TO_ID, tt, UInt32(0)))
    end
    (false, UInt32(0))
end

# True/complex property paths: these require graph traversal and cannot be handled
# inline by _bt_extend_tp; only SpPathIRI and SpPathA (plain IRI / rdf:type in
# predicate position) are "trivial" and ARE handled by _bt_extend_tp.
@inline function _bt_is_complex_path(pred::Union{SpExpr, SpPath})::Bool
    pred isa SpPath && !(pred isa SpPathIRI) && !(pred isa SpPathA)
end

# Intern the predicate as a constant (is_const, id).
# Handles SpExpr (SpIRI, SpLiteral, SpVar) as well as SpPathIRI / SpPathA.
@inline function _bt_pred_const_id(pred::Union{SpExpr, SpPath}, ctx::_SpEvalCtx)::Tuple{Bool, UInt32}
    if pred isa SpPathIRI
        iri_str = pred.value
        if ctx.base !== nothing && !occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", iri_str)
            iri_str = _sp_resolve_iri(ctx.base, iri_str)
        end
        return (true, get(_IRI_TO_ID, IRI(iri_str), UInt32(0)))
    elseif pred isa SpPathA
        return (true, get(_IRI_TO_ID, IRI(_SP_RDF_TYPE), UInt32(0)))
    elseif pred isa SpExpr
        return _bt_const_id(pred, ctx)
    end
    (false, UInt32(0))  # complex SpPath — should not reach here
end

# Variable symbol for the predicate (handles SpPathIRI/SpPathA which are constants).
@inline function _bt_pred_var_sym(pred::Union{SpExpr, SpPath})::Union{Symbol, Nothing}
    pred isa SpExpr ? _bt_var_sym(pred) : nothing  # SpPathIRI/SpPathA are constants
end

# Extend bt by joining with one triple pattern.
# SpPathIRI and SpPathA predicates are treated as plain IRI constants.
# Complex property paths must be caught by the caller before calling this.
function _bt_extend_tp(bt::_BT, tp::SpTriple, ctx::_SpEvalCtx)::_BT
    n = _bt_nrows(bt)
    n == 0 && return bt

    s_expr = tp.subject
    o_expr = tp.object

    # Intern query constants once (not per row).
    s_is_c, s_cid = _bt_const_id(s_expr, ctx)
    p_is_c, p_cid = _bt_pred_const_id(tp.predicate, ctx)
    o_is_c, o_cid = _bt_const_id(o_expr, ctx)

    # Short-circuit: constant missing from registry → no results.
    (s_is_c && s_cid == 0) && return _BT(bt.vars)
    (p_is_c && p_cid == 0) && return _BT(bt.vars)
    (o_is_c && o_cid == 0) && return _BT(bt.vars)

    # Variable symbols for each position (nothing = constant position).
    s_var = _bt_var_sym(s_expr)
    p_var = _bt_pred_var_sym(tp.predicate)
    o_var = _bt_var_sym(o_expr)

    # Column indices of existing (already-in-bt) variables; 0 = not yet present.
    s_col = s_var !== nothing ? get(bt.var_idx, s_var, 0) : 0
    p_col = p_var !== nothing ? get(bt.var_idx, p_var, 0) : 0
    o_col = o_var !== nothing ? get(bt.var_idx, o_var, 0) : 0

    # New variables introduced by this triple pattern (deduplicated, s→p→o order).
    new_vars = Symbol[]
    s_var !== nothing && s_col == 0 && push!(new_vars, s_var)
    p_var !== nothing && p_col == 0 && (p_var in new_vars || push!(new_vars, p_var))
    o_var !== nothing && o_col == 0 && (o_var in new_vars || push!(new_vars, o_var))

    # Build output schema.
    out_vars = vcat(bt.vars, new_vars)
    out_idx  = copy(bt.var_idx)
    base     = length(bt.vars)
    for (i, v) in enumerate(new_vars)
        out_idx[v] = base + i
    end

    # Which positions are responsible for writing new columns.
    # When the same variable appears twice (self-join), only the first write fires;
    # the self-join filter below ensures the two IDs agree.
    s_wrt = s_var !== nothing && s_col == 0
    p_wrt = p_var !== nothing && p_col == 0 && (s_var === nothing || p_var !== s_var)
    o_wrt = o_var !== nothing && o_col == 0 &&
                (s_var === nothing || o_var !== s_var) &&
                (p_var === nothing || o_var !== p_var)

    # SpBNode: first binding must match a BlankNode term.
    s_needs_bn = s_expr isa SpBNode && s_col == 0
    o_needs_bn = o_expr isa SpBNode && o_col == 0

    # Allocate output columns.
    out_cols = [sizehint!(UInt32[], n) for _ in 1:length(out_vars)]
    out_nrows = 0  # track emitted rows explicitly (handles 0-column all-constant case)

    for row in 1:n
        # Retrieve bound IDs from the current row (0 = unbound).
        s_rid = s_col != 0 ? @inbounds(bt.cols[s_col][row]) : UInt32(0)
        p_rid = p_col != 0 ? @inbounds(bt.cols[p_col][row]) : UInt32(0)
        o_rid = o_col != 0 ? @inbounds(bt.cols[o_col][row]) : UInt32(0)

        # Filter IDs for _match_ids: constant > row-bound value > nothing (wildcard).
        s_fn = s_is_c ? s_cid : (s_rid != 0 ? s_rid : nothing)
        p_fn = p_is_c ? p_cid : (p_rid != 0 ? p_rid : nothing)
        o_fn = o_is_c ? o_cid : (o_rid != 0 ? o_rid : nothing)

        for (t_s, t_p, t_o) in _match_ids(ctx.active_graph, s_fn, p_fn, o_fn)
            # Self-join consistency: same variable in multiple positions must match.
            s_var !== nothing && p_var !== nothing && s_var === p_var && t_s != t_p && continue
            s_var !== nothing && o_var !== nothing && s_var === o_var && t_s != t_o && continue
            p_var !== nothing && o_var !== nothing && p_var === o_var && t_p != t_o && continue
            # SpBNode first-time binding must be a BlankNode.
            s_needs_bn && !(_resolve(t_s) isa BlankNode) && continue
            o_needs_bn && !(_resolve(t_o) isa BlankNode) && continue

            # Emit: copy existing columns for this row, then append new bindings.
            for col in 1:base
                push!(@inbounds(out_cols[col]), @inbounds(bt.cols[col][row]))
            end
            s_wrt && push!(@inbounds(out_cols[out_idx[s_var]]), t_s)
            p_wrt && push!(@inbounds(out_cols[out_idx[p_var]]), t_p)
            o_wrt && push!(@inbounds(out_cols[out_idx[o_var]]), t_o)
            out_nrows += 1
        end
    end

    _BT(out_vars, out_idx, out_cols, out_nrows)
end

# ── Columnar left join (OPTIONAL) ─────────────────────────────────────────────
#
# _bt_left_join is the columnar equivalent of the per-row SpOptional loop.
# It keeps all input rows in the output, extending matched rows with new
# variable bindings and padding unmatched rows with UInt32(0) (= unbound).
#
# Fast paths:
#   • Single trivial triple predicate  → _bt_left_join_tp  (zero round-trips)
#   • Multi-triple BGP, no prop paths  → _bt_left_join_bgp (one extra alloc for
#                                         a synthetic row-id column)
# Fallback (complex optional body: property paths, UNION, nested OPTIONAL, …):
#   • _bt_to_solutions once, then per-row _sp_eval_pattern, then _solutions_to_bt.
#   • Same semantics as the old code but pays the BT round-trip only once rather
#     than building a fresh 1-row BT for each input solution.

# Single trivial triple — mirrors _bt_extend_tp but keeps non-matching rows.
function _bt_left_join_tp(bt::_BT, tp::SpTriple, ctx::_SpEvalCtx)::_BT
    n = _bt_nrows(bt)
    n == 0 && return bt

    s_expr = tp.subject
    o_expr = tp.object

    s_is_c, s_cid = _bt_const_id(s_expr, ctx)
    p_is_c, p_cid = _bt_pred_const_id(tp.predicate, ctx)
    o_is_c, o_cid = _bt_const_id(o_expr, ctx)

    # A constant not in the registry means no row can match; for a left join
    # we simply keep all input rows as-is (no new variables introduced yet).
    if (s_is_c && s_cid == 0) || (p_is_c && p_cid == 0) || (o_is_c && o_cid == 0)
        return bt
    end

    s_var = _bt_var_sym(s_expr)
    p_var = _bt_pred_var_sym(tp.predicate)
    o_var = _bt_var_sym(o_expr)

    s_col = s_var !== nothing ? get(bt.var_idx, s_var, 0) : 0
    p_col = p_var !== nothing ? get(bt.var_idx, p_var, 0) : 0
    o_col = o_var !== nothing ? get(bt.var_idx, o_var, 0) : 0

    new_vars = Symbol[]
    s_var !== nothing && s_col == 0 && push!(new_vars, s_var)
    p_var !== nothing && p_col == 0 && (p_var in new_vars || push!(new_vars, p_var))
    o_var !== nothing && o_col == 0 && (o_var in new_vars || push!(new_vars, o_var))

    out_vars = vcat(bt.vars, new_vars)
    out_idx  = copy(bt.var_idx)
    base     = length(bt.vars)
    for (i, v) in enumerate(new_vars)
        out_idx[v] = base + i
    end

    s_wrt = s_var !== nothing && s_col == 0
    p_wrt = p_var !== nothing && p_col == 0 && (s_var === nothing || p_var !== s_var)
    o_wrt = o_var !== nothing && o_col == 0 &&
                (s_var === nothing || o_var !== s_var) &&
                (p_var === nothing || o_var !== p_var)

    s_needs_bn = s_expr isa SpBNode && s_col == 0
    o_needs_bn = o_expr isa SpBNode && o_col == 0

    out_cols  = [sizehint!(UInt32[], n) for _ in 1:length(out_vars)]
    out_nrows = 0

    for row in 1:n
        s_rid = s_col != 0 ? @inbounds(bt.cols[s_col][row]) : UInt32(0)
        p_rid = p_col != 0 ? @inbounds(bt.cols[p_col][row]) : UInt32(0)
        o_rid = o_col != 0 ? @inbounds(bt.cols[o_col][row]) : UInt32(0)

        s_fn = s_is_c ? s_cid : (s_rid != 0 ? s_rid : nothing)
        p_fn = p_is_c ? p_cid : (p_rid != 0 ? p_rid : nothing)
        o_fn = o_is_c ? o_cid : (o_rid != 0 ? o_rid : nothing)

        matched = false
        for (t_s, t_p, t_o) in _match_ids(ctx.active_graph, s_fn, p_fn, o_fn)
            s_var !== nothing && p_var !== nothing && s_var === p_var && t_s != t_p && continue
            s_var !== nothing && o_var !== nothing && s_var === o_var && t_s != t_o && continue
            p_var !== nothing && o_var !== nothing && p_var === o_var && t_p != t_o && continue
            s_needs_bn && !(_resolve(t_s) isa BlankNode) && continue
            o_needs_bn && !(_resolve(t_o) isa BlankNode) && continue

            for col in 1:base
                push!(@inbounds(out_cols[col]), @inbounds(bt.cols[col][row]))
            end
            s_wrt && push!(@inbounds(out_cols[out_idx[s_var]]), t_s)
            p_wrt && push!(@inbounds(out_cols[out_idx[p_var]]), t_p)
            o_wrt && push!(@inbounds(out_cols[out_idx[o_var]]), t_o)
            out_nrows += 1
            matched = true
        end

        if !matched
            # LEFT JOIN: keep input row, new vars stay unbound (zero).
            for col in 1:base
                push!(@inbounds(out_cols[col]), @inbounds(bt.cols[col][row]))
            end
            for i in (base + 1):length(out_vars)
                push!(@inbounds(out_cols[i]), UInt32(0))
            end
            out_nrows += 1
        end
    end

    _BT(out_vars, out_idx, out_cols, out_nrows)
end

# Multi-triple BGP left join.
# Appends a synthetic row-id column so that after the inner join we can
# identify which input rows had at least one match.
function _bt_left_join_bgp(bt::_BT, bgp::SpBGP, ctx::_SpEvalCtx)::_BT
    n    = _bt_nrows(bt)
    base = length(bt.vars)

    # Synthetic column: row indices 1..n stored as UInt32.
    # The symbol contains a null byte so it can never clash with a SPARQL variable.
    rid_sym = Symbol("\x00rid\x00")
    rid_col = Vector{UInt32}(undef, n)
    for i in 1:n; @inbounds rid_col[i] = UInt32(i); end

    ext_vars = vcat(bt.vars, [rid_sym])
    ext_idx  = copy(bt.var_idx);  ext_idx[rid_sym] = base + 1
    ext_cols = vcat(bt.cols, [rid_col])
    inner_bt = _BT(ext_vars, ext_idx, ext_cols, n)

    # Inner join over all optional triples (most selective first; all of the
    # input table's variables count as bound).
    for tp in _sp_reorder_bgp(bgp.triples, ctx, Set(bt.vars))
        _bt_nrows(inner_bt) == 0 && break
        inner_bt = _bt_extend_tp(inner_bt, tp, ctx)
    end

    # Variables newly introduced by the optional body.
    new_vars = [v for v in inner_bt.vars if !haskey(bt.var_idx, v) && v !== rid_sym]

    out_vars = vcat(bt.vars, new_vars)
    out_idx  = copy(bt.var_idx)
    for (i, v) in enumerate(new_vars)
        out_idx[v] = base + i
    end
    out_cols  = [sizehint!(UInt32[], n) for _ in 1:length(out_vars)]
    out_nrows = 0

    # Emit matched rows from the inner result (drop the rid column).
    rid_ci  = inner_bt.var_idx[rid_sym]
    matched = falses(n)
    for j in 1:_bt_nrows(inner_bt)
        rid = @inbounds inner_bt.cols[rid_ci][j]
        @inbounds matched[rid] = true
        for (i, v) in enumerate(out_vars)
            ci  = get(inner_bt.var_idx, v, 0)
            val = ci != 0 ? @inbounds(inner_bt.cols[ci][j]) : UInt32(0)
            push!(@inbounds(out_cols[i]), val)
        end
        out_nrows += 1
    end

    # Emit unmatched input rows — new vars are unbound (zero).
    for row in 1:n
        @inbounds matched[row] && continue
        for col in 1:base
            push!(@inbounds(out_cols[col]), @inbounds(bt.cols[col][row]))
        end
        for i in (base + 1):length(out_vars)
            push!(@inbounds(out_cols[i]), UInt32(0))
        end
        out_nrows += 1
    end

    _BT(out_vars, out_idx, out_cols, out_nrows)
end

# Top-level dispatcher: choose the best left-join strategy for an OPTIONAL body.
function _bt_left_join(bt::_BT, opt_pat::SpPat, ctx::_SpEvalCtx)::_BT
    _bt_nrows(bt) == 0 && return bt

    # Normalise: unwrap a SpGroup that contains only SpBGP elements (no filters,
    # BIND, nested OPTIONAL, etc.) into a single merged BGP so we get the fast path.
    bgp = _bt_extract_plain_bgp(opt_pat)

    if bgp !== nothing &&
       !any(tp -> _bt_is_complex_path(tp.predicate) || _tp_needs_tt_matching(tp), bgp.triples)
        isempty(bgp.triples) && return bt
        length(bgp.triples) == 1 && return _bt_left_join_tp(bt, bgp.triples[1], ctx)
        return _bt_left_join_bgp(bt, bgp, ctx)
    end

    # Fallback: materialise once, then per-row evaluation (same semantics as before,
    # but pays the BT→solutions conversion only once instead of once per input row).
    input_sols = _bt_to_solutions(bt)
    results    = _SpSolution[]
    for μ in input_sols
        extended = _sp_eval_pattern(opt_pat, ctx, _SpSolution[μ])
        if isempty(extended)
            push!(results, μ)
        else
            append!(results, extended)
        end
    end
    _solutions_to_bt(results)
end

# Return a SpBGP (possibly merged from several SpBGPs inside a flat SpGroup) if
# opt_pat contains only plain BGP triples and nothing else — no SpFilter, SpBind,
# SpOptional, SpUnion, etc.  Returns nothing if any non-BGP element is found.
function _bt_extract_plain_bgp(opt_pat::SpPat)::Union{SpBGP, Nothing}
    opt_pat isa SpBGP && return opt_pat
    opt_pat isa SpGroup || return nothing
    triples = SpTriple[]
    for elem in opt_pat.elements
        elem isa SpBGP  && (append!(triples, elem.triples); continue)
        return nothing  # filter, bind, nested optional, etc.
    end
    SpBGP(triples)
end

# Apply a BIND element inside a BT-native group, adding (or replacing) one column.
# Building a per-row _SpSolution is cheaper than flushing the whole BT to solutions
# and re-packing: O(n) Dict allocs vs the 2× O(n) round-trip.
function _bt_apply_bind(bt::_BT, bind::SpBind, ctx::_SpEvalCtx)::_BT
    n = _bt_nrows(bt)
    n == 0 && return bt

    vname   = bind.var.name
    nv      = _bt_ncols(bt)
    new_col = Vector{UInt32}(undef, n)
    empty_sols = _SpSolution[]  # sols arg only needed for EXISTS/aggregates

    # Reuse a single solution Dict across all rows (empty! avoids n fresh Dict allocs).
    μ = sizehint!(_SpSolution(), nv)

    for row in 1:n
        empty!(μ)
        for i in 1:nv
            id = @inbounds bt.cols[i][row]
            id != 0 && (μ[@inbounds bt.vars[i]] = _resolve(id))
        end
        val = try
            _sp_eval_expr(bind.expr, ctx, μ, empty_sols)
        catch
            nothing
        end
        @inbounds new_col[row] = val === nothing ? UInt32(0) : _intern!(val)
    end

    existing = get(bt.var_idx, vname, 0)
    if existing != 0
        # Variable already present — overwrite its column in place.
        new_cols          = copy(bt.cols)
        new_cols[existing] = new_col
        return _BT(bt.vars, bt.var_idx, new_cols, n)
    else
        new_vars = vcat(bt.vars, [vname])
        new_idx  = copy(bt.var_idx);  new_idx[vname] = nv + 1
        new_cols = vcat(bt.cols, [new_col])
        return _BT(new_vars, new_idx, new_cols, n)
    end
end

# Collect the set of variable names referenced in an expression tree.
# Used by _bt_apply_filter to only resolve the variables actually needed.
# Returns false if the expression contains an EXISTS or NOT EXISTS sub-expression.
# These implicitly read *all* outer bound variables, so we cannot restrict resolution.
function _sp_expr_no_exists(expr::SpExpr)::Bool
    (expr isa SpExists || expr isa SpNotExists) && return false
    expr isa SpVar || expr isa SpConst || expr isa SpLiteral ||
    expr isa SpIRI || expr isa SpBNode || expr isa SpAnonBNode && return true
    expr isa SpUnary   && return _sp_expr_no_exists(expr.arg)
    expr isa SpBinary  && return _sp_expr_no_exists(expr.left) && _sp_expr_no_exists(expr.right)
    (expr isa SpCall || expr isa SpCoalesce) && return all(_sp_expr_no_exists, expr.args)
    expr isa SpIn      && return _sp_expr_no_exists(expr.expr) && all(_sp_expr_no_exists, expr.list)
    expr isa SpIf      && return _sp_expr_no_exists(expr.cond) && _sp_expr_no_exists(expr.then_) && _sp_expr_no_exists(expr.else_)
    expr isa SpAggregate && return expr.arg === nothing || _sp_expr_no_exists(expr.arg)
    expr isa SpTripleTerm && return _sp_expr_no_exists(expr.subject) &&
                                    _sp_expr_no_exists(expr.predicate) &&
                                    _sp_expr_no_exists(expr.object)
    true   # unknown node type — conservative
end

function _sp_expr_vars!(expr::SpExpr, out::Set{Symbol})
    if expr isa SpVar
        push!(out, expr.name)
    elseif expr isa SpConst || expr isa SpIRI || expr isa SpLiteral ||
           expr isa SpBNode  || expr isa SpAnonBNode
        nothing   # leaf with no variables
    elseif expr isa SpUnary
        _sp_expr_vars!(expr.arg, out)
    elseif expr isa SpBinary
        _sp_expr_vars!(expr.left, out);  _sp_expr_vars!(expr.right, out)
    elseif expr isa SpCall || expr isa SpCoalesce
        for a in expr.args; _sp_expr_vars!(a, out); end
    elseif expr isa SpIn
        _sp_expr_vars!(expr.expr, out)
        for a in expr.list; _sp_expr_vars!(a, out); end
    elseif expr isa SpIf
        _sp_expr_vars!(expr.cond, out);  _sp_expr_vars!(expr.then_, out);  _sp_expr_vars!(expr.else_, out)
    elseif expr isa SpAggregate
        expr.arg !== nothing && _sp_expr_vars!(expr.arg, out)
    elseif expr isa SpTripleTerm
        _sp_expr_vars!(expr.subject,   out)
        _sp_expr_vars!(expr.predicate, out)
        _sp_expr_vars!(expr.object,    out)
    end
    # SpExists / SpNotExists: handled by _sp_expr_no_exists guard in caller.
end

function _sp_expr_vars(expr::SpExpr)
    out = Set{Symbol}()
    _sp_expr_vars!(expr, out)
    out
end

# ── Constant folding for filter expressions ───────────────────────────────────
#
# Walk the expression tree and replace every variable-free sub-expression with a
# SpConst holding the pre-evaluated RDFTerm.  Called once per _bt_apply_filter
# invocation so that literals, IRIs, and composed constant sub-expressions are
# only evaluated once regardless of how many rows the BT contains.
#
# Returns the (possibly new) expression.  Non-evaluable sub-expressions (those
# containing variables, EXISTS, aggregates, or blank nodes that need scope) are
# returned unchanged.

function _sp_fold_constants(expr::SpExpr, ctx::_SpEvalCtx)::SpExpr
    # Already folded or a plain variable — nothing to do.
    expr isa SpConst && return expr
    expr isa SpVar   && return expr

    # Leaf constants: evaluate directly.
    if expr isa SpLiteral
        try
            term = if !isempty(expr.lang)
                Literal(expr.lexical, IRI(expr.datatype), expr.lang)
            else
                Literal(expr.lexical, IRI(expr.datatype), "")
            end
            return SpConst(term)
        catch
            return expr
        end
    end

    if expr isa SpIRI
        try
            iri_str = expr.value
            if ctx.base !== nothing && !occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", iri_str)
                iri_str = _sp_resolve_iri(ctx.base, iri_str)
            end
            return SpConst(IRI(iri_str))
        catch
            return expr
        end
    end

    # EXISTS / NOT EXISTS / blank nodes / aggregates cannot be pre-evaluated.
    (expr isa SpExists || expr isa SpNotExists ||
     expr isa SpBNode  || expr isa SpAnonBNode ||
     expr isa SpAggregate) && return expr

    # Recursive cases: fold children, then try to fold self if all children are now constants.
    if expr isa SpUnary
        child = _sp_fold_constants(expr.arg, ctx)
        child isa SpConst || return SpUnary(expr.op, child)
        try
            μ_empty = _SpSolution()
            v = _sp_eval_expr(SpUnary(expr.op, child), ctx, μ_empty, _SpSolution[])
            return SpConst(v)
        catch
            return SpUnary(expr.op, child)
        end

    elseif expr isa SpBinary
        l = _sp_fold_constants(expr.left, ctx)
        r = _sp_fold_constants(expr.right, ctx)
        if l isa SpConst && r isa SpConst
            try
                μ_empty = _SpSolution()
                v = _sp_eval_expr(SpBinary(expr.op, l, r), ctx, μ_empty, _SpSolution[])
                return SpConst(v)
            catch
                # e.g. type error in constant arithmetic — leave folded children
            end
        end
        return SpBinary(expr.op, l, r)

    elseif expr isa SpCall
        args = [_sp_fold_constants(a, ctx) for a in expr.args]
        if all(a -> a isa SpConst, args)
            try
                μ_empty = _SpSolution()
                v = _sp_eval_expr(SpCall(expr.func, args), ctx, μ_empty, _SpSolution[])
                return SpConst(v)
            catch end
        end
        return SpCall(expr.func, args)

    elseif expr isa SpIf
        cond  = _sp_fold_constants(expr.cond,  ctx)
        then_ = _sp_fold_constants(expr.then_, ctx)
        else_ = _sp_fold_constants(expr.else_, ctx)
        if cond isa SpConst && then_ isa SpConst && else_ isa SpConst
            try
                μ_empty = _SpSolution()
                v = _sp_eval_expr(SpIf(cond, then_, else_), ctx, μ_empty, _SpSolution[])
                return SpConst(v)
            catch end
        end
        return SpIf(cond, then_, else_)

    elseif expr isa SpCoalesce
        args = [_sp_fold_constants(a, ctx) for a in expr.args]
        if all(a -> a isa SpConst, args)
            try
                μ_empty = _SpSolution()
                v = _sp_eval_expr(SpCoalesce(args), ctx, μ_empty, _SpSolution[])
                return SpConst(v)
            catch end
        end
        return SpCoalesce(args)

    elseif expr isa SpIn
        inner = _sp_fold_constants(expr.expr, ctx)
        list  = [_sp_fold_constants(a, ctx) for a in expr.list]
        return SpIn(inner, list, expr.negated)
    end

    # Fallback: return unchanged (unknown expression type).
    expr
end

# ── Simple numeric comparison helpers (fast path for FILTER) ─────────────────

# Returns true if expr is a simple numeric comparison: SpVar OP SpConst(numeric Literal)
# or SpConst(numeric Literal) OP SpVar
function _is_simple_numeric_cmp(expr::SpExpr)
    expr isa SpBinary || return false
    expr.op in (:lt, :le, :gt, :ge, :eq) || return false
    lvar   = expr.left  isa SpVar
    rvar   = expr.right isa SpVar
    lconst = expr.left  isa SpConst && _sp_is_numeric_literal(expr.left.term)
    rconst = expr.right isa SpConst && _sp_is_numeric_literal(expr.right.term)
    (lvar && rconst) || (rvar && lconst)
end

# Extract (var_name, op, const_float) from a simple numeric comparison
# Flips the operator when the variable is on the right side.
function _unpack_numeric_cmp(expr::SpBinary)
    if expr.left isa SpVar
        var = (expr.left::SpVar).name
        cv  = _sp_to_float((expr.right::SpConst).term::Literal)
        return (var, expr.op, cv)
    else
        var = (expr.right::SpVar).name
        cv  = _sp_to_float((expr.left::SpConst).term::Literal)
        flipped = expr.op === :lt ? :gt :
                  expr.op === :le ? :ge :
                  expr.op === :gt ? :lt :
                  expr.op === :ge ? :le : expr.op
        return (var, flipped, cv)
    end
end

# Apply a FILTER to a BT, retaining only rows where the expression evaluates to
# true.  Per SPARQL §17.2, errors and non-boolean values count as false (no row).
# Like _bt_apply_bind, we materialise one lightweight _SpSolution per row to
# drive _sp_eval_expr — but unlike _bt_to_solutions we never allocate the full
# output Dict and only copy columns for rows that actually pass the filter.
function _bt_apply_filter(bt::_BT, filt::SpFilter, ctx::_SpEvalCtx)::_BT
    n = _bt_nrows(bt)
    n == 0 && return bt
    nv = _bt_ncols(bt)

    # Pre-fold all constant sub-expressions in the filter once, before the loop.
    folded_expr = _sp_fold_constants(filt.expr, ctx)

    # ── Fast path: simple numeric comparison ?var OP const ──────────────────
    if _is_simple_numeric_cmp(folded_expr)
        var_name, op, cv = _unpack_numeric_cmp(folded_expr::SpBinary)
        col_idx = get(bt.var_idx, var_name, 0)
        if col_idx != 0 && !isnan(cv)
            id_col = bt.cols[col_idx]
            out_result = @no_escape begin
                # Allocate scratch row-index buffer in bump allocator
                keep_idx = @alloc(Int, n)
                out_count = 0
                @inbounds for row in 1:n
                    id = id_col[row]
                    fv = id == 0 ? NaN : _numeric_float(id)
                    passes = if op === :lt;  fv <  cv
                             elseif op === :le; fv <= cv
                             elseif op === :gt; fv >  cv
                             elseif op === :ge; fv >= cv
                             else              fv == cv
                             end
                    if passes
                        out_count += 1
                        keep_idx[out_count] = row
                    end
                end
                # Copy surviving rows to heap
                out_cs = [Vector{UInt32}(undef, out_count) for _ in 1:nv]
                for j in 1:out_count
                    r = keep_idx[j]
                    for i in 1:nv
                        @inbounds out_cs[i][j] = bt.cols[i][r]
                    end
                end
                (out_cs, out_count)
            end
            out_cols, out_nrows = out_result
            return _BT(bt.vars, bt.var_idx, out_cols, out_nrows)
        end
    end

    # ── General path ─────────────────────────────────────────────────────────
    # Determine which columns are actually referenced by the filter.
    needed_cols = if _sp_expr_no_exists(folded_expr)
        needed_vars = _sp_expr_vars(folded_expr)
        [(bt.var_idx[v], v) for v in needed_vars if haskey(bt.var_idx, v)]
    else
        [(i, bt.vars[i]) for i in 1:nv]
    end

    empty_sols = _SpSolution[]
    μ = sizehint!(_SpSolution(), length(needed_cols))

    # Use Bumper for scratch row-index storage, copy survivors to heap at end
    gen_result = @no_escape begin
        keep_idx = @alloc(Int, n)
        out_count = 0

        for row in 1:n
            empty!(μ)
            for (ci, v) in needed_cols
                id = @inbounds bt.cols[ci][row]
                id != 0 && (μ[v] = _resolve(id))
            end
            if _sp_filter_passes(folded_expr, ctx, μ, empty_sols)
                out_count += 1
                @inbounds keep_idx[out_count] = row
            end
        end

        # Copy surviving rows to heap-allocated final columns
        out_cs = [Vector{UInt32}(undef, out_count) for _ in 1:nv]
        for j in 1:out_count
            r = @inbounds keep_idx[j]
            for i in 1:nv
                @inbounds out_cs[i][j] = bt.cols[i][r]
            end
        end
        (out_cs, out_count)
    end
    out_cols, out_nrows = gen_result
    _BT(bt.vars, bt.var_idx, out_cols, out_nrows)
end

# ── Term materialisation (AST node → RDFTerm) ─────────────────────────────────

# Convert a SpExpr (that is a "constant" term, not variable) to an RDFTerm.
# Returns nothing if cannot be resolved.
function _sp_term_to_rdf(node::SpExpr, ctx::_SpEvalCtx, μ::_SpSolution)::Union{RDFTerm, Nothing}
    if node isa SpVar
        get(μ, node.name, nothing)
    elseif node isa SpIRI
        iri_str = node.value
        if ctx.base !== nothing && !occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", iri_str)
            iri_str = _sp_resolve_iri(ctx.base, iri_str)
        end
        IRI(iri_str)
    elseif node isa SpLiteral
        try
            if !isempty(node.lang)
                Literal(node.lexical, IRI(node.datatype), node.lang)
            else
                Literal(node.lexical, IRI(node.datatype), "")
            end
        catch
            nothing
        end
    elseif node isa SpBNode
        # Blank nodes in query patterns are scoped per basic graph pattern
        get!(ctx.blank_node_scope, node.label, _mint_blank_node())
    elseif node isa SpAnonBNode
        # Look up any existing binding for this anonymous blank node
        sym = Symbol("_sp_anon_", node.id)
        get(μ, sym, nothing)
    else
        nothing
    end
end

# ── Expression evaluation ─────────────────────────────────────────────────────

# Evaluate a SpExpr in the context of a solution.
# Returns an RDFTerm on success, throws an exception on error.
function _sp_eval_expr(expr::SpExpr, ctx::_SpEvalCtx, μ::_SpSolution, sols::Vector{_SpSolution})::RDFTerm
    if expr isa SpConst
        return expr.term   # pre-folded constant — zero allocation

    elseif expr isa SpVar
        haskey(μ, expr.name) || error("Unbound variable: ?$(expr.name)")
        return μ[expr.name]

    elseif expr isa SpIRI
        iri_str = expr.value
        if ctx.base !== nothing && !occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", iri_str)
            iri_str = _sp_resolve_iri(ctx.base, iri_str)
        end
        return IRI(iri_str)

    elseif expr isa SpLiteral
        if !isempty(expr.lang)
            return Literal(expr.lexical, IRI(expr.datatype), expr.lang)
        else
            return Literal(expr.lexical, IRI(expr.datatype), "")
        end

    elseif expr isa SpBNode
        return get!(ctx.blank_node_scope, expr.label, _mint_blank_node())

    elseif expr isa SpAnonBNode
        return _mint_blank_node()

    elseif expr isa SpUnary
        arg = _sp_eval_expr(expr.arg, ctx, μ, sols)
        if expr.op === :not
            b = _sp_to_bool(arg)
            return _sp_bool_literal(!b)
        elseif expr.op === :neg
            arg isa Literal || error("Unary minus requires a numeric literal")
            return _sp_numeric_neg(arg::Literal)
        else   # :pos
            return arg
        end

    elseif expr isa SpBinary
        return _sp_eval_binary(expr, ctx, μ, sols)

    elseif expr isa SpCall
        return _sp_eval_call(expr, ctx, μ, sols)

    elseif expr isa SpAggregate
        error("Aggregate function outside aggregation context")

    elseif expr isa SpExists
        # Inject outer bindings into EXISTS pattern evaluation (SPARQL 1.1 spec: EXISTS uses μ)
        sols_inner = _sp_eval_pattern(expr.pattern, ctx, [copy(μ)])
        return _sp_bool_literal(!isempty(sols_inner))

    elseif expr isa SpNotExists
        # Inject outer bindings into NOT EXISTS pattern evaluation
        sols_inner = _sp_eval_pattern(expr.pattern, ctx, [copy(μ)])
        return _sp_bool_literal(isempty(sols_inner))

    elseif expr isa SpIn
        v = _sp_eval_expr(expr.expr, ctx, μ, sols)
        for item in expr.list
            val = try _sp_eval_expr(item, ctx, μ, sols) catch; continue end
            _sp_value_equal(v, val) && return _sp_bool_literal(!expr.negated)
        end
        return _sp_bool_literal(expr.negated)

    elseif expr isa SpIf
        # SPARQL spec: errors in the condition propagate (do not fall through to else)
        cond = _sp_eval_expr(expr.cond, ctx, μ, sols)
        b = _sp_to_bool(cond)
        return b ? _sp_eval_expr(expr.then_, ctx, μ, sols) : _sp_eval_expr(expr.else_, ctx, μ, sols)

    elseif expr isa SpCoalesce
        for arg in expr.args
            v = try _sp_eval_expr(arg, ctx, μ, sols) catch; continue end
            return v
        end
        error("COALESCE: all arguments errored or unbound")

    else
        error("Unknown expression type: $(typeof(expr))")
    end
end

function _sp_eval_binary(expr::SpBinary, ctx::_SpEvalCtx, μ::_SpSolution, sols::Vector{_SpSolution})::RDFTerm
    op = expr.op

    # Short-circuit operators
    if op === :and
        l = try _sp_to_bool(_sp_eval_expr(expr.left, ctx, μ, sols)) catch; return _sp_bool_literal(false) end
        !l && return _sp_bool_literal(false)
        r = try _sp_to_bool(_sp_eval_expr(expr.right, ctx, μ, sols)) catch; return _sp_bool_literal(false) end
        return _sp_bool_literal(r)
    elseif op === :or
        l_val = try _sp_eval_expr(expr.left, ctx, μ, sols) catch nothing end
        l = l_val !== nothing ? (try _sp_to_bool(l_val) catch; false end) : false
        l && return _sp_bool_literal(true)
        r_val = try _sp_eval_expr(expr.right, ctx, μ, sols) catch nothing end
        r = r_val !== nothing ? (try _sp_to_bool(r_val) catch; false end) : false
        l_val === nothing && r_val === nothing && error("Both operands of || errored")
        return _sp_bool_literal(r)
    end

    left  = _sp_eval_expr(expr.left,  ctx, μ, sols)
    right = _sp_eval_expr(expr.right, ctx, μ, sols)

    if op === :add
        (left isa Literal && right isa Literal && _sp_is_numeric(left.datatype.value) && _sp_is_numeric(right.datatype.value)) ||
            error("+ requires numeric operands")
        return _sp_numeric_add(left::Literal, right::Literal)
    elseif op === :sub
        (left isa Literal && right isa Literal && _sp_is_numeric(left.datatype.value) && _sp_is_numeric(right.datatype.value)) ||
            error("- requires numeric operands")
        return _sp_numeric_sub(left::Literal, right::Literal)
    elseif op === :mul
        (left isa Literal && right isa Literal && _sp_is_numeric(left.datatype.value) && _sp_is_numeric(right.datatype.value)) ||
            error("* requires numeric operands")
        return _sp_numeric_mul(left::Literal, right::Literal)
    elseif op === :div
        (left isa Literal && right isa Literal && _sp_is_numeric(left.datatype.value) && _sp_is_numeric(right.datatype.value)) ||
            error("/ requires numeric operands")
        return _sp_numeric_div(left::Literal, right::Literal)
    elseif op === :eq
        result = try _sp_value_equal(left, right) catch; return _sp_bool_literal(false) end
        return _sp_bool_literal(result)
    elseif op === :neq
        result = try _sp_value_equal(left, right) catch; return _sp_bool_literal(true) end
        return _sp_bool_literal(!result)
    elseif op === :lt
        return _sp_bool_literal(_sp_compare(left, right) < 0)
    elseif op === :le
        return _sp_bool_literal(_sp_compare(left, right) <= 0)
    elseif op === :gt
        return _sp_bool_literal(_sp_compare(left, right) > 0)
    elseif op === :ge
        return _sp_bool_literal(_sp_compare(left, right) >= 0)
    else
        error("Unknown binary operator: $op")
    end
end

function _sp_eval_call(expr::SpCall, ctx::_SpEvalCtx, μ::_SpSolution, sols::Vector{_SpSolution})::RDFTerm
    fname = expr.func

    # Special forms handled here
    if fname == "bound"
        length(expr.args) == 1 || error("BOUND takes 1 variable argument")
        arg = expr.args[1]
        arg isa SpVar || error("BOUND requires a variable")
        return _sp_bool_literal(haskey(μ, arg.name))
    end

    # Evaluate all arguments
    args = RDFTerm[]
    for a in expr.args
        push!(args, _sp_eval_expr(a, ctx, μ, sols))
    end

    _sp_call_builtin(fname, args, ctx.base, ctx.bnode_solution_scope)
end

# ── BGP evaluation ────────────────────────────────────────────────────────────

# Two-phase triple binding (used by property-path evaluation and other callers):
#   Phase 1 — _sp_compat_term: pure compatibility check, zero allocations.
#   Phase 2 — _sp_new_binding!: write new bindings into an already-copied solution.
#
# This replaces the old eager copy-then-check pattern so we only allocate
# when the triple is actually compatible with the current solution.

@inline function _sp_compat_term(pattern::SpExpr, val::RDFTerm, μ::_SpSolution)::Bool
    if pattern isa SpVar
        existing = get(μ, pattern.name, nothing)
        return existing === nothing || existing == val
    elseif pattern isa SpIRI
        # Compare string values directly — avoids allocating a new IRI wrapper.
        val isa IRI || return false
        return (val::IRI).value == pattern.value
    elseif pattern isa SpLiteral
        # Compare fields directly — avoids allocating IRI + Literal objects.
        val isa Literal || return false
        lit = val::Literal
        return lit.lexical_form == pattern.lexical &&
               lit.datatype.value == pattern.datatype &&
               lit.language_tag == pattern.lang
    elseif pattern isa SpBNode
        sym = Symbol("_sp_bnode_", pattern.label)
        existing = get(μ, sym, nothing)
        return existing === nothing ? val isa BlankNode : existing == val
    elseif pattern isa SpAnonBNode
        sym = Symbol("_sp_anon_", pattern.id)
        existing = get(μ, sym, nothing)
        return existing === nothing || existing == val
    elseif pattern isa SpTripleTerm
        val isa TripleTerm || return false
        tt = val::TripleTerm
        _sp_compat_term(pattern.subject,   tt.subject,   μ) || return false
        _sp_compat_term(pattern.predicate, tt.predicate, μ) || return false
        _sp_compat_term(pattern.object,    tt.object,    μ) || return false
        return true
    else
        return false
    end
end

@inline function _sp_new_binding!(pattern::SpExpr, val::RDFTerm, μ::_SpSolution)
    if pattern isa SpVar
        haskey(μ, pattern.name) || (μ[pattern.name] = val)
    elseif pattern isa SpBNode
        sym = Symbol("_sp_bnode_", pattern.label)
        haskey(μ, sym) || (μ[sym] = val)
    elseif pattern isa SpAnonBNode
        sym = Symbol("_sp_anon_", pattern.id)
        haskey(μ, sym) || (μ[sym] = val)
    elseif pattern isa SpTripleTerm
        # Recurse into the embedded triple term to bind inner variables
        val isa TripleTerm || return
        tt = val::TripleTerm
        _sp_new_binding!(pattern.subject,   tt.subject,   μ)
        _sp_new_binding!(pattern.predicate, tt.predicate, μ)
        _sp_new_binding!(pattern.object,    tt.object,    μ)
    end
    # SpIRI and SpLiteral are constants — no binding to set
end

# Given a triple pattern and a matching triple, produce the extended solution or nothing on conflict.
function _sp_bind_triple(tp::SpTriple, triple::Triple, μ::_SpSolution)::Union{_SpSolution, Nothing}
    # Phase 1: check compatibility without any allocation
    _sp_compat_term(tp.subject, triple.subject, μ) || return nothing
    if tp.predicate isa SpExpr
        _sp_compat_term(tp.predicate::SpExpr, triple.predicate, μ) || return nothing
    end
    _sp_compat_term(tp.object, triple.object, μ) || return nothing
    # Phase 2: copy once on success, then write new bindings
    μ2 = copy(μ)
    _sp_new_binding!(tp.subject,   triple.subject,   μ2)
    tp.predicate isa SpExpr && _sp_new_binding!(tp.predicate::SpExpr, triple.predicate, μ2)
    _sp_new_binding!(tp.object,    triple.object,    μ2)
    μ2
end

# _sp_bind_term: mutating single-term binding used by property-path evaluation
# (called on a pre-copied solution, so alloc-on-first-bind is acceptable there).
function _sp_bind_term(pattern::SpExpr, val::RDFTerm, μ::_SpSolution)::Bool
    if pattern isa SpVar
        name = pattern.name
        if haskey(μ, name)
            return μ[name] == val
        else
            μ[name] = val
            return true
        end
    elseif pattern isa SpIRI
        # Compare string values directly — avoids allocating a new IRI wrapper.
        val isa IRI || return false
        return (val::IRI).value == pattern.value
    elseif pattern isa SpLiteral
        # Compare fields directly — avoids allocating IRI + Literal objects.
        val isa Literal || return false
        lit = val::Literal
        return lit.lexical_form == pattern.lexical &&
               lit.datatype.value == pattern.datatype &&
               lit.language_tag == pattern.lang
    elseif pattern isa SpBNode
        name = "_sp_bnode_" * pattern.label
        sym = Symbol(name)
        if haskey(μ, sym)
            return μ[sym] == val
        else
            val isa BlankNode || return false
            μ[sym] = val
            return true
        end
    elseif pattern isa SpAnonBNode
        sym = Symbol("_sp_anon_", pattern.id)
        if haskey(μ, sym)
            return μ[sym] == val
        else
            μ[sym] = val
            return true
        end
    elseif pattern isa SpTripleTerm
        val isa TripleTerm || return false
        tt = val::TripleTerm
        _sp_bind_term(pattern.subject,   tt.subject,   μ) || return false
        _sp_bind_term(pattern.predicate, tt.predicate, μ) || return false
        _sp_bind_term(pattern.object,    tt.object,    μ) || return false
        return true
    else
        return false
    end
end

# Resolve a SpExpr to an RDFTerm (or nothing if it's an unbound var)
function _sp_resolve_tp_term(expr::SpExpr, ctx::_SpEvalCtx, μ::_SpSolution)::Union{RDFTerm, Nothing}
    if expr isa SpVar
        get(μ, expr.name, nothing)
    elseif expr isa SpIRI
        iri_str = expr.value
        if ctx.base !== nothing && !occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", iri_str)
            iri_str = _sp_resolve_iri(ctx.base, iri_str)
        end
        IRI(iri_str)
    elseif expr isa SpLiteral
        try
            !isempty(expr.lang) ?
                Literal(expr.lexical, IRI(expr.datatype), expr.lang) :
                Literal(expr.lexical, IRI(expr.datatype), "")
        catch
            nothing
        end
    elseif expr isa SpBNode
        get(ctx.blank_node_scope, expr.label, nothing)
    elseif expr isa SpAnonBNode
        # Look up the anonymous blank node binding already established in this solution
        sym = Symbol("_sp_anon_", expr.id)
        get(μ, sym, nothing)
    elseif expr isa SpTripleTerm
        s_term = _sp_resolve_tp_term(expr.subject,   ctx, μ)
        p_term = _sp_resolve_tp_term(expr.predicate, ctx, μ)
        o_term = _sp_resolve_tp_term(expr.object,    ctx, μ)
        (s_term === nothing || p_term === nothing || o_term === nothing) && return nothing
        p_term isa IRI       || return nothing
        s_term isa SubjectTerm || return nothing
        try TripleTerm(s_term, p_term::IRI, o_term) catch; nothing end
    else
        nothing
    end
end

# ── RDF-star triple-term helpers ──────────────────────────────────────────────

# Returns true when an expression is (or contains) an SpTripleTerm that has at
# least one inner variable — meaning we cannot treat it as a static hexastore key
# and must fall back to per-row matching.
function _expr_has_tt_vars(expr::SpExpr)::Bool
    expr isa SpVar       && return false   # just a variable, not a TripleTerm
    expr isa SpTripleTerm && return (
        _expr_has_tt_vars_inner(expr.subject)   ||
        _expr_has_tt_vars_inner(expr.predicate) ||
        _expr_has_tt_vars_inner(expr.object))
    false
end

function _expr_has_tt_vars_inner(expr::SpExpr)::Bool
    expr isa SpVar        && return true
    expr isa SpBNode      && return true
    expr isa SpAnonBNode  && return true
    expr isa SpTripleTerm && return (
        _expr_has_tt_vars_inner(expr.subject)   ||
        _expr_has_tt_vars_inner(expr.predicate) ||
        _expr_has_tt_vars_inner(expr.object))
    false
end

# Returns true when a triple pattern requires per-row TripleTerm matching
# (i.e., subject or object is an SpTripleTerm with inner variables).
@inline function _tp_needs_tt_matching(tp::SpTriple)::Bool
    _expr_has_tt_vars(tp.subject) || _expr_has_tt_vars(tp.object)
end

# Evaluate a single triple pattern per-row.  Used when the subject or object is
# an SpTripleTerm with inner variables that the columnar BT path cannot handle.
function _sp_eval_tp_row(tp::SpTriple, ctx::_SpEvalCtx, μ::_SpSolution)::Vector{_SpSolution}
    # Resolve constants for the hexastore filter; leave wildcards as nothing.
    s_filter = begin
        t = _sp_resolve_tp_term(tp.subject, ctx, μ)
        t isa SubjectTerm ? t : nothing
    end
    p_filter = if tp.predicate isa SpPathA
        IRI(_SP_RDF_TYPE)
    elseif tp.predicate isa SpPathIRI
        IRI((tp.predicate::SpPathIRI).value)
    elseif tp.predicate isa SpExpr
        t = _sp_resolve_tp_term(tp.predicate::SpExpr, ctx, μ)
        t isa IRI ? t : nothing
    else
        nothing
    end
    o_filter = begin
        t = _sp_resolve_tp_term(tp.object, ctx, μ)
        t isa ObjectTerm ? t : nothing
    end

    results = _SpSolution[]
    for triple in match(ctx.active_graph;
                        subject   = s_filter,
                        predicate = p_filter,
                        object    = o_filter)
        μ2 = _sp_bind_triple(tp, triple, μ)
        μ2 !== nothing && push!(results, μ2)
    end
    results
end

# ── BGP join-order optimization ───────────────────────────────────────────────
#
# BGP join is commutative, so triple patterns can be evaluated in any order
# without changing the result multiset.  Order matters enormously for cost:
# evaluating an unselective pattern first materialises a huge intermediate
# table, and evaluating two patterns that share no variables back-to-back
# produces a Cartesian product.
#
# The hexastore gives the *exact* cardinality of any constant-bound pattern in
# O(log n) (_count_ids), so no statistics are needed.  _sp_reorder_bgp runs a
# greedy selection: repeatedly pick the cheapest remaining pattern, preferring
# patterns connected (by a shared variable) to the already-bound variable set.

# Variables of a triple pattern (subject/object SpVar, SpBNode, SpAnonBNode,
# plus a variable predicate).  Inner variables of RDF-star triple terms are
# ignored — conservative for connectivity, and such patterns are ranked as
# uncountable anyway.
function _sp_tp_vars(tp::SpTriple)::Vector{Symbol}
    vars = Symbol[]
    sv = _bt_var_sym(tp.subject)
    sv !== nothing && push!(vars, sv)
    pv = _bt_pred_var_sym(tp.predicate)
    pv !== nothing && !(pv in vars) && push!(vars, pv)
    ov = _bt_var_sym(tp.object)
    ov !== nothing && !(ov in vars) && push!(vars, ov)
    vars
end

# Estimated evaluation cost of one triple pattern: the exact hexastore count
# over its constant positions, discounted ×1/16 for each variable position
# already bound (a bound variable restricts the match like a constant, but its
# value isn't known here, so a fixed discount is applied).  Complex property
# paths and triple-term patterns can't be counted; they are ranked as
# more-expensive-than-anything-countable so they run last, when the most
# variables are bound.
function _sp_tp_cost(tp::SpTriple, ctx::_SpEvalCtx, bound::Set{Symbol})::Float64
    g = ctx.active_graph
    base = if _bt_is_complex_path(tp.predicate) || _tp_needs_tt_matching(tp)
        Float64(length(g)) * 16.0^3 + 1.0   # never beats a countable pattern
    else
        s_is_c, s_cid = _bt_const_id(tp.subject, ctx)
        p_is_c, p_cid = _bt_pred_const_id(tp.predicate, ctx)
        o_is_c, o_cid = _bt_const_id(tp.object, ctx)
        # A constant absent from the registry means zero matches — cheapest
        # possible pattern (it empties the table immediately).
        ((s_is_c && s_cid == 0) || (p_is_c && p_cid == 0) || (o_is_c && o_cid == 0)) &&
            return 0.0
        Float64(_count_ids(g, s_is_c ? s_cid : nothing,
                              p_is_c ? p_cid : nothing,
                              o_is_c ? o_cid : nothing))
    end
    discount = 1.0
    for v in _sp_tp_vars(tp)
        v in bound && (discount *= 16.0)
    end
    base / discount
end

# Greedy join-order selection.  Returns a permutation of `triples`; `bound` is
# the set of variables already bound before the BGP runs (e.g. by the input
# solutions or an enclosing pattern).  Stable: ties keep source order.
function _sp_reorder_bgp(triples::Vector{SpTriple}, ctx::_SpEvalCtx,
                         bound::Set{Symbol})::Vector{SpTriple}
    length(triples) <= 1 && return triples
    bound     = copy(bound)
    tvars     = [_sp_tp_vars(tp) for tp in triples]
    remaining = collect(1:length(triples))
    out       = Vector{SpTriple}(undef, 0)
    sizehint!(out, length(triples))
    while !isempty(remaining)
        best_pos  = 1
        best_key  = (typemax(Int), Inf)
        for (pos, j) in enumerate(remaining)
            # connected = shares a bound variable, or has no variables at all
            connected = isempty(tvars[j]) || any(v -> v in bound, tvars[j])
            key = (connected ? 0 : 1, _sp_tp_cost(triples[j], ctx, bound))
            if key < best_key
                best_key = key
                best_pos = pos
            end
        end
        j = remaining[best_pos]
        deleteat!(remaining, best_pos)
        push!(out, triples[j])
        union!(bound, tvars[j])
    end
    out
end

# Evaluate a BGP against the active graph using a columnar BindingTable.
#
# Solutions are stored column-wise as parallel Vector{UInt32} arrays during
# the join loop, eliminating per-row Dict copy allocations.  Property-path
# triples and RDF-star triple-term patterns with inner variables fall back to
# per-solution evaluation.
function _sp_eval_bgp(bgp::SpBGP, ctx::_SpEvalCtx, input::Vector{_SpSolution})::Vector{_SpSolution}
    bt = _solutions_to_bt(input)

    for tp in _sp_reorder_bgp(bgp.triples, ctx, Set(bt.vars))
        _bt_nrows(bt) == 0 && break

        if _bt_is_complex_path(tp.predicate)
            # Complex property path (*, +, ?, |, /, !): materialise, evaluate
            # per-solution via _sp_eval_path_pattern, then re-pack into BT.
            sols = _bt_to_solutions(bt)
            next = _SpSolution[]
            for μ in sols
                append!(next, _sp_eval_path_pattern(
                    tp.subject, tp.predicate::SpPath, tp.object, ctx, μ))
            end
            bt = _solutions_to_bt(next)
        elseif _tp_needs_tt_matching(tp)
            # SpTripleTerm with inner variables: per-row matching so we can
            # filter for TripleTerm terms and bind their inner variables.
            sols = _bt_to_solutions(bt)
            next = _SpSolution[]
            for μ in sols
                append!(next, _sp_eval_tp_row(tp, ctx, μ))
            end
            bt = _solutions_to_bt(next)
        else
            # Plain IRI / SpPathIRI / SpPathA / SpVar predicate — use BT fast path.
            bt = _bt_extend_tp(bt, tp, ctx)
        end
    end

    _bt_to_solutions(bt)
end

# ── SERVICE evaluation (SPARQL 1.1 Federated Query) ───────────────────────────
#
# The inner pattern is rendered back to SPARQL text (all IRIs absolute, no
# prologue needed), wrapped in `SELECT * WHERE { … }`, and sent to the remote
# endpoint through the _remote_sparql transport hook (installed by the
# RDFHTTPExt extension when HTTP.jl is loaded).  The returned solutions are
# joined with the current solutions on their shared variables.
#
# SERVICE SILENT: any failure (no transport, network error, non-SELECT result,
# variable endpoint) degrades to the join identity — input solutions pass
# through unchanged with the service variables left unbound.
function _sp_eval_service(svc::SpService, ctx::_SpEvalCtx,
                          input::Vector{_SpSolution})::Vector{_SpSolution}
    if !(svc.endpoint isa SpIRI)
        svc.silent && return input
        error("SERVICE with a variable endpoint is not supported; " *
              "use an explicit IRI (or SERVICE SILENT to tolerate it)")
    end
    endpoint = (svc.endpoint::SpIRI).value
    query    = "SELECT * WHERE " * _sp_render_pattern(svc.pattern)

    result = try
        _remote_sparql(endpoint, query)
    catch
        svc.silent && return input
        rethrow()
    end
    if !(result isa SolutionSet)
        svc.silent && return input
        error("SERVICE endpoint <$endpoint> returned $(typeof(result)); " *
              "expected SELECT solutions")
    end

    remote = _SpSolution[]
    sizehint!(remote, length(result))
    for row in result
        μ = _SpSolution()
        for v in (result::SolutionSet).variables
            t = row[v]
            t === nothing || (μ[v] = t)
        end
        push!(remote, μ)
    end

    out = _SpSolution[]
    for μ1 in input, μ2 in remote
        _sp_compatible(μ1, μ2) && push!(out, _sp_merge_sol(μ1, μ2))
    end
    out
end

# ── Property path evaluation ──────────────────────────────────────────────────

# LRU cache: maps (graph_objectid, predicate_iri_string) -> (SimpleDiGraph, id_to_vtx, vtx_to_id)
# Built once per predicate per graph instance, reused across BFS calls.
const _PATH_GRAPH_CACHE      = LRU{Tuple{UInt,String}, Tuple{SimpleDiGraph, Dict{UInt32,Int}, Vector{UInt32}}}(maxsize=256)
const _PATH_CACHE_LOCK        = ReentrantLock()   # LRUCache is not thread-safe

function _get_predicate_graph(ctx::_SpEvalCtx, iri::IRI)
    key = (objectid(ctx.active_graph), iri.value)

    # Fast check under lock — common case: already cached.
    cached = lock(_PATH_CACHE_LOCK) do
        get(_PATH_GRAPH_CACHE, key, nothing)
    end
    cached !== nothing && return cached

    # Cache miss: build the Graphs.jl adjacency structure outside the lock so
    # we don't stall other threads while iterating a potentially large graph.
    id_to_vtx = Dict{UInt32, Int}()
    vtx_to_id = UInt32[]

    for t in match(ctx.active_graph; predicate=iri)
        s_id = _intern!(t.subject)
        o_id = _intern!(t.object)
        if !haskey(id_to_vtx, s_id)
            push!(vtx_to_id, s_id)
            id_to_vtx[s_id] = length(vtx_to_id)
        end
        if !haskey(id_to_vtx, o_id)
            push!(vtx_to_id, o_id)
            id_to_vtx[o_id] = length(vtx_to_id)
        end
    end

    nv_g = length(vtx_to_id)
    g = SimpleDiGraph(nv_g)
    for t in match(ctx.active_graph; predicate=iri)
        s_id = get(id_to_vtx, _intern!(t.subject), 0)
        o_id = get(id_to_vtx, _intern!(t.object),  0)
        s_id != 0 && o_id != 0 && add_edge!(g, s_id, o_id)
    end
    entry = (g, id_to_vtx, vtx_to_id)

    # Store under lock — if another thread built the same entry concurrently,
    # the LRU simply overwrites it with the same value (idempotent).
    lock(_PATH_CACHE_LOCK) do
        _PATH_GRAPH_CACHE[key] = entry
    end
    entry
end

# BFS reachability on a SimpleDiGraph from src vertex; returns Set of reachable term IDs
function _graph_bfs_from(g::SimpleDiGraph, src::Int, vtx_to_id::Vector{UInt32},
                          include_src::Bool)::Set{RDFTerm}
    results = Set{RDFTerm}()
    nv_g = nv(g)
    nv_g == 0 && return results
    visited = falses(nv_g)
    visited[src] = true
    queue = Int[src]
    qi = 1
    while qi <= length(queue)
        u = queue[qi]; qi += 1
        for w in outneighbors(g, u)
            if !visited[w]
                visited[w] = true
                push!(queue, w)
                push!(results, _resolve(vtx_to_id[w]))
            end
        end
    end
    if include_src
        push!(results, _resolve(vtx_to_id[src]))
    end
    results
end

# BFS reachability in reverse (using inneighbors)
function _graph_bfs_reverse(g::SimpleDiGraph, src::Int, vtx_to_id::Vector{UInt32},
                             include_src::Bool)::Set{RDFTerm}
    results = Set{RDFTerm}()
    nv_g = nv(g)
    nv_g == 0 && return results
    visited = falses(nv_g)
    visited[src] = true
    queue = Int[src]
    qi = 1
    while qi <= length(queue)
        u = queue[qi]; qi += 1
        for w in inneighbors(g, u)
            if !visited[w]
                visited[w] = true
                push!(queue, w)
                push!(results, _resolve(vtx_to_id[w]))
            end
        end
    end
    if include_src
        push!(results, _resolve(vtx_to_id[src]))
    end
    results
end

function _sp_eval_path_pattern(s_expr::SpExpr, path::SpPath, o_expr::SpExpr,
                                 ctx::_SpEvalCtx, μ::_SpSolution)::Vector{_SpSolution}
    # Sequence paths use multiset join semantics: evaluate each side separately
    # and join, preserving duplicates from different intermediate nodes.
    if path isa SpPathSeq
        # Fresh internal variable for the intermediate node
        mid_sym = Symbol("_sp_ppv_$(objectid(path))")
        mid_expr = SpVar(mid_sym)
        left_results = _sp_eval_path_pattern(s_expr, path.left, mid_expr, ctx, μ)
        results = _SpSolution[]
        for μ2 in left_results
            for sol in _sp_eval_path_pattern(mid_expr, path.right, o_expr, ctx, μ2)
                # Strip the internal intermediate variable before returning
                clean = copy(sol)
                delete!(clean, mid_sym)
                push!(results, clean)
            end
        end
        return results
    end

    s = _sp_resolve_tp_term(s_expr, ctx, μ)
    o = _sp_resolve_tp_term(o_expr, ctx, μ)

    # Whether each expression is a query constant (IRI/literal/bnode literal in query text),
    # not a variable. Constants always participate in zero-length ZeroOrX paths even if they
    # are not present as terms in the graph (e.g., on empty datasets).
    s_is_const = !(s_expr isa SpVar)
    o_is_const = !(o_expr isa SpVar)

    # Get all (s, o) pairs reachable via path
    if s !== nothing
        # s is bound → enumerate reachable objects
        if o !== nothing
            # Both bound: check if there's a path from s to o
            reachable = _sp_path_reachable_to(s, path, ctx)
            # For ZeroOrX: if s is a query constant and equals o, that's a valid zero-length path
            if s == o && (path isa SpPathZeroOrMore || path isa SpPathZeroOrOne) && s_is_const
                return [copy(μ)]
            end
            if o in reachable
                return [copy(μ)]
            else
                return _SpSolution[]
            end
        else
            # s bound, o unbound → enumerate
            reachable = _sp_path_reachable_to(s, path, ctx)
            # For ZeroOrX: if s is a query constant, always include s itself (zero-length)
            if (path isa SpPathZeroOrMore || path isa SpPathZeroOrOne) && s_is_const
                push!(reachable, s)
            end
            results = _SpSolution[]
            for obj in reachable
                ext = copy(μ)
                _sp_bind_term(o_expr, obj, ext) && push!(results, ext)
            end
            return results
        end
    elseif o !== nothing
        # o bound, s unbound → enumerate reverse direction
        reachable = _sp_path_reachable_from(o, path, ctx)
        # For ZeroOrX: if o is a query constant, always include o itself (zero-length self-match)
        if (path isa SpPathZeroOrMore || path isa SpPathZeroOrOne) && o_is_const
            push!(reachable, o)
        end
        results = _SpSolution[]
        for subj in reachable
            ext = copy(μ)
            _sp_bind_term(s_expr, subj, ext) && push!(results, ext)
        end
        return results
    else
        # Both unbound: enumerate all pairs
        all_pairs = _sp_path_all_pairs(path, ctx)
        results = _SpSolution[]
        for (subj, obj) in all_pairs
            ext = copy(μ)
            if _sp_bind_term(s_expr, subj, ext) && _sp_bind_term(o_expr, obj, ext)
                push!(results, ext)
            end
        end
        return results
    end
end

# Returns the set of objects reachable from subject via path
function _sp_path_reachable_to(subj::RDFTerm, path::SpPath, ctx::_SpEvalCtx)::Set{RDFTerm}
    if path isa SpPathIRI
        iri = IRI(path.value)
        results = Set{RDFTerm}()
        subj isa SubjectTerm || return results
        for t in match(ctx.active_graph; subject=subj::SubjectTerm, predicate=iri)
            push!(results, t.object)
        end
        return results

    elseif path isa SpPathA
        iri = IRI(_SP_RDF_TYPE)
        results = Set{RDFTerm}()
        subj isa SubjectTerm || return results
        for t in match(ctx.active_graph; subject=subj::SubjectTerm, predicate=iri)
            push!(results, t.object)
        end
        return results

    elseif path isa SpPathSeq
        # seq: intermediate nodes
        intermediate = _sp_path_reachable_to(subj, path.left, ctx)
        results = Set{RDFTerm}()
        for mid in intermediate
            union!(results, _sp_path_reachable_to(mid, path.right, ctx))
        end
        return results

    elseif path isa SpPathAlt
        return union(_sp_path_reachable_to(subj, path.left, ctx),
                     _sp_path_reachable_to(subj, path.right, ctx))

    elseif path isa SpPathInverse
        # inverse: find subjects of which subj is the object
        return _sp_path_reachable_from(subj, path.child, ctx)

    elseif path isa SpPathZeroOrMore
        return _sp_path_closure(subj, path.child, ctx, true)

    elseif path isa SpPathOneOrMore
        return _sp_path_closure(subj, path.child, ctx, false)

    elseif path isa SpPathZeroOrOne
        # Only include the subject itself (zero-length) if it's a graph term
        results = _sp_is_graph_term(subj, ctx) ? Set{RDFTerm}([subj]) : Set{RDFTerm}()
        union!(results, _sp_path_reachable_to(subj, path.child, ctx))
        return results

    elseif path isa SpPathNeg
        # Negated Property Set: !(fwd_preds | ^inv_preds)
        # Forward elements block forward traversal; inverse elements block inverse traversal.
        # If NPS has forward elements → allow forward arcs (not in blocked).
        # If NPS has inverse elements → allow inverse arcs (not in blocked_inv).
        blocked = Set{IRI}()
        blocked_inv = Set{IRI}()
        has_forward = false
        has_inverse = false
        for el in path.elements
            if el isa SpPathIRI
                push!(blocked, IRI(el.value)); has_forward = true
            elseif el isa SpPathA
                push!(blocked, IRI(_SP_RDF_TYPE)); has_forward = true
            elseif el isa SpPathInverse && el.child isa SpPathIRI
                push!(blocked_inv, IRI((el.child::SpPathIRI).value)); has_inverse = true
            elseif el isa SpPathInverse && el.child isa SpPathA
                push!(blocked_inv, IRI(_SP_RDF_TYPE)); has_inverse = true
            end
        end
        results = Set{RDFTerm}()
        # Forward traversal: ?subj pred ?obj where pred ∉ blocked
        if has_forward && subj isa SubjectTerm
            for t in match(ctx.active_graph; subject=subj::SubjectTerm)
                t.predicate ∉ blocked && push!(results, t.object)
            end
        end
        # Inverse traversal: ?obj pred ?subj where pred ∉ blocked_inv
        # (i.e., find objects o such that (o, pred, subj) and pred ∉ blocked_inv)
        if has_inverse
            obj_term = subj isa ObjectTerm ? subj::ObjectTerm : nothing
            if obj_term !== nothing
                for t in match(ctx.active_graph; object=obj_term)
                    t.predicate ∉ blocked_inv && push!(results, t.subject)
                end
            end
        end
        return results

    elseif path isa SpPathRange
        # {n,m}: paths of length n through m
        results = Set{RDFTerm}()
        current = Set{RDFTerm}([subj])
        min_ = path.min_; max_ = path.max_ === nothing ? 100 : path.max_
        step = 0
        for i in 1:max_
            next = Set{RDFTerm}()
            for s in current
                union!(next, _sp_path_reachable_to(s, path.child, ctx))
            end
            step = i
            current = next
            step >= min_ && union!(results, current)
        end
        return results

    else
        return Set{RDFTerm}()
    end
end

# Returns subjects that can reach obj via path (for inverse path resolution)
function _sp_path_reachable_from(obj::RDFTerm, path::SpPath, ctx::_SpEvalCtx)::Set{RDFTerm}
    if path isa SpPathIRI
        iri = IRI(path.value)
        results = Set{RDFTerm}()
        obj isa ObjectTerm || return results
        for t in match(ctx.active_graph; predicate=iri, object=obj::ObjectTerm)
            push!(results, t.subject)
        end
        return results
    elseif path isa SpPathA
        iri = IRI(_SP_RDF_TYPE)
        results = Set{RDFTerm}()
        obj isa ObjectTerm || return results
        for t in match(ctx.active_graph; predicate=iri, object=obj::ObjectTerm)
            push!(results, t.subject)
        end
        return results
    elseif path isa SpPathInverse
        return _sp_path_reachable_to(obj, path.child, ctx)
    elseif path isa SpPathSeq
        # seq reverse: start from right, go left
        intermediate = _sp_path_reachable_from(obj, path.right, ctx)
        results = Set{RDFTerm}()
        for mid in intermediate
            union!(results, _sp_path_reachable_from(mid, path.left, ctx))
        end
        return results
    elseif path isa SpPathAlt
        return union(_sp_path_reachable_from(obj, path.left, ctx),
                     _sp_path_reachable_from(obj, path.right, ctx))
    elseif path isa SpPathZeroOrMore
        # Closure in reverse; zero-length includes obj only if it's a graph term
        visited = _sp_is_graph_term(obj, ctx) ? Set{RDFTerm}([obj]) : Set{RDFTerm}()
        frontier = Set{RDFTerm}([obj])
        while !isempty(frontier)
            next = Set{RDFTerm}()
            for o in frontier
                for s in _sp_path_reachable_from(o, path.child, ctx)
                    s ∉ visited && (push!(next, s); push!(visited, s))
                end
            end
            frontier = next
        end
        return visited
    elseif path isa SpPathOneOrMore
        first_set = _sp_path_reachable_from(obj, path.child, ctx)
        visited = copy(first_set)
        frontier = copy(first_set)
        while !isempty(frontier)
            next = Set{RDFTerm}()
            for o in frontier
                for s in _sp_path_reachable_from(o, path.child, ctx)
                    s ∉ visited && (push!(next, s); push!(visited, s))
                end
            end
            frontier = next
        end
        return visited
    elseif path isa SpPathZeroOrOne
        # Only include obj itself (zero-length) if it's a graph term
        results = _sp_is_graph_term(obj, ctx) ? Set{RDFTerm}([obj]) : Set{RDFTerm}()
        union!(results, _sp_path_reachable_from(obj, path.child, ctx))
        return results
    elseif path isa SpPathNeg
        # _sp_path_reachable_from(obj, !P): what subjects s can reach obj via !P?
        # Forward elements of P: find s with (s, pred, obj) and pred ∉ blocked
        # Inverse elements of P: find s (objects) with (obj, pred, s) and pred ∉ blocked_inv
        blocked = Set{IRI}(); blocked_inv = Set{IRI}()
        has_forward = false; has_inverse = false
        for el in path.elements
            if el isa SpPathIRI; push!(blocked, IRI(el.value)); has_forward = true
            elseif el isa SpPathA; push!(blocked, IRI(_SP_RDF_TYPE)); has_forward = true
            elseif el isa SpPathInverse && el.child isa SpPathIRI
                push!(blocked_inv, IRI((el.child::SpPathIRI).value)); has_inverse = true
            elseif el isa SpPathInverse && el.child isa SpPathA
                push!(blocked_inv, IRI(_SP_RDF_TYPE)); has_inverse = true
            end
        end
        results = Set{RDFTerm}()
        if has_forward
            obj_term = obj isa ObjectTerm ? obj::ObjectTerm : nothing
            if obj_term !== nothing
                for t in match(ctx.active_graph; object=obj_term)
                    t.predicate ∉ blocked && push!(results, t.subject)
                end
            end
        end
        if has_inverse && obj isa SubjectTerm
            for t in match(ctx.active_graph; subject=obj::SubjectTerm)
                t.predicate ∉ blocked_inv && push!(results, t.object)
            end
        end
        return results
    else
        return Set{RDFTerm}()
    end
end

# Check if a term appears as a subject or object in the active graph
function _sp_is_graph_term(t::RDFTerm, ctx::_SpEvalCtx)::Bool
    for triple in ctx.active_graph
        (triple.subject === t || triple.subject == t) && return true
        (triple.object  === t || triple.object  == t) && return true
    end
    false
end

# Closure (BFS) for * and + paths
# For ZeroOrMore (include_self=true), the subject is only included if it is
# a term in the graph (SPARQL spec: ZeroOrX paths don't match VALUES-only terms).
function _sp_path_closure(subj::RDFTerm, path::SpPath, ctx::_SpEvalCtx, include_self::Bool)::Set{RDFTerm}
    # Fast path: use cached Graphs.jl adjacency list for plain IRI paths
    if path isa SpPathIRI
        iri = IRI(path.value)
        g, id_to_vtx, vtx_to_id = _get_predicate_graph(ctx, iri)
        subj_id = get(_type_map(subj), subj, UInt32(0))
        if subj_id != 0
            src = get(id_to_vtx, subj_id, 0)
            if src != 0
                include_real = include_self && _sp_is_graph_term(subj, ctx)
                return _graph_bfs_from(g, src, vtx_to_id, include_real)
            end
        end
        return (include_self && _sp_is_graph_term(subj, ctx)) ? Set{RDFTerm}([subj]) : Set{RDFTerm}()
    end

    # General path: iterative BFS using recursive reachability
    visited = (include_self && _sp_is_graph_term(subj, ctx)) ? Set{RDFTerm}([subj]) : Set{RDFTerm}()
    frontier = Set{RDFTerm}([subj])
    while !isempty(frontier)
        next = Set{RDFTerm}()
        for s in frontier
            for o in _sp_path_reachable_to(s, path, ctx)
                o ∉ visited && (push!(next, o); push!(visited, o))
            end
        end
        frontier = next
    end
    visited
end

# Enumerate all (s, o) pairs for path (both variables unbound case)
function _sp_path_all_pairs(path::SpPath, ctx::_SpEvalCtx)::Vector{Tuple{RDFTerm, RDFTerm}}
    pairs = Tuple{RDFTerm, RDFTerm}[]
    # Collect all terms from the graph (subjects and objects)
    all_terms = Set{RDFTerm}()
    for triple in ctx.active_graph
        push!(all_terms, triple.subject)
        push!(all_terms, triple.object)
    end
    # For ZeroOrX paths we must start from every graph term (objects can be start nodes)
    start_terms = (path isa SpPathZeroOrMore || path isa SpPathZeroOrOne) ?
        all_terms : Set{RDFTerm}(t for t in all_terms if t isa SubjectTerm)
    for subj in start_terms
        for obj in _sp_path_reachable_to(subj, path, ctx)
            push!(pairs, (subj, obj))
        end
    end
    pairs
end

# ── Pattern evaluation ────────────────────────────────────────────────────────

function _sp_eval_pattern(pat::SpPat, ctx::_SpEvalCtx, input::Vector{_SpSolution})::Vector{_SpSolution}
    if pat isa SpBGP
        return _sp_eval_bgp(pat, ctx, input)

    elseif pat isa SpGroup
        # BT-native group evaluation: maintain a columnar BindingTable throughout,
        # converting to Vector{_SpSolution} only when an element type forces it.
        #
        # Handled natively (zero intermediate Dict materialisation):
        #   SpBGP     → _bt_extend_tp per triple (or path fallback)
        #   SpOptional → _bt_left_join
        #   SpBind    → _bt_apply_bind
        #   SpFilter  → collected, applied in one pass at the end
        #
        # Flush+process+re-pack (uncommon in typical queries):
        #   Nested SpGroup, SpValues, SpUnion, SpMinus, SpGraph, SpService, …
        filters = SpFilter[]
        bt      = _solutions_to_bt(input)

        for elem in pat.elements
            _bt_nrows(bt) == 0 && break

            if elem isa SpFilter
                push!(filters, elem)

            elseif elem isa SpBGP
                for tp in _sp_reorder_bgp((elem::SpBGP).triples, ctx, Set(bt.vars))
                    _bt_nrows(bt) == 0 && break
                    if _bt_is_complex_path(tp.predicate)
                        sols = _bt_to_solutions(bt)
                        next = _SpSolution[]
                        for μ in sols
                            append!(next, _sp_eval_path_pattern(
                                tp.subject, tp.predicate::SpPath, tp.object, ctx, μ))
                        end
                        bt = _solutions_to_bt(next)
                    else
                        bt = _bt_extend_tp(bt, tp, ctx)
                    end
                end

            elseif elem isa SpOptional
                bt = _bt_left_join(bt, (elem::SpOptional).pattern, ctx)

            elseif elem isa SpBind
                bt = _bt_apply_bind(bt, elem::SpBind, ctx)

            elseif elem isa SpGroup
                # Nested subgroup: evaluated independently from the empty solution,
                # then joined with the current BT.  Flush for the join step.
                inner_sols = _sp_eval_pattern(elem, ctx, [_SpSolution()])
                sols       = _bt_to_solutions(bt)
                new_sols   = _SpSolution[]
                for μ in sols
                    for μ2 in inner_sols
                        _sp_compatible(μ, μ2) && push!(new_sols, _sp_merge_sol(μ, μ2))
                    end
                end
                bt = _solutions_to_bt(new_sols)

            else
                # SpValues, SpUnion, SpMinus, SpGraph, SpService, etc.
                # These receive the current solutions as input (matching the original
                # semantics of passing `solutions` into _sp_eval_pattern).
                sols = _bt_to_solutions(bt)
                sols = _sp_eval_pattern(elem, ctx, sols)
                bt   = _solutions_to_bt(sols)
            end
        end

        # Apply all collected filters in BT space, then materialise once.
        # Filter position within a group pattern does not affect SPARQL semantics
        # (§18.6): filters always scope over the whole group.
        for f in filters
            _bt_nrows(bt) == 0 && break
            bt = _bt_apply_filter(bt, f, ctx)
        end
        return _bt_to_solutions(bt)

    elseif pat isa SpFilter
        return filter(μ -> _sp_filter_passes(pat.expr, ctx, μ, input), input)

    elseif pat isa SpOptional
        # Columnar left outer join via _bt_left_join.
        # Fast paths: plain single-triple BGP → _bt_left_join_tp (zero Dict allocs
        # during the join); multi-triple BGP → _bt_left_join_bgp (one synthetic
        # row-id column).  Complex bodies fall back to per-row _sp_eval_pattern but
        # still pay the BT↔solution conversion only once rather than once per row.
        bt = _solutions_to_bt(input)
        bt = _bt_left_join(bt, pat.pattern, ctx)
        return _bt_to_solutions(bt)

    elseif pat isa SpUnion
        # SPARQL algebra: Union branches are evaluated from empty, then joined with input
        empty_input = _SpSolution[]
        push!(empty_input, _SpSolution())
        left_sols  = _sp_eval_pattern(pat.left,  ctx, empty_input)
        right_sols = _sp_eval_pattern(pat.right, ctx, empty_input)
        branch_sols = vcat(left_sols, right_sols)
        results = _SpSolution[]
        for μ in input
            for μ2 in branch_sols
                _sp_compatible(μ, μ2) && push!(results, _sp_merge_sol(μ, μ2))
            end
        end
        return results

    elseif pat isa SpMinus
        # MINUS: left \ right (set difference on compatible solutions)
        # Per SPARQL spec §18.5, right side is evaluated from the empty solution set
        right_sols = _sp_eval_pattern(pat.pattern, ctx, [_SpSolution()])
        return filter(μ -> !any(μ2 -> _sp_compatible(μ, μ2) && !isempty(intersect(keys(μ), keys(μ2))),
                                right_sols),
                     input)

    elseif pat isa SpGraph
        # GRAPH ?var { } or GRAPH <iri> { }
        if pat.name isa SpVar
            vname = (pat.name::SpVar).name
            results = _SpSolution[]
            for (graph_name, g) in ctx.dataset
                inner_ctx = _sp_with_graph(ctx, g)
                for μ in input
                    ext = copy(μ)
                    if !haskey(ext, vname)
                        ext[vname] = graph_name
                        for s in _sp_eval_pattern(pat.pattern, inner_ctx, [ext])
                            push!(results, s)
                        end
                    elseif ext[vname] == graph_name
                        for s in _sp_eval_pattern(pat.pattern, inner_ctx, [ext])
                            push!(results, s)
                        end
                    end
                end
            end
            return results
        else
            # GRAPH <iri> { }
            iri_str = (pat.name::SpIRI).value
            # Resolve relative IRIs against the evaluation context base
            if ctx.base !== nothing && !occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", iri_str)
                iri_str = _sp_resolve_iri(ctx.base, iri_str)
            end
            g_name = IRI(iri_str)
            g = get(ctx.dataset, g_name, nothing)
            g === nothing && return _SpSolution[]
            inner_ctx = _sp_with_graph(ctx, g)
            return _sp_eval_pattern(pat.pattern, inner_ctx, input)
        end

    elseif pat isa SpService
        return _sp_eval_service(pat, ctx, input)

    elseif pat isa SpBind
        results = _SpSolution[]
        vname = pat.var.name
        for μ in input
            if haskey(μ, vname)
                push!(results, copy(μ))  # already bound: skip
                continue
            end
            # Reset per-solution BNODE(str) scope for each solution row
            ctx.bnode_solution_scope = Dict{String, BlankNode}()
            val = try _sp_eval_expr(pat.expr, ctx, μ, input) catch; nothing end
            ext = copy(μ)
            if val !== nothing
                ext[vname] = val
            end
            push!(results, ext)
        end
        return results

    elseif pat isa SpValues
        # Inline data: cross-product with input
        inline_sols = _sp_inline_data_solutions(pat, ctx.base)
        results = _SpSolution[]
        for μ in input
            for μ2 in inline_sols
                _sp_compatible(μ, μ2) && push!(results, _sp_merge_sol(μ, μ2))
            end
        end
        return results

    elseif pat isa SpSubQuery
        sq = pat.query
        if sq isa SpSelectQuery
            # Per SPARQL spec: subqueries are evaluated independently (from empty
            # solution), then their results are joined with the outer input.
            # Outer variable bindings must NOT be injected into the subquery.
            sub_results = _sp_execute_select(sq, ctx, [_SpSolution()])
            # Project to solution mappings
            sub_sols = _SpSolution[]
            for r in sub_results
                μ2 = _SpSolution()
                for v in keys(r)
                    val = r[v]
                    val !== nothing && (μ2[v] = val)
                end
                push!(sub_sols, μ2)
            end
            # JOIN with outer input
            results = _SpSolution[]
            for μ in input
                for μ2 in sub_sols
                    _sp_compatible(μ, μ2) && push!(results, _sp_merge_sol(μ, μ2))
                end
            end
            return results
        else
            return _SpSolution[]
        end

    else
        return input
    end
end

function _sp_filter_passes(expr::SpExpr, ctx::_SpEvalCtx, μ::_SpSolution, sols::Vector{_SpSolution})::Bool
    val = try _sp_eval_expr(expr, ctx, μ, sols) catch; return false end
    try _sp_to_bool(val) catch; return false end
end

# Convert VALUES inline data to solution mappings
function _sp_inline_data_solutions(vals::SpValues, base::Union{String,Nothing}=nothing)::Vector{_SpSolution}
    results = _SpSolution[]
    for row in vals.rows
        μ = _SpSolution()
        valid = true
        for (var, val) in zip(vals.vars, row)
            if val !== nothing
                t = try _sp_ast_to_term(val, base) catch; valid = false; break end
                t !== nothing && (μ[var.name] = t)
            end
            # UNDEF → variable simply not bound in this row
        end
        valid && push!(results, μ)
    end
    results
end

# Convert a constant SpExpr to an RDFTerm (no solution lookup).
# base is used to resolve relative IRIs.
function _sp_ast_to_term(expr::SpExpr, base::Union{String,Nothing}=nothing)::Union{RDFTerm, Nothing}
    if expr isa SpIRI
        iri_str = expr.value
        if base !== nothing && !occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", iri_str)
            iri_str = _sp_resolve_iri(base, iri_str)
        end
        return IRI(iri_str)
    elseif expr isa SpLiteral
        return try
            !isempty(expr.lang) ?
                Literal(expr.lexical, IRI(expr.datatype), expr.lang) :
                Literal(expr.lexical, IRI(expr.datatype), "")
        catch; nothing
        end
    elseif expr isa SpBNode; return _mint_blank_node()
    else; return nothing
    end
end

# ── Solution modifiers ────────────────────────────────────────────────────────

function _sp_apply_group_by(sols::Vector{_SpSolution}, group_by::Vector{SpGroupCond},
                              ctx::_SpEvalCtx)::Dict{Vector{Union{RDFTerm,Nothing}}, Vector{_SpSolution}}
    groups = Dict{Vector{Union{RDFTerm,Nothing}}, Vector{_SpSolution}}()
    for μ in sols
        key = Union{RDFTerm, Nothing}[]
        for gc in group_by
            v = try _sp_eval_expr(gc.expr, ctx, μ, sols) catch; nothing end
            push!(key, v)
        end
        push!(get!(groups, key, _SpSolution[]), μ)
    end
    groups
end

function _sp_apply_aggregate(agg::SpAggregate, group::Vector{_SpSolution},
                               ctx::_SpEvalCtx)::Union{RDFTerm, Nothing}
    try
        if agg.func === :count
            if agg.arg === nothing
                return Literal(string(length(group)), IRI(_SP_XSD_INTEGER), "")
            else
                vals = RDFTerm[]
                for μ in group
                    v = try _sp_eval_expr(agg.arg, ctx, μ, group) catch; continue end
                    agg.distinct ? (v ∉ vals && push!(vals, v)) : push!(vals, v)
                end
                return Literal(string(length(vals)), IRI(_SP_XSD_INTEGER), "")
            end
        elseif agg.func === :sum
            vals = _sp_agg_numeric_vals(agg, group, ctx)
            isempty(vals) && return Literal("0", IRI(_SP_XSD_INTEGER), "")
            result = vals[1]
            for v in vals[2:end]; result = _sp_numeric_add(result, v); end
            return result
        elseif agg.func === :avg
            vals = _sp_agg_numeric_vals(agg, group, ctx)
            isempty(vals) && return Literal("0", IRI(_SP_XSD_INTEGER), "")
            s = vals[1]
            for v in vals[2:end]; s = _sp_numeric_add(s, v); end
            n = Literal(string(length(vals)), IRI(_SP_XSD_INTEGER), "")
            return _sp_numeric_div(s, n)
        elseif agg.func === :min
            vals = _sp_agg_rdf_vals(agg, group, ctx)
            isempty(vals) && return nothing
            result = vals[1]
            for v in vals[2:end]; _sp_compare(v, result) < 0 && (result = v); end
            return result
        elseif agg.func === :max
            vals = _sp_agg_rdf_vals(agg, group, ctx)
            isempty(vals) && return nothing
            result = vals[1]
            for v in vals[2:end]; _sp_compare(v, result) > 0 && (result = v); end
            return result
        elseif agg.func === :sample
            vals = _sp_agg_rdf_vals(agg, group, ctx)
            isempty(vals) && return nothing
            return vals[1]
        elseif agg.func === :group_concat
            vals = _sp_agg_rdf_vals(agg, group, ctx)
            sep = agg.separator !== nothing ? agg.separator : " "
            strs = [v isa Literal ? v.lexical_form : (v isa IRI ? v.value : "") for v in vals]
            return Literal(join(strs, sep), IRI(_SP_XSD_STRING), "")
        end
    catch
        return nothing
    end
    return nothing
end

function _sp_agg_numeric_vals(agg::SpAggregate, group::Vector{_SpSolution}, ctx::_SpEvalCtx)::Vector{Literal}
    # Per SPARQL 1.1 spec section 11.4.3.4: errors in numeric aggregates propagate
    # (if any member is bound but non-numeric, the whole aggregate is an error).
    # Unbound variables (evaluation throws) are skipped.
    vals = Literal[]
    seen = Set{RDFTerm}()
    for μ in group
        v = try _sp_eval_expr(agg.arg, ctx, μ, group) catch; continue end
        # If the value evaluates but is not numeric, propagate as error
        v isa Literal && _sp_is_numeric(v.datatype.value) || error("non-numeric value in numeric aggregate: $v")
        agg.distinct && (v in seen && continue; push!(seen, v))
        push!(vals, v::Literal)
    end
    vals
end

function _sp_agg_rdf_vals(agg::SpAggregate, group::Vector{_SpSolution}, ctx::_SpEvalCtx)::Vector{RDFTerm}
    vals = RDFTerm[]
    seen = Set{RDFTerm}()
    for μ in group
        v = try _sp_eval_expr(agg.arg, ctx, μ, group) catch; continue end
        agg.distinct && (v in seen && continue; push!(seen, v))
        push!(vals, v)
    end
    vals
end

function _sp_apply_order_by(sols::Vector{_SpSolution}, order_by::Vector{SpOrderCond},
                              ctx::_SpEvalCtx)::Vector{_SpSolution}
    isempty(order_by) && return sols
    sort(sols, lt = (a, b) -> begin
        for cond in order_by
            va = try _sp_eval_expr(cond.expr, ctx, a, sols) catch; nothing end
            vb = try _sp_eval_expr(cond.expr, ctx, b, sols) catch; nothing end
            if va === nothing && vb === nothing; continue end
            if va === nothing; return cond.ascending end   # unbound < bound
            if vb === nothing; return !cond.ascending end
            c = try _sp_compare(va, vb) catch; 0 end
            c != 0 && return cond.ascending ? c < 0 : c > 0
        end
        false
    end, alg=Base.Sort.MergeSort)
end

# ── Direct-BT WHERE evaluation (avoids intermediate _bt_to_solutions) ─────────
#
# For simple SELECT queries that don't need aggregation, sorting, or DISTINCT,
# _sp_eval_where_bt returns the BT produced by the WHERE clause directly, so
# that _sp_execute_select can project straight from column vectors to output rows
# without ever building the intermediate Vector{_SpSolution}.
#
# Returns nothing when the pattern contains elements that require the full
# _sp_eval_pattern path (property paths, UNION, GRAPH, nested groups, VALUES, …).

function _sp_eval_where_bt(pat::SpPat, ctx::_SpEvalCtx)::Union{_BT, Nothing}
    # Initial BT: one row, no columns (= the single empty input solution).
    bt = _BT(Symbol[], Dict{Symbol,Int}(), Vector{UInt32}[], 1)

    if pat isa SpBGP
        any(tp -> _bt_is_complex_path(tp.predicate) || _tp_needs_tt_matching(tp),
            pat.triples) && return nothing
        for tp in _sp_reorder_bgp(pat.triples, ctx, Set{Symbol}())
            _bt_nrows(bt) == 0 && return bt
            bt = _bt_extend_tp(bt, tp, ctx)
        end
        return bt
    end

    pat isa SpGroup || return nothing

    # Reject groups that contain elements we can't handle in BT space.
    for elem in pat.elements
        if !(elem isa SpBGP || elem isa SpOptional || elem isa SpBind || elem isa SpFilter)
            return nothing   # nested SpGroup, SpValues, SpUnion, SpGraph, SpService, …
        end
        if elem isa SpBGP && any(tp -> _bt_is_complex_path(tp.predicate) || _tp_needs_tt_matching(tp), elem.triples)
            return nothing   # property path or RDF-star pattern inside BGP
        end
    end

    # All elements are BT-native — no Dict materialisation until the final projection.
    # SpFilter is collected and applied at the end (SPARQL §18.6: filter scopes over
    # the whole group regardless of where it appears syntactically).
    filters = SpFilter[]
    for elem in pat.elements
        _bt_nrows(bt) == 0 && break
        if elem isa SpBGP
            for tp in _sp_reorder_bgp((elem::SpBGP).triples, ctx, Set(bt.vars))
                _bt_nrows(bt) == 0 && break
                bt = _bt_extend_tp(bt, tp, ctx)
            end
        elseif elem isa SpOptional
            bt = _bt_left_join(bt, (elem::SpOptional).pattern, ctx)
        elseif elem isa SpBind
            bt = _bt_apply_bind(bt, elem::SpBind, ctx)
        else  # SpFilter
            push!(filters, elem::SpFilter)
        end
    end
    for f in filters
        _bt_nrows(bt) == 0 && break
        bt = _bt_apply_filter(bt, f, ctx)
    end
    bt
end

# Project BT rows [from..to] directly into the columnar SolutionSet, resolving
# term IDs only once — no intermediate Dict or _SpSolution allocations.
function _bt_to_solution_set(bt::_BT, vars::Vector{Symbol}, from::Int, to::Int)::SolutionSet
    ss   = SolutionSet(vars)
    nout = to - from + 1
    nout <= 0 && return ss

    # Pre-size every output column to avoid repeated reallocation.
    for col in ss._cols; sizehint!(col, nout); end

    # Column index for each projected variable (0 = not in BT → always nothing).
    col_idx = [get(bt.var_idx, v, 0) for v in vars]
    nv      = length(vars)

    for k in 1:nout
        j = from + k - 1
        for i in 1:nv
            ci = @inbounds col_idx[i]
            val = if ci != 0
                id = @inbounds bt.cols[ci][j]
                id != 0 ? _resolve(id) : nothing
            else
                nothing
            end
            push!(ss._cols[i], val)
        end
    end
    ss
end

# ── SELECT execution ──────────────────────────────────────────────────────────

function _sp_execute_select(q::SpSelectQuery, ctx::_SpEvalCtx,
                              outer_input::Union{Vector{_SpSolution}, Nothing}=nothing)::SolutionSet
    # ── BT fast path ─────────────────────────────────────────────────────────
    # Conditions: top-level call, plain variable projections only, no GROUP BY /
    # aggregates / ORDER BY / VALUES / DISTINCT.  When these hold, the WHERE
    # clause is evaluated entirely in column-vector space and the output rows are
    # projected directly from the BT — skipping the intermediate _bt_to_solutions
    # pass that would otherwise materialise n Dict{Symbol,RDFTerm} objects.
    if outer_input === nothing && !q.star && !q.distinct && !q.reduced &&
       isempty(q.group_by) && !_sp_has_aggregates(q.columns) &&
       isempty(q.order_by) && q.values === nothing &&
       all(col -> col.as_var === nothing && col.expr isa SpVar, q.columns)
        bt = _sp_eval_where_bt(q.pattern, ctx)
        if bt !== nothing
            vars   = unique(Symbol[(col.expr::SpVar).name for col in q.columns])
            n      = _bt_nrows(bt)
            offset = q.offset !== nothing ? min(q.offset, n) : 0
            lim    = q.limit  !== nothing ? min(q.limit, n - offset) : (n - offset)
            return _bt_to_solution_set(bt, vars, offset + 1, offset + lim)
        end
    end

    # ── Full path ─────────────────────────────────────────────────────────────
    # 1. Evaluate WHERE pattern
    input = outer_input !== nothing ? outer_input : [_SpSolution()]
    sols = _sp_eval_pattern(q.pattern, ctx, input)

    # 2. GROUP BY / Aggregates
    if !isempty(q.group_by) || _sp_has_aggregates(q.columns)
        sols = _sp_apply_group_aggregation(q, sols, ctx)
    end

    # 3. HAVING (evaluated per-group inside _sp_apply_group_aggregation)

    # 4. ORDER BY
    sols = _sp_apply_order_by(sols, q.order_by, ctx)

    # 5. LIMIT / OFFSET
    total = length(sols)
    offset = q.offset !== nothing ? min(q.offset, total) : 0
    limit  = q.limit  !== nothing ? min(q.limit, total - offset) : (total - offset)
    sols = sols[offset+1:offset+limit]

    # 6. VALUES clause
    if q.values !== nothing
        inline_sols = _sp_inline_data_solutions(q.values, ctx.base)
        new_sols = _SpSolution[]
        for μ in sols
            for μ2 in inline_sols
                _sp_compatible(μ, μ2) && push!(new_sols, _sp_merge_sol(μ, μ2))
            end
        end
        sols = new_sols
    end

    # 7. Project
    if q.star
        vars_set = Set{Symbol}(_sp_collect_all_vars(sols))
        # Also include BIND-introduced variables (even if always unbound)
        _sp_collect_bind_vars!(q.pattern, vars_set)
        vars = sort(collect(vars_set))
        rows = [Dict{Symbol, Union{RDFTerm, Nothing}}(v => get(μ, v, nothing) for v in vars)
                for μ in sols]
        # 8. DISTINCT
        if q.distinct || q.reduced
            seen = Set{Vector{String}}()
            rows = filter(rows) do row
                key = [string(get(row, v, nothing)) for v in vars]
                key ∉ seen && (push!(seen, key); true)
            end
        end
        return SolutionSet(vars, rows)
    else
        vars = Symbol[]
        for col in q.columns
            if col.as_var !== nothing
                push!(vars, col.as_var.name)
            elseif col.expr isa SpVar
                push!(vars, (col.expr::SpVar).name)
            end
        end
        vars = unique(vars)
        rows = Dict{Symbol, Union{RDFTerm, Nothing}}[]
        # Fast path: all columns are plain variable projections (no expressions,
        # no aggregates, no BNODE()).  Skip the per-row copy(μ) and bnode_scope.
        all_simple = all(col -> col.as_var === nothing && col.expr isa SpVar, q.columns)
        if all_simple
            for μ in sols
                row = Dict{Symbol, Union{RDFTerm, Nothing}}()
                for col in q.columns
                    vname = (col.expr::SpVar).name
                    row[vname] = get(μ, vname, nothing)
                end
                push!(rows, row)
            end
        else
            for μ in sols
                # Reset per-solution BNODE(str) scope for each result row
                ctx.bnode_solution_scope = Dict{String, BlankNode}()
                row = Dict{Symbol, Union{RDFTerm, Nothing}}()
                # Extended solution: allows later SELECT expressions to reference
                # variables introduced by earlier SELECT expressions (projexp03 pattern).
                μ_ext = copy(μ)
                for col in q.columns
                    if col.as_var !== nothing
                        vname = col.as_var.name
                        if _sp_expr_is_aggregate(col.expr)
                            # Aggregate already computed into μ by _sp_apply_group_aggregation
                            v = get(μ, vname, nothing)
                            row[vname] = v
                            v !== nothing && (μ_ext[vname] = v)
                        else
                            v = try _sp_eval_expr(col.expr, ctx, μ_ext, sols) catch; nothing end
                            row[vname] = v
                            v !== nothing && (μ_ext[vname] = v)
                        end
                    elseif col.expr isa SpVar
                        vname = (col.expr::SpVar).name
                        row[vname] = get(μ_ext, vname, nothing)
                    end
                end
                push!(rows, row)
            end
        end
        # 8. DISTINCT
        if q.distinct || q.reduced
            seen = Set{Vector{String}}()
            rows = filter(rows) do row
                key = [string(get(row, v, nothing)) for v in vars]
                key ∉ seen && (push!(seen, key); true)
            end
        end
        return SolutionSet(vars, rows)
    end
end

function _sp_collect_all_vars(sols::Vector{_SpSolution})::Vector{Symbol}
    seen = Set{Symbol}()
    for μ in sols
        for k in keys(μ)
            s = string(k)
            !startswith(s, "_sp_bnode_") && !startswith(s, "_sp_anon_") && push!(seen, k)
        end
    end
    sort(collect(seen))
end

# Recursively collect all variables visible to SELECT * from a pattern tree.
# Includes BGP triple-pattern variables, BIND variables, VALUES variables, GRAPH
# name variables, OPTIONAL, UNION, etc.  Does NOT recurse into subqueries.
function _sp_collect_bind_vars!(pat::SpPat, result::Set{Symbol})
    if pat isa SpBGP
        for tp in pat.triples
            tp.subject   isa SpVar && push!(result, (tp.subject::SpVar).name)
            # predicate is usually SpIRI or SpPath, but can be SpVar
            tp.predicate isa SpVar && push!(result, (tp.predicate::SpVar).name)
            tp.object    isa SpVar && push!(result, (tp.object::SpVar).name)
            # Note: SpAnonBNode and SpBNode are internal variables, not user-visible
        end
    elseif pat isa SpBind
        push!(result, pat.var.name)
    elseif pat isa SpValues
        # Variables declared in VALUES are in scope even when the result is empty
        for v in pat.vars
            push!(result, v.name)
        end
    elseif pat isa SpGroup
        for elem in pat.elements
            elem isa SpPat && _sp_collect_bind_vars!(elem, result)
        end
    elseif pat isa SpOptional
        _sp_collect_bind_vars!(pat.pattern, result)
    elseif pat isa SpUnion
        _sp_collect_bind_vars!(pat.left, result)
        _sp_collect_bind_vars!(pat.right, result)
    elseif pat isa SpGraph
        pat.name isa SpVar && push!(result, (pat.name::SpVar).name)
        _sp_collect_bind_vars!(pat.pattern, result)
    elseif pat isa SpMinus
        # MINUS RHS vars are NOT in scope for SELECT *, only recurse into LHS implicitly
        # (SpMinus only has .pattern which is the RHS, so don't recurse)
        nothing
    end
    # Note: SpSubquery vars are NOT in scope for SELECT * of the outer query
    result
end

function _sp_has_aggregates(cols::Vector{SpSelectColumn})::Bool
    any(col -> _sp_expr_is_aggregate(col.expr), cols)
end

function _sp_apply_group_aggregation(q::SpSelectQuery, sols::Vector{_SpSolution},
                                      ctx::_SpEvalCtx)::Vector{_SpSolution}
    # Group solutions
    if isempty(q.group_by)
        # Implicit single group
        groups = Dict{Vector{Union{RDFTerm,Nothing}}, Vector{_SpSolution}}(
            Union{RDFTerm,Nothing}[] => sols
        )
    else
        groups = _sp_apply_group_by(sols, q.group_by, ctx)
    end

    # For each group, compute aggregate values and produce one representative solution
    result = _SpSolution[]
    for (key, group) in groups
        μ = _SpSolution()
        # Bind GROUP BY variables to their key value
        for (i, gc) in enumerate(q.group_by)
            if gc.var !== nothing
                key[i] !== nothing && (μ[gc.var.name] = key[i])
            elseif gc.expr isa SpVar
                key[i] !== nothing && (μ[(gc.expr::SpVar).name] = key[i])
            end
        end
        # Compute non-aggregate columns (bind from first solution in group)
        if !isempty(group)
            for (k, v) in group[1]
                !haskey(μ, k) && !startswith(string(k), "_sp_bnode_") && (μ[k] = v)
            end
        end
        # Compute aggregate expressions from columns
        for col in q.columns
            if _sp_expr_is_aggregate(col.expr)
                vname = col.as_var !== nothing ? col.as_var.name : :_agg_result
                val = _sp_eval_aggregate_expr(col.expr, group, ctx, sols)
                val !== nothing && (μ[vname] = val)
            end
        end
        # Evaluate HAVING.  Pass μ so that aggregate aliases (e.g. ?blastRadius
        # defined by COUNT(DISTINCT ...) AS ?blastRadius in SELECT) resolve
        # correctly — they live in μ, not in the raw group solutions.
        having_ok = true
        for having_expr in q.having
            val = try _sp_eval_aggregate_expr(having_expr, group, ctx, sols, μ) catch; nothing end
            b   = val === nothing ? false : (try _sp_to_bool(val) catch; false end)
            if !b; having_ok = false; break; end
        end
        having_ok || continue
        push!(result, μ)
    end
    result
end

function _sp_eval_aggregate_expr(expr::SpExpr, group::Vector{_SpSolution}, ctx::_SpEvalCtx,
                                  all_sols::Vector{_SpSolution},
                                  precomputed::Union{_SpSolution, Nothing}=nothing)::Union{RDFTerm, Nothing}
    # Shorthand for recursive calls that propagates precomputed bindings
    rec(e) = _sp_eval_aggregate_expr(e, group, ctx, all_sols, precomputed)

    if expr isa SpAggregate
        return _sp_apply_aggregate(expr, group, ctx)

    elseif expr isa SpBinary
        # Recursively evaluate both sides in aggregate context
        l = rec(expr.left)
        r = rec(expr.right)
        (l === nothing || r === nothing) && return nothing
        # Evaluate the operator via a temporary solution with pre-computed values
        μt = _SpSolution(:_l => l, :_r => r)
        fake = SpBinary(expr.op, SpVar(:_l), SpVar(:_r))
        return try _sp_eval_expr(fake, ctx, μt, all_sols) catch; nothing end

    elseif expr isa SpUnary
        v = rec(expr.arg)
        v === nothing && return nothing
        μt = _SpSolution(:_v => v)
        fake = SpUnary(expr.op, SpVar(:_v))
        return try _sp_eval_expr(fake, ctx, μt, all_sols) catch; nothing end

    elseif expr isa SpCall
        args = Union{RDFTerm, Nothing}[]
        for a in expr.args
            push!(args, rec(a))
        end
        nothing in args && return nothing
        return try _sp_call_builtin(expr.func, RDFTerm[a for a in args], ctx.base) catch; nothing end

    elseif expr isa SpIf
        cond = rec(expr.cond)
        b = try _sp_to_bool(cond) catch; return nothing end
        return b ? rec(expr.then_) : rec(expr.else_)

    elseif expr isa SpCoalesce
        for a in expr.args
            v = try rec(a) catch; nothing end
            v !== nothing && return v
        end
        return nothing

    else
        # Non-aggregate: check precomputed aggregate aliases first (e.g. aliases
        # defined in SELECT that are referenced in HAVING), then fall back to
        # evaluating against the first solution in the group.
        if precomputed !== nothing && expr isa SpVar
            v = get(precomputed, expr.name, nothing)
            v !== nothing && return v
        end
        isempty(group) && return nothing
        try _sp_eval_expr(expr, ctx, group[1], all_sols) catch; nothing end
    end
end

# ── CONSTRUCT execution ───────────────────────────────────────────────────────

function _sp_execute_construct(q::SpConstructQuery, ctx::_SpEvalCtx)::Graph
    # Handle FROM / FROM NAMED dataset clauses
    eval_ctx = if !isempty(q.datasets)
        new_default = Graph()
        new_named   = Dict{IRI, Graph}()
        for dc in q.datasets
            iri_str = dc.iri
            # Resolve relative IRI against base (the parser may or may not have done this)
            if ctx.base !== nothing && !occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", iri_str)
                iri_str = _sp_resolve_iri(ctx.base, iri_str)
            end
            iri_key = IRI(iri_str)
            g = get(ctx.dataset, iri_key, nothing)
            if g !== nothing
                if dc.named
                    new_named[iri_key] = g
                else
                    merge!(new_default, g)
                end
            end
        end
        tmp_ds = Dataset(; default_graph=new_default)
        for (k, g) in new_named
            tmp_ds[k] = g
        end
        _SpEvalCtx(tmp_ds, ctx.base)
    else
        ctx
    end

    sols = _sp_eval_pattern(q.pattern, eval_ctx, [_SpSolution()])

    # ORDER BY, LIMIT, OFFSET
    sols = _sp_apply_order_by(sols, q.order_by, ctx)
    total = length(sols)
    offset = q.offset !== nothing ? min(q.offset, total) : 0
    limit  = q.limit  !== nothing ? min(q.limit, total - offset) : (total - offset)
    sols = sols[offset+1:offset+limit]

    result = Graph()
    template = q.template !== nothing ? q.template : begin
        # CONSTRUCT WHERE: template = WHERE pattern triples
        if q.pattern isa SpBGP
            (q.pattern::SpBGP).triples
        elseif q.pattern isa SpGroup
            bgp_triples = SpTriple[]
            for el in (q.pattern::SpGroup).elements
                el isa SpBGP && append!(bgp_triples, el.triples)
            end
            bgp_triples
        else
            SpTriple[]
        end
    end

    for μ in sols
        # Fresh anonymous blank node map per solution — ensures each solution
        # gets its own blank nodes for RDF list / anonymous patterns in the template.
        anon_map = Dict{UInt64, BlankNode}()
        for tp in template
            s_term = _sp_instantiate_term(tp.subject, ctx, μ, anon_map)
            o_term = _sp_instantiate_term(tp.object, ctx, μ, anon_map)
            p_term = if tp.predicate isa SpExpr
                _sp_instantiate_term(tp.predicate::SpExpr, ctx, μ, anon_map)
            elseif tp.predicate isa SpPathIRI
                IRI((tp.predicate::SpPathIRI).value)
            elseif tp.predicate isa SpPathA
                IRI(_SP_RDF_TYPE)
            else
                nothing
            end
            # Skip if any term is unbound, is a literal in subject/predicate position, etc.
            s_term isa SubjectTerm || continue
            p_term isa IRI         || continue
            o_term isa ObjectTerm  || continue
            push!(result, Triple(s_term::SubjectTerm, p_term::IRI, o_term::ObjectTerm))
        end
    end
    result
end

function _sp_instantiate_term(expr::SpExpr, ctx::_SpEvalCtx, μ::_SpSolution,
                               anon_map::Dict{UInt64,BlankNode}=Dict{UInt64,BlankNode}())::Union{RDFTerm, Nothing}
    if expr isa SpVar
        return get(μ, expr.name, nothing)
    elseif expr isa SpIRI
        return IRI(expr.value)
    elseif expr isa SpLiteral
        return try
            !isempty(expr.lang) ?
                Literal(expr.lexical, IRI(expr.datatype), expr.lang) :
                Literal(expr.lexical, IRI(expr.datatype), "")
        catch; nothing
        end
    elseif expr isa SpBNode
        # Blank nodes in templates: reuse per-solution mapping
        bnode_sym = Symbol("_sp_bnode_construct_" * expr.label)
        haskey(μ, bnode_sym) && return μ[bnode_sym]
        # Map based on the BGP blank node binding if available
        bgp_sym = Symbol("_sp_bnode_" * expr.label)
        get(μ, bgp_sym, nothing)
    elseif expr isa SpAnonBNode
        # Anonymous blank nodes in CONSTRUCT templates: mint one fresh blank node
        # per (anon-node-instance, solution) pair so that list structure is preserved
        # within a solution but each solution gets its own nodes.
        return get!(anon_map, expr.id, _mint_blank_node())
    else
        return nothing
    end
end

# ── ASK execution ─────────────────────────────────────────────────────────────

function _sp_execute_ask(q::SpAskQuery, ctx::_SpEvalCtx)::Bool
    sols = _sp_eval_pattern(q.pattern, ctx, [_SpSolution()])
    !isempty(sols)
end

# ── DESCRIBE execution ────────────────────────────────────────────────────────

function _sp_execute_describe(q::SpDescribeQuery, ctx::_SpEvalCtx)::Graph
    result = Graph()
    resources = RDFTerm[]

    if q.star
        # DESCRIBE * → describe all subjects in results
        if q.pattern !== nothing
            sols = _sp_eval_pattern(q.pattern, ctx, [_SpSolution()])
            for μ in sols
                for (_, v) in μ; v isa IRI && push!(resources, v); end
            end
        end
    else
        if q.pattern !== nothing
            sols = _sp_eval_pattern(q.pattern, ctx, [_SpSolution()])
            for res in q.resources
                if res isa SpVar
                    for μ in sols
                        v = get(μ, (res::SpVar).name, nothing)
                        v !== nothing && push!(resources, v)
                    end
                elseif res isa SpIRI
                    push!(resources, IRI(res.value))
                end
            end
        else
            for res in q.resources
                res isa SpIRI && push!(resources, IRI(res.value))
            end
        end
    end

    # Collect all triples where resource appears as subject
    seen = Set{RDFTerm}()
    for r in resources
        r in seen && continue; push!(seen, r)
        r isa SubjectTerm || continue
        for t in match(ctx.active_graph; subject=r::SubjectTerm)
            push!(result, t)
        end
    end
    result
end

# ── Public-facing execution functions ─────────────────────────────────────────

function _sp_execute_query(unit::SpQueryUnit, ctx::_SpEvalCtx)
    q = unit.query
    if q isa SpSelectQuery
        return _sp_execute_select(q, ctx)
    elseif q isa SpConstructQuery
        return _sp_execute_construct(q, ctx)
    elseif q isa SpAskQuery
        return _sp_execute_ask(q, ctx)
    elseif q isa SpDescribeQuery
        return _sp_execute_describe(q, ctx)
    else
        error("Unknown query form: $(typeof(q))")
    end
end
