# ── Schema introspection for text-to-SPARQL ───────────────────────────────────
#
# describe_schema(g) summarizes a graph's *actual* shape — the classes and
# predicates present in the data, their domains/ranges, cardinality, and example
# values — and to_prompt renders that summary as compact text for an LLM system
# prompt.  Together they let a model author correct SPARQL against a graph it
# cannot otherwise see.  Everything is derived from the data itself (no ontology
# is required), which is what makes it work on the messy, partially-typed graphs
# that LLM extraction produces.

"""
    ClassInfo

A class discovered in a graph (an object of `rdf:type`): its `iri`, the number
of distinct instances (`count`), and `rdfs:label` / `rdfs:comment` when present.
"""
struct ClassInfo
    iri::IRI
    count::Int
    label::Union{String, Nothing}
    comment::Union{String, Nothing}
end

"""
    PredicateInfo

A predicate discovered in a graph, with the shape information an LLM needs to
use it in a query:

- `iri`, `count` — the predicate and how many triples use it
- `subject_classes` — `rdf:type`s of its subjects (domain), most frequent first
- `datatypes` — datatypes of its literal objects (range, for data properties)
- `object_classes` — `rdf:type`s of its IRI/blank-node objects (range, for
  object properties), most frequent first
- `examples` — a few representative object values
- `max_per_subject` — the largest number of distinct values any single subject
  has (`1` ⇒ effectively single-valued; `>1` ⇒ multi-valued)
- `label`, `comment` — `rdfs:label` / `rdfs:comment` of the predicate, if present
"""
struct PredicateInfo
    iri::IRI
    count::Int
    subject_classes::Vector{IRI}
    datatypes::Vector{IRI}
    object_classes::Vector{IRI}
    examples::Vector{ObjectTerm}
    max_per_subject::Int
    label::Union{String, Nothing}
    comment::Union{String, Nothing}
end

"""
    SchemaSummary

The result of [`describe_schema`](@ref): `classes` and `predicates` (each sorted
by usage, most frequent first) plus the total `ntriples`.  Render it for a
prompt with [`to_prompt`](@ref).
"""
struct SchemaSummary
    classes::Vector{ClassInfo}
    predicates::Vector{PredicateInfo}
    ntriples::Int
end

# First literal lexical form for (subj_id, pred_id), or nothing.
function _schema_text(g::Graph, subj_id::UInt32, pred_id::UInt32)::Union{String, Nothing}
    pred_id == 0 && return nothing
    for (_, _, o) in _match_ids(g, subj_id, pred_id, nothing)
        t = _resolve(o)
        t isa Literal && return t.lexical_form
    end
    nothing
end

# Interned-ID class counts → IRIs, descending count, ties by IRI string.
function _by_count_desc(counts::Dict{UInt32, Int})::Vector{IRI}
    ids = collect(keys(counts))
    sort!(ids; by = id -> (-counts[id], (_resolve(id)::IRI).value))
    IRI[_resolve(id)::IRI for id in ids]
end

# Same, for IRI-keyed counts (datatype IRIs are not necessarily interned as
# standalone terms, so they are accumulated by value rather than by ID).
function _by_count_desc(counts::Dict{IRI, Int})::Vector{IRI}
    iris = collect(keys(counts))
    sort!(iris; by = iri -> (-counts[iri], iri.value))
    iris
end

# Per-predicate accumulator (keyed by interned IDs during the scan).
mutable struct _PredAcc
    count::Int
    subj_classes::Dict{UInt32, Int}
    datatypes::Dict{IRI, Int}          # datatype IRI → count (by value)
    obj_classes::Dict{UInt32, Int}
    examples::Vector{UInt32}           # distinct object ids, in encounter order
    example_set::Set{UInt32}
    max_per_subject::Int
end
_PredAcc() = _PredAcc(0, Dict{UInt32,Int}(), Dict{IRI,Int}(), Dict{UInt32,Int}(),
                      UInt32[], Set{UInt32}(), 0)

