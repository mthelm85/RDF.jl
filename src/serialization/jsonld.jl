"""
JSON-LD 1.1 serialization and deserialization for RDF graphs and datasets.

Supports:
- `Base.read(io, MIME"application/ld+json"(), Graph)` — parse JSON-LD into a Graph
- `Base.read(io, MIME"application/ld+json"(), Dataset)` — parse JSON-LD into a Dataset
- `Base.write(io, MIME"application/ld+json"(), g::Graph; context=nothing)` — serialize Graph
- `Base.write(io, MIME"application/ld+json"(), ds::Dataset; context=nothing)` — serialize Dataset

Remote context loading is not supported. Inline contexts only.
"""

const _MIME_JSONLD = MIME"application/ld+json"

# ── Common IRI string constants ───────────────────────────────────────────────

const _JRDF_TYPE         = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
const _JRDF_FIRST        = "http://www.w3.org/1999/02/22-rdf-syntax-ns#first"
const _JRDF_REST         = "http://www.w3.org/1999/02/22-rdf-syntax-ns#rest"
const _JRDF_NIL          = "http://www.w3.org/1999/02/22-rdf-syntax-ns#nil"
const _JRDF_JSON         = "http://www.w3.org/1999/02/22-rdf-syntax-ns#JSON"
const _JXSD_STRING_S     = "http://www.w3.org/2001/XMLSchema#string"
const _JXSD_INTEGER_S    = "http://www.w3.org/2001/XMLSchema#integer"
const _JXSD_DOUBLE_S     = "http://www.w3.org/2001/XMLSchema#double"
const _JXSD_BOOLEAN_S    = "http://www.w3.org/2001/XMLSchema#boolean"

# JSON-LD keywords (all start with @)
const _JSONLD_KEYWORDS = Set{String}([
    "@base", "@container", "@context", "@default", "@direction", "@embed",
    "@explicit", "@first", "@from", "@graph", "@id", "@import", "@included",
    "@index", "@json", "@language", "@list", "@nest", "@none", "@omitDefault",
    "@prefix", "@preserve", "@protected", "@requireAll", "@reverse", "@set",
    "@type", "@value", "@version", "@vocab",
])

# ── Context ───────────────────────────────────────────────────────────────────

mutable struct _JsonLDContext
    base::Union{String,Nothing}
    vocab::Union{String,Nothing}
    language::Union{String,Nothing}
    # term name → term definition (String shorthand or Dict with @id etc.)
    terms::Dict{String,Any}
    # resolves a (resolved, absolute) context IRI → context value, or nothing.
    # Preserved across context resets so nested/remote contexts can be loaded.
    loader::Any
end

_JsonLDContext(loader=nothing) = _JsonLDContext(nothing, nothing, nothing, Dict{String,Any}(), loader)

function _copy_ctx(ctx::_JsonLDContext)::_JsonLDContext
    _JsonLDContext(ctx.base, ctx.vocab, ctx.language, copy(ctx.terms), ctx.loader)
end

# ── IRI expansion ─────────────────────────────────────────────────────────────

"""
    _expand_iri(ctx, value; vocab, base) -> Union{String,Nothing}

Expand a potentially compact IRI or term name to a full absolute IRI.
"""
function _expand_iri(ctx::_JsonLDContext, value::String;
                     vocab::Bool=false, base::Bool=false)::Union{String,Nothing}
    isempty(value) && return nothing

    # Keywords pass through unchanged
    value in _JSONLD_KEYWORDS && return value

    # Check if value is a defined term
    if haskey(ctx.terms, value)
        td = ctx.terms[value]
        td === nothing && return nothing
        mapped = _term_def_id(td)
        mapped === nothing && return nothing
        # Avoid infinite recursion
        if mapped != value
            return _expand_iri(ctx, mapped; vocab=vocab, base=base)
        end
        return mapped
    end

    # If value contains ':', try prefix expansion
    colon_idx = findfirst(':', value)
    if colon_idx !== nothing
        prefix = value[1:colon_idx-1]
        rest   = value[colon_idx+1:end]

        # _: signals a blank node identifier
        prefix == "_" && return value

        # Check if prefix is a known term/prefix in the context
        if haskey(ctx.terms, prefix)
            td = ctx.terms[prefix]
            if td !== nothing
                mapped = _term_def_id(td)
                if mapped !== nothing
                    # Expand rest as well (recursive)
                    return mapped * rest
                end
            end
        end

        # If it looks like an absolute IRI scheme → already absolute
        if occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", value)
            return value
        end
    end

    # Use vocab for bare terms (predicates, types)
    if vocab && ctx.vocab !== nothing
        return ctx.vocab * value
    end

    # Resolve against base IRI
    if base && ctx.base !== nothing
        return _resolve_iri(ctx.base, value)
    end

    value
end

# Extract the @id string from a term definition
function _term_def_id(td)::Union{String,Nothing}
    td isa AbstractString && return String(td)
    if td isa AbstractDict
        raw = get(td, "@id", nothing)
        raw === nothing && return nothing
        return String(raw)
    end
    nothing
end

