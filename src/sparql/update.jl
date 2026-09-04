# ── SPARQL 1.1 Update Executor ────────────────────────────────────────────────
#
# Implements SPARQL 1.1 Update semantics.
# Reference: https://www.w3.org/TR/sparql11-update/
#
# Each update operation mutates the Dataset in-place.

# ── Graph resolution helpers ──────────────────────────────────────────────────

# Get or create a named graph by IRI
function _sp_upd_get_or_create_named(ctx::_SpEvalCtx, iri::String)::Graph
    key = IRI(iri)
    if !haskey(ctx.dataset, key)
        ctx.dataset[key] = Graph()
    end
    ctx.dataset[key]
end

# ── Quad block materialisation ────────────────────────────────────────────────

# Materialize a SpQuadBlock into actual triples, grouped by target graph.
# Used for INSERT DATA / DELETE DATA (no variable binding).
# Blank node labels are scoped to the entire block (per SPARQL Update spec).
function _sp_materialise_quad_block_static(quads::SpQuadBlock, ctx::_SpEvalCtx)::Vector{Pair{Union{String, Nothing}, Vector{Triple}}}
    result = Pair{Union{String, Nothing}, Vector{Triple}}[]
    bnode_map = Dict{String, BlankNode}()  # shared across all graphs in one DATA block
    for (graph_iri, triples) in quads
        materialised = Triple[]
        for tp in triples
            t = _sp_upd_materialise_triple_static(tp, bnode_map)
            t !== nothing && push!(materialised, t)
        end
        push!(result, graph_iri => materialised)
    end
    result
end

function _sp_upd_materialise_triple_static(tp::SpTriple, bnode_map::Dict{String,BlankNode})::Union{Triple, Nothing}
    s = _sp_upd_static_term(tp.subject, bnode_map)
    p = if tp.predicate isa SpExpr
        _sp_upd_static_term(tp.predicate::SpExpr, bnode_map)
    else
        _sp_upd_path_to_iri(tp.predicate)
    end
    o = _sp_upd_static_term(tp.object, bnode_map)
    s isa SubjectTerm && p isa IRI && o isa ObjectTerm || return nothing
    Triple(s::SubjectTerm, p::IRI, o::ObjectTerm)
end

# Convert a simple SpPath predicate to an IRI (only for non-complex paths).
function _sp_upd_path_to_iri(path::SpPath)::Union{IRI, Nothing}
    path isa SpPathIRI && return IRI(path.value)
    path isa SpPathA   && return IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    return nothing  # complex paths can't appear in INSERT/DELETE templates
end

# Convert a constant SpExpr (no variables) to an RDFTerm
function _sp_upd_static_term(expr::SpExpr, bnode_map::Dict{String,BlankNode})::Union{RDFTerm, Nothing}
    if expr isa SpIRI
        return IRI(expr.value)
    elseif expr isa SpLiteral
        return try
            !isempty(expr.lang) ?
                Literal(expr.lexical, IRI(expr.datatype), expr.lang) :
                Literal(expr.lexical, IRI(expr.datatype), "")
        catch; nothing end
    elseif expr isa SpBNode
        # Same label in one block → same blank node (SPARQL Update scoping rule)
        return get!(bnode_map, expr.label, _mint_blank_node())
    elseif expr isa SpAnonBNode
        return _mint_blank_node()
    else
        return nothing  # variables not allowed in DATA blocks
    end
end

# Materialise a quad block template with a solution (for MODIFY).
# Returns triples grouped by (graph_iri or nothing = default).
function _sp_materialise_quad_block_template(quads::SpQuadBlock, ctx::_SpEvalCtx, μ::_SpSolution)::Vector{Pair{Union{String, Nothing}, Vector{Triple}}}
    result = Pair{Union{String, Nothing}, Vector{Triple}}[]
    # Blank node label → BlankNode mapping per solution
    bnode_map = Dict{String, BlankNode}()
    for (graph_iri, triples) in quads
        materialised = Triple[]
        for tp in triples
            t = _sp_upd_materialise_template_triple(tp, ctx, μ, bnode_map)
            t !== nothing && push!(materialised, t)
        end
        push!(result, graph_iri => materialised)
    end
    result
end

function _sp_upd_materialise_template_triple(tp::SpTriple, ctx::_SpEvalCtx, μ::_SpSolution,
                                               bnode_map::Dict{String, BlankNode})::Union{Triple, Nothing}
    s = _sp_upd_template_term(tp.subject, μ, bnode_map)
    p = if tp.predicate isa SpExpr
        _sp_upd_template_term(tp.predicate::SpExpr, μ, bnode_map)
    else
        _sp_upd_path_to_iri(tp.predicate)
    end
    o = _sp_upd_template_term(tp.object, μ, bnode_map)
    s isa SubjectTerm && p isa IRI && o isa ObjectTerm || return nothing
    Triple(s::SubjectTerm, p::IRI, o::ObjectTerm)
