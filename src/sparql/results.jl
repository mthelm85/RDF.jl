# SPARQL 1.1 Query Results serialization + deserialization
#
# Implements the W3C standard wire formats for SPARQL results:
#   • SPARQL/JSON  (application/sparql-results+json)  — W3C TR sparql11-results-json
#   • SPARQL/XML   (application/sparql-results+xml)   — W3C TR rdf-sparql-XMLres
#   • SPARQL/CSV   (text/csv)                          — W3C TR sparql11-results-csv-tsv
#   • SPARQL/TSV   (text/tab-separated-values)         — W3C TR sparql11-results-csv-tsv
#
# SELECT/ASK: read + write (SPARQL/JSON); write-only for XML/CSV/TSV.
# Read support is used by the RDFHTTPExt extension to parse endpoint responses.

const _MIME_SPARQL_JSON = MIME"application/sparql-results+json"
const _MIME_SPARQL_XML  = MIME"application/sparql-results+xml"
const _MIME_SPARQL_CSV  = MIME"text/csv"
const _MIME_SPARQL_TSV  = MIME"text/tab-separated-values"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Minimal JSON string escaper — avoids a JSON dependency in this file.
@inline function _srj_write_escaped(io::IO, s::AbstractString)
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c < '\x20'
            print(io, "\\u", string(UInt16(c), base=16, pad=4))
        else
            print(io, c)
        end
    end
end

# Minimal XML character escaper.
@inline function _srx_write_escaped(io::IO, s::AbstractString)
    for c in s
        if c == '&'
            print(io, "&amp;")
        elseif c == '<'
            print(io, "&lt;")
        elseif c == '>'
            print(io, "&gt;")
        elseif c == '"'
            print(io, "&quot;")
        elseif c == '\''
            print(io, "&apos;")
        else
            print(io, c)
        end
    end
end

# ── SPARQL/JSON ───────────────────────────────────────────────────────────────

function _srj_write_term(io::IO, term::RDFTerm)
    if term isa IRI
        print(io, "{\"type\":\"uri\",\"value\":\"")
        _srj_write_escaped(io, term.value)
        print(io, "\"}")
    elseif term isa BlankNode
        print(io, "{\"type\":\"bnode\",\"value\":\"b", term.id, "\"}")
    elseif term isa Literal
        if !isempty(term.language_tag)
            # SPARQL 1.2: a directional tag "lang--dir" splits into
            # "xml:lang" and "its:dir" fields
            dd = findfirst("--", term.language_tag)
            if dd !== nothing
                print(io, "{\"type\":\"literal\",\"xml:lang\":\"")
                _srj_write_escaped(io, term.language_tag[1:first(dd)-1])
                print(io, "\",\"its:dir\":\"")
                _srj_write_escaped(io, term.language_tag[last(dd)+1:end])
            else
                print(io, "{\"type\":\"literal\",\"xml:lang\":\"")
                _srj_write_escaped(io, term.language_tag)
            end
            print(io, "\",\"value\":\"")
            _srj_write_escaped(io, term.lexical_form)
            print(io, "\"}")
        else
            print(io, "{\"type\":\"literal\",\"datatype\":\"")
            _srj_write_escaped(io, term.datatype.value)
            print(io, "\",\"value\":\"")
            _srj_write_escaped(io, term.lexical_form)
            print(io, "\"}")
        end
    elseif term isa TripleTerm
        # SPARQL 1.2: triple-term binding
        print(io, "{\"type\":\"triple\",\"value\":{\"subject\":")
        _srj_write_term(io, term.subject::RDFTerm)
        print(io, ",\"predicate\":")
        _srj_write_term(io, term.predicate)
        print(io, ",\"object\":")
        _srj_write_term(io, term.object::RDFTerm)
        print(io, "}}")
    end
end