# Minimal RFC 3986 §5.2 IRI resolution: resolve ref against base
function _resolve_iri(base::String, ref::String)::String
    isempty(ref) && return base

    # If ref has a scheme, it is absolute
    occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", ref) && return ref

    # Handle // authority-relative
    if startswith(ref, "//")
        m = match(r"^([A-Za-z][A-Za-z0-9+\-.]*):", base)
        m !== nothing && return String(m.captures[1]) * ":" * ref
        return ref
    end

    # Fragment-only
    if startswith(ref, "#")
        hash_i = findfirst('#', base)
        base_no_frag = hash_i !== nothing ? base[1:hash_i-1] : base
        return base_no_frag * ref
    end

    # Query-relative
    if startswith(ref, "?")
        qm_i = findfirst('?', base)
        frag_i = findfirst('#', base)
        cut = length(base)
        qm_i !== nothing && (cut = min(cut, qm_i - 1))
        frag_i !== nothing && (cut = min(cut, frag_i - 1))
        return base[1:cut] * ref
    end

    # Path-absolute
    if startswith(ref, "/")
        m = match(r"^([A-Za-z][A-Za-z0-9+\-.]*://[^/]*)", base)
        authority = m !== nothing ? String(m.captures[1]) : ""
        return _jsonld_remove_dot_segments(authority * ref)
    end

    # Relative path — merge with base directory
    qm_i = findfirst('?', base)
    frag_i = findfirst('#', base)
    cut = length(base)
    qm_i !== nothing && (cut = min(cut, qm_i - 1))
    frag_i !== nothing && (cut = min(cut, frag_i - 1))
    base_path = base[1:cut]
    last_slash = findlast('/', base_path)
    base_dir = last_slash !== nothing ? base_path[1:last_slash] : ""
    _jsonld_remove_dot_segments(base_dir * ref)
end

function _jsonld_remove_dot_segments(path::String)::String
    # RFC 3986 §5.2.4
    input = path
    output = ""
    while !isempty(input)
        if startswith(input, "../")
            input = input[4:end]
        elseif startswith(input, "./")
            input = input[3:end]
        elseif startswith(input, "/./")
            input = "/" * input[4:end]
        elseif input == "/."
            input = "/"
        elseif startswith(input, "/../")
            input = "/" * input[5:end]
            slash = findlast('/', output)
            output = slash !== nothing ? output[1:slash-1] : ""
        elseif input == "/.."
            input = "/"
            slash = findlast('/', output)
            output = slash !== nothing ? output[1:slash-1] : ""
        elseif input == "." || input == ".."
            input = ""
        else
            seg_start = startswith(input, "/") ? 2 : 1
            next_slash = findnext('/', input, seg_start)
            seg_end = next_slash !== nothing ? next_slash - 1 : length(input)
            output *= input[1:seg_end]
            input = input[seg_end+1:end]
        end
    end
    output
end

# ── Context processing ────────────────────────────────────────────────────────

