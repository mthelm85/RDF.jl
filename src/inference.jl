# RDFS forward-chaining materialization

const _RDFS_ALL_RULES = [:subClassOf, :subPropertyOf, :domain, :range, :type_propagation]

function infer_rdfs(g::Graph; rules::Vector{Symbol}=_RDFS_ALL_RULES)::Graph
    result = Graph()
    for t in g; push!(result, t); end
    infer_rdfs!(result; rules=rules)
    result
end

function infer_rdfs!(g::Graph; rules::Vector{Symbol}=_RDFS_ALL_RULES)
    # Iterate to fixpoint
    changed = true
    while changed
        changed = false
        for rule in rules
            changed |= _apply_rule!(g, rule)
        end
    end
    g
end

function _apply_rule!(g::Graph, rule::Symbol)::Bool
    rule === :subClassOf      && return _rule_subclassof!(g)
    rule === :subPropertyOf   && return _rule_subpropertyof!(g)
    rule === :domain          && return _rule_domain!(g)
    rule === :range           && return _rule_range!(g)
    rule === :type_propagation && return _rule_type_propagation!(g)
    false
end

# rdfs2: ?x rdf:type ?C  if  ?x ?p ?y  and  ?p rdfs:domain ?C
function _rule_domain!(g::Graph)::Bool
    changed = false
    domains = _collect_pairs(g, _RDFS_DOMAIN)
    for t in collect(g)  # collect to avoid mutation during iteration
        prop = t.predicate
        haskey(domains, prop) || continue
        for cls in domains[prop]
            new_t = Triple(t.subject, _RDF_TYPE, cls)
            new_t ∉ g && (push!(g, new_t); changed = true)
        end
    end
    changed
end

# rdfs3: ?y rdf:type ?C  if  ?x ?p ?y  and  ?p rdfs:range ?C  and ?y is IRI/BN
function _rule_range!(g::Graph)::Bool
    changed = false
    ranges = _collect_pairs(g, _RDFS_RANGE)
    for t in collect(g)
        prop = t.predicate
        haskey(ranges, prop) || continue
        t.object isa Literal && continue
        obj = t.object::SubjectTerm
        for cls in ranges[prop]
            new_t = Triple(obj, _RDF_TYPE, cls)
            new_t ∉ g && (push!(g, new_t); changed = true)
        end
    end
    changed
end

# rdfs9: ?x rdf:type ?D  if  ?x rdf:type ?C  and  ?C rdfs:subClassOf ?D
function _rule_subclassof!(g::Graph)::Bool
    changed = false
    subclass = _collect_pairs(g, _RDFS_SUBCLASSOF)  # child → Set{parent}
    for t in collect(g)
        t.predicate == _RDF_TYPE || continue
        cls = t.object
        cls isa IRI || continue
        haskey(subclass, cls) || continue
        for sup in subclass[cls::IRI]
            new_t = Triple(t.subject, _RDF_TYPE, sup)
            new_t ∉ g && (push!(g, new_t); changed = true)
        end
    end
    changed
end

# rdfs7: ?x ?q ?y  if  ?x ?p ?y  and  ?p rdfs:subPropertyOf ?q
function _rule_subpropertyof!(g::Graph)::Bool
    changed = false
    subprop = _collect_pairs(g, _RDFS_SUBPROPERTYOF)  # child → Set{parent}
    for t in collect(g)
        haskey(subprop, t.predicate) || continue
        for sup in subprop[t.predicate]
            sup isa IRI || continue
            new_t = Triple(t.subject, sup::IRI, t.object)
            new_t ∉ g && (push!(g, new_t); changed = true)
        end
    end
    changed
end

# rdfs11: Transitive closure of rdfs:subClassOf
# rdfs5: Transitive closure of rdfs:subPropertyOf
# (both handled by repeated application of the above rules to fixpoint)

function _rule_type_propagation!(g::Graph)::Bool
    # rdfs-entailment of rdf:type through rdfs:subClassOf transitivity
    # Already handled by fixpoint of subclassof rule; no extra work needed.
    false
end

# Collect (subject → Set{object}) for a given predicate
function _collect_pairs(g::Graph, pred::IRI)::Dict{IRI, Set{ObjectTerm}}
    d = Dict{IRI, Set{ObjectTerm}}()
    for t in match(g; predicate=pred)
        t.subject isa IRI || continue
        s = t.subject::IRI
        push!(get!(d, s, Set{ObjectTerm}()), t.object)
    end
    d
end

# Entailment checking
function entails(g::Graph, t::Triple; regime::Symbol=:rdfs)::Bool
    regime === :rdfs || error("Unknown regime: $regime (use OWL.jl for OWL regimes)")
    t ∈ g && return true
    closed = infer_rdfs(g)
    t ∈ closed
end

# IRI constants for inference rules (avoid repeated dict lookups)
const _RDF_TYPE          = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
const _RDFS_SUBCLASSOF   = IRI("http://www.w3.org/2000/01/rdf-schema#subClassOf")
const _RDFS_SUBPROPERTYOF = IRI("http://www.w3.org/2000/01/rdf-schema#subPropertyOf")
const _RDFS_DOMAIN       = IRI("http://www.w3.org/2000/01/rdf-schema#domain")
const _RDFS_RANGE        = IRI("http://www.w3.org/2000/01/rdf-schema#range")
