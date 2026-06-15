# ── SHACL core validation ──────────────────────────────────────────────────────
#
# A W3C SHACL Core engine: validate a data graph against a shapes graph and
# produce a sh:ValidationReport.  Implements the core constraint components,
# targets, and property paths (the SPARQL-based extension is out of scope).
#
# Reference: https://www.w3.org/TR/shacl/
#
# The AI framing (see docs): SHACL is the standard mechanism for guardrailing
# LLM-extracted triples — validate before committing, and feed the report back
# to the model for self-correction (see to_prompt(::ValidationReport)).

const _SH       = "http://www.w3.org/ns/shacl#"
const _RDF_NS_  = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
const _RDFS_NS_ = "http://www.w3.org/2000/01/rdf-schema#"
const _XSD_NS_  = "http://www.w3.org/2001/XMLSchema#"

@inline _sh(local_name::String) = IRI(_SH * local_name)

const _SH_RDF_TYPE       = IRI(_RDF_NS_ * "type")
const _SH_RDF_FIRST      = IRI(_RDF_NS_ * "first")
const _SH_RDF_REST       = IRI(_RDF_NS_ * "rest")
const _SH_RDF_NIL        = IRI(_RDF_NS_ * "nil")
const _SH_RDFS_SUBCLASS  = IRI(_RDFS_NS_ * "subClassOf")
const _SH_RDFS_CLASS     = IRI(_RDFS_NS_ * "Class")

# ── Public result types ─────────────────────────────────────────────────────────

"""
    ValidationResult

A single SHACL violation: the `focus_node` that failed, the `path` of the
property shape (or `nothing` for a node shape), the offending `value` (or
`nothing` for cardinality/closed constraints), the `source_shape`, the
`component` (the `sh:…ConstraintComponent` IRI), the `severity`, and a
human-readable `message`.
"""
struct ValidationResult
    focus_node::RDFTerm
    path::Union{RDFTerm, Nothing}      # the shape's path node (IRI or blank-node path expr)
    value::Union{RDFTerm, Nothing}
    source_shape::Union{RDFTerm, Nothing}
    component::IRI
    severity::IRI
    message::String
end

"""
    ValidationReport

The result of [`validate_shapes`](@ref): `conforms` (true iff there are no
`sh:Violation` results) and the list of `results`.
"""
struct ValidationReport
    conforms::Bool
    results::Vector{ValidationResult}
end

Base.show(io::IO, r::ValidationReport) =
    print(io, "ValidationReport(conforms=", r.conforms, ", ",
          length(r.results), " result", length(r.results) == 1 ? "" : "s", ")")

# ── Shapes-graph reading helpers ────────────────────────────────────────────────

_sh_objects(g::Graph, s, p::IRI) = ObjectTerm[t.object for t in match(g; subject=s, predicate=p)]

function _sh_one(g::Graph, s, p::IRI)
    for t in match(g; subject=s, predicate=p)
        return t.object
    end
    nothing
end

_sh_has(g::Graph, s, p::IRI, o) = !isempty(collect(match(g; subject=s, predicate=p, object=o)))

# Read an RDF collection (rdf:first/rest list) headed at `node`.
function _sh_list(g::Graph, node)::Vector{RDFTerm}
    out = RDFTerm[]
    cur = node
    while cur isa SubjectTerm && cur != _SH_RDF_NIL
        f = _sh_one(g, cur, _SH_RDF_FIRST)
        f === nothing && break
        push!(out, f)
        cur = _sh_one(g, cur, _SH_RDF_REST)
        cur === nothing && break
    end
    out
end

# ── Property paths ──────────────────────────────────────────────────────────────

# Value nodes reachable from `focus` via `path` (an IRI predicate, or a blank
# node describing inverse/sequence/alternative/cardinality paths).
function _sh_path_values(g::Graph, focus::RDFTerm, path)::Vector{RDFTerm}
    if path isa IRI
        return focus isa SubjectTerm ?
            ObjectTerm[t.object for t in match(g; subject=focus, predicate=path)] : RDFTerm[]
    end
    # Blank-node path descriptions
    inv = _sh_one(g, path, _sh("inversePath"))
    if inv !== nothing
        return RDFTerm[t.subject for t in match(g; predicate=_sh_as_pred(inv), object=focus)]
    end
    alt = _sh_one(g, path, _sh("alternativePath"))
    if alt !== nothing
        out = RDFTerm[]
        for sub in _sh_list(g, alt); union!(out, _sh_path_values(g, focus, sub)); end
        return out
    end
    zom = _sh_one(g, path, _sh("zeroOrMorePath"))
    zom !== nothing && return _sh_closure(g, focus, zom, true)
    oom = _sh_one(g, path, _sh("oneOrMorePath"))
    oom !== nothing && return _sh_closure(g, focus, oom, false)
    zoo = _sh_one(g, path, _sh("zeroOrOnePath"))
    if zoo !== nothing
        out = RDFTerm[focus]
        union!(out, _sh_path_values(g, focus, zoo))
        return out
    end
    # Otherwise: a sequence path (an rdf:List of path elements)
    seq = _sh_list(g, path)
    if !isempty(seq)
        frontier = RDFTerm[focus]
        for elem in seq
            nxt = RDFTerm[]
            for f in frontier; union!(nxt, _sh_path_values(g, f, elem)); end
            frontier = nxt
        end
        return frontier
    end
    RDFTerm[]
