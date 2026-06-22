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
const _JRDF_VALUE        = "http://www.w3.org/1999/02/22-rdf-syntax-ns#value"
const _JRDF_LANGUAGE     = "http://www.w3.org/1999/02/22-rdf-syntax-ns#language"
const _JRDF_DIRECTION    = "http://www.w3.org/1999/02/22-rdf-syntax-ns#direction"
const _I18N_BASE         = "https://www.w3.org/ns/i18n#"
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
    # names of @protected terms (cannot be redefined with a different mapping)
    protected::Set{String}
    # the context to revert to when entering a nested node object, set when a
    # non-propagating (type-scoped or @propagate:false) context is applied;
    # nothing means the active context propagates normally.
    previous::Any
    # the URL of the current context document, used to resolve relative context
    # references and @import (NOT changed by @base, which only affects data).
    docbase::Any
end

_JsonLDContext(loader=nothing) =
    _JsonLDContext(nothing, nothing, nothing, Dict{String,Any}(), loader,
                   Set{String}(), nothing, nothing)

function _copy_ctx(ctx::_JsonLDContext)::_JsonLDContext
    _JsonLDContext(ctx.base, ctx.vocab, ctx.language, copy(ctx.terms),
                   ctx.loader, copy(ctx.protected), ctx.previous, ctx.docbase)
end

# Signature of a term definition used to decide whether two definitions are the
# same (for @protected redefinition checks).
function _term_sig(t)
    t isa AbstractString && return (t, nothing, nothing, nothing, nothing, nothing)
    if t isa AbstractDict
        cs = haskey(t, "@context") ? JSON3.write(t["@context"]) : nothing
        return (get(t, "@id", nothing), get(t, "@type", nothing),
                get(t, "@container", nothing), get(t, "@reverse", nothing),
                get(t, "@language", nothing), cs)
    end
    (nothing, nothing, nothing, nothing, nothing, nothing)
end

# ── IRI expansion ─────────────────────────────────────────────────────────────

"""
    _expand_iri(ctx, value; vocab, base) -> Union{String,Nothing}

Expand a potentially compact IRI or term name to a full absolute IRI.
"""
function _expand_iri(ctx::_JsonLDContext, value::String;
                     vocab::Bool=false, base::Bool=false)::Union{String,Nothing}
    # An empty string expands to the base IRI when base resolution applies
    # (e.g. {"@id": ""} denotes the document/base IRI); otherwise it drops.
    isempty(value) && return (base && ctx.base !== nothing) ?
                              _resolve_iri(ctx.base, "") : nothing

    # Keywords pass through unchanged
    value in _JSONLD_KEYWORDS && return value

    # Check if value is a defined term. Bare-term lookup only applies in vocab
    # mode (property keys / @type); for document-relative resolution (@id) terms
    # are ignored and the value resolves against the base.
    if vocab && haskey(ctx.terms, value)
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

        # _: signals a blank node identifier; a suffix beginning with // means
        # the value is an absolute IRI, not a compact IRI — return it unchanged.
        prefix == "_" && return value
        startswith(rest, "//") && return value

        # Check if prefix is a known term/prefix in the context. A term marked
        # @prefix:false may not be used as a compact-IRI prefix.
        if haskey(ctx.terms, prefix)
            td = ctx.terms[prefix]
            if td !== nothing && !(td isa AbstractDict && get(td, "@prefix", nothing) === false)
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

# Parse an IRI into (scheme, authority, path, query, fragment) per RFC 3986
# Appendix B.  `authority` and the optional components are `nothing` when
# absent ("" means present-but-empty, e.g. file:///).
const _IRI_PARTS_RE = r"^(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$"s

function _parse_iri(iri::String)
    m = match(_IRI_PARTS_RE, iri)
    m === nothing && return (nothing, nothing, iri, nothing, nothing)
    path = m.captures[3] === nothing ? "" : String(m.captures[3])
    (m.captures[1] === nothing ? nothing : String(m.captures[1]),
     m.captures[2] === nothing ? nothing : String(m.captures[2]),
     path,
     m.captures[4] === nothing ? nothing : String(m.captures[4]),
     m.captures[5] === nothing ? nothing : String(m.captures[5]))
end

function _recompose_iri(scheme, authority, path, query, fragment)::String
    s = scheme === nothing ? "" : scheme * ":"
    authority === nothing || (s *= "//" * authority)
    s *= path
    query === nothing || (s *= "?" * query)
    fragment === nothing || (s *= "#" * fragment)
    s
end

# RFC 3986 §5.2.3 merge: combine the base path with a relative reference path.
function _merge_paths(bauth, bpath::String, refpath::String)::String
    (bauth !== nothing && isempty(bpath)) && return "/" * refpath
    i = findlast('/', bpath)
    i === nothing ? refpath : bpath[1:i] * refpath
end

# RFC 3986 §5.3 reference transformation: resolve `ref` against `base`.
function _resolve_iri(base::String, ref::String)::String
    rs, ra, rp, rq, rf = _parse_iri(ref)
    bs, ba, bp, bq, _  = _parse_iri(base)

    if rs !== nothing
        return _recompose_iri(rs, ra, _jsonld_remove_dot_segments(rp), rq, rf)
    end
    if ra !== nothing
        return _recompose_iri(bs, ra, _jsonld_remove_dot_segments(rp), rq, rf)
    end
    if isempty(rp)
        return _recompose_iri(bs, ba, bp, rq !== nothing ? rq : bq, rf)
    end
    tp = startswith(rp, "/") ? _jsonld_remove_dot_segments(rp) :
         _jsonld_remove_dot_segments(_merge_paths(ba, bp, rp))
    _recompose_iri(bs, ba, tp, rq, rf)
end