end

function _sp_upd_template_term(expr::SpExpr, μ::_SpSolution, bnode_map::Dict{String, BlankNode})::Union{RDFTerm, Nothing}
    if expr isa SpVar
        return get(μ, expr.name, nothing)
    elseif expr isa SpIRI
        return IRI(expr.value)
    elseif expr isa SpLiteral
        return try
            !isempty(expr.lang) ?
                Literal(expr.lexical, IRI(expr.datatype), expr.lang) :
                Literal(expr.lexical, IRI(expr.datatype), "")
        catch; nothing end
    elseif expr isa SpBNode
        # Blank node labels in templates are scoped per solution (bnode_map is per-solution)
        return get!(bnode_map, expr.label, _mint_blank_node())
    elseif expr isa SpAnonBNode
        return nothing  # anonymous blank nodes in templates are discarded
    else
        return nothing
    end
end

# ── Apply quads to dataset ────────────────────────────────────────────────────

# Add or delete a set of (graph_iri_or_nothing, triples) from dataset.
# mode = :add or :delete
function _sp_upd_apply_quads!(ctx::_SpEvalCtx, quads::Vector{Pair{Union{String, Nothing}, Vector{Triple}}}, mode::Symbol)
    for (graph_iri, triples) in quads
        g = if graph_iri === nothing
            ctx.dataset.default_graph
        else
            _sp_upd_get_or_create_named(ctx, graph_iri::String)
        end
        for t in triples
            if mode === :add
                push!(g, t)
            else
                delete!(g, t)
            end
        end
    end
end

# ── INSERT DATA ───────────────────────────────────────────────────────────────

function _sp_execute_update_op!(op::SpInsertData, ctx::_SpEvalCtx)
    materialised = _sp_materialise_quad_block_static(op.quads, ctx)
    _sp_upd_apply_quads!(ctx, materialised, :add)
end

# ── DELETE DATA ───────────────────────────────────────────────────────────────

function _sp_execute_update_op!(op::SpDeleteData, ctx::_SpEvalCtx)
    materialised = _sp_materialise_quad_block_static(op.quads, ctx)
    _sp_upd_apply_quads!(ctx, materialised, :delete)
end

# ── DELETE WHERE ──────────────────────────────────────────────────────────────

function _sp_execute_update_op!(op::SpDeleteWhere, ctx::_SpEvalCtx)
    # Execute pattern against the dataset and collect matched quads
    sols = _sp_eval_pattern(op.pattern, ctx, [_SpSolution()])

    # Collect (graph_iri_or_nothing, triple) pairs from the pattern
    quads_to_delete = Pair{Union{String,Nothing}, Triple}[]
    for μ in sols
        _sp_collect_pattern_quads!(op.pattern, μ, ctx, nothing, quads_to_delete)
    end

    # Delete from the appropriate graph (deduplicate first)
    seen = Set{Pair{Union{String,Nothing}, Triple}}()
    for (graph_iri, t) in quads_to_delete
        qpair = graph_iri => t
        qpair in seen && continue
        push!(seen, qpair)
        g = if graph_iri === nothing
            ctx.active_graph
        else
            get(ctx.dataset, IRI(graph_iri), nothing)
        end
        g !== nothing && delete!(g, t)
    end
end

# Collect (graph_iri_or_nothing, triple) quads from a pattern match result.
# graph_iri tracks the current GRAPH context (nothing = active/default graph).
function _sp_collect_pattern_quads!(pat::SpPat, μ::_SpSolution, ctx::_SpEvalCtx,
                                     graph_iri::Union{String,Nothing},
                                     out::Vector{Pair{Union{String,Nothing},Triple}})
    if pat isa SpBGP
        bnode_map = Dict{String, BlankNode}()
        for tp in pat.triples
            t = _sp_upd_materialise_template_triple(tp, ctx, μ, bnode_map)
            t !== nothing && push!(out, graph_iri => t)
        end
    elseif pat isa SpGroup
        for el in pat.elements
            el isa SpPat && _sp_collect_pattern_quads!(el, μ, ctx, graph_iri, out)
        end
    elseif pat isa SpGraph
        g_iri = if pat.name isa SpIRI
            (pat.name::SpIRI).value
        elseif pat.name isa SpVar
            v = get(μ, (pat.name::SpVar).name, nothing)
            v isa IRI ? v.value : nothing
        else
            nothing
        end
        _sp_collect_pattern_quads!(pat.pattern, μ, ctx, g_iri, out)
    end
end