end

# A predicate position may be an IRI directly.
_sh_as_pred(p) = p isa IRI ? p : p

# Transitive (optionally reflexive) closure of a path.
function _sh_closure(g::Graph, focus::RDFTerm, sub_path, reflexive::Bool)::Vector{RDFTerm}
    seen = Set{RDFTerm}()
    reflexive && push!(seen, focus)
    frontier = _sh_path_values(g, focus, sub_path)
    while !isempty(frontier)
        nxt = RDFTerm[]
        for v in frontier
            v in seen && continue
            push!(seen, v)
            append!(nxt, _sh_path_values(g, v, sub_path))
        end
        frontier = nxt
    end
    collect(seen)
end

# ── Subclass / type helpers ─────────────────────────────────────────────────────

# Does `node` have rdf:type that is `cls` or a (transitive) subclass of `cls`?
function _sh_is_instance(g::Graph, node::RDFTerm, cls::RDFTerm)::Bool
    node isa SubjectTerm || return false
    for t in match(g; subject=node, predicate=_SH_RDF_TYPE)
        _sh_subclass_of(g, t.object, cls) && return true
    end
    false
end

function _sh_subclass_of(g::Graph, sub::RDFTerm, sup::RDFTerm)::Bool
    sub == sup && return true
    seen = Set{RDFTerm}([sub]); frontier = RDFTerm[sub]
    while !isempty(frontier)
        nxt = RDFTerm[]
        for c in frontier, t in match(g; subject=c, predicate=_SH_RDFS_SUBCLASS)
            t.object == sup && return true
            if !(t.object in seen); push!(seen, t.object); push!(nxt, t.object); end
        end
        frontier = nxt
    end
    false
end

# ── Datatype well-formedness ────────────────────────────────────────────────────

const _SH_KNOWN_XSD = Set{String}([
    _XSD_NS_ .* ("integer","decimal","double","float","boolean","date","dateTime",
                 "int","long","short","byte","nonNegativeInteger","positiveInteger",
                 "nonPositiveInteger","negativeInteger","unsignedInt","unsignedLong",
                 "unsignedShort","unsignedByte")...
])

function _sh_lexical_ok(lit::Literal)::Bool
    dt = lit.datatype.value
    dt in _SH_KNOWN_XSD || return true   # unknown datatype → assume well-formed
    tryvalue(lit) !== nothing
end

# ── Constraint context ──────────────────────────────────────────────────────────

mutable struct _ShCtx
    data::Graph
    shapes::Graph
    results::Vector{ValidationResult}
end

# Severity declared on a shape (default sh:Violation).
function _sh_severity(ctx::_ShCtx, shape)::IRI
    s = _sh_one(ctx.shapes, shape, _sh("severity"))
    s isa IRI ? s : _sh("Violation")
end

function _sh_report!(ctx::_ShCtx, shape, focus, path, value, component::IRI;
                     message::String="")
    push!(ctx.results, ValidationResult(focus, path, value, shape, component,
                                        _sh_severity(ctx, shape), message))
end

# ── Public API ──────────────────────────────────────────────────────────────────

"""
    validate_shapes(data::Graph, shapes::Graph) -> ValidationReport

Validate `data` against the SHACL shapes in `shapes` (the two may be the same
graph).  Returns a [`ValidationReport`](@ref).

```julia
report = validate_shapes(data, shapes)
report.conforms || for r in report.results
    println(r.focus_node, " — ", r.message)
end
```

Implements SHACL Core: node and property shapes; the `targetNode`,
`targetClass`, `targetSubjectsOf`, `targetObjectsOf`, and implicit-class
targets; predicate / inverse / sequence / alternative / zeroOrMore /
oneOrMore / zeroOrOne paths; and the core constraint components (value type,
cardinality, value range, string, property-pair, logical, shape-based,
`sh:closed`, `sh:hasValue`, `sh:in`).  See also [`conforms`](@ref).
"""
function validate_shapes(data::Graph, shapes::Graph)::ValidationReport
    ctx = _ShCtx(data, shapes, ValidationResult[])
    for shape in _sh_all_shapes_with_targets(shapes)
        _sh_truthy(shapes, shape, _sh("deactivated")) && continue
        for focus in _sh_target_nodes(ctx, shape)
            _sh_validate(ctx, shape, focus)
        end
    end
    # SHACL: a data graph conforms iff there are no validation results at all
    # (any severity — sh:Info / sh:Warning results also make conforms false).
    ValidationReport(isempty(ctx.results), ctx.results)