# RFC 3986 §5.2.4 remove_dot_segments, operating on a path component only.
function _jsonld_remove_dot_segments(path::String)::String
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
            j = findlast('/', output); output = j === nothing ? "" : output[1:j-1]
        elseif input == "/.."
            input = "/"
            j = findlast('/', output); output = j === nothing ? "" : output[1:j-1]
        elseif input == "." || input == ".."
            input = ""
        else
            nxt = startswith(input, "/") ? findnext('/', input, 2) : findfirst('/', input)
            if nxt === nothing
                output *= input
                input = ""
            else
                output *= input[1:prevind(input, nxt)]
                input = input[nxt:end]
            end
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
function _process_context(ctx::_JsonLDContext, raw_ctx;
                          override_protected::Bool=false,
                          propagate::Bool=true)::_JsonLDContext
    # @context: null resets the context but keeps the document base and loader.
    # Clearing the active context that has @protected terms is only allowed when
    # overriding (a term/type-scoped context); an embedded null reset fails.
    if raw_ctx === nothing
        # Clearing protected terms via null is allowed only for a propagating
        # override (a property/term-scoped context); a plain or non-propagating
        # (type-scoped) null reset over protected terms fails.
        (!override_protected || !propagate) && !isempty(ctx.protected) &&
            throw(ParseError("attempt to clear protected terms with a null context",
                             0, 0, _MIME_JSONLD()))
        # Resetting restores the document base (base option), not the overwritten
        # @base from the cleared context.
        return _JsonLDContext(ctx.docbase, nothing, nothing, Dict{String,Any}(),
                              ctx.loader, Set{String}(), propagate ? nothing : ctx, ctx.docbase)
    end

    if raw_ctx isa AbstractArray
        result = _copy_ctx(ctx)
        for entry in raw_ctx
            result = _process_context(result, entry;
                                      override_protected=override_protected, propagate=propagate)
        end
        return result
    end

    if raw_ctx isa AbstractString
        # A string @context is a reference to a remote context document, resolved
        # against the document URL (docbase) — not @base, which is data-only.
        sref = String(raw_ctx)
        rbase = ctx.docbase !== nothing ? ctx.docbase : ctx.base
        iri = occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", sref) ? sref :
              (rbase !== nothing ? _resolve_iri(rbase, sref) : sref)
        loaded = ctx.loader === nothing ? nothing : ctx.loader(iri)
        if loaded === nothing
            throw(ParseError(
                "Remote JSON-LD context \"$iri\" could not be resolved; pass " *
                "contexts=Dict(iri => context) or load_remote_contexts=true",
                0, 0, _MIME_JSONLD()))
        end
        # Process the loaded context with the document base set to the context's
        # own IRI (so its relative term IRIs resolve correctly), loader preserved.
        sub = _JsonLDContext(iri, ctx.vocab, ctx.language, copy(ctx.terms),
                             ctx.loader, copy(ctx.protected), ctx.previous, iri)
        sub = _process_context(sub, loaded;
                               override_protected=override_protected, propagate=propagate)
        sub.base = ctx.base       # restore the document base for subsequent processing
        sub.docbase = ctx.docbase
        return sub
    end

    # A local context must be a map (string/array/null handled above).
    raw_ctx isa AbstractDict ||
        throw(ParseError("invalid local context", 0, 0, _MIME_JSONLD()))

    # @import: load the referenced context and merge it under the current one
    # (the current context's entries win); then process the merged result.
    if haskey(raw_ctx, "@import")
        imp = raw_ctx["@import"]
        imp isa AbstractString ||
            throw(ParseError("@import must be a string", 0, 0, _MIME_JSONLD()))
        sref = String(imp)
        ibase = ctx.docbase !== nothing ? ctx.docbase : ctx.base
        iri = occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", sref) ? sref :
              (ibase !== nothing ? _resolve_iri(ibase, sref) : sref)
        loaded = ctx.loader === nothing ? nothing : ctx.loader(iri)
        loaded === nothing && throw(ParseError(
            "@import context \"$iri\" could not be resolved", 0, 0, _MIME_JSONLD()))
        loaded isa AbstractArray &&
            throw(ParseError("@import can only reference a single context", 0, 0, _MIME_JSONLD()))
        loaded isa AbstractDict ||
            throw(ParseError("invalid @import context", 0, 0, _MIME_JSONLD()))
        haskey(loaded, "@import") &&
            throw(ParseError("@import may not be used in an imported context", 0, 0, _MIME_JSONLD()))
        merged = Dict{String,Any}()
        for (k, v) in loaded; merged[String(k)] = v; end
        for (k, v) in raw_ctx
            String(k) == "@import" && continue
            merged[String(k)] = v
        end
        return _process_context(ctx, merged; override_protected=override_protected,
                                propagate=propagate)
    end

    result = _copy_ctx(ctx)

    # Effective propagation: a context-level @propagate overrides the inherited
    # default. A non-propagating context remembers the prior context so nested
    # node objects can revert to it.
    eff_propagate = haskey(raw_ctx, "@propagate") ? (raw_ctx["@propagate"] === true) : propagate
    result.previous = eff_propagate ? ctx.previous : ctx

    # @base
    if haskey(raw_ctx, "@base")
        v = raw_ctx["@base"]
        if v === nothing
            result.base = nothing
        elseif v isa AbstractString
            sv = String(v)
            if isempty(sv)
                # @base "" resolves to the current base (e.g. the base option).
                result.base = result.base === nothing ? nothing : _resolve_iri(result.base, "")
            elseif occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", sv)
                result.base = sv                       # absolute IRI, kept verbatim
            elseif result.base !== nothing
                result.base = _resolve_iri(result.base, sv)   # relative to current base
            else
                result.base = sv
            end
        else
            throw(ParseError("@base must be a string or null", 0, 0, _MIME_JSONLD()))
        end
    end

    # @vocab
    if haskey(raw_ctx, "@vocab")
        v = raw_ctx["@vocab"]
        if v === nothing
            result.vocab = nothing
        elseif v isa AbstractString
            sv = String(v)
            # @vocab is expanded against the current vocab/base (so a relative or
            # empty @vocab resolves to a document-relative IRI).
            expanded = _expand_iri(result, sv; vocab=true, base=true)
            result.vocab = (expanded !== nothing && expanded != sv) ? expanded : sv
        else
            throw(ParseError("@vocab must be a string or null", 0, 0, _MIME_JSONLD()))
        end
    end

    # @language
    if haskey(raw_ctx, "@language")
        v = raw_ctx["@language"]
        if v === nothing
            result.language = nothing
        elseif v isa AbstractString
            result.language = lowercase(String(v))
        else
            throw(ParseError("@language must be a string or null", 0, 0, _MIME_JSONLD()))
        end
    end

    # @version, if present, must be 1.1.
    if haskey(raw_ctx, "@version")
        vv = raw_ctx["@version"]
        (vv isa Number && Float64(vv) == 1.1) ||
            throw(ParseError("@version must be 1.1", 0, 0, _MIME_JSONLD()))
    end
    # @propagate must be a boolean.
    if haskey(raw_ctx, "@propagate") && !(raw_ctx["@propagate"] isa Bool)
        throw(ParseError("@propagate must be a boolean", 0, 0, _MIME_JSONLD()))
    end
    # @direction must be "ltr", "rtl", or null.
    if haskey(raw_ctx, "@direction")
        dv = raw_ctx["@direction"]
        (dv === nothing || (dv isa AbstractString && lowercase(String(dv)) in ("ltr", "rtl"))) ||
            throw(ParseError("@direction must be ltr or rtl", 0, 0, _MIME_JSONLD()))
    end
    # @import must be a string.
    if haskey(raw_ctx, "@import") && !(raw_ctx["@import"] isa AbstractString)
        throw(ParseError("@import must be a string", 0, 0, _MIME_JSONLD()))
    end
    # A context-level @type definition must be a non-empty map containing only
    # @container (which must be @set) and/or @protected.
    if haskey(raw_ctx, "@type")
        tv = raw_ctx["@type"]
        (tv isa AbstractDict && !isempty(tv) &&
         all(kk -> String(kk) in ("@container", "@protected"), keys(tv)) &&
         (!haskey(tv, "@container") || String(tv["@container"]) == "@set")) ||
            throw(ParseError("invalid context @type definition", 0, 0, _MIME_JSONLD()))
    end

    # Whether all terms in this context are protected by default.
    ctx_protected = get(raw_ctx, "@protected", false) === true

    # Term definitions. Process simple (string) definitions — which establish
    # prefixes — before map definitions, so a term whose @id uses a prefix
    # defined later in the same context still resolves (forward references).
    _term_pairs = [(String(k), v) for (k, v) in raw_ctx]
    _term_pairs = vcat([p for p in _term_pairs if !(p[2] isa AbstractDict)],
                       [p for p in _term_pairs if p[2] isa AbstractDict])
    for (sk, v) in _term_pairs
        sk in ("@base", "@vocab", "@language", "@version") && continue
        # A key in keyword form (@ followed by letters) is reserved and ignored;
        # other @-keys (e.g. "@", "@foo.bar") are ordinary terms.
        occursin(r"^@[A-Za-z]+$", sk) && continue
        # The empty string is not a valid term.
        sk == "" && throw(ParseError("definition for the empty term", 0, 0, _MIME_JSONLD()))

        term_protected = ctx_protected
        newdef = nothing
        # Exclude the term being (re)defined from the active context while
        # expanding its own mapping, so a compact-IRI-shaped term name resolves
        # via its prefix rather than its previous self-definition. Keep the
        # previous definition for the @protected redefinition check.
        prev_def = get(result.terms, sk, nothing)
        delete!(result.terms, sk)
        if v === nothing
            newdef = nothing
        elseif v isa AbstractString
            sv = String(v)
            # A mapping in keyword form that is not a real keyword → term ignored.
            occursin(r"^@[A-Za-z]+$", sv) && !(sv in _JSONLD_KEYWORDS) && continue
            # Cyclic IRI mapping: a compact IRI prefixed by the term itself.
            (startswith(sv, sk * ":") && !startswith(sv, sk * "://")) &&
                throw(ParseError("cyclic IRI mapping for \"$sk\"", 0, 0, _MIME_JSONLD()))
            expanded = _expand_iri(result, sv; vocab=true, base=false)
            newdef = (expanded !== nothing && expanded != sv) ? expanded : sv
        else
            # A term definition must be a string, map, or null.
            v isa AbstractDict ||
                throw(ParseError("invalid term definition for \"$sk\"", 0, 0, _MIME_JSONLD()))
            td = Dict{String,Any}()
            # @id and @reverse cannot coexist.
            haskey(v, "@id") && haskey(v, "@reverse") &&
                throw(ParseError("term definition has both @id and @reverse", 0, 0, _MIME_JSONLD()))
            if haskey(v, "@id")
                vid = v["@id"]
                if vid === nothing
                    td["@id"] = nothing
                elseif vid isa AbstractString
                    sv = String(vid)
                    # An @id in keyword form that is not a real keyword makes the
                    # term reserved/ignored (not defined).
                    occursin(r"^@[A-Za-z]+$", sv) && !(sv in _JSONLD_KEYWORDS) && continue
                    # @id may not be set to a keyword like @context.
                    sv == "@context" &&
                        throw(ParseError("invalid keyword alias to @context", 0, 0, _MIME_JSONLD()))
                    # Cyclic IRI mapping: a compact IRI prefixed by the term itself.
                    (startswith(sv, sk * ":") && !startswith(sv, sk * "://")) &&
                        throw(ParseError("cyclic IRI mapping for \"$sk\"", 0, 0, _MIME_JSONLD()))
                    expanded = _expand_iri(result, sv; vocab=true, base=false)
                    td["@id"] = (expanded !== nothing && expanded != sv) ? expanded : sv
                else
                    throw(ParseError("@id in term definition must be a string", 0, 0, _MIME_JSONLD()))
                end
            else
                # Default @id: expand the term name itself
                expanded = _expand_iri(result, sk; vocab=true, base=false)
                td["@id"] = (expanded !== nothing) ? expanded : sk
            end
            # @prefix must be a boolean.
            if haskey(v, "@prefix")
                v["@prefix"] isa Bool ||
                    throw(ParseError("@prefix must be a boolean", 0, 0, _MIME_JSONLD()))
                td["@prefix"] = v["@prefix"]
            end
            if haskey(v, "@type")
                tv = v["@type"]
                tv isa AbstractString ||
                    throw(ParseError("@type in term definition must be a string", 0, 0, _MIME_JSONLD()))
                tvs = String(tv)
                if tvs in ("@id", "@vocab", "@json", "@none")
                    td["@type"] = tvs
                else
                    ety = _expand_iri(result, tvs; vocab=true, base=false)
                    (ety === nothing || startswith(ety, "_:") || !occursin(':', ety)) &&
                        throw(ParseError("invalid type mapping \"$tvs\"", 0, 0, _MIME_JSONLD()))
                    td["@type"] = ety
                end
            end
            if haskey(v, "@container")
                # @container may be a single keyword or an array of keywords
                # (e.g. ["@language", "@set"]) in JSON-LD 1.1.
                cv = v["@container"]
                cont = cv isa AbstractString ? String[String(cv)] :
                       cv isa AbstractArray  ? String[String(x) for x in cv] : String[]
                isempty(cont) &&
                    throw(ParseError("invalid @container mapping", 0, 0, _MIME_JSONLD()))
                for c in cont
                    c in ("@list", "@set", "@index", "@language", "@id", "@type", "@graph") ||
                        throw(ParseError("invalid @container mapping \"$c\"", 0, 0, _MIME_JSONLD()))
                end
                # A reverse property's container is limited to @set / @index.
                haskey(v, "@reverse") && !all(c -> c in ("@set", "@index"), cont) &&
                    throw(ParseError("invalid @container for reverse property", 0, 0, _MIME_JSONLD()))
                td["@container"] = length(cont) == 1 ? cont[1] : cont
            end
            # @index in a term definition must be a non-keyword string, and the
            # term's container must include @index (property-valued index).
            if haskey(v, "@index")
                iv = v["@index"]
                iv isa AbstractString ||
                    throw(ParseError("@index in term definition must be a string", 0, 0, _MIME_JSONLD()))
                String(iv) in _JSONLD_KEYWORDS &&
                    throw(ParseError("@index must not be a keyword", 0, 0, _MIME_JSONLD()))
                cont = get(td, "@container", nothing)
                has_index = cont isa AbstractString ? cont == "@index" :
                            cont isa AbstractArray ? ("@index" in cont) : false
                has_index ||
                    throw(ParseError("@index requires @container @index", 0, 0, _MIME_JSONLD()))
                td["@index"] = String(iv)
            end
            if haskey(v, "@reverse")
                rv = v["@reverse"]
                rv isa AbstractString ||
                    throw(ParseError("@reverse in term definition must be a string", 0, 0, _MIME_JSONLD()))
                # A keyword-form @reverse value makes the term ignored (even with
                # @vocab set, which would otherwise turn it into an IRI).
                occursin(r"^@[A-Za-z]+$", String(rv)) && !(String(rv) in _JSONLD_KEYWORDS) && continue
                rev_iri = _expand_iri(result, String(rv); vocab=true, base=false)
                # A keyword-form mapping (@…) makes the term ignored, not invalid.
                if rev_iri !== nothing && !startswith(rev_iri, "@")
                    (startswith(rev_iri, "_:") || !occursin(':', rev_iri)) &&
                        throw(ParseError("invalid reverse property IRI \"$(String(rv))\"", 0, 0, _MIME_JSONLD()))
                    td["@reverse"] = rev_iri
                end
            end
            if haskey(v, "@language")
                lv = v["@language"]
                td["@language"] = lv === nothing ? nothing : lowercase(String(lv))
            end
            # @nest in a term definition must be exactly "@nest", and cannot be
            # combined with @reverse.
            if haskey(v, "@nest")
                nv = v["@nest"]
                (nv isa AbstractString && String(nv) == "@nest") ||
                    throw(ParseError("invalid @nest value in term definition",
                                     0, 0, _MIME_JSONLD()))
                haskey(v, "@reverse") &&
                    throw(ParseError("@nest cannot be used with @reverse",
                                     0, 0, _MIME_JSONLD()))
            end
            # A property-scoped @context is stored raw and applied when this
            # term's values are expanded.
            # Store the scoped @context with the URL of the context document it
            # was defined in, so its own relative context references resolve
            # correctly when the scoped context is later applied.
            if haskey(v, "@context")
                td["@context"] = v["@context"]
                result.docbase !== nothing && (td["@context_base"] = result.docbase)
            end
            # @prefix:true cannot apply to a keyword alias, nor to a term name
            # that is not a simple prefix (a relative IRI / contains '/' or ':').
            if get(v, "@prefix", false) === true
                (haskey(v, "@id") && v["@id"] isa AbstractString && startswith(String(v["@id"]), "@")) &&
                    throw(ParseError("a keyword alias cannot be a prefix", 0, 0, _MIME_JSONLD()))
                (occursin('/', sk) || occursin(':', sk)) &&
                    throw(ParseError("a relative IRI cannot be used as a prefix", 0, 0, _MIME_JSONLD()))
            end
            haskey(v, "@protected") && (term_protected = v["@protected"] === true)
            newdef = td
        end

        was_protected = sk in result.protected
        # @protected: a protected term may not be redefined with a different
        # mapping (an identical redefinition is allowed).  Scoped contexts are
        # processed with override_protected and may redefine protected terms.
        if !override_protected && was_protected &&
           _term_sig(prev_def) != _term_sig(newdef)
            throw(ParseError("attempt to redefine protected term \"$sk\"", 0, 0, _MIME_JSONLD()))
        end
        result.terms[sk] = newdef
        # An identical redefinition retains protection unless @protected:false is
        # given explicitly.
        explicit_unprotect = v isa AbstractDict && get(v, "@protected", nothing) === false
        if term_protected || (was_protected && !explicit_unprotect)
            push!(result.protected, sk)
        else
            delete!(result.protected, sk)
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
            # Keep @nest-aliased keys under their original name so the term's
            # scoped @context remains discoverable when hoisting.
            target = (kw === nothing || kw == "@nest") ? k : kw
            if haskey(nd, target)
                # Several keys alias the same keyword: list-valued keywords merge
                # their values; a scalar keyword collision (e.g. @id) is an error.
                target in ("@type", "@included", "@nest", "@graph", "@set", "@list") ||
                    throw(ParseError("colliding keywords \"$target\"", 0, 0, _MIME_JSONLD()))
                ex = nd[target]
                nd[target] = Any[(ex isa AbstractArray ? collect(ex) : Any[ex])...,
                                 (v isa AbstractArray ? collect(v) : Any[v])...]
            else
                nd[target] = v
            end
        end
        d = nd
    end

    # Value object
    haskey(d, "@value") && return _expand_value_object(d, ctx)

    # List object — may only carry @list and @index.
    if haskey(d, "@list")
        for k in keys(d)
            String(k) in ("@list", "@index", "@context") ||
                throw(ParseError("invalid set or list object key \"$k\"", 0, 0, _MIME_JSONLD()))
        end
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
    # A map term definition whose @id is a keyword is also an alias.
    if td isa AbstractDict && haskey(td, "@id")
        id = td["@id"]
        id isa AbstractString && startswith(id, "@") && id in _JSONLD_KEYWORDS && return String(id)
    end
    nothing
