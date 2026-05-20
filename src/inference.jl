# RDFS forward-chaining materialization

const _RDFS_ALL_RULES = [:subClassOf, :subPropertyOf, :domain, :range, :type_propagation]

function infer_rdfs(g::Graph; rules::Vector{Symbol}=_RDFS_ALL_RULES)::Graph
    result = Graph()
    for t in g; push!(result, t); end
    infer_rdfs!(result; rules=rules)
    result
end

function infer_rdfs!(g::Graph; rules::Vector{Symbol}=_RDFS_ALL_RULES)
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
    rule === :type_propagation && return false
    false
end

# rdfs2: ?x rdf:type ?C  if  ?x ?p ?y  and  ?p rdfs:domain ?C
function _rule_domain!(g::Graph)::Bool
    changed = false
    domains = _collect_pairs(g, _RDFS_DOMAIN)
    for t in collect(g)
        prop = t.predicate
        haskey(domains, prop) || continue
        for cls in domains[prop]
            cls isa IRI || continue
            new_t = Triple(t.subject, _RDF_TYPE, cls::IRI)
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
            cls isa IRI || continue
            new_t = Triple(obj, _RDF_TYPE, cls::IRI)
            new_t ∉ g && (push!(g, new_t); changed = true)
        end
    end
    changed
end

# rdfs9: ?x rdf:type ?D  if  ?x rdf:type ?C  and  ?C rdfs:subClassOf ?D
# rdfs11: ?C rdfs:subClassOf ?E  if  ?C rdfs:subClassOf ?D  and  ?D rdfs:subClassOf ?E
# rdfs10: ?C rdfs:subClassOf ?C  (reflexivity for classes appearing in subClassOf triples)
function _rule_subclassof!(g::Graph)::Bool
    changed = false
    subclass = _collect_pairs(g, _RDFS_SUBCLASSOF)  # child → Set{parent}

    # rdfs11: transitive closure of subClassOf itself
    for (child, parents) in subclass
        for parent in copy(parents)
            parent isa IRI || continue
            haskey(subclass, parent::IRI) || continue
            for grandparent in subclass[parent::IRI]
                grandparent isa IRI || continue
                new_t = Triple(child, _RDFS_SUBCLASSOF, grandparent::IRI)
                new_t ∉ g && (push!(g, new_t); changed = true)
            end
        end
    end

    # rdfs10: every class appearing in a subClassOf triple is a subclass of itself
    for (child, parents) in subclass
        new_t = Triple(child, _RDFS_SUBCLASSOF, child)
        new_t ∉ g && (push!(g, new_t); changed = true)
        for parent in parents
            parent isa IRI || continue
            new_t = Triple(parent::IRI, _RDFS_SUBCLASSOF, parent)
            new_t ∉ g && (push!(g, new_t); changed = true)
        end
    end

    # rdfs9: type propagation via subClassOf
    for t in collect(g)
        t.predicate == _RDF_TYPE || continue
        cls = t.object
        cls isa IRI || continue
        haskey(subclass, cls::IRI) || continue
        for sup in subclass[cls::IRI]
            sup isa IRI || continue
            new_t = Triple(t.subject, _RDF_TYPE, sup::IRI)
            new_t ∉ g && (push!(g, new_t); changed = true)
        end
    end

    changed
end

# rdfs7: ?x ?q ?y  if  ?x ?p ?y  and  ?p rdfs:subPropertyOf ?q
# rdfs5: ?p rdfs:subPropertyOf ?r  if  ?p rdfs:subPropertyOf ?q  and  ?q rdfs:subPropertyOf ?r
function _rule_subpropertyof!(g::Graph)::Bool
    changed = false
    subprop = _collect_pairs(g, _RDFS_SUBPROPERTYOF)  # child → Set{parent}

    # rdfs5: transitive closure of subPropertyOf itself
    for (child, parents) in subprop
        for parent in copy(parents)
            parent isa IRI || continue
            haskey(subprop, parent::IRI) || continue
            for grandparent in subprop[parent::IRI]
                grandparent isa IRI || continue
                new_t = Triple(child, _RDFS_SUBPROPERTYOF, grandparent::IRI)
                new_t ∉ g && (push!(g, new_t); changed = true)
            end
        end
    end

    # rdfs7: property substitution for data triples
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
    if regime === :simple
        return t ∈ g
    end
    regime === :rdfs || error("Unknown regime: $regime (use OWL.jl for OWL regimes)")
    t ∈ g && return true
    closed = infer_rdfs(g)
    t ∈ closed
end

# IRI constants for inference rules
const _RDF_TYPE           = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
const _RDFS_SUBCLASSOF    = IRI("http://www.w3.org/2000/01/rdf-schema#subClassOf")
const _RDFS_SUBPROPERTYOF = IRI("http://www.w3.org/2000/01/rdf-schema#subPropertyOf")
const _RDFS_DOMAIN        = IRI("http://www.w3.org/2000/01/rdf-schema#domain")
const _RDFS_RANGE         = IRI("http://www.w3.org/2000/01/rdf-schema#range")