"""
    _process_context(ctx, raw_ctx) -> _JsonLDContext

Process a raw JSON-LD @context value (null, string, object, or array) and
return an updated context. Throws ParseError for remote context references.
"""
function _process_context(ctx::_JsonLDContext, raw_ctx)::_JsonLDContext
    # @context: null resets the context but keeps the document base and loader.
    raw_ctx === nothing && return _JsonLDContext(ctx.base, nothing, nothing,
                                                 Dict{String,Any}(), ctx.loader)

    if raw_ctx isa AbstractArray
        result = _copy_ctx(ctx)
        for entry in raw_ctx
            result = _process_context(result, entry)
        end
        return result
    end

    if raw_ctx isa AbstractString
        # A string @context is a reference to a remote context document.
        # Resolve it relative to the document base, then load it via the loader.
        sref = String(raw_ctx)
        iri = occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", sref) ? sref :
              (ctx.base !== nothing ? _resolve_iri(ctx.base, sref) : sref)
        loaded = ctx.loader === nothing ? nothing : ctx.loader(iri)
        if loaded === nothing
            throw(ParseError(
                "Remote JSON-LD context \"$iri\" could not be resolved; pass " *
                "contexts=Dict(iri => context) or load_remote_contexts=true",
                0, 0, _MIME_JSONLD()))
        end
        # Process the loaded context with the document base set to the context's
        # own IRI (so its relative term IRIs resolve correctly), loader preserved.
        sub = _JsonLDContext(iri, ctx.vocab, ctx.language, copy(ctx.terms), ctx.loader)
        sub = _process_context(sub, loaded)
        sub.base = ctx.base   # restore the document base for subsequent processing
        return sub
    end

    raw_ctx isa AbstractDict || return ctx
    result = _copy_ctx(ctx)

    # @base
    if haskey(raw_ctx, "@base")
        v = raw_ctx["@base"]
        if v === nothing
            result.base = nothing
        elseif v isa AbstractString
            sv = String(v)
            if !isempty(sv) && result.base !== nothing && !occursin(r"^[A-Za-z][A-Za-z0-9+\-.]:", sv)
                result.base = _resolve_iri(result.base, sv)
            else
                result.base = isempty(sv) ? nothing : sv
            end
        end
    end

    # @vocab
    if haskey(raw_ctx, "@vocab")
        v = raw_ctx["@vocab"]
        if v === nothing
            result.vocab = nothing
        elseif v isa AbstractString
            sv = String(v)
            expanded = _expand_iri(result, sv; vocab=true, base=false)
            result.vocab = (expanded !== nothing && expanded != sv) ? expanded : sv
        end
    end

    # @language
    if haskey(raw_ctx, "@language")
        v = raw_ctx["@language"]
        if v === nothing
            result.language = nothing
        elseif v isa AbstractString
            result.language = lowercase(String(v))
        end
    end

    # Term definitions
    for (k, v) in raw_ctx
        sk = String(k)
        sk in ("@base", "@vocab", "@language", "@version") && continue
        startswith(sk, "@") && continue

        if v === nothing
            result.terms[sk] = nothing
            continue
        end

        if v isa AbstractString
            sv = String(v)
            expanded = _expand_iri(result, sv; vocab=true, base=false)
            result.terms[sk] = (expanded !== nothing && expanded != sv) ? expanded : sv
            continue
        end

        if v isa AbstractDict
            td = Dict{String,Any}()
            if haskey(v, "@id")
                vid = v["@id"]
                if vid === nothing
                    td["@id"] = nothing
                elseif vid isa AbstractString
                    sv = String(vid)
                    expanded = _expand_iri(result, sv; vocab=true, base=false)
                    td["@id"] = (expanded !== nothing && expanded != sv) ? expanded : sv
                end
            else
                # Default @id: expand the term name itself
                expanded = _expand_iri(result, sk; vocab=true, base=false)
                td["@id"] = (expanded !== nothing) ? expanded : sk
            end
            if haskey(v, "@type")
                tv = v["@type"]
                td["@type"] = tv isa AbstractString ? String(tv) : tv
            end
            if haskey(v, "@container")
                # @container may be a single keyword or an array of keywords
                # (e.g. ["@language", "@set"]) in JSON-LD 1.1.
                cv = v["@container"]
                td["@container"] = cv isa AbstractString ? String(cv) :
                                   cv isa AbstractArray  ? String[String(x) for x in cv] : cv
            end
            if haskey(v, "@reverse")
                rv = v["@reverse"]
                td["@reverse"] = rv isa AbstractString ? String(rv) : rv
            end
            if haskey(v, "@language")
                lv = v["@language"]
                td["@language"] = lv === nothing ? nothing : lowercase(String(lv))
            end
            result.terms[sk] = td
        end
    end

    result
end

# ── JSON-LD expansion ─────────────────────────────────────────────────────────

"""
    _expand_document(doc, ctx) -> Vector{Any}

Expand a JSON-LD document to its canonical expanded form (absolute IRIs only).
"""
function _expand_document(doc, ctx::_JsonLDContext)::Vector{Any}
    result = _expand_value(doc, ctx)
    result === nothing && return Any[]
    result isa AbstractArray && return Any[x for x in result if x !== nothing]
    Any[result]
end

function _expand_value(doc, ctx::_JsonLDContext)
    doc === nothing && return nothing

    if doc isa AbstractArray
        out = Any[]
        for item in doc
            v = _expand_value(item, ctx)
            if v isa AbstractArray
                append!(out, v)
            elseif v !== nothing
                push!(out, v)
            end
        end
        return out
    end

    if doc isa Bool
        return Dict{String,Any}("@value" => doc, "@type" => _JXSD_BOOLEAN_S)
    end

    if doc isa Integer
        return Dict{String,Any}("@value" => doc, "@type" => _JXSD_INTEGER_S)
    end

    if doc isa AbstractFloat || doc isa Number
        return Dict{String,Any}("@value" => Float64(doc), "@type" => _JXSD_DOUBLE_S)
    end

    if doc isa AbstractString
        return Dict{String,Any}("@value" => String(doc), "@type" => _JXSD_STRING_S)
    end

    doc isa AbstractDict || return nothing

    # Normalise to a concrete Dict{String,Any}
    d = Dict{String,Any}(String(k) => v for (k, v) in doc)

    # Process @context first so it affects the current node
    if haskey(d, "@context")
        ctx = _process_context(ctx, d["@context"])
    end

    # Resolve keyword aliases: a term whose definition is a keyword (e.g.
    # "uri": "@id") makes that term an alias for the keyword.  Rename such keys
    # so the keyword-based handling below sees them.
    if any(k -> (kw = _kw_alias(ctx, k); kw !== nothing && kw != k), keys(d))
        nd = Dict{String,Any}()
        for (k, v) in d
            kw = _kw_alias(ctx, k)
            nd[kw === nothing ? k : kw] = v
        end
        d = nd
    end

    # Value object
    haskey(d, "@value") && return _expand_value_object(d, ctx)

    # List object
    if haskey(d, "@list")
        return Dict{String,Any}("@list" => _expand_list_values(d["@list"], ctx))
    end

    # Set object
    haskey(d, "@set") && return _expand_value(d["@set"], ctx)

    # Node object
    _expand_node(d, ctx)