end

# Whether a map key denotes @none (literally or via a keyword alias).
_is_none_key(ctx::_JsonLDContext, key::AbstractString) =
    key == "@none" || _kw_alias(ctx, key) == "@none"

# The @container keywords declared for a term definition, as a vector.
function _container_of(td)::Vector{String}
    (td isa AbstractDict && haskey(td, "@container")) || return String[]
    c = td["@container"]
    c isa AbstractString ? String[String(c)] :
    c isa AbstractArray  ? String[String(x) for x in c] : String[]
end

function _expand_value_object(d::Dict{String,Any}, ctx::_JsonLDContext)
    # A value object may only contain these keys.
    for k in keys(d)
        String(k) in ("@value", "@type", "@language", "@index", "@direction") ||
            throw(ParseError("invalid value object key \"$k\"", 0, 0, _MIME_JSONLD()))
    end
    # @type and @language are mutually exclusive.
    haskey(d, "@type") && haskey(d, "@language") &&
        throw(ParseError("value object with both @type and @language", 0, 0, _MIME_JSONLD()))
    # @index must be a string.
    haskey(d, "@index") && !(d["@index"] isa AbstractString) &&
        throw(ParseError("@index must be a string", 0, 0, _MIME_JSONLD()))

    # Resolve the datatype up front, expanding aliases (e.g. a term mapped to
    # @json, or to a datatype IRI).
    dt_expanded = nothing
    if haskey(d, "@type")
        dtraw = d["@type"]
        dtraw isa AbstractString ||
            throw(ParseError("@type of a value object must be a string", 0, 0, _MIME_JSONLD()))
        dts = String(dtraw)
        dt_expanded = dts == "@json" ? "@json" : _expand_iri(ctx, dts; vocab=true, base=false)
    end
    is_json = dt_expanded == "@json"

    val = d["@value"]
    # A null @value drops the value — except for @type: @json, where null is a
    # valid JSON value.
    val === nothing && !is_json && return nothing
    # @value must be a scalar (string/number/boolean), except for @type: @json
    # where any JSON value is permitted.
    is_json || (val isa AbstractString || val isa Number || val isa Bool) ||
        throw(ParseError("invalid @value (must be a scalar)", 0, 0, _MIME_JSONLD()))
    # A language-tagged value must be a string.
    haskey(d, "@language") && !(val isa AbstractString) &&
        throw(ParseError("language-tagged @value must be a string", 0, 0, _MIME_JSONLD()))

    result = Dict{String,Any}("@value" => val)
    if is_json
        result["@type"] = "@json"
    elseif dt_expanded !== nothing
        # The datatype must be an absolute IRI (not a blank node, relative, or
        # containing whitespace).
        (startswith(dt_expanded, "_:") || !occursin(':', dt_expanded) ||
         occursin(r"\s", dt_expanded)) &&
            throw(ParseError("invalid value object datatype", 0, 0, _MIME_JSONLD()))
        result["@type"] = dt_expanded
    elseif haskey(d, "@language")
        lv = d["@language"]
        if lv !== nothing
            ls = String(lv)
            # A malformed language tag causes the value to be dropped (rejected),
            # not a hard error.
            occursin(r"^[a-zA-Z]{1,8}(-[a-zA-Z0-9]{1,8})*$", ls) || return nothing
            result["@language"] = lowercase(ls)
        end
        haskey(d, "@direction") && (result["@direction"] = String(d["@direction"]))
    elseif haskey(d, "@direction")
        result["@direction"] = String(d["@direction"])
    end
    result
