# ── IRI constants (avoid forward-reference to the rdfs/rdf vocab modules) ─────
const _VOCAB_RDFS_LABEL   = IRI("http://www.w3.org/2000/01/rdf-schema#label")
const _VOCAB_RDFS_COMMENT = IRI("http://www.w3.org/2000/01/rdf-schema#comment")

# ── Vocabulary ────────────────────────────────────────────────────────────────

"""
    Vocabulary

An RDF vocabulary loaded from a graph, file, or URI.  Provides:

- **Dot-notation** access to terms: `vocab.BachelorDegree`
- **String indexing**: `vocab["BachelorDegree"]` or `vocab["http://..."]`
- **Metadata**: [`label`](@ref) and [`comment`](@ref) via `rdfs:label` / `rdfs:comment`
- **Term enumeration**: [`terms`](@ref)

Construct via [`Vocabulary(graph)`](@ref Vocabulary(::Graph)) or
[`load_vocabulary`](@ref).
"""
struct Vocabulary
    graph::Graph
    base::Union{String, Nothing}
    _index::Dict{String, IRI}   # local name → IRI
end

"""
    Vocabulary(g::Graph; base=nothing) -> Vocabulary

Construct a `Vocabulary` from an existing RDF `Graph`.

If `base` (a string prefix such as `"http://purl.org/ctdl/terms/"`) is given,
only IRIs whose string value starts with `base` are indexed, and local names
are the remainder after `base`.  Otherwise every subject IRI is indexed by
the fragment after the last `#` or `/`.

```julia
g = rdf_read("ctdl.ttl")
v = Vocabulary(g; base="http://purl.org/ctdl/terms/")
v.BachelorDegree   # => IRI("http://purl.org/ctdl/terms/BachelorDegree")
```
"""
function Vocabulary(g::Graph; base::Union{AbstractString, Nothing}=nothing)
    b = base === nothing ? nothing : String(base)
    Vocabulary(g, b, _vocab_build_index(g, b))
end

# ── Index construction ────────────────────────────────────────────────────────

function _vocab_build_index(g::Graph, base::Union{String, Nothing})::Dict{String, IRI}
    index = Dict{String, IRI}()
    for t in g
        t.subject isa IRI || continue
        iri = t.subject::IRI
        local_name = if base !== nothing
            startswith(iri.value, base) || continue
            iri.value[ncodeunits(base)+1:end]
        else
            _vocab_local_name(iri)
        end
        isempty(local_name) && continue
        haskey(index, local_name) || (index[local_name] = iri)
    end
    index
end

function _vocab_local_name(iri::IRI)::String
    s = iri.value
    h = findlast('#', s)
    h !== nothing && return s[nextind(s, h):end]
    sl = findlast('/', s)
    sl !== nothing && return s[nextind(s, sl):end]
    return s
end

# ── Term access ───────────────────────────────────────────────────────────────

function Base.getproperty(v::Vocabulary, name::Symbol)
    # Pass through struct fields directly
    name === :graph  && return getfield(v, :graph)
    name === :base   && return getfield(v, :base)
    name === :_index && return getfield(v, :_index)

    key = String(name)
    idx = getfield(v, :_index)
    iri = get(idx, key, nothing)
    iri !== nothing && return iri

    # Fall back to constructing base + name (enables access to terms not
    # explicitly used as subjects, e.g. newly added vocabulary terms)
    b = getfield(v, :base)
    b !== nothing && return IRI(b * key)

    throw(KeyError(key))
end

"""
    vocab["TermName"]            # local name lookup
    vocab["http://full/iri"]     # full IRI passthrough

Index a vocabulary term by local name string.  If `name` looks like a full
absolute IRI (starts with a scheme) it is wrapped in `IRI(name)` directly.
Raises `KeyError` if the local name is not found and no `base` is set.
"""
function Base.getindex(v::Vocabulary, name::AbstractString)
    # Full absolute IRI passthrough
    occursin(r"^[A-Za-z][A-Za-z0-9+\-.]*:", name) && return IRI(name)

    idx = getfield(v, :_index)
    iri = get(idx, name, nothing)
    iri !== nothing && return iri

    b = getfield(v, :base)
    b !== nothing && return IRI(b * name)

    throw(KeyError(name))