end

# The keyword a key denotes, accounting for aliases (term → keyword); nothing
# if the key is an ordinary term/IRI.
function _kw_alias(ctx::_JsonLDContext, key::AbstractString)
    (startswith(key, "@") && key in _JSONLD_KEYWORDS) && return String(key)
    td = get(ctx.terms, String(key), nothing)
    td isa AbstractString && startswith(td, "@") && td in _JSONLD_KEYWORDS && return String(td)
    nothing
end

# The @container keywords declared for a term definition, as a vector.
function _container_of(td)::Vector{String}
    (td isa AbstractDict && haskey(td, "@container")) || return String[]
    c = td["@container"]
    c isa AbstractString ? String[String(c)] :
    c isa AbstractArray  ? String[String(x) for x in c] : String[]
end

function _expand_value_object(d::Dict{String,Any}, ctx::_JsonLDContext)
    val = d["@value"]
    # A null @value expands to nothing (the value is dropped entirely).
    val === nothing && return nothing
    result = Dict{String,Any}("@value" => val)
    if haskey(d, "@type")
        dt = String(d["@type"])
        if dt == "@json"
            result["@type"] = "@json"
        else
            expanded_dt = _expand_iri(ctx, dt; vocab=true, base=false)
            result["@type"] = expanded_dt !== nothing ? expanded_dt : dt
        end
    elseif haskey(d, "@language")
        lv = d["@language"]
        lv !== nothing && (result["@language"] = lowercase(String(lv)))
        haskey(d, "@direction") && (result["@direction"] = String(d["@direction"]))
    elseif haskey(d, "@direction")
        result["@direction"] = String(d["@direction"])
    end
    result
end

function _expand_list_values(list_val, ctx::_JsonLDContext)::Vector{Any}
    list_val === nothing && return Any[]
    if !(list_val isa AbstractArray)
        v = _expand_value(list_val, ctx)
        return v !== nothing ? Any[v] : Any[]
    end
    out = Any[]
    for item in list_val
        v = _expand_value(item, ctx)
        v !== nothing && push!(out, v)
    end
    out
end

function _expand_node(d::Dict{String,Any}, ctx::_JsonLDContext)
    node = Dict{String,Any}()

    # @id
    if haskey(d, "@id")
        raw_id = d["@id"]
        if raw_id isa AbstractString
            expanded_id = _expand_iri(ctx, String(raw_id); vocab=false, base=true)
            expanded_id !== nothing && (node["@id"] = expanded_id)
        end
    end

    # @type
    if haskey(d, "@type")
        types = d["@type"]
        types_arr = types isa AbstractArray ? collect(types) : Any[types]
        expanded_types = String[]
        for t in types_arr
            t isa AbstractString || continue
            et = _expand_iri(ctx, String(t); vocab=true, base=false)
            et !== nothing && push!(expanded_types, et)
        end
        isempty(expanded_types) || (node["@type"] = expanded_types)
    end

    # @graph
    if haskey(d, "@graph")
        node["@graph"] = _expand_document(d["@graph"], ctx)
    end

    # @reverse
    if haskey(d, "@reverse")
        rev = d["@reverse"]
        if rev isa AbstractDict
            rev_map = Dict{String,Any}()
            for (k, v) in rev
                sk = String(k)
                expanded_pred = _expand_iri(ctx, sk; vocab=true, base=false)
                expanded_pred === nothing && continue
                expanded_pred in _JSONLD_KEYWORDS && continue
                !occursin(':', expanded_pred) && continue
                expanded_vals = _expand_property_values(v, expanded_pred, ctx)
                isempty(expanded_vals) || (rev_map[expanded_pred] = expanded_vals)
            end
            isempty(rev_map) || (node["@reverse"] = rev_map)
        end
    end

    # Other properties
    for (k, v) in d
        k in ("@context", "@id", "@type", "@graph", "@reverse") && continue
        startswith(k, "@") && continue

        expanded_pred = _expand_iri(ctx, k; vocab=true, base=false)
        expanded_pred === nothing && continue
        expanded_pred in _JSONLD_KEYWORDS && continue
        !occursin(':', expanded_pred) && continue

        # @container coercion (driven by the *term*, not the IRI).
        tdk = get(ctx.terms, k, nothing)
        container = _container_of(tdk)

        expanded_vals = if tdk isa AbstractDict && get(tdk, "@type", nothing) == "@json"
            # @json coercion: the entire value is a single JSON literal.
            Any[Dict{String,Any}("@value" => v, "@type" => "@json")]
        elseif "@language" in container && v isa AbstractDict
            # Language map: { lang => value(s) } → language-tagged literals.
            out = Any[]
            for (lang, lv) in v
                ls = lowercase(String(lang))
                for item in (lv isa AbstractArray ? collect(lv) : Any[lv])
                    item === nothing && continue
                    vo = Dict{String,Any}("@value" => String(item))
                    ls == "@none" || (vo["@language"] = ls)
                    push!(out, vo)
                end
            end
            out
        elseif ("@index" in container) && v isa AbstractDict
            # Index map: { index => value(s) } → values expanded, index dropped.
            out = Any[]
            for (_, iv) in v
                append!(out, _expand_property_values(iv, expanded_pred, ctx))
            end
            out
        else
            _expand_property_values(v, expanded_pred, ctx)
        end

        if "@list" in container
            # Values under a @list-container term form a single list — unless
            # they are already list objects (avoid double-wrapping).
            if !any(x -> x isa AbstractDict && haskey(x, "@list"), expanded_vals)
                expanded_vals = Any[Dict{String,Any}("@list" => expanded_vals)]
            end
        end
        # "@set" container: values stay a plain array (the default) — no-op.

        isempty(expanded_vals) && continue
        if haskey(node, expanded_pred)
            append!(node[expanded_pred]::Vector{Any}, expanded_vals)
        else
            node[expanded_pred] = expanded_vals
        end
    end

    # Return nothing for empty expansion (no @id, no properties, no @graph)
    isempty(node) && return nothing
    node