end

# Expand a single list/scalar member, applying the list term's @type coercion
# (@id/@vocab → node reference; a datatype → typed value) to bare strings.
function _expand_coerced(item, ctx::_JsonLDContext, coerce)
    if item isa AbstractString && coerce !== nothing
        cs = String(coerce)
        if cs == "@id"
            ex = _expand_iri(ctx, String(item); vocab=false, base=true)
            return Dict{String,Any}("@id" => (ex !== nothing ? ex : String(item)))
        elseif cs == "@vocab"
            ex = _expand_iri(ctx, String(item); vocab=true, base=true)
            return Dict{String,Any}("@id" => (ex !== nothing ? ex : String(item)))
        elseif cs != "@none"
            return Dict{String,Any}("@value" => String(item), "@type" => cs)
        end
    end
    _expand_value(item, ctx)
end

function _expand_list_values(list_val, ctx::_JsonLDContext; coerce=nothing)::Vector{Any}
    list_val === nothing && return Any[]
    if !(list_val isa AbstractArray)
        v = _expand_coerced(list_val, ctx, coerce)
        return v !== nothing ? Any[v] : Any[]
    end
    out = Any[]
    for item in list_val
        # A nested array becomes a nested list object.
        if item isa AbstractArray
            push!(out, Dict{String,Any}("@list" => _expand_list_values(item, ctx; coerce=coerce)))
            continue
        end
        v = _expand_coerced(item, ctx, coerce)
        v !== nothing && push!(out, v)
    end
    out
end

# Apply a term's scoped @context, resolving its own relative context references
# against the URL of the context document the term was defined in (@context_base),
# then restoring the document docbase for subsequent value expansion.
function _apply_scoped_context(ctx::_JsonLDContext, td::AbstractDict;
                              propagate::Bool=true)::_JsonLDContext
    cb = get(td, "@context_base", nothing)
    if cb === nothing
        return _process_context(ctx, td["@context"]; override_protected=true, propagate=propagate)
    end
    tmp = _copy_ctx(ctx); tmp.docbase = cb
    r = _process_context(tmp, td["@context"]; override_protected=true, propagate=propagate)
    r.docbase = ctx.docbase
    r
end