"""
    write(io, :json, sol::SolutionSet)
    write(io, MIME"application/sparql-results+json"(), sol::SolutionSet)

Serialize SPARQL SELECT results to the W3C SPARQL 1.1 JSON format
(`application/sparql-results+json`). `:json` and `:srj` are accepted as aliases.
"""
function Base.write(io::IO, ::_MIME_SPARQL_JSON, sol::SolutionSet)
    print(io, "{\"head\":{\"vars\":[")
    for (i, v) in enumerate(sol.variables)
        i > 1 && print(io, ",")
        print(io, "\"", String(v), "\"")
    end
    print(io, "]},\"results\":{\"bindings\":[")
    for (ri, row) in enumerate(sol)
        ri > 1 && print(io, ",")
        print(io, "{")
        first_binding = true
        for v in sol.variables
            val = get(row, v, nothing)
            val === nothing && continue
            first_binding || print(io, ",")
            first_binding = false
            print(io, "\"", String(v), "\":")
            _srj_write_term(io, val)
        end
        print(io, "}")
    end
    print(io, "]}}")
    nothing
end

"""
    write(io, :json, b::Bool)
    write(io, MIME"application/sparql-results+json"(), b::Bool)

Serialize a SPARQL ASK result to the W3C SPARQL 1.1 JSON format.
"""
function Base.write(io::IO, ::_MIME_SPARQL_JSON, b::Bool)
    print(io, "{\"head\":{},\"boolean\":", b ? "true" : "false", "}")
    nothing
end

# ── SPARQL/XML ────────────────────────────────────────────────────────────────

"""
    write(io, :xml, sol::SolutionSet)
    write(io, MIME"application/sparql-results+xml"(), sol::SolutionSet)

Serialize SPARQL SELECT results to the W3C SPARQL 1.1 XML format
(`application/sparql-results+xml`). `:xml` and `:srx` are accepted as aliases.
"""
function Base.write(io::IO, ::_MIME_SPARQL_XML, sol::SolutionSet)
    println(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
    println(io, "<sparql xmlns=\"http://www.w3.org/2005/sparql-results#\">")
    println(io, "  <head>")
    for v in sol.variables
        println(io, "    <variable name=\"", String(v), "\"/>")
    end
    println(io, "  </head>")
    println(io, "  <results>")
    for row in sol
        println(io, "    <result>")
        for v in sol.variables
            val = get(row, v, nothing)
            val === nothing && continue
            print(io, "      <binding name=\"", String(v), "\">")
            _srx_write_term(io, val)
            println(io, "</binding>")
        end
        println(io, "    </result>")
    end
    print(io, "  </results>\n</sparql>")
    nothing
end

function _srx_write_term(io::IO, term::RDFTerm)
    if term isa IRI
        print(io, "<uri>")
        _srx_write_escaped(io, term.value)
        print(io, "</uri>")
    elseif term isa BlankNode
        print(io, "<bnode>b", term.id, "</bnode>")
    elseif term isa Literal
        if !isempty(term.language_tag)
            print(io, "<literal xml:lang=\"")
            _srx_write_escaped(io, term.language_tag)
            print(io, "\">")
            _srx_write_escaped(io, term.lexical_form)
            print(io, "</literal>")
        else
            print(io, "<literal datatype=\"")
            _srx_write_escaped(io, term.datatype.value)
            print(io, "\">")
            _srx_write_escaped(io, term.lexical_form)
            print(io, "</literal>")
        end
    elseif term isa TripleTerm
        # SPARQL 1.2 XML results: <triple><subject>…</subject>…</triple>
        print(io, "<triple><subject>")
        _srx_write_term(io, term.subject::RDFTerm)
        print(io, "</subject><predicate>")
        _srx_write_term(io, term.predicate)
        print(io, "</predicate><object>")
        _srx_write_term(io, term.object::RDFTerm)
        print(io, "</object></triple>")
    end
end

"""
    write(io, MIME"application/sparql-results+xml"(), b::Bool)

Serialize a SPARQL ASK result to the W3C SPARQL 1.1 XML format.
"""
function Base.write(io::IO, ::_MIME_SPARQL_XML, b::Bool)
    println(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
    println(io, "<sparql xmlns=\"http://www.w3.org/2005/sparql-results#\">")
    println(io, "  <head/>")
    println(io, "  <boolean>", b ? "true" : "false", "</boolean>")
    print(io, "</sparql>")
    nothing
end

# ── SPARQL/CSV ────────────────────────────────────────────────────────────────

# RFC 4180: fields containing commas, double-quotes, or newlines must be quoted;
# embedded double-quotes are escaped as two double-quotes.
function _csv_field(term::RDFTerm)::String
    raw = if term isa IRI
        term.value
    elseif term isa BlankNode
        "_:b$(term.id)"
    else  # Literal
        term.lexical_form
    end
    # Quote if necessary per RFC 4180
    if occursin(',', raw) || occursin('"', raw) || occursin('\n', raw) || occursin('\r', raw)
        "\"$(replace(raw, "\"" => "\"\""))\""
    else
        raw
    end