"""
    describe_schema(g::Graph; max_examples=3) -> SchemaSummary

Introspect the structure of `g` from its data: the classes (objects of
`rdf:type`) and predicates present, each predicate's domain (subject classes),
range (literal datatypes and/or object classes), cardinality, up to
`max_examples` example object values, and any `rdfs:label` / `rdfs:comment`.

```julia
s = describe_schema(g)
prompt = "Schema:\\n" * to_prompt(s; prefixes=Dict("ex" => "http://example.org/")) *
         "\\n\\nWrite a SPARQL query that …"
```

See also [`to_prompt`](@ref).
"""
function describe_schema(g::Graph; max_examples::Int=3)::SchemaSummary
    type_id    = term_id(rdf.type)
    label_id   = term_id(rdfs.label)
    comment_id = term_id(rdfs.comment)

    # Pass 1 — type assertions: subject → its class ids, and per-class instances.
    subj_types     = Dict{UInt32, Vector{UInt32}}()
    class_subjects = Dict{UInt32, Set{UInt32}}()
    if type_id != 0
        for (s, _, o) in _match_ids(g, nothing, type_id, nothing)
            push!(get!(subj_types, s, UInt32[]), o)
            push!(get!(class_subjects, o, Set{UInt32}()), s)
        end
    end

    # Pass 2 — every non-rdf:type triple, in SPO order so that triples sharing
    # a (subject, predicate) are contiguous (used for the cardinality count).
    accs    = Dict{UInt32, _PredAcc}()
    prev_s  = UInt32(0); prev_p = UInt32(0); run = 0
    finish_run!() = begin
        if prev_p != 0 && prev_p != type_id
            a = accs[prev_p]
            run > a.max_per_subject && (a.max_per_subject = run)
        end
    end
    for (s, p, o) in eachid(g)
        p == type_id && continue
        a = get!(accs, p, _PredAcc())
        a.count += 1
        # domain
        if haskey(subj_types, s)
            for c in subj_types[s]
                a.subj_classes[c] = get(a.subj_classes, c, 0) + 1
            end
        end
        # range: literal → datatype; IRI/bnode → its classes
        ot = _resolve(o)
        if ot isa Literal
            dt = ot.datatype
            a.datatypes[dt] = get(a.datatypes, dt, 0) + 1
        elseif haskey(subj_types, o)
            for c in subj_types[o]
                a.obj_classes[c] = get(a.obj_classes, c, 0) + 1
            end
        end
        # examples (distinct objects, encounter order)
        if length(a.examples) < max_examples && !(o in a.example_set)
            push!(a.examples, o); push!(a.example_set, o)
        end
        # cardinality via contiguous (s, p) runs
        if s == prev_s && p == prev_p
            run += 1
        else
            finish_run!()
            prev_s = s; prev_p = p; run = 1
        end
    end
    finish_run!()

    # ── Build ClassInfo list ────────────────────────────────────────────────
    classes = ClassInfo[]
    for (cid, subs) in class_subjects
        iri = _resolve(cid)::IRI
        push!(classes, ClassInfo(iri, length(subs),
                                 _schema_text(g, cid, label_id),
                                 _schema_text(g, cid, comment_id)))
    end
    sort!(classes; by = c -> (-c.count, c.iri.value))

    # ── Build PredicateInfo list ────────────────────────────────────────────
    predicates = PredicateInfo[]
    for (pid, a) in accs
        iri = _resolve(pid)::IRI
        push!(predicates, PredicateInfo(
            iri, a.count,
            _by_count_desc(a.subj_classes),
            _by_count_desc(a.datatypes),
            _by_count_desc(a.obj_classes),
            ObjectTerm[_resolve(o) for o in a.examples],
            a.max_per_subject,
            _schema_text(g, pid, label_id),
            _schema_text(g, pid, comment_id)))
    end
    sort!(predicates; by = p -> (-p.count, p.iri.value))

    SchemaSummary(classes, predicates, length(g))
end

# ── Prompt rendering ───────────────────────────────────────────────────────────

# Compact an IRI to prefix:local when a declared prefix matches; else <iri>.
function _schema_compact(iri::IRI, prefixes::Dict{String,String})::String
    v = iri.value
    for (pre, base) in prefixes
        if startswith(v, base) && length(v) > length(base)
            return pre * ":" * v[nextind(v, length(base)):end]
        end
    end
    "<" * v * ">"
end

function _schema_render_term(t::ObjectTerm, prefixes::Dict{String,String})::String
    t isa IRI       && return _schema_compact(t, prefixes)
    t isa BlankNode && return "[]"
    t isa Literal   && return sprint(show, t)   # quoted, with @lang / ^^type
    sprint(show, t)
end

"""
    to_prompt(s::SchemaSummary; budget=nothing, prefixes=Dict()) -> String

Render a [`SchemaSummary`](@ref) as compact, deterministic text for an LLM
system prompt: a `# Classes` section (name, instance count, label) and a
`# Properties` section (name, count, domain → range, cardinality, examples,
label).

`prefixes` (prefix → IRI base) compacts IRIs to `prefix:local` and is strongly
recommended. `budget` is an approximate token budget (≈ 4 bytes/token); when
set, the most-used classes and predicates are kept first and the output is
guaranteed not to exceed `4 × budget` bytes.

```julia
to_prompt(describe_schema(g); budget=1500,
          prefixes=Dict("ex" => "http://example.org/",
                        "foaf" => "http://xmlns.com/foaf/0.1/"))
```
"""
function to_prompt(s::SchemaSummary;
                   budget::Union{Int, Nothing}=nothing,
                   prefixes::Dict{String,String}=Dict{String,String}())::String
    (isempty(s.classes) && isempty(s.predicates)) && return ""
    lines = String[]

    if !isempty(s.classes)
        push!(lines, "# Classes")
        for c in s.classes
            line = _schema_compact(c.iri, prefixes) * " ($(c.count))"
            c.label !== nothing && (line *= " — " * c.label)
            push!(lines, line)
        end
    end

    if !isempty(s.predicates)
        !isempty(lines) && push!(lines, "")
        push!(lines, "# Properties")
        for p in s.predicates
            dom = isempty(p.subject_classes) ? "?" :
                  join((_schema_compact(c, prefixes) for c in p.subject_classes), "|")
            rng_parts = String[]
            append!(rng_parts, (_schema_compact(c, prefixes) for c in p.object_classes))
            append!(rng_parts, (_schema_compact(d, prefixes) for d in p.datatypes))
            rng = isempty(rng_parts) ? "?" : join(rng_parts, "|")
            card = p.max_per_subject > 1 ? ", multi" : ""
            line = _schema_compact(p.iri, prefixes) * " ($(p.count)$card): " *
                   dom * " → " * rng
            p.label !== nothing && (line *= "  [" * p.label * "]")
            if !isempty(p.examples)
                line *= "  e.g. " *
                    join((_schema_render_term(e, prefixes) for e in p.examples), ", ")
            end
            push!(lines, line)
        end
    end

    budget === nothing && return join(lines, "\n")

    # Greedy: keep whole lines in order until the byte budget is reached.
    char_budget = 4 * budget
    out = IOBuffer(); n = 0
    for (i, line) in enumerate(lines)
        add = ncodeunits(line) + (i == 1 ? 0 : 1)   # +1 for the joining newline
        n + add > char_budget && break
        i > 1 && write(out, '\n')
        write(out, line); n += add
    end
    String(take!(out))
end