function _expand_node(d::Dict{String,Any}, ctx::_JsonLDContext)
    node = Dict{String,Any}()

    # Type-scoped contexts do NOT propagate into nested nodes, so remember the
    # context as it stands before they are applied; nested node values are
    # expanded from this base (plus any propagating property-scoped contexts).
    child_base = ctx

    # Type-scoped contexts: a node's @type values may name terms whose term
    # definition carries a scoped @context.  Apply them — in lexicographic order
    # of the type values — to the active context before expanding properties.
    if haskey(d, "@type")
        tvals = d["@type"]
        tvals_arr = tvals isa AbstractArray ?
            sort!(String[String(t) for t in tvals if t isa AbstractString]) :
            (tvals isa AbstractString ? String[String(tvals)] : String[])
        for tv in tvals_arr
            td = get(ctx.terms, tv, nothing)
            if td isa AbstractDict && haskey(td, "@context")
                ctx = _apply_scoped_context(ctx, td; propagate=false)
            end
        end
    end

    # @id
    if haskey(d, "@id")
        raw_id = d["@id"]
        raw_id isa AbstractString ||
            throw(ParseError("@id value must be a string", 0, 0, _MIME_JSONLD()))
        # An @id in keyword form that is not a real keyword is ignored.
        if !(occursin(r"^@[A-Za-z]+$", String(raw_id)) && !(String(raw_id) in _JSONLD_KEYWORDS))
            expanded_id = _expand_iri(ctx, String(raw_id); vocab=false, base=true)
            expanded_id !== nothing && (node["@id"] = expanded_id)
        end
    end

    # @type — the type values are expanded against the context *before* any
    # type-scoped contexts are applied (so a type-scoped @vocab/@base reset does
    # not affect the type IRIs themselves).  @type values nested under @nest are
    # hoisted in as well.
    nest_types = _nest_types(d, ctx)
    if haskey(d, "@type") || !isempty(nest_types)
        types = get(d, "@type", Any[])
        types_arr = types isa AbstractArray ? collect(types) : Any[types]
        append!(types_arr, nest_types)
        expanded_types = String[]
        for t in types_arr
            t isa AbstractString ||
                throw(ParseError("@type value must be a string", 0, 0, _MIME_JSONLD()))
            et = _expand_iri(child_base, String(t); vocab=true, base=true)
            et !== nothing && push!(expanded_types, et)
        end
        isempty(expanded_types) || (node["@type"] = expanded_types)
    end

    # @graph
    if haskey(d, "@graph")
        node["@graph"] = _expand_document(d["@graph"], ctx)
    end

    # @included: independent node objects emitted alongside this node.
    if haskey(d, "@included")
        _validate_included(d["@included"])
        inc = _expand_document(d["@included"], ctx)
        isempty(inc) || (node["@included"] = inc)
    end

    # @reverse
    if haskey(d, "@reverse")
        rev = d["@reverse"]
        rev isa AbstractDict ||
            throw(ParseError("@reverse value must be a map", 0, 0, _MIME_JSONLD()))
        rev_map = Dict{String,Any}()
        for (k, v) in rev
            sk = String(k)
            # A reverse term inside @reverse is a double reversal — it becomes a
            # forward property of this node.
            rtd = get(ctx.terms, sk, nothing)
            if rtd isa AbstractDict && haskey(rtd, "@reverse")
                fpred = rtd["@reverse"]
                fvals = _expand_values_with_td(v, rtd, ctx)
                if !isempty(fvals)
                    haskey(node, fpred) ? append!(node[fpred]::Vector{Any}, fvals) :
                                          (node[fpred] = fvals)
                end
                continue
            end
            expanded_pred = _expand_iri(ctx, sk; vocab=true, base=false)
            expanded_pred === nothing && continue
            # @reverse map keys must be properties, not keywords.
            expanded_pred in _JSONLD_KEYWORDS &&
                throw(ParseError("invalid key \"$expanded_pred\" in @reverse", 0, 0, _MIME_JSONLD()))
            !occursin(':', expanded_pred) && continue
            expanded_vals = _expand_property_values(v, expanded_pred, ctx)
            # Reverse property values must be node references, not literals/lists.
            for ev in expanded_vals
                (ev isa AbstractDict && !haskey(ev, "@value") && !haskey(ev, "@list")) ||
                    throw(ParseError("invalid reverse property value", 0, 0, _MIME_JSONLD()))
            end
            isempty(expanded_vals) || (rev_map[expanded_pred] = expanded_vals)
        end
        isempty(rev_map) || (node["@reverse"] = rev_map)
    end

    # Other properties (with @nest contents hoisted into this node). `actx` is
    # the active context for this property (differs from `ctx` only for @nest-
    # hoisted properties that carry the @nest term's scoped @context).
    for (k, v, actx) in _gather_props(d, ctx)
        cbase = actx === ctx ? child_base : actx
        tdk = get(actx.terms, k, nothing)

        # A reverse term (defined with @reverse) routes its values into the
        # node's @reverse map under the reverse IRI; values must be nodes. A
        # reverse term with an @index/@id container takes a map whose values are
        # the reverse values (the keys/index are dropped).
        if tdk isa AbstractDict && haskey(tdk, "@reverse")
            rev_iri = tdk["@reverse"]
            revcont = _container_of(tdk)
            revvals = if ("@index" in revcont || "@id" in revcont) && v isa AbstractDict
                rv = Any[]
                for (_, sub) in v
                    append!(rv, _expand_values_with_td(sub, tdk, actx))
                end
                rv
            else
                _expand_values_with_td(v, tdk, actx)
            end
            for rv in revvals
                (rv isa AbstractDict && !haskey(rv, "@value") && !haskey(rv, "@list")) ||
                    throw(ParseError("invalid reverse property value", 0, 0, _MIME_JSONLD()))
            end
            if !isempty(revvals)
                rmap = get!(() -> Dict{String,Any}(), node, "@reverse")
                append!(get!(() -> Any[], rmap, rev_iri), revvals)
            end
            continue
        end

        expanded_pred = _expand_iri(actx, k; vocab=true, base=false)
        expanded_pred === nothing && continue
        expanded_pred in _JSONLD_KEYWORDS && continue
        !occursin(':', expanded_pred) && continue

        # @container coercion (driven by the *term*, not the IRI).
        container = _container_of(tdk)

        # A property-scoped @context applies while expanding this term's values
        # and propagates into nested nodes. `pctx` is the active context (for
        # scalar coercion, value objects, and bare @id references); `cctx` is
        # what nested node objects inherit — the propagating base without
        # ancestor type-scoped terms, with this property-scoped context layered
        # on, so type-scoped contexts do not propagate but property-scoped do.
        pctx = actx
        cctx = cbase
        if tdk isa AbstractDict && haskey(tdk, "@context")
            pctx = _apply_scoped_context(actx, tdk)
            cctx = _apply_scoped_context(cbase, tdk)
        end

        expanded_vals = if tdk isa AbstractDict && get(tdk, "@type", nothing) == "@json"
            # @json coercion: the entire value is a single JSON literal.
            Any[Dict{String,Any}("@value" => v, "@type" => "@json")]
        elseif "@language" in container && v isa AbstractDict
            # Language map: { lang => value(s) } → language-tagged literals.
            out = Any[]
            for (lang, lv) in v
                ls = lowercase(String(lang))
                isnone = _is_none_key(ctx, String(lang))
                for item in (lv isa AbstractArray ? collect(lv) : Any[lv])
                    item === nothing && continue
                    vo = Dict{String,Any}("@value" => String(item))
                    isnone || (vo["@language"] = ls)
                    push!(out, vo)
                end
            end
            out
        elseif "@graph" in container
            # Graph container: each value is wrapped in a graph object. With
            # @id/@index the value is a map keyed by graph id / index, and an
            # existing graph object is kept as-is; a plain @graph always wraps
            # (so a value that is already a graph becomes a nested graph).
            out = Any[]
            if ("@id" in container || "@index" in container) && v isa AbstractDict
                _wrapg(node) = (node isa AbstractDict && haskey(node, "@graph")) ?
                               node : Dict{String,Any}("@graph" => Any[node])
                gidx = tdk isa AbstractDict ? get(tdk, "@index", nothing) : nothing
                for (key, sub) in v
                    for node in _expand_property_values(sub, expanded_pred, pctx)
                        go = _wrapg(node)
                        if "@id" in container && !_is_none_key(ctx, String(key))
                            eid = _expand_iri(pctx, String(key); vocab=false, base=true)
                            if eid !== nothing
                                go = Dict{String,Any}(go)   # copy before tagging
                                go["@id"] = eid
                            end
                        end
                        # Property-valued @index: the index key becomes a property
                        # of the graph node.
                        if gidx !== nothing && !_is_none_key(ctx, String(key))
                            ip = _expand_iri(pctx, gidx; vocab=true, base=false)
                            if ip !== nothing
                                go = Dict{String,Any}(go)
                                go[ip] = _expand_index_value(String(key), gidx, pctx)
                            end
                        end
                        push!(out, go)
                    end
                end
            else
                for node in _expand_property_values(v, expanded_pred, pctx)
                    push!(out, Dict{String,Any}("@graph" => Any[node]))
                end
            end
            out
        elseif "@id" in container && v isa AbstractDict
            # Id map: { id => node }. The key supplies each node's @id (unless
            # the node already has one, or the key is @none).
            out = Any[]
            for (key, sub) in v
                for node in _expand_map_nodes(sub, pctx)
                    if node isa AbstractDict && !haskey(node, "@id") && !_is_none_key(ctx, String(key))
                        eid = _expand_iri(pctx, String(key); vocab=false, base=true)
                        eid !== nothing && (node["@id"] = eid)
                    end
                    push!(out, node)
                end
            end
            out
        elseif "@type" in container && v isa AbstractDict
            # Type map: { type => node }. The key is prepended to each node's
            # @type, and the key term's type-scoped @context applies to the node.
            out = Any[]
            for (key, sub) in v
                ekey = _is_none_key(ctx, String(key)) ? nothing :
                       _expand_iri(pctx, String(key); vocab=true, base=false)
                kctx = pctx
                kt = get(pctx.terms, String(key), nothing)
                if kt isa AbstractDict && haskey(kt, "@context")
                    kctx = _apply_scoped_context(pctx, kt)
                end
                tcoerce = tdk isa AbstractDict ? get(tdk, "@type", nothing) : nothing
                for node in _expand_map_nodes(sub, kctx; coerce=tcoerce)
                    # Type-map values must be node references, not literals.
                    (node isa AbstractDict && !haskey(node, "@value")) ||
                        throw(ParseError("type-map value must not be a literal", 0, 0, _MIME_JSONLD()))
                    if ekey !== nothing
                        ex = get(node, "@type", nothing)
                        node["@type"] = ex === nothing ? String[ekey] :
                            String[ekey, (ex isa AbstractArray ? ex : Any[ex])...]
                    end
                    push!(out, node)
                end
            end
            out
        elseif ("@index" in container) && v isa AbstractDict
            # Index map: { index => value(s) }. By default the index is dropped;
            # with a property-valued @index the index key becomes a value of that
            # property on each indexed node.
            idx_prop = tdk isa AbstractDict ? get(tdk, "@index", nothing) : nothing
            out = Any[]
            for (idxkey, iv) in v
                members = _expand_property_values(iv, expanded_pred, pctx)
                if idx_prop !== nothing && !_is_none_key(ctx, String(idxkey))
                    ipred = _expand_iri(pctx, idx_prop; vocab=true, base=false)
                    ival = _expand_index_value(String(idxkey), idx_prop, pctx)
                    if ipred !== nothing
                        for m in members
                            m isa AbstractDict && !haskey(m, "@value") ||
                                throw(ParseError("cannot add an index property to a value object",
                                                 0, 0, _MIME_JSONLD()))
                            append!(get!(() -> Any[], m, ipred), ival)
                        end
                    end
                end
                append!(out, members)
            end
            out
        else
            _expand_property_values(v, expanded_pred, pctx; child=cctx)
        end

        if "@list" in container
            # A @list-container term turns its value into a single list. A value
            # that is already a list object is used as-is; an array value becomes
            # a list whose members may themselves be nested lists.
            if v isa AbstractDict && haskey(v, "@list")
                # already a list object — expanded_vals holds it
            else
                lc = tdk isa AbstractDict ? get(tdk, "@type", nothing) : nothing
                expanded_vals = Any[Dict{String,Any}("@list" => _expand_list_values(v, pctx; coerce=lc))]
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

    # An empty expansion becomes a blank node (kept) when the input was a plain
    # (possibly only-@context) node object, but is dropped when the input carried
    # value-object/@id keywords — a malformed value object or an ignored @id.
    if isempty(node)
        any(k -> _kw_alias(ctx, String(k)) in
                 ("@value", "@language", "@direction", "@index", "@id"), keys(d)) &&
            return nothing
        return Dict{String,Any}()
    end
    node