end

"""
    write(io, :csv, sol::SolutionSet)
    write(io, MIME"text/csv"(), sol::SolutionSet)

Serialize SPARQL SELECT results to the W3C SPARQL 1.1 CSV format (`text/csv`).

Blank nodes are serialized as `_:bN`. Unbound variables produce an empty field.
"""
function Base.write(io::IO, ::_MIME_SPARQL_CSV, sol::SolutionSet)
    println(io, join(String.(sol.variables), ","))
    for row in sol
        first_col = true
        for v in sol.variables
            first_col || print(io, ",")
            first_col = false
            val = get(row, v, nothing)
            val !== nothing && print(io, _csv_field(val))
        end
        println(io)
    end
    nothing
end

# ── SPARQL/TSV ────────────────────────────────────────────────────────────────

# SPARQL/TSV uses N-Triples-style term serialization with ?-prefixed header vars.
function _tsv_field(term::RDFTerm)::String
    if term isa IRI
        "<$(term.value)>"
    elseif term isa BlankNode
        "_:b$(term.id)"
    else
        lit = term::Literal
        lex = replace(lit.lexical_form, "\\" => "\\\\", "\"" => "\\\"",
                      "\n" => "\\n", "\r" => "\\r", "\t" => "\\t")
        if !isempty(lit.language_tag)
            "\"$(lex)\"@$(lit.language_tag)"
        else
            dt = lit.datatype.value
            # xsd:string may be written as a plain quoted string per the spec
            if dt == "http://www.w3.org/2001/XMLSchema#string"
                "\"$(lex)\""
            else
                "\"$(lex)\"^^<$(dt)>"
            end
        end
    end
end

"""
    write(io, :tsv, sol::SolutionSet)
    write(io, MIME"text/tab-separated-values"(), sol::SolutionSet)

Serialize SPARQL SELECT results to the W3C SPARQL 1.1 TSV format
(`text/tab-separated-values`).

Variables are prefixed with `?` in the header row. Terms use N-Triples syntax.
Unbound variables produce an empty field.
"""
function Base.write(io::IO, ::_MIME_SPARQL_TSV, sol::SolutionSet)
    println(io, join(["?" * String(v) for v in sol.variables], "\t"))
    for row in sol
        first_col = true
        for v in sol.variables
            first_col || print(io, "\t")
            first_col = false
            val = get(row, v, nothing)
            val !== nothing && print(io, _tsv_field(val))
        end
        println(io)
    end
    nothing
end

# ── SPARQL/JSON reader ────────────────────────────────────────────────────────
#
# Parses a W3C SPARQL 1.1 JSON result document into a SolutionSet (SELECT)
# or Bool (ASK).  Used by the RDFHTTPExt extension to consume endpoint responses.

"""
    read_sparql_json(body::AbstractString) → SolutionSet | Bool

Parse a W3C SPARQL 1.1 JSON result document (the body of an
`application/sparql-results+json` HTTP response) into a `SolutionSet` for
SELECT results or a `Bool` for ASK results.

This is a low-level helper primarily used by the `RDFHTTPExt` extension for
consuming remote SPARQL endpoint responses.  Normal users call `sparql(url, query)`
after loading HTTP.jl.
"""
function read_sparql_json(body::AbstractString)::Union{SolutionSet, Bool}
    obj = JSON.parse(body)

    # ASK response: {"head": {}, "boolean": true/false}
    if haskey(obj, "boolean")
        return Bool(obj["boolean"])
    end

    # SELECT response
    head = obj["head"]
    vars = haskey(head, "vars") ? Symbol.(head["vars"]) : Symbol[]

    ss = SolutionSet(vars)
    results_obj = get(obj, "results", nothing)
    results_obj === nothing && return ss

    bindings = get(results_obj, "bindings", nothing)
    bindings === nothing && return ss

    for binding in bindings
        row = Dict{Symbol, Union{RDFTerm, Nothing}}()
        for var in vars
            entry = get(binding, String(var), nothing)
            row[var] = entry === nothing ? nothing : _srj_read_term(entry)
        end
        push!(ss, row)
    end
    return ss