# ── MODIFY (INSERT/DELETE … USING … WHERE) ────────────────────────────────────

function _sp_execute_update_op!(op::SpModify, ctx::_SpEvalCtx)
    # Build evaluation context:
    # - WITH iri changes the active graph for pattern evaluation
    eval_ctx = if op.with_iri !== nothing
        g = _sp_upd_get_or_create_named(ctx, op.with_iri)
        _sp_with_graph(ctx, g)
    else
        ctx
    end

    # USING clauses affect dataset visibility (for pattern evaluation).
    # If USING is present, build a temporary dataset restricted to those graphs.
    if !isempty(op.using_)
        tmp_ds = Dataset()
        for dc in op.using_
            iri_key = IRI(dc.iri)
            if dc.named
                src = get(ctx.dataset, iri_key, nothing)
                src !== nothing && (tmp_ds[iri_key] = src)
            else
                # USING <iri> (unnamed) → becomes default graph
                src = get(ctx.dataset, iri_key, nothing)
                if src !== nothing
                    merge!(tmp_ds.default_graph, src)
                end
            end
        end
        eval_ctx = _SpEvalCtx(tmp_ds, eval_ctx.base)
    end

    # Evaluate WHERE pattern
    sols = _sp_eval_pattern(op.pattern, eval_ctx, [_SpSolution()])

    # Collect all deletes first, then inserts (SPARQL spec: delete before insert)
    to_delete = Pair{Union{String, Nothing}, Vector{Triple}}[]
    to_insert = Pair{Union{String, Nothing}, Vector{Triple}}[]

    for μ in sols
        if !isempty(op.delete_quads)
            d = _sp_materialise_quad_block_template(op.delete_quads, ctx, μ)
            append!(to_delete, d)
        end
        if !isempty(op.insert_quads)
            # Each solution gets its own bnode_map for INSERT (bnode sharing per solution)
            ins = _sp_materialise_quad_block_template(op.insert_quads, ctx, μ)
            append!(to_insert, ins)
        end
    end

    # Override graph context with WITH iri for apply
    apply_ctx = if op.with_iri !== nothing
        _SpEvalCtx(ctx.dataset, _sp_upd_get_or_create_named(ctx, op.with_iri),
                   ctx.base, Dict{String, BlankNode}(), Dict{String, BlankNode}(),
                   ctx.load_datasets)
    else
        ctx
    end

    _sp_upd_apply_quads_with_ctx!(apply_ctx, to_delete, :delete)
    _sp_upd_apply_quads_with_ctx!(apply_ctx, to_insert, :add)
end

# Apply quads, where graph_iri=nothing means "active graph" (not always default)
function _sp_upd_apply_quads_with_ctx!(ctx::_SpEvalCtx, quads::Vector{Pair{Union{String, Nothing}, Vector{Triple}}}, mode::Symbol)
    for (graph_iri, triples) in quads
        g = if graph_iri === nothing
            ctx.active_graph
        else
            _sp_upd_get_or_create_named(ctx, graph_iri::String)
        end
        for t in triples
            if mode === :add
                push!(g, t)
            else
                delete!(g, t)
            end
        end
    end
end

# ── LOAD ──────────────────────────────────────────────────────────────────────

function _sp_execute_update_op!(op::SpLoad, ctx::_SpEvalCtx)
    # LOAD is a network operation; we don't implement it for now.
    # SILENT suppresses errors.
    op.silent || error("SPARQL LOAD is not supported in this implementation")
end

# ── CLEAR ─────────────────────────────────────────────────────────────────────

function _sp_execute_update_op!(op::SpClear, ctx::_SpEvalCtx)
    _sp_upd_clear_ref!(ctx, op.target, op.silent)
end

function _sp_upd_clear_ref!(ctx::_SpEvalCtx, ref::SpGraphRef, silent::Bool)
    ds = ctx.dataset
    if ref isa SpGraphRefDefault
        _sp_clear_graph!(ds.default_graph)
    elseif ref isa SpGraphRefIRI
        key = IRI(ref.iri)
        if haskey(ds, key)
            _sp_clear_graph!(ds[key])
        elseif !silent
            error("Named graph <$(ref.iri)> does not exist")
        end
    elseif ref isa SpGraphRefAll
        _sp_clear_graph!(ds.default_graph)
        for g in values(ds.named_graphs); _sp_clear_graph!(g); end
    elseif ref isa SpGraphRefNamed
        for g in values(ds.named_graphs); _sp_clear_graph!(g); end
    end
end

function _sp_clear_graph!(g::Graph)
    triples = collect(g)
    for t in triples
        delete!(g, t)
    end
end

# ── DROP ──────────────────────────────────────────────────────────────────────