end

# @included must be a node object or an array of node objects (not a string,
# value object, or list object).
function _validate_included(v)
    for it in (v isa AbstractArray ? collect(v) : Any[v])
        (it isa AbstractDict && !haskey(it, "@value") && !haskey(it, "@list")) ||
            throw(ParseError("invalid @included value", 0, 0, _MIME_JSONLD()))
    end
end

# Collect @type values hoisted from @nest properties (recursively); a node's
# own @type is handled separately by the caller.
function _nest_types(d::AbstractDict, ctx::_JsonLDContext)::Vector{Any}
    out = Any[]
    for (k0, v) in d
        _kw_alias(ctx, String(k0)) == "@nest" || continue
        for nv in (v isa AbstractArray ? collect(v) : Any[v])
            nv isa AbstractDict || continue
            for (kk, vv) in nv
                _kw_alias(ctx, String(kk)) == "@type" &&
                    append!(out, vv isa AbstractArray ? collect(vv) : Any[vv])
            end
            append!(out, _nest_types(nv, ctx))
        end
    end
    out
end

# Collect a node's ordinary (non-keyword) property pairs as (key, value, ctx),
# recursively hoisting @nest contents into the parent. The third element is the
# active context for that property — for @nest-hoisted props it includes the
# @nest term's scoped @context.
function _gather_props(d::AbstractDict, ctx::_JsonLDContext)::Vector{Tuple{String,Any,_JsonLDContext}}
    pairs = Tuple{String,Any,_JsonLDContext}[]
    for (k0, v) in d
        k = String(k0)
        kw = _kw_alias(ctx, k)
        if kw == "@nest"
            nctx = ctx
            td = get(ctx.terms, k, nothing)
            td isa AbstractDict && haskey(td, "@context") &&
                (nctx = _apply_scoped_context(ctx, td))
            for nv in (v isa AbstractArray ? collect(v) : Any[v])
                # @nest must be a node object (not a scalar or value object).
                (nv isa AbstractDict && !haskey(nv, "@value")) ||
                    throw(ParseError("invalid @nest value", 0, 0, _MIME_JSONLD()))
                append!(pairs, _gather_props(nv, nctx))
            end
        elseif kw === nothing && (!startswith(k, "@") || haskey(ctx.terms, k))
            # ordinary terms, plus @-keys that are explicitly defined terms
            # (e.g. "@", "@foo.bar"); reserved keyword-form keys are dropped.
            push!(pairs, (k, v, ctx))
        end
    end
    pairs
end

# Expand a property-valued index key as a value of the @index property,
# applying that property's @type:@id/@vocab coercion.
function _expand_index_value(idxkey::String, idx_prop, ctx::_JsonLDContext)::Vector{Any}
    td = get(ctx.terms, idx_prop, nothing)
    coerce = td isa AbstractDict ? get(td, "@type", nothing) : nothing
    if coerce == "@vocab"
        ex = _expand_iri(ctx, idxkey; vocab=true, base=false)
        return Any[Dict{String,Any}("@id" => (ex !== nothing ? ex : idxkey))]
    elseif coerce == "@id"
        ex = _expand_iri(ctx, idxkey; vocab=false, base=true)
        return Any[Dict{String,Any}("@id" => (ex !== nothing ? ex : idxkey))]
    end
    Any[Dict{String,Any}("@value" => idxkey)]
end

# Expand reverse-term values applying the term's @type:@id/@vocab coercion to
# bare strings (node references); other values expand normally.
function _expand_values_with_td(v, td, ctx::_JsonLDContext)::Vector{Any}
    coerce = td isa AbstractDict ? get(td, "@type", nothing) : nothing
    out = Any[]
    for val in (v isa AbstractArray ? collect(v) : Any[v])
        ev = if val isa AbstractString && (coerce == "@id" || coerce == "@vocab")
            ex = coerce == "@id" ? _expand_iri(ctx, String(val); vocab=false, base=true) :
                                   _expand_iri(ctx, String(val); vocab=true, base=false)
            Dict{String,Any}("@id" => (ex !== nothing ? ex : String(val)))
        else
            _expand_value(val, ctx)
        end
        ev isa AbstractArray ? append!(out, ev) : (ev !== nothing && push!(out, ev))
    end
    out
end

# Expand the value(s) of an @id-/@type-map entry into node objects.  A bare
# string is a node reference ({"@id": string}) unless the term coerces values to
# a datatype (then it becomes a value object — invalid in a @type map).
function _expand_map_nodes(sub, ctx::_JsonLDContext; coerce=nothing)::Vector{Any}
    items = sub isa AbstractArray ? collect(sub) : Any[sub]
    out = Any[]
    datatype = coerce !== nothing && !(coerce in ("@id", "@vocab"))
    for it in items
        ev = if it isa AbstractString
            datatype ? _expand_coerced(it, ctx, coerce) :
                       _expand_value(Dict{String,Any}("@id" => String(it)), ctx)
        else
            _expand_value(it, ctx)
        end
        ev === nothing && continue
        ev isa AbstractArray ? append!(out, ev) : push!(out, ev)
    end
    out
end

function _expand_property_values(v, pred::String, ctx::_JsonLDContext;
                                 child::_JsonLDContext=ctx)::Vector{Any}
    vals = v isa AbstractArray ? collect(v) : Any[v]
    out = Any[]
    for val in vals
        expanded = _expand_property_value(val, pred, ctx, child)
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