end

# Convert a single SPARQL/JSON binding object to an RDFTerm.
function _srj_read_term(t)::RDFTerm
    type = String(t["type"])
    if type == "uri"
        return IRI(String(t["value"]))
    elseif type == "bnode"
        # Blank node IDs from remote endpoints are string labels (e.g. "b0").
        # We hash the label to a UInt64 so that the same remote label consistently
        # maps to the same local BlankNode within a single result document.
        return BlankNode(hash(String(t["value"]), UInt(0x424e4f44)))  # seed avoids collision with mint counter
    elseif type == "triple"
        # SPARQL 1.2: triple-term binding — value is a nested s/p/o object
        v = t["value"]
        return TripleTerm(_srj_read_term(v["subject"]),
                          _srj_read_term(v["predicate"]),
                          _srj_read_term(v["object"]))
    else  # "literal" (and any unrecognised type → literal fallback)
        val = String(t["value"])
        if haskey(t, "xml:lang")
            lang = String(t["xml:lang"])
            if haskey(t, "its:dir")   # SPARQL 1.2 base direction
                return Literal(val; lang=lang, dir=String(t["its:dir"]))
            end
            return Literal(val; lang=lang)
        elseif haskey(t, "datatype")
            dt = String(t["datatype"])
            # Positional 2-arg form: Literal(lexical, datatypeIRI)
            return Literal(val, IRI(dt))
        else
            return Literal(val)
        end
    end
end


# ── Unified results writer ────────────────────────────────────────────────────

"""
    write_sparql_results(io::IO, format, result) -> nothing

Serialize any SPARQL query result to one of the four W3C wire formats.

`format` is a symbol — `:json` (`:srj`), `:xml` (`:srx`), `:csv`, `:tsv` — or the
corresponding `MIME` value.  `result` is whatever [`sparql`](@ref) returned: a
`SolutionSet` for SELECT, or a `Bool` for ASK.

This exists because `sparql` returns `Union{SolutionSet, Bool}` depending on the
query form, so code that serializes a query it did not write itself cannot use
`write(io, format, result)` — there is deliberately no `write(io, ::Symbol,
::Bool)` method, as every argument type would belong to Base and defining one
would be type piracy.  `write_sparql_results` is owned by RDF.jl, so it can
accept both arms of that union.

It is the mirror of [`read_sparql_json`](@ref), which already handles both on
the way in.

# Examples

```julia
# Serialize a query whose form is not known ahead of time — e.g. an HTTP
# endpoint doing SPARQL protocol content negotiation
result = sparql(ds, user_query)
write_sparql_results(io, :json, result)     # SELECT and ASK both work

write_sparql_results(io, :csv, sparql(ds, "SELECT * WHERE { ?s ?p ?o }"))
write_sparql_results(io, :xml, sparql(ds, "ASK { ?s ?p ?o }"))
```

CONSTRUCT and DESCRIBE return a `Graph`, which is RDF rather than a result set —
serialize those with `write(io, :ttl, g)` and friends.
"""
function write_sparql_results(io::IO, format, sol::SolutionSet)
    Base.write(io, _results_format_mime(format), sol)
    nothing
end

function write_sparql_results(io::IO, format, b::Bool)
    Base.write(io, _results_format_mime(format), b)
    nothing
end

# CSV and TSV have no serialization for a boolean in the W3C spec — only JSON
# and XML do. Say so plainly rather than letting Base's `write(io, x, xs...)`
# fallback emit a stray byte.
function write_sparql_results(io::IO,
                              format::Union{MIME"text/csv",
                                            MIME"text/tab-separated-values"},
                              b::Bool)
    throw(ArgumentError(
        "SPARQL ASK results have no $(string(format)) serialization — the W3C " *
        "CSV/TSV format covers SELECT result sets only. Use :json or :xml."))
end

write_sparql_results(io::IO, format::Symbol, b::Bool) =
    write_sparql_results(io, _results_format_mime(format), b)