end

function _expand_property_values(v, pred::String, ctx::_JsonLDContext)::Vector{Any}
    vals = v isa AbstractArray ? collect(v) : Any[v]
    out = Any[]
    for val in vals
        expanded = _expand_property_value(val, pred, ctx)
        # A value may expand to an array (e.g. a @set, or a nested array) — those
        # are flattened into the property's value list rather than nested.
        if expanded isa AbstractArray
            append!(out, expanded)
        elseif expanded !== nothing
            push!(out, expanded)
        end
    end
    out
end

function _expand_property_value(val, pred::String, ctx::_JsonLDContext)
    # Look up term definition for this predicate (for @type coercion)
    term_def = _find_term_def_by_id(ctx, pred)

    if val isa AbstractDict
        return _expand_value(val, ctx)
    end

    if val isa AbstractString
        sv = String(val)

        # @type coercion from term definition
        if term_def !== nothing && term_def isa AbstractDict && haskey(term_def, "@type")
            coerce = String(term_def["@type"])
            if coerce == "@id"
                expanded = _expand_iri(ctx, sv; vocab=false, base=true)
                return Dict{String,Any}("@id" => (expanded !== nothing ? expanded : sv))
            elseif coerce == "@vocab"
                expanded = _expand_iri(ctx, sv; vocab=true, base=false)
                return Dict{String,Any}("@id" => (expanded !== nothing ? expanded : sv))
            else
                expanded_dt = _expand_iri(ctx, coerce; vocab=true, base=false)
                dt = expanded_dt !== nothing ? expanded_dt : coerce
                return Dict{String,Any}("@value" => sv, "@type" => dt)
            end
        end

        # @language from term definition
        if term_def !== nothing && term_def isa AbstractDict && haskey(term_def, "@language")
            lang = term_def["@language"]
            if lang === nothing
                return Dict{String,Any}("@value" => sv, "@type" => _JXSD_STRING_S)
            else
                return Dict{String,Any}("@value" => sv, "@language" => lowercase(String(lang)))
            end
        end

        # Default language from context
        if ctx.language !== nothing
            return Dict{String,Any}("@value" => sv, "@language" => ctx.language)
        end

        return Dict{String,Any}("@value" => sv, "@type" => _JXSD_STRING_S)
    end

    if val isa Bool
        return Dict{String,Any}("@value" => val, "@type" => _JXSD_BOOLEAN_S)
    end

    if val isa Integer
        return Dict{String,Any}("@value" => val, "@type" => _JXSD_INTEGER_S)
    end

    if val isa AbstractFloat || val isa Number
        return Dict{String,Any}("@value" => Float64(val), "@type" => _JXSD_DOUBLE_S)
    end

    nothing
end

# Find a term definition whose @id matches the given IRI
function _find_term_def_by_id(ctx::_JsonLDContext, pred_iri::String)
    for (_, td) in ctx.terms
        td === nothing && continue
        mapped = _term_def_id(td)
        mapped == pred_iri && return td
    end
    nothing
end

# ── RDF deserialization ───────────────────────────────────────────────────────

"""
    _jsonld_to_rdf(expanded, base) -> Dataset

Convert an expanded JSON-LD document to an RDF Dataset.
"""
function _jsonld_to_rdf(expanded::Vector{Any}, base::Union{String,Nothing})::Dataset
    ds = Dataset()
    blank_map = Dict{String,BlankNode}()
    for node in expanded
        node isa AbstractDict || continue
        _process_node!(ds.default_graph, node, ds, blank_map)
    end
    ds
end

function _bnode_for_label(blank_map::Dict{String,BlankNode}, label::String)::BlankNode
    get!(blank_map, label) do
        _mint_blank_node()
    end
end

function _id_to_term(id_str::String, blank_map::Dict{String,BlankNode})::Union{IRI,BlankNode,Nothing}
    isempty(id_str) && return nothing
    if startswith(id_str, "_:")
        label = id_str[3:end]
        isempty(label) && return nothing
        return _bnode_for_label(blank_map, label)
    end
    try
        IRI(id_str)
    catch
        nothing
    end
end