function _expand_property_value(val, pred::String, ctx::_JsonLDContext,
                                child::_JsonLDContext=ctx)
    # Look up term definition for this predicate (for @type coercion)
    term_def = _find_term_def_by_id(ctx, pred)

    if val isa AbstractDict
        # An explicit @list / @set object carries this property's @type coercion
        # down to its members.
        coerce = term_def isa AbstractDict ? get(term_def, "@type", nothing) : nothing
        if coerce !== nothing
            if haskey(val, "@list")
                return Dict{String,Any}("@list" => _expand_list_values(val["@list"], ctx; coerce=coerce))
            elseif haskey(val, "@set")
                s = val["@set"]
                items = s isa AbstractArray ? collect(s) : Any[s]
                out = Any[]
                for it in items
                    ev = _expand_coerced(it, ctx, coerce)
                    ev === nothing || push!(out, ev)
                end
                return out
            end
        end
        # A value/list object and a bare @id reference use the active context
        # (their @value/@id resolve against the type-scoped base); a nested node
        # object inherits the propagating child context (so ancestor type-scoped
        # terms do not leak into it).
        is_value = haskey(val, "@value") ||
                   any(k -> _kw_alias(ctx, String(k)) in ("@value", "@list"), keys(val))
        nonctx = [String(k) for k in keys(val)
                  if String(k) != "@context" && _kw_alias(ctx, String(k)) != "@context"]
        is_id_ref = length(nonctx) == 1 && _kw_alias(ctx, nonctx[1]) == "@id"
        return _expand_value(val, (is_value || is_id_ref) ? ctx : child)
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
                expanded = _expand_iri(ctx, sv; vocab=true, base=true)
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

    # A native (boolean/number) value coerced to an arbitrary datatype: emit its
    # canonical lexical form tagged with the coercion datatype.
    if (val isa Bool || val isa Number) && term_def isa AbstractDict &&
       haskey(term_def, "@type")
        coerce = String(term_def["@type"])
        if !(coerce in ("@id", "@vocab", "@json"))
            dt = _expand_iri(ctx, coerce; vocab=true, base=false)
            dt = dt !== nothing ? dt : coerce
            lex = val isa Bool ? (val ? "true" : "false") :
                  val isa Integer ? string(val) : _double_lexical(Float64(val))
            return Dict{String,Any}("@value" => lex, "@type" => dt)
        end
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
# Active rdfDirection serialization mode ("i18n-datatype", "compound-literal",
# or nothing). Set for the duration of a single _jsonld_to_rdf call so the deep
# value-conversion helpers can read it without threading a parameter everywhere.
const _RDF_DIRECTION_MODE = Ref{Union{String,Nothing}}(nothing)

function _jsonld_to_rdf(expanded::Vector{Any}, base::Union{String,Nothing};
                        rdfdir::Union{String,Nothing}=nothing)::Dataset
    ds = Dataset()
    blank_map = Dict{String,BlankNode}()
    prev = _RDF_DIRECTION_MODE[]
    _RDF_DIRECTION_MODE[] = rdfdir
    try
        for node in expanded
            node isa AbstractDict || continue
            _process_node!(ds.default_graph, node, ds, blank_map; top_level=true)
        end
    finally
        _RDF_DIRECTION_MODE[] = prev
    end
    ds
end

function _bnode_for_label(blank_map::Dict{String,BlankNode}, label::String)::BlankNode
    get!(blank_map, label) do
        _mint_blank_node()
    end
end

# An absolute IRI must have a scheme and contain no forbidden characters
# (whitespace, controls, or <>"{}|^`); invalid IRIs are dropped from output.
function _is_valid_iri(s::AbstractString)::Bool
    occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", s) || return false
    count(==('#'), s) <= 1 || return false      # at most one fragment
    !any(c -> c <= ' ' || c in ('<','>','"','{','}','|','^','\\','`'), s)
end

function _id_to_term(id_str::String, blank_map::Dict{String,BlankNode})::Union{IRI,BlankNode,Nothing}
    isempty(id_str) && return nothing
    if startswith(id_str, "_:")
        label = id_str[3:end]
        isempty(label) && return nothing
        return _bnode_for_label(blank_map, label)
    end
    _is_valid_iri(id_str) || return nothing
    try
        IRI(id_str)
    catch
        nothing
    end
end

# Emit a node's triples into `graph`, returning the subject term (or nothing
# if the node has an unusable @id).  Handles @type, properties, @reverse, and
# @graph (named graphs).
function _process_node!(graph::Graph, node::AbstractDict, ds::Dataset,
                        blank_map::Dict{String,BlankNode}; top_level::Bool=false)
    d = Dict{String,Any}(String(k) => v for (k, v) in node)

    # A value or list object is not a node; free-floating, it yields no triples.
    (haskey(d, "@value") || haskey(d, "@list")) && return nothing

    # A bare graph object (only @graph). At the top level (the document object)
    # its contents belong to the current/default graph; nested, it denotes a
    # fresh named graph keyed by a blank node.
    if haskey(d, "@graph") && length(d) == 1
        if top_level
            _process_graph_contents!(graph, d["@graph"], ds, blank_map)
            return nothing
        end
        gname = _mint_blank_node()
        ng = get!(() -> Graph(), ds.named_graphs, gname)
        _process_graph_contents!(ng, d["@graph"], ds, blank_map)
        return gname
    end

    # Determine subject
    subj = if haskey(d, "@id")
        s = _id_to_term(String(d["@id"]), blank_map)
        s === nothing && return nothing
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
            obj isa Union{IRI,BlankNode} || continue
            push!(graph, Triple(subj, IRI(_JRDF_TYPE), obj))
        end
    end

    # Properties
    for (pred_str, values) in d
        pred_str in ("@id", "@type", "@graph", "@reverse") && continue
        startswith(pred_str, "@") && continue
        _is_valid_iri(pred_str) || continue

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

    # @reverse — each value is itself a node; emit its own triples, then link
    # it back to `subj` via the (inverted) reverse predicate.
    if haskey(d, "@reverse")
        rev = d["@reverse"]
        if rev isa AbstractDict
            for (pred_str, values) in rev
                occursin(':', pred_str) || continue
                pred_iri = try IRI(pred_str) catch; continue end
                values isa AbstractArray || (values = Any[values])
                for vo in values
                    vo isa AbstractDict || continue
                    rev_subj = _process_node!(graph, vo, ds, blank_map)
                    rev_subj isa Union{IRI,BlankNode} || continue
                    push!(graph, Triple(rev_subj, pred_iri, subj))
                end
            end
        end
    end

    # @graph on a node that is itself a node (has an @id or other content):
    # the contents form a named graph keyed by this node's subject.
    if haskey(d, "@graph")
        ng = get!(() -> Graph(), ds.named_graphs, subj)
        _process_graph_contents!(ng, d["@graph"], ds, blank_map)
    end

    # @included nodes are emitted as independent nodes in the same graph.
    if haskey(d, "@included")
        _process_graph_contents!(graph, d["@included"], ds, blank_map)
    end

    return subj
end

# Process the value of an @graph key (a node object or array of node objects)
# into the given graph.
function _process_graph_contents!(graph::Graph, contents, ds::Dataset, blank_map::Dict{String,BlankNode})
    nodes = contents isa AbstractArray ? contents : Any[contents]
    for sn in nodes
        sn isa AbstractDict && _process_node!(graph, sn, ds, blank_map)
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

    # Graph object (e.g. from an @container: @graph term): emit its contents
    # into a named graph and return the graph name (the @id if given, else a
    # fresh blank node).
    if haskey(d, "@graph")
        gname = haskey(d, "@id") ? _id_to_term(String(d["@id"]), blank_map) : nothing
        gname === nothing && (gname = _mint_blank_node())
        ng = get!(() -> Graph(), ds.named_graphs, gname)
        _process_graph_contents!(ng, d["@graph"], ds, blank_map)
        # Any extra properties of the graph object (e.g. a property-valued index)
        # are emitted on the graph name in the current graph.
        for (p, vals) in d
            (p == "@graph" || p == "@id" || startswith(p, "@") || !_is_valid_iri(p)) && continue
            pi = IRI(p)
            for vob in (vals isa AbstractArray ? vals : Any[vals])
                o = _val_to_rdf(vob, graph, ds, blank_map)
                o === nothing || push!(graph, Triple(gname, pi, o))
            end
        end
        return gname
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

        # rdfDirection serialization modes (only when @direction is present).
        if dir !== nothing && _RDF_DIRECTION_MODE[] !== nothing
            dir_s = lowercase(String(dir))
            dir_s in ("ltr", "rtl") || return nothing
            lang_s = lang === nothing ? "" : lowercase(String(lang))
            mode = _RDF_DIRECTION_MODE[]
            if mode == "i18n-datatype"
                return Literal(string(raw_val), IRI(_I18N_BASE * lang_s * "_" * dir_s))
            elseif mode == "compound-literal"
                bn = _mint_blank_node()
                push!(graph, Triple(bn, IRI(_JRDF_VALUE), Literal(string(raw_val))))
                lang === nothing ||
                    push!(graph, Triple(bn, IRI(_JRDF_LANGUAGE), Literal(lang_s)))
                push!(graph, Triple(bn, IRI(_JRDF_DIRECTION), Literal(dir_s)))
                return bn
            end
        end

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

    # Anonymous node object (including an empty node object → a bare blank node).
    if isempty(d) || any(k -> occursin(':', k) || startswith(k, "@"), keys(d))
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