end

Base.length(v::Vocabulary)   = length(getfield(v, :_index))
Base.isempty(v::Vocabulary)  = isempty(getfield(v, :_index))

Base.propertynames(v::Vocabulary) =
    vcat([:graph, :base], Symbol.(keys(getfield(v, :_index))))

function Base.show(io::IO, v::Vocabulary)
    n = length(v)
    b = getfield(v, :base)
    if b !== nothing
        print(io, "Vocabulary(", repr(b), ", ", n, " term", n == 1 ? "" : "s", ")")
    else
        print(io, "Vocabulary(", n, " term", n == 1 ? "" : "s", ")")
    end
end

# ── Iteration / enumeration ────────────────────────────────────────────────────

"""
    terms(v::Vocabulary)

Return an iterator over every `IRI` indexed in the vocabulary.

```julia
for iri in terms(ctdl)
    println(label(ctdl, iri), "  =>  ", iri)
end
```
"""
terms(v::Vocabulary) = values(getfield(v, :_index))

# ── Metadata helpers ──────────────────────────────────────────────────────────

"""
    label(v::Vocabulary, iri::IRI; lang="en") -> Union{String, Nothing}

Return the `rdfs:label` of `iri` in the vocabulary.

Prefers a label whose language tag starts with `lang` (default `"en"`), so
`"en-US"` matches `lang="en"`.  Falls back to any plain (untagged) literal
if no language-matched label exists.  Returns `nothing` if no label is found.

```julia
label(ctdl, ctdl.BachelorDegree)             # => "Bachelor's Degree"
label(ctdl, ctdl.BachelorDegree; lang="es")  # => Spanish label if present
```
"""
label(v::Vocabulary, iri::IRI; lang::AbstractString="en") =
    _vocab_string_prop(v.graph, iri, _VOCAB_RDFS_LABEL, lang)

"""
    comment(v::Vocabulary, iri::IRI; lang="en") -> Union{String, Nothing}

Return the `rdfs:comment` of `iri` in the vocabulary.

Same language preference logic as [`label`](@ref).

```julia
comment(ctdl, ctdl.Course)
# => "Single structured sequence of one or more educational activities"
```
"""
comment(v::Vocabulary, iri::IRI; lang::AbstractString="en") =
    _vocab_string_prop(v.graph, iri, _VOCAB_RDFS_COMMENT, lang)

function _vocab_string_prop(g::Graph, subject::IRI, predicate::IRI,
                             lang::AbstractString)::Union{String, Nothing}
    fallback = nothing
    for t in match(g; subject=subject, predicate=predicate)
        t.object isa Literal || continue
        lit = t.object::Literal
        if !isempty(lit.language_tag)
            tag = lit.language_tag
            # Accept exact match or subtag (e.g. "en-US" for lang="en")
            if tag == lang || startswith(tag, lang * "-")
                return lit.lexical_form
            end
        elseif fallback === nothing
            # Plain (untagged) literal — keep as fallback, continue seeking a lang match
            fallback = lit.lexical_form
        end
    end
    fallback
end

# ── Dataset → Graph flattening ────────────────────────────────────────────────

# Used by load_vocabulary (file) and by RDFHTTPExt (remote).
# Merges all named graphs and the default graph into a single Graph.
function _dataset_to_graph(ds::Dataset)::Graph
    g = Graph()
    for q in ds
        push!(g, Triple(q.subject, q.predicate, q.object))
    end
    g
end

# ── Loading ────────────────────────────────────────────────────────────────────