function _process_node!(graph::Graph, node::AbstractDict, ds::Dataset, blank_map::Dict{String,BlankNode})
    d = Dict{String,Any}(String(k) => v for (k, v) in node)

    # Handle @graph → named graph
    if haskey(d, "@graph")
        graph_name = if haskey(d, "@id")
            _id_to_term(String(d["@id"]), blank_map)
        else
            nothing
        end

        subgraph = Graph()
        sub_nodes = d["@graph"]
        sub_nodes isa AbstractArray || (sub_nodes = Any[sub_nodes])
        for sn in sub_nodes
            sn isa AbstractDict || continue
            _process_node!(subgraph, sn, ds, blank_map)
        end

        if graph_name !== nothing
            ds[graph_name] = subgraph
        else
            for t in subgraph
                push!(graph, t)
            end
        end
        return
    end

    # Determine subject
    subj = if haskey(d, "@id")
        s = _id_to_term(String(d["@id"]), blank_map)
        s === nothing && return
        s
    else
        _mint_blank_node()
    end

    # @type → rdf:type triples
    if haskey(d, "@type")
        types = d["@type"]
        types isa AbstractArray || (types = Any[types])
        for t in types
            t isa AbstractString || continue
            obj = _id_to_term(String(t), blank_map)
            obj isa IRI || continue
            push!(graph, Triple(subj, IRI(_JRDF_TYPE), obj))
        end
    end

    # Properties
    for (pred_str, values) in d
        pred_str in ("@id", "@type", "@graph", "@reverse") && continue
        startswith(pred_str, "@") && continue
        occursin(':', pred_str) || continue

        pred_iri = try
            IRI(pred_str)
        catch
            continue
        end

        values isa AbstractArray || (values = Any[values])
        for vo in values
            obj = _val_to_rdf(vo, graph, ds, blank_map)
            obj === nothing && continue
            push!(graph, Triple(subj, pred_iri, obj))
        end
    end

    # @reverse
    if haskey(d, "@reverse")
        rev = d["@reverse"]
        rev isa AbstractDict || return
        for (pred_str, values) in rev
            occursin(':', pred_str) || continue
            pred_iri = try IRI(pred_str) catch; continue end
            values isa AbstractArray || (values = Any[values])
            for vo in values
                vo isa AbstractDict || continue
                vo_d = Dict{String,Any}(String(k) => v for (k, v) in vo)
                rev_subj = if haskey(vo_d, "@id")
                    _id_to_term(String(vo_d["@id"]), blank_map)
                else
                    nothing
                end
                rev_subj isa Union{IRI,BlankNode} || continue
                push!(graph, Triple(rev_subj, pred_iri, subj))
            end
        end
    end
end

function _val_to_rdf(vo, graph::Graph, ds::Dataset, blank_map::Dict{String,BlankNode})::Union{IRI,BlankNode,Literal,Nothing}
    vo isa AbstractDict || return nothing
    d = Dict{String,Any}(String(k) => v for (k, v) in vo)

    # @list → RDF list (linked blank node chain)
    if haskey(d, "@list")
        items = d["@list"]
        items isa AbstractArray || (items = Any[items])
        return _build_rdf_list(items, graph, ds, blank_map)
    end

    # @id reference (IRI or blank node)
    if haskey(d, "@id") && length(d) == 1
        return _id_to_term(String(d["@id"]), blank_map)
    end

    # Nested node object that has @id plus properties
    if haskey(d, "@id") && !haskey(d, "@value")
        subj = _id_to_term(String(d["@id"]), blank_map)
        subj === nothing && return nothing
        _process_node!(graph, d, ds, blank_map)
        return subj
    end

    # Value object with @value
    if haskey(d, "@value")
        raw_val = d["@value"]
        dtype   = get(d, "@type", nothing)
        lang    = get(d, "@language", nothing)
        dir     = get(d, "@direction", nothing)

        if lang !== nothing
            lang_s = lowercase(String(lang))
            if dir !== nothing
                dir_s = lowercase(String(dir))
                dir_s in ("ltr", "rtl") || return nothing
                return Literal(string(raw_val), _RDF_DIR_LANGSTRING, "$lang_s--$dir_s")
            end
            return Literal(string(raw_val); lang=lang_s)
        end

        if dtype == "@json"
            return Literal(_json_canonical(raw_val), IRI(_JRDF_JSON))
        end

        if dtype !== nothing
            dt_s = String(dtype)
            lex  = _jsonld_raw_to_lexical(raw_val, dt_s)
            dt_iri = try IRI(dt_s) catch; return nothing end
            if dt_iri == _RDF_LANGSTRING || dt_iri == _RDF_DIR_LANGSTRING
                return nothing  # lang string without a language tag is invalid
            end
            return Literal(lex, dt_iri)
        end

        # No type, no language → plain value converted by Julia type
        if raw_val isa Bool
            return Literal(raw_val ? "true" : "false", _XSD_BOOLEAN)
        elseif raw_val isa Integer
            return Literal(string(raw_val), _XSD_INTEGER)
        elseif raw_val isa AbstractFloat || raw_val isa Number
            return Literal(_double_lexical(Float64(raw_val)), _XSD_DOUBLE)
        else
            return Literal(string(raw_val))
        end
    end

    # Anonymous node object
    if any(k -> occursin(':', k) || startswith(k, "@"), keys(d))
        bnode = _mint_blank_node()
        # Inject a synthetic @id so _process_node! can use it
        d_with_id = copy(d)
        d_with_id["@id"] = "_:anon_$(bnode.id)"
        blank_map["anon_$(bnode.id)"] = bnode
        _process_node!(graph, d_with_id, ds, blank_map)
        return bnode
    end

    nothing