function _sp_execute_update_op!(op::SpDrop, ctx::_SpEvalCtx)
    ds = ctx.dataset
    if op.target isa SpGraphRefDefault
        _sp_clear_graph!(ds.default_graph)
    elseif op.target isa SpGraphRefIRI
        key = IRI(op.target.iri)
        if haskey(ds, key)
            delete!(ds.named_graphs, key)
        elseif !op.silent
            error("Named graph <$(op.target.iri)> does not exist")
        end
    elseif op.target isa SpGraphRefAll
        _sp_clear_graph!(ds.default_graph)
        empty!(ds.named_graphs)
    elseif op.target isa SpGraphRefNamed
        empty!(ds.named_graphs)
    end
end

# ── CREATE ────────────────────────────────────────────────────────────────────

function _sp_execute_update_op!(op::SpCreate, ctx::_SpEvalCtx)
    key = IRI(op.iri)
    if haskey(ctx.dataset, key)
        op.silent || error("Named graph <$(op.iri)> already exists")
    else
        ctx.dataset[key] = Graph()
    end
end

# ── ADD ───────────────────────────────────────────────────────────────────────

function _sp_execute_update_op!(op::SpAdd, ctx::_SpEvalCtx)
    src = _sp_upd_resolve_single_graph(ctx, op.src, op.silent; create=false)
    dst = _sp_upd_resolve_single_graph(ctx, op.dst, op.silent; create=true)
    (src === nothing || dst === nothing) && return
    src === dst && return  # adding to self is a no-op
    for t in collect(src)
        push!(dst, t)
    end
end

# ── MOVE ──────────────────────────────────────────────────────────────────────

function _sp_execute_update_op!(op::SpMove, ctx::_SpEvalCtx)
    src = _sp_upd_resolve_single_graph(ctx, op.src, op.silent; create=false)
    dst = _sp_upd_resolve_single_graph(ctx, op.dst, op.silent; create=true)
    (src === nothing || dst === nothing) && return
    src === dst && return
    _sp_clear_graph!(dst)
    for t in collect(src)
        push!(dst, t)
    end
    _sp_clear_graph!(src)
    # Also remove src named graph if it was a named graph (not default)
    _sp_upd_maybe_drop_ref!(ctx, op.src)
    # Also create dst named graph if it was a named graph
    _sp_upd_maybe_register_ref!(ctx, op.dst, dst)
end

# ── COPY ──────────────────────────────────────────────────────────────────────

function _sp_execute_update_op!(op::SpCopy, ctx::_SpEvalCtx)
    src = _sp_upd_resolve_single_graph(ctx, op.src, op.silent; create=false)
    dst = _sp_upd_resolve_single_graph(ctx, op.dst, op.silent; create=true)
    (src === nothing || dst === nothing) && return
    src === dst && return
    _sp_clear_graph!(dst)
    for t in collect(src)
        push!(dst, t)
    end
end

# ── Graph management helpers ──────────────────────────────────────────────────

# Resolve a SpGraphRef to a single Graph (default or specific named).
# When create=true, creates the named graph if it does not exist (for ADD/COPY/MOVE destinations).
# Returns nothing on error (with SILENT); errors otherwise.
function _sp_upd_resolve_single_graph(ctx::_SpEvalCtx, ref::SpGraphRef, silent::Bool;
                                       create::Bool=false)::Union{Graph, Nothing}
    if ref isa SpGraphRefDefault
        return ctx.dataset.default_graph
    elseif ref isa SpGraphRefIRI
        key = IRI(ref.iri)
        if haskey(ctx.dataset, key)
            return ctx.dataset[key]
        elseif create
            g = Graph()
            ctx.dataset[key] = g
            return g
        elseif silent
            return nothing
        else
            error("Named graph <$(ref.iri)> does not exist")
        end
    else
        silent || error("ADD/MOVE/COPY requires specific graph references (DEFAULT or named IRI)")
        return nothing
    end
end

function _sp_upd_maybe_drop_ref!(ctx::_SpEvalCtx, ref::SpGraphRef)
    if ref isa SpGraphRefIRI
        key = IRI(ref.iri)
        haskey(ctx.dataset, key) && delete!(ctx.dataset.named_graphs, key)
    end
end

function _sp_upd_maybe_register_ref!(ctx::_SpEvalCtx, ref::SpGraphRef, g::Graph)
    if ref isa SpGraphRefIRI
        key = IRI(ref.iri)
        !haskey(ctx.dataset, key) && (ctx.dataset[key] = g)
    end
end

# ── Top-level update executor ─────────────────────────────────────────────────

function _sp_execute_update!(unit::SpUpdateUnit, ctx::_SpEvalCtx)
    for op in unit.ops
        _sp_execute_update_op!(op, ctx)
    end
end