end

"""
    conforms(data::Graph, shapes::Graph) -> Bool

True iff `data` has no `sh:Violation` results against `shapes`.  Convenience
wrapper over [`validate_shapes`](@ref).
"""
conforms(data::Graph, shapes::Graph)::Bool = validate_shapes(data, shapes).conforms

_sh_truthy(g, s, p::IRI) = (o = _sh_one(g, s, p); o isa Literal && o.lexical_form == "true")

# Shapes that carry at least one target declaration (the validation roots).
function _sh_all_shapes_with_targets(shapes::Graph)
    roots = Set{RDFTerm}()
    for p in (_sh("targetNode"), _sh("targetClass"),
              _sh("targetSubjectsOf"), _sh("targetObjectsOf"))
        for t in match(shapes; predicate=p); push!(roots, t.subject); end
    end
    # Implicit class target: a node that is both a shape and an rdfs:Class.
    for t in match(shapes; predicate=_SH_RDF_TYPE, object=_sh("NodeShape"))
        _sh_has(shapes, t.subject, _SH_RDF_TYPE, _SH_RDFS_CLASS) && push!(roots, t.subject)
    end
    for t in match(shapes; predicate=_SH_RDF_TYPE, object=_SH_RDFS_CLASS)
        (_sh_has(shapes, t.subject, _SH_RDF_TYPE, _sh("NodeShape")) ||
         _sh_has(shapes, t.subject, _SH_RDF_TYPE, _sh("PropertyShape"))) &&
            push!(roots, t.subject)
    end
    roots
end

function _sh_target_nodes(ctx::_ShCtx, shape)::Vector{RDFTerm}
    out = RDFTerm[]
    for n in _sh_objects(ctx.shapes, shape, _sh("targetNode")); push!(out, n); end
    for c in _sh_objects(ctx.shapes, shape, _sh("targetClass"))
        append!(out, _sh_instances_of(ctx.data, c))
    end
    for p in _sh_objects(ctx.shapes, shape, _sh("targetSubjectsOf"))
        p isa IRI && for t in match(ctx.data; predicate=p); push!(out, t.subject); end
    end
    for p in _sh_objects(ctx.shapes, shape, _sh("targetObjectsOf"))
        p isa IRI && for t in match(ctx.data; predicate=p); push!(out, t.object); end
    end
    # Implicit class target: the shape is itself an rdfs:Class.
    _sh_has(ctx.shapes, shape, _SH_RDF_TYPE, _SH_RDFS_CLASS) &&
        append!(out, _sh_instances_of(ctx.data, shape))
    unique(out)
end

# All nodes that are instances of `cls` or any (transitive) subclass of it.
function _sh_instances_of(data::Graph, cls::RDFTerm)::Vector{RDFTerm}
    # Sub-class closure (cls + everything rdfs:subClassOf* cls).
    classes = Set{RDFTerm}([cls]); frontier = RDFTerm[cls]
    while !isempty(frontier)
        nxt = RDFTerm[]
        for c in frontier, t in match(data; predicate=_SH_RDFS_SUBCLASS, object=c)
            if !(t.subject in classes); push!(classes, t.subject); push!(nxt, t.subject); end
        end
        frontier = nxt
    end
    out = RDFTerm[]
    for k in classes, t in match(data; predicate=_SH_RDF_TYPE, object=k)
        push!(out, t.subject)
    end
    out
end

# Validate a focus node against a shape (node or property shape).
function _sh_validate(ctx::_ShCtx, shape, focus::RDFTerm)
    _sh_truthy(ctx.shapes, shape, _sh("deactivated")) && return
    path = _sh_one(ctx.shapes, shape, _sh("path"))
    if path === nothing
        # Node shape: the focus node is the single value node.
        _sh_check_constraints(ctx, shape, focus, nothing, RDFTerm[focus])
    else
        vals = _sh_path_values(ctx.data, focus, path)
        _sh_check_constraints(ctx, shape, focus, path, vals)
    end
end

include("shacl_constraints.jl")