end

# Canonical JSON (RFC 8785 / JCS subset) for rdf:JSON literals: object keys
# sorted by code point, no insignificant whitespace, JSON-escaped strings.
function _json_canonical(v)::String
    v === nothing && return "null"
    v isa Bool    && return v ? "true" : "false"
    v isa Integer && return string(v)
    if v isa Real
        f = Float64(v)
        return isinteger(f) ? string(Integer(f)) : string(f)
    end
    v isa AbstractString && return JSON3.write(String(v))
    if v isa AbstractArray
        return "[" * join((_json_canonical(x) for x in v), ",") * "]"
    end
    if v isa AbstractDict || v isa JSON3.Object
        ks = sort!(String[String(k) for k in keys(v)])
        return "{" * join((JSON3.write(k) * ":" * _json_canonical(v[Symbol(k)]) for k in ks), ",") * "}"
    end
    "null"
end

function _jsonld_raw_to_lexical(raw, dtype::String)::String
    if raw isa Bool
        return raw ? "true" : "false"
    end
    if raw isa Integer
        dtype == _JXSD_DOUBLE_S && return _double_lexical(Float64(raw))
        return string(raw)
    end
    if raw isa AbstractFloat || raw isa Number
        f = Float64(raw)
        dtype == _JXSD_DOUBLE_S && return _double_lexical(f)
        return string(f)
    end
    string(raw)
end

function _build_rdf_list(items::AbstractArray, graph::Graph, ds::Dataset, blank_map::Dict{String,BlankNode})::Union{IRI,BlankNode}
    isempty(items) && return IRI(_JRDF_NIL)
    head   = _mint_blank_node()
    current = head
    n = length(items)
    for (i, item) in enumerate(items)
        obj = _val_to_rdf(item, graph, ds, blank_map)
        if obj === nothing
            # Still need to advance the list node
            push!(graph, Triple(current, IRI(_JRDF_FIRST), Literal("")))
        else
            push!(graph, Triple(current, IRI(_JRDF_FIRST), obj))
        end
        if i < n
            next_node = _mint_blank_node()
            push!(graph, Triple(current, IRI(_JRDF_REST), next_node))
            current = next_node
        else
            push!(graph, Triple(current, IRI(_JRDF_REST), IRI(_JRDF_NIL)))
        end
    end
    head
end

# ── Read ──────────────────────────────────────────────────────────────────────

"""
    Base.read(io::IO, ::MIME"application/ld+json", ::Type{Graph}) -> Graph

Parse a JSON-LD document from `io` and return all triples as a single Graph
(named graphs are merged into the default graph).
"""
# Transport hook for remote JSON-LD context loading, installed by RDFHTTPExt
# when HTTP.jl is loaded.  iri::String -> context value (the remote document's
# @context) or nothing.  Keeps the core HTTP-free.
const _JSONLD_REMOTE_LOADER = Ref{Any}(nothing)

# Build a context loader from the `contexts` map/callable and the
# `load_remote_contexts` flag.  Returns iri -> context value | nothing.
function _build_jsonld_loader(contexts, load_remote::Bool)
    base_loader = if contexts isa AbstractDict
        iri -> get(contexts, String(iri), nothing)
    elseif contexts !== nothing
        contexts                       # assume callable
    else
        _ -> nothing
    end
    load_remote || return base_loader
    function (iri)
        v = base_loader(iri)
        v !== nothing && return v
        f = _JSONLD_REMOTE_LOADER[]
        f === nothing && throw(ParseError(
            "load_remote_contexts=true requires HTTP.jl: run `using HTTP`",
            0, 0, _MIME_JSONLD()))
        f(iri)
    end
end

function Base.read(io::IO, ::_MIME_JSONLD, ::Type{Graph};
                   base::Union{AbstractString,Nothing}=nothing,
                   contexts=nothing, load_remote_contexts::Bool=false)::Graph
    ds = Base.read(io, _MIME_JSONLD(), Dataset; base=base,
                   contexts=contexts, load_remote_contexts=load_remote_contexts)
    g = ds.default_graph
    for (_, ng) in ds.named_graphs
        for t in ng
            push!(g, t)
        end
    end
    g
end