"""
    load_vocabulary(source; base=nothing, format=nothing) -> Vocabulary

Load an RDF vocabulary from a local file path or a remote HTTP/HTTPS URL.

**Local files** — format inferred from extension:

| Extension | Format |
|-----------|--------|
| `.ttl` | Turtle 1.1 |
| `.nt` | N-Triples |
| `.nq` | N-Quads |
| `.jsonld`, `.json-ld`, `.json` | JSON-LD 1.1 |

**Remote URLs** — requires `HTTP.jl` to be loaded alongside `RDF.jl`.
Content-negotiation requests Turtle first, then N-Triples, then JSON-LD.

**`base`** restricts indexing to IRIs that start with the given string prefix and
sets the namespace used by `vocab.Term` property access.  If omitted, all subject
IRIs are indexed by local name (fragment after the last `#` or `/`).

**`format`** overrides extension-based detection, e.g. `MIME"text/turtle"()`.

# Examples

```julia
# Local Turtle file
ctdl = load_vocabulary("ctdl.ttl"; base="http://purl.org/ctdl/terms/")

# Remote URL (requires HTTP.jl)
using HTTP
ctdl = load_vocabulary("https://credreg.net/ctdl/schema/encoding/turtle";
                        base="http://purl.org/ctdl/terms/")

# Term access
ctdl.BachelorDegree               # => IRI("http://purl.org/ctdl/terms/BachelorDegree")
label(ctdl, ctdl.Course)          # => "Course"
comment(ctdl, ctdl.estimatedCost) # => description string

# Enumerate all indexed terms
for iri in terms(ctdl)
    println(label(ctdl, iri), "  =>  ", iri)
end

# Use in a SPARQL query
sparql(ds, \"""
  SELECT ?cred WHERE {
    ?cred a <\$(ctdl.BachelorDegree)> .
  }
\""")
```
"""
function load_vocabulary(source::AbstractString;
                         base::Union{AbstractString, Nothing}=nothing,
                         format::Union{MIME, Nothing}=nothing)
    if startswith(source, "http://") || startswith(source, "https://")
        return _vocab_load_http(source; base=base, format=format)
    end
    mime = format !== nothing ? format : _vocab_mime_from_path(source)
    g = _vocab_graph_from_file(source, mime)
    Vocabulary(g; base=base)
end

function _vocab_mime_from_path(path::AbstractString)::MIME
    lp = lowercase(path)
    endswith(lp, ".ttl")     && return MIME"text/turtle"()
    endswith(lp, ".nt")      && return MIME"application/n-triples"()
    endswith(lp, ".nq")      && return MIME"application/n-quads"()
    endswith(lp, ".jsonld")  && return MIME"application/ld+json"()
    endswith(lp, ".json-ld") && return MIME"application/ld+json"()
    endswith(lp, ".json")    && return MIME"application/ld+json"()
    throw(ArgumentError(
        "Cannot infer RDF format from path $(repr(path)). " *
        "Pass `format=MIME\"text/turtle\"()` explicitly, or convert the " *
        "file to Turtle / N-Triples first."))
end

# Turtle / N-Triples → Graph directly
function _vocab_graph_from_file(path::AbstractString, mime::MIME)::Graph
    open(path, "r") do io
        Base.read(io, mime, Graph)
    end
end

# JSON-LD / N-Quads → Dataset → flatten
function _vocab_graph_from_file(path::AbstractString,
                                 mime::Union{MIME"application/ld+json",
                                             MIME"application/n-quads"})::Graph
    ds = open(path, "r") do io
        Base.read(io, mime, Dataset)
    end
    _dataset_to_graph(ds)
end

# ── HTTP stub (overridden in RDFHTTPExt) ──────────────────────────────────────

function _vocab_load_http(source::AbstractString; kwargs...)
    error(
        "load_vocabulary with an HTTP/HTTPS URL requires HTTP.jl. " *
        "Add `using HTTP` before calling load_vocabulary.")
end