# ECMAScript Number::toString (per RFC 8785 / JCS) for a finite Float64: shortest
# round-tripping decimal, formatted exactly as ECMA-262 specifies.
function _ecma_number(x::Real)::String
    f = Float64(x)
    f == 0.0 && return "0"
    (isnan(f) || isinf(f)) && return "null"
    neg = f < 0
    f = abs(f)
    # Shortest decimal from Julia (Ryu-based), parsed into digits and exponent.
    str = string(f)
    mant, e10 = if occursin('e', str)
        p = split(str, 'e'); (String(p[1]), parse(Int, p[2]))
    else
        (str, 0)
    end
    intpart, fracpart = occursin('.', mant) ?
        (String(split(mant, '.')[1]), String(split(mant, '.')[2])) : (mant, "")
    combined = intpart * fracpart
    point = length(intpart) + e10           # digits before the decimal point
    lead = 0
    while lead < length(combined) - 1 && combined[lead+1] == '0'
        lead += 1
    end
    combined = combined[lead+1:end]; point -= lead
    combined = rstrip(combined, '0')
    isempty(combined) && (combined = "0")
    digits = String(combined); k = length(digits); n = point
    s = if k <= n <= 21
        digits * "0"^(n - k)
    elseif 0 < n <= 21
        digits[1:n] * "." * digits[n+1:end]
    elseif -6 < n <= 0
        "0." * "0"^(-n) * digits
    else
        mantis = k == 1 ? digits : digits[1:1] * "." * digits[2:end]
        ex = n - 1
        mantis * "e" * (ex >= 0 ? "+" : "-") * string(abs(ex))
    end
    neg ? "-" * s : s
end

# Canonical JSON (RFC 8785 / JCS subset) for rdf:JSON literals: object keys
# sorted by code point, no insignificant whitespace, JSON-escaped strings.
function _json_canonical(v)::String
    v === nothing && return "null"
    v isa Bool    && return v ? "true" : "false"
    v isa Integer && return string(v)
    if v isa Real
        f = Float64(v)
        # Only collapse to an integer literal within Int64's exact range.
        (isinteger(f) && abs(f) < 9.007199254740992e15) && return string(Integer(f))
        return _ecma_number(f)
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
        # A dropped member (e.g. an invalid IRI) yields no rdf:first triple, but
        # the list node and its rdf:rest chain are still emitted.
        obj === nothing || push!(graph, Triple(current, IRI(_JRDF_FIRST), obj))
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
                   contexts=nothing, load_remote_contexts::Bool=false,
                   rdfdirection::Union{AbstractString,Nothing}=nothing,
                   expandcontext=nothing)::Graph
    ds = Base.read(io, _MIME_JSONLD(), Dataset; base=base,
                   contexts=contexts, load_remote_contexts=load_remote_contexts,
                   rdfdirection=rdfdirection, expandcontext=expandcontext)
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
                   contexts=nothing, load_remote_contexts::Bool=false,
                   rdfdirection::Union{AbstractString,Nothing}=nothing,
                   expandcontext=nothing)::Dataset
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
    base !== nothing && (ctx.base = String(base); ctx.docbase = String(base))
    # expandContext option: a context applied to the document before expansion
    # (a string is treated as a context reference, resolved/loaded as usual).
    expandcontext === nothing || (ctx = _process_context(ctx, expandcontext))
    expanded = _expand_document(doc, ctx)
    _jsonld_to_rdf(expanded, ctx.base;
                   rdfdir=(rdfdirection === nothing ? nothing : String(rdfdirection)))
end

# ── Write ─────────────────────────────────────────────────────────────────────

# Active rdfDirection mode for serialization (i18n-datatype / compound-literal /
# nothing); set for the duration of a write so _object_to_jsonld_obj can decode
# i18n-datatype literals back to @direction value objects.
const _WRITE_DIRECTION_MODE = Ref{Union{String,Nothing}}(nothing)

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
    # An rdf:JSON literal round-trips as a @json value object (its lexical form
    # is canonical JSON).
    if dt == _JRDF_JSON
        parsed = try JSON3.read(obj.lexical_form) catch; obj.lexical_form end
        return Dict{String,Any}("@value" => parsed, "@type" => "@json")
    end
    # Under rdfDirection: i18n-datatype, decode an i18n#<lang>_<dir> typed literal
    # back to a value object with @language/@direction.
    if _WRITE_DIRECTION_MODE[] == "i18n-datatype" && startswith(dt, _I18N_BASE)
        tag = dt[ncodeunits(_I18N_BASE)+1:end]
        us = findlast('_', tag)
        if us !== nothing
            lang = tag[1:us-1]; dir = tag[us+1:end]
            r = Dict{String,Any}("@value" => obj.lexical_form, "@direction" => dir)
            isempty(lang) || (r["@language"] = lang)
            return r
        end
    end
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
function Base.write(io::IO, ::_MIME_JSONLD, g::Graph; context=nothing, indent::Int=2,
                    rdfdirection::Union{AbstractString,Nothing}=nothing)
    prev = _WRITE_DIRECTION_MODE[]
    _WRITE_DIRECTION_MODE[] = rdfdirection === nothing ? nothing : String(rdfdirection)
    try
        nodes  = _graph_to_jsonld(g)
        output = if context !== nothing
            Dict{String,Any}("@context" => context, "@graph" => nodes)
        else
            nodes
        end
        print(io, JSON3.write(output))
    finally
        _WRITE_DIRECTION_MODE[] = prev
    end
    nothing
end

"""
    Base.write(io::IO, ::MIME"application/ld+json", ds::Dataset; context=nothing, indent::Int=2)

Serialize an RDF `Dataset` to JSON-LD format. Named graphs are represented with
`"@graph"` entries; the default graph's triples appear at the top level.
"""
function Base.write(io::IO, ::_MIME_JSONLD, ds::Dataset; context=nothing, indent::Int=2,
                    rdfdirection::Union{AbstractString,Nothing}=nothing)
    prev = _WRITE_DIRECTION_MODE[]
    _WRITE_DIRECTION_MODE[] = rdfdirection === nothing ? nothing : String(rdfdirection)
    try
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
    finally
        _WRITE_DIRECTION_MODE[] = prev
    end
    nothing
end

function _graph_to_jsonld(g::Graph)::Vector{Any}
    # subject key → (subject-id-string, predicate-iri → [object nodes])
    subject_ids    = String[]
    subject_preds  = Dict{String, Dict{String,Vector{Any}}}()

    # Under rdfDirection: compound-literal, blank nodes that are compound
    # literals (rdf:value + rdf:direction [+ rdf:language] only) collapse into
    # a single @direction value object and are not emitted as standalone nodes.
    compound = _compound_literals(g)

    for triple in g
        triple.subject isa BlankNode && haskey(compound, triple.subject) && continue
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
            obj_node = (triple.object isa BlankNode && haskey(compound, triple.object)) ?
                       compound[triple.object] : _object_to_jsonld_obj(triple.object)
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

# Identify compound-literal blank nodes (rdfDirection: compound-literal): a
# blank node whose only properties are rdf:value, rdf:direction, and optionally
# rdf:language maps to a @value/@direction/@language value object.
function _compound_literals(g::Graph)::Dict{BlankNode,Dict{String,Any}}
    out = Dict{BlankNode,Dict{String,Any}}()
    _WRITE_DIRECTION_MODE[] == "compound-literal" || return out
    bysubj = Dict{BlankNode,Vector{Any}}()
    for t in g
        t.subject isa BlankNode || continue
        push!(get!(() -> Any[], bysubj, t.subject), t)
    end
    allowed = Set([_JRDF_VALUE, _JRDF_DIRECTION, _JRDF_LANGUAGE])
    for (bn, ts) in bysubj
        preds = Set(t.predicate.value for t in ts)
        (_JRDF_VALUE in preds && _JRDF_DIRECTION in preds && preds ⊆ allowed) || continue
        vo = Dict{String,Any}()
        for t in ts
            t.object isa Literal || continue
            lf = t.object.lexical_form
            t.predicate.value == _JRDF_VALUE     && (vo["@value"] = lf)
            t.predicate.value == _JRDF_DIRECTION && (vo["@direction"] = lf)
            t.predicate.value == _JRDF_LANGUAGE  && (vo["@language"] = lf)
        end
        out[bn] = vo
    end
    out
end

# File extension dispatch (.jsonld, .json-ld) is handled in ntriples.jl's
# rdf_read / rdf_write functions, which were updated to delegate to this MIME type.