"""
    Base.read(io::IO, ::MIME"application/ld+json", ::Type{Dataset}) -> Dataset

Parse a JSON-LD document from `io` and return a Dataset (preserving named graphs).
"""
function Base.read(io::IO, ::_MIME_JSONLD, ::Type{Dataset};
                   base::Union{AbstractString,Nothing}=nothing,
                   contexts=nothing, load_remote_contexts::Bool=false)::Dataset
    # Parse from the raw bytes, not a String: JSON3.read(::String) treats a
    # short/path-like string as a filename and stats it (which aborts on some
    # high-Unicode content via libuv on Windows).
    bytes = Base.read(io)
    doc  = try
        JSON3.read(bytes)
    catch e
        throw(ParseError("Invalid JSON: $e", 0, 0, _MIME_JSONLD()))
    end
    ctx      = _JsonLDContext(_build_jsonld_loader(contexts, load_remote_contexts))
    base !== nothing && (ctx.base = String(base))
    expanded = _expand_document(doc, ctx)
    _jsonld_to_rdf(expanded, ctx.base)
end

# ── Write ─────────────────────────────────────────────────────────────────────

_jbn_label(bn::BlankNode) = "_:b$(bn.id)"

function _object_to_jsonld_obj(obj::IRI)
    Dict{String,Any}("@id" => obj.value)
end

function _object_to_jsonld_obj(obj::BlankNode)
    Dict{String,Any}("@id" => _jbn_label(obj))
end

function _object_to_jsonld_obj(obj::Literal)
    dt = obj.datatype.value
    if !isempty(obj.language_tag)
        dd = findfirst("--", obj.language_tag)
        if dd !== nothing
            lang = obj.language_tag[1:first(dd)-1]
            dir  = obj.language_tag[last(dd)+1:end]
            return Dict{String,Any}("@value" => obj.lexical_form,
                                    "@language" => lang,
                                    "@direction" => dir)
        end
        return Dict{String,Any}("@value" => obj.lexical_form, "@language" => obj.language_tag)
    end
    dt == _JXSD_STRING_S && return Dict{String,Any}("@value" => obj.lexical_form)
    Dict{String,Any}("@value" => obj.lexical_form, "@type" => dt)
end

function _object_to_jsonld_obj(obj::TripleTerm)
    # TripleTerm has no standard JSON-LD representation; omit (return nothing)
    nothing
end

"""
    Base.write(io::IO, ::MIME"application/ld+json", g::Graph; context=nothing, indent::Int=2)

Serialize an RDF `Graph` to JSON-LD format. If `context` is provided (a `Dict`
or `String`), it is included as `"@context"` in the root object.
"""
function Base.write(io::IO, ::_MIME_JSONLD, g::Graph; context=nothing, indent::Int=2)
    nodes  = _graph_to_jsonld(g)
    output = if context !== nothing
        Dict{String,Any}("@context" => context, "@graph" => nodes)
    else
        nodes
    end
    print(io, JSON3.write(output))
    nothing
end

"""
    Base.write(io::IO, ::MIME"application/ld+json", ds::Dataset; context=nothing, indent::Int=2)

Serialize an RDF `Dataset` to JSON-LD format. Named graphs are represented with
`"@graph"` entries; the default graph's triples appear at the top level.
"""
function Base.write(io::IO, ::_MIME_JSONLD, ds::Dataset; context=nothing, indent::Int=2)
    top = Any[]

    if !isempty(ds.default_graph)
        for n in _graph_to_jsonld(ds.default_graph)
            push!(top, n)
        end
    end

    for (name, ng) in ds.named_graphs
        graph_id = name isa IRI ? name.value : _jbn_label(name)
        named_entry = Dict{String,Any}(
            "@id"    => graph_id,
            "@graph" => _graph_to_jsonld(ng),
        )
        push!(top, named_entry)
    end

    output = if context !== nothing
        Dict{String,Any}("@context" => context, "@graph" => top)
    else
        top
    end
    print(io, JSON3.write(output))
    nothing
end

function _graph_to_jsonld(g::Graph)::Vector{Any}
    # subject key → (subject-id-string, predicate-iri → [object nodes])
    subject_ids    = String[]
    subject_preds  = Dict{String, Dict{String,Vector{Any}}}()

    for triple in g
        s_key = triple.subject isa IRI ? triple.subject.value : _jbn_label(triple.subject)

        if !haskey(subject_preds, s_key)
            push!(subject_ids, s_key)
            subject_preds[s_key] = Dict{String,Vector{Any}}()
        end
        pred_map = subject_preds[s_key]
        pred_iri = triple.predicate.value

        if pred_iri == _JRDF_TYPE && triple.object isa IRI
            vals = get!(pred_map, "@type") do; Any[] end
            push!(vals, triple.object.value)
        else
            obj_node = _object_to_jsonld_obj(triple.object)
            obj_node === nothing && continue
            vals = get!(pred_map, pred_iri) do; Any[] end
            push!(vals, obj_node)
        end
    end

    nodes = Any[]
    for s_key in subject_ids
        pred_map = subject_preds[s_key]
        node = Dict{String,Any}("@id" => s_key)
        for (pred, vals) in pred_map
            node[pred] = vals
        end
        push!(nodes, node)
    end
    nodes
end

# File extension dispatch (.jsonld, .json-ld) is handled in ntriples.jl's
# rdf_read / rdf_write functions, which were updated to delegate to this MIME type.
