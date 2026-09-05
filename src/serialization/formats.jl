# ── Format specifiers ─────────────────────────────────────────────────────────
#
# MIME remains the *dispatch* layer for serialization: it is the extension point
# third-party packages hook into (`RDFXMLExt` adds `read(io, MIME"application/
# rdf+xml"(), Graph)` without touching this package), and it is what HTTP
# content negotiation hands you verbatim.
#
# Symbols are the *front door* — what a human types.  `read(io, :ttl, Graph)`
# beats `read(io, MIME"text/turtle"(), Graph)`, and a typo produces a helpful
# ArgumentError listing the valid names instead of a MethodError about a MIME
# type nobody asked about.
#
# Everything below normalizes a symbol to a MIME and forwards.

"""
    RDF._format_mime(fmt) -> MIME

Normalize an RDF serialization format specifier to its `MIME` value.  Accepts a
`MIME` unchanged, or one of the symbol aliases:

| Symbol | MIME |
|--------|------|
| `:ttl`, `:turtle` | `text/turtle` |
| `:nt`, `:ntriples` | `application/n-triples` |
| `:nq`, `:nquads` | `application/n-quads` |
| `:trig` | `application/trig` |
| `:jsonld` | `application/ld+json` |
| `:rdfxml`, `:xml` | `application/rdf+xml` |
"""
_format_mime(m::MIME) = m
_format_mime(s::AbstractString) = MIME(s)

function _format_mime(fmt::Symbol)
    fmt === :ttl    || fmt === :turtle   ? MIME"text/turtle"()          :
    fmt === :nt     || fmt === :ntriples ? MIME"application/n-triples"() :
    fmt === :nq     || fmt === :nquads   ? MIME"application/n-quads"()   :
    fmt === :trig                        ? MIME"application/trig"()      :
    fmt === :jsonld                      ? MIME"application/ld+json"()   :
    fmt === :rdfxml || fmt === :xml      ? MIME"application/rdf+xml"()   :
    throw(ArgumentError(
        "unknown RDF format $(repr(fmt)). Valid formats are :ttl (:turtle), " *
        ":nt (:ntriples), :nq (:nquads), :trig, :jsonld, :rdfxml (:xml) — or a " *
        "MIME value such as MIME\"text/turtle\"()."))
end

"""
    RDF._results_format_mime(fmt) -> MIME

Normalize a SPARQL *results* format specifier to its `MIME` value.  Accepts a
`MIME` unchanged, or one of the symbol aliases:

| Symbol | MIME |
|--------|------|
| `:json`, `:srj` | `application/sparql-results+json` |
| `:xml`, `:srx` | `application/sparql-results+xml` |
| `:csv` | `text/csv` |
| `:tsv` | `text/tab-separated-values` |

Kept separate from [`RDF._format_mime`](@ref) because `:json` and `:xml` mean
different things for a results set than for a graph.
"""
_results_format_mime(m::MIME) = m

function _results_format_mime(fmt::Symbol)
    fmt === :json || fmt === :srj ? MIME"application/sparql-results+json"() :
    fmt === :xml  || fmt === :srx ? MIME"application/sparql-results+xml"()  :
    fmt === :csv                  ? MIME"text/csv"()                        :
    fmt === :tsv                  ? MIME"text/tab-separated-values"()       :
    throw(ArgumentError(
        "unknown SPARQL results format $(repr(fmt)). Valid formats are " *
        ":json (:srj), :xml (:srx), :csv, :tsv — or a MIME value such as " *
        "MIME\"application/sparql-results+json\"()."))
end

# Accept-header / Content-Type string for a format specifier.  Strings pass
# through untouched so callers can hand over a full negotiation string.
_format_accept(s::AbstractString) = String(s)
_format_accept(m::MIME)           = string(m)
_format_accept(fmt::Symbol)       = string(_format_mime(fmt))


# ── Symbol forwarders ─────────────────────────────────────────────────────────
#
# Restricted to RDF.jl-owned types (`Graph`, `Dataset`, `Vector{Triple}`,
# `SolutionSet`), so these are dispatch extensions rather than type piracy.
# Path-based forms (`read("data.ttl", :ttl, Graph)`) come for free via Base's
# `read(filename, args...)` fallback.

Base.read(io::IO, fmt::Symbol, ::Type{Graph}; kw...) =
    Base.read(io, _format_mime(fmt), Graph; kw...)

Base.read(io::IO, fmt::Symbol, ::Type{Graph}, base::AbstractString) =
    Base.read(io, _format_mime(fmt), Graph, base)

Base.read(io::IO, fmt::Symbol, ::Type{Dataset}; kw...) =
    Base.read(io, _format_mime(fmt), Dataset; kw...)

Base.read(io::IO, fmt::Symbol, ::Type{Dataset}, base::AbstractString) =
    Base.read(io, _format_mime(fmt), Dataset, base)

Base.read(io::IO, fmt::Symbol, ::Type{Vector{Triple}}) =
    Base.read(io, _format_mime(fmt), Vector{Triple})

Base.read(io::IO, fmt::Symbol, ::Type{Vector{Triple}}, base::AbstractString) =
    Base.read(io, _format_mime(fmt), Vector{Triple}, base)

Base.write(io::IO, fmt::Symbol, g::Graph; kw...) =
    Base.write(io, _format_mime(fmt), g; kw...)

Base.write(io::IO, fmt::Symbol, ds::Dataset; kw...) =
    Base.write(io, _format_mime(fmt), ds; kw...)

Base.write(io::IO, fmt::Symbol, sol::SolutionSet) =
    Base.write(io, _results_format_mime(fmt), sol)

parse_triples(f::Function, io::IO, fmt::Symbol) =
    parse_triples(f, io, _format_mime(fmt))

parse_triples(io::IO, fmt::Symbol) = parse_triples(io, _format_mime(fmt))

# NOTE: there is deliberately no `write(io, ::Symbol, ::Bool)` for ASK results.
# Every argument type would belong to Base, making it genuine type piracy: any
# unrelated `write(io, some_symbol, some_bool)` in any package would silently
# change meaning once RDF.jl is loaded.  (The `write(io, ::MIME, ::Bool)`
# methods in sparql/results.jl are safe by comparison — the media type in the
# MIME parameter namespaces them.)  ASK results are plain `Bool`s, so they take
# the MIME form:
#
#     write(io, MIME"application/sparql-results+json"(), sparql(ds, "ASK { … }"))
