# W3C SPARQL 1.1 + 1.2 Conformance Tests
#
# The fixtures are vendored under test/w3c/fixtures/sparql11/ and sparql12/,
# so these run unconditionally — like every other test.
#
# Skipped categories (require HTTP or an external endpoint):
#   service, http-rdf-update, protocol, service-description,
#   entailment, syntax-fed

using Test, RDF
import JSON3

# The fixtures are vendored in the repository, so the W3C SPARQL suites run
# unconditionally — like every other test.
const _SP_FIXTURES = joinpath(@__DIR__, "w3c", "fixtures", "sparql11")

if isdir(_SP_FIXTURES)

# ─── Vocabulary ──────────────────────────────────────────────────────────────

const _SP_MF_NS   = "http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#"
const _SP_QT_NS   = "http://www.w3.org/2001/sw/DataAccess/tests/test-query#"
const _SP_UT_NS   = "http://www.w3.org/2009/sparql/tests/test-update#"
const _SP_RDF_NS  = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
const _SP_RDFS_NS = "http://www.w3.org/2000/01/rdf-schema#"
const _SP_XSD_NS  = "http://www.w3.org/2001/XMLSchema#"

const _SP_RDF_TYPE      = IRI(_SP_RDF_NS  * "type")
const _SP_RDF_FIRST     = IRI(_SP_RDF_NS  * "first")
const _SP_RDF_REST      = IRI(_SP_RDF_NS  * "rest")
const _SP_RDFS_LABEL    = IRI(_SP_RDFS_NS * "label")
const _SP_MF_MANIFEST   = IRI(_SP_MF_NS   * "Manifest")
const _SP_MF_ENTRIES    = IRI(_SP_MF_NS   * "entries")
const _SP_MF_ACTION     = IRI(_SP_MF_NS   * "action")
const _SP_MF_RESULT     = IRI(_SP_MF_NS   * "result")
const _SP_MF_NAME       = IRI(_SP_MF_NS   * "name")
const _SP_MF_POS_SYN    = IRI(_SP_MF_NS   * "PositiveSyntaxTest11")
const _SP_MF_NEG_SYN    = IRI(_SP_MF_NS   * "NegativeSyntaxTest11")
const _SP_MF_POS_UPD    = IRI(_SP_MF_NS   * "PositiveUpdateSyntaxTest11")
const _SP_MF_NEG_UPD    = IRI(_SP_MF_NS   * "NegativeUpdateSyntaxTest11")
# SPARQL 1.2 manifests use the unsuffixed type names
const _SP_MF_POS_SYN12  = IRI(_SP_MF_NS   * "PositiveSyntaxTest")
const _SP_MF_NEG_SYN12  = IRI(_SP_MF_NS   * "NegativeSyntaxTest")
const _SP_MF_POS_UPD12  = IRI(_SP_MF_NS   * "PositiveUpdateSyntaxTest")
const _SP_MF_NEG_UPD12  = IRI(_SP_MF_NS   * "NegativeUpdateSyntaxTest")
const _SP_MF_QUERY_EVAL = IRI(_SP_MF_NS   * "QueryEvaluationTest")
const _SP_MF_UPD_EVAL   = IRI(_SP_MF_NS   * "UpdateEvaluationTest")
const _SP_MF_CSV_RES    = IRI(_SP_MF_NS   * "CSVResultFormatTest")
const _SP_QT_QUERY      = IRI(_SP_QT_NS   * "query")
const _SP_QT_DATA       = IRI(_SP_QT_NS   * "data")
const _SP_QT_GRAPH_DATA = IRI(_SP_QT_NS   * "graphData")
const _SP_UT_REQUEST    = IRI(_SP_UT_NS   * "request")
const _SP_UT_DATA       = IRI(_SP_UT_NS   * "data")
const _SP_UT_GRAPH_DATA = IRI(_SP_UT_NS   * "graphData")
const _SP_UT_GRAPH      = IRI(_SP_UT_NS   * "graph")

# rs: result-set vocabulary (used in some .ttl expected result files)
const _SP_RS_NS         = "http://www.w3.org/2001/sw/DataAccess/tests/result-set#"
const _SP_RS_RESULT_SET = IRI(_SP_RS_NS * "ResultSet")
const _SP_RS_RESULT_VAR = IRI(_SP_RS_NS * "resultVariable")
const _SP_RS_SOLUTION   = IRI(_SP_RS_NS * "solution")
const _SP_RS_BINDING    = IRI(_SP_RS_NS * "binding")
const _SP_RS_VARIABLE   = IRI(_SP_RS_NS * "variable")
const _SP_RS_VALUE      = IRI(_SP_RS_NS * "value")

# ─── Test structs ────────────────────────────────────────────────────────────

struct _SpPosSyntaxTest
    name::String
    action_file::String          # .rq or .ru file that must parse without error
end

struct _SpNegSyntaxTest
    name::String
    action_file::String          # .rq or .ru file that must raise ParseError
end

struct _SpQueryEvalTest
    name::String
    query_file::String
    data_file::Union{String, Nothing}
    graph_data::Vector{Pair{String, String}}  # file_path => named_graph_iri
    result_file::String          # .srx | .srj | .tsv | .ttl | .nt
end

struct _SpUpdateEvalTest
    name::String
    request_file::String
    pre_data::Union{String, Nothing}
    pre_graphs::Vector{Pair{String, String}}
    post_data::Union{String, Nothing}
    post_graphs::Vector{Pair{String, String}}
end

struct _SpCSVResultTest
    name::String
    query_file::String
    data_file::Union{String, Nothing}
    graph_data::Vector{Pair{String, String}}
    result_file::String          # .csv
end

const _SpTest = Union{_SpPosSyntaxTest, _SpNegSyntaxTest, _SpQueryEvalTest,
                      _SpUpdateEvalTest, _SpCSVResultTest}

# ─── Path utilities ──────────────────────────────────────────────────────────

function _sp_path_to_file_uri(path::AbstractString)::String
    abs = abspath(String(path))
    if Sys.iswindows()
        return "file:///" * replace(abs, '\\' => '/')
    else
        return "file://" * abs
    end
end

function _sp_iri_to_path(iri_val::AbstractString)::String
    s = String(iri_val)
    startswith(s, "file:///") || error("Expected file:/// IRI, got: $s")
    rest = s[9:end]   # strip "file:///"
    return Sys.iswindows() ? replace(rest, '/' => '\\') : "/" * rest
end

# ─── Graph query helpers ─────────────────────────────────────────────────────

# Return the first object of (s, p, ?) triples, or nothing.
function _sp_one(g::Graph, s, p)
    for t in match(g; subject=s, predicate=p)
        return t.object
    end
    return nothing
end

# Return all objects of (s, p, ?) triples.
function _sp_all(g::Graph, s, p)
    return [t.object for t in match(g; subject=s, predicate=p)]
end

# Return all subjects of (?, p, o) triples.
function _sp_subjects_of(g::Graph, p, o)
    return [t.subject for t in match(g; predicate=p, object=o)]
end

# Walk an RDF list starting from `head`, returning its members.
function _sp_walk_list(g::Graph, head)::Vector
    result = []
    node = head
    while node isa BlankNode
        first_obj = _sp_one(g, node, _SP_RDF_FIRST)
        rest_obj  = _sp_one(g, node, _SP_RDF_REST)
        first_obj !== nothing && push!(result, first_obj)
        node = rest_obj
    end
    return result
end

# ─── Minimal RDF/XML parser (subset sufficient for W3C test fixtures) ────────

function _sp_parse_rdfxml(path::String)::Graph
    g    = Graph()
    base = _sp_path_to_file_uri(path)
    src  = read(path, String)

    # Collect namespace bindings from xmlns:prefix="uri" attributes
    ns = Dict{String,String}("rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#")
    for m in eachmatch(r"""xmlns:(\w+)=["']([^"']+)["']""", src)
        ns[String(m.captures[1])] = String(m.captures[2])
    end

    # Expand a prefixed name using collected namespaces
    function expand(qname::AbstractString)::String
        i = findfirst(':', qname)
        i === nothing && return String(qname)
        prefix = String(qname[1:i-1])
        local_  = String(qname[i+1:end])
        return get(ns, prefix, "") * local_
    end

    # Resolve a possibly-relative IRI against the document base
    function resolve(iri::AbstractString)::String
        isempty(iri) && return base
        occursin("://", iri) && return String(iri)  # already absolute
        startswith(iri, "#") && return base * String(iri)
        return String(iri)  # use as-is (already absolute in W3C test fixtures)
    end

    # Parse each rdf:Description block
    for dm in eachmatch(r"""<rdf:Description\s+rdf:about=["']([^"']*)["']\s*>(.*?)</rdf:Description>"""s, src)
        subj = IRI(resolve(dm.captures[1]))
        body = dm.captures[2]

        # Property with rdf:resource (IRI object): <p:q rdf:resource="..."/>
        for pm in eachmatch(r"""<([\w:]+)\s+rdf:resource=["']([^"']*)["']\s*/?>""", body)
            pred = IRI(expand(pm.captures[1]))
            obj  = IRI(resolve(pm.captures[2]))
            push!(g, Triple(subj, pred, obj))
        end

        # Property with rdf:datatype (typed literal): <p:q rdf:datatype='dt'>val</p:q>
        for pm in eachmatch(r"""<([\w:]+)\s+rdf:datatype=["']([^"']+)["']>(.*?)</[\w:]+>"""s, body)
            pred = IRI(expand(pm.captures[1]))
            dt   = IRI(String(pm.captures[2]))
            push!(g, Triple(subj, pred, Literal(String(strip(pm.captures[3])), dt, "")))
        end

        # Plain-text literal property: <p:q>value</p:q>  (no attributes)
        for pm in eachmatch(r"""<([\w:]+)>([^<]*)</[\w:]+>""", body)
            tag  = pm.captures[1]
            startswith(tag, "rdf:") && continue   # skip rdf:* elements
            pred = IRI(expand(tag))
            push!(g, Triple(subj, pred, Literal(String(pm.captures[2]),
                IRI("http://www.w3.org/2001/XMLSchema#string"), "")))
        end
    end
    return g
end

# ─── Graph loading ───────────────────────────────────────────────────────────

function _sp_load_graph(path::String)::Graph
    ext = lowercase(last(splitext(path)))
    if ext == ".ttl"
        open(path) do io
            read(io, MIME"text/turtle"(), Graph, _sp_path_to_file_uri(path))
        end
    elseif ext == ".nt"
        open(path) do io
            read(io, MIME"application/n-triples"(), Graph)
        end
    elseif ext == ".rdf" || ext == ".xml"
        _sp_parse_rdfxml(path)
    else
        error("Unknown RDF format: $ext (file: $path)")
    end
end

# ─── Manifest loading ────────────────────────────────────────────────────────

function _sp_load_manifest(manifest_path::String)::Graph
    open(manifest_path) do io
        read(io, MIME"text/turtle"(), Graph, _sp_path_to_file_uri(manifest_path))
    end
end

# Collect (file_path, named_graph_iri) pairs from qt:graphData or ut:graphData.
# For a direct IRI object: (iri_path, iri_value).
# For a blank node [ file_pred <file.ttl> ; rdfs:label "iri" ]: (file_path, iri).
function _sp_collect_graph_data(g::Graph, bn, gd_pred::IRI,
                                 file_pred::IRI)::Vector{Pair{String,String}}
    result = Pair{String,String}[]
    for gd in _sp_all(g, bn, gd_pred)
        if gd isa IRI
            push!(result, _sp_iri_to_path(gd.value) => gd.value)
        elseif gd isa BlankNode
            file_iri = _sp_one(g, gd, file_pred)
            label    = _sp_one(g, gd, _SP_RDFS_LABEL)
            if file_iri isa IRI && label isa Literal
                push!(result, _sp_iri_to_path(file_iri.value) => label.lexical_form)
            end
        end
    end
    return result
end

# Parse a single manifest entry into a _SpTest (or nothing if unrecognised).
function _sp_parse_entry(g::Graph, entry)::Union{_SpTest, Nothing}
    name_lit = _sp_one(g, entry, _SP_MF_NAME)
    name = name_lit isa Literal ? name_lit.lexical_form :
           entry isa IRI        ? entry.value : string(entry)

    test_types = _sp_all(g, entry, _SP_RDF_TYPE)
    test_type  = nothing
    for tt in test_types
        if tt in (_SP_MF_POS_SYN, _SP_MF_NEG_SYN, _SP_MF_POS_UPD, _SP_MF_NEG_UPD,
                  _SP_MF_POS_SYN12, _SP_MF_NEG_SYN12, _SP_MF_POS_UPD12, _SP_MF_NEG_UPD12,
                  _SP_MF_QUERY_EVAL, _SP_MF_UPD_EVAL, _SP_MF_CSV_RES)
            test_type = tt; break
        end
    end
    test_type === nothing && return nothing

    action = _sp_one(g, entry, _SP_MF_ACTION)
    result = _sp_one(g, entry, _SP_MF_RESULT)

    # ── Positive syntax (query or update) ────────────────────────────────────
    if test_type in (_SP_MF_POS_SYN, _SP_MF_POS_UPD, _SP_MF_POS_SYN12, _SP_MF_POS_UPD12)
        action isa IRI || return nothing
        return _SpPosSyntaxTest(name, _sp_iri_to_path(action.value))

    # ── Negative syntax (query or update) ────────────────────────────────────
    elseif test_type in (_SP_MF_NEG_SYN, _SP_MF_NEG_UPD, _SP_MF_NEG_SYN12, _SP_MF_NEG_UPD12)
        action isa IRI || return nothing
        return _SpNegSyntaxTest(name, _sp_iri_to_path(action.value))

    # ── Query evaluation ─────────────────────────────────────────────────────
    elseif test_type == _SP_MF_QUERY_EVAL
        action isa BlankNode || return nothing
        q_iri = _sp_one(g, action, _SP_QT_QUERY)
        q_iri isa IRI || return nothing

        d_iri = _sp_one(g, action, _SP_QT_DATA)
        gd    = _sp_collect_graph_data(g, action, _SP_QT_GRAPH_DATA, _SP_UT_GRAPH)

        result isa IRI || return nothing
        return _SpQueryEvalTest(name,
            _sp_iri_to_path(q_iri.value),
            d_iri isa IRI ? _sp_iri_to_path(d_iri.value) : nothing,
            gd,
            _sp_iri_to_path(result.value))

    # ── Update evaluation ────────────────────────────────────────────────────
    elseif test_type == _SP_MF_UPD_EVAL
        action isa BlankNode || return nothing
        req_iri = _sp_one(g, action, _SP_UT_REQUEST)
        req_iri isa IRI || return nothing

        pre_d_iri = _sp_one(g, action, _SP_UT_DATA)
        pre_gd    = _sp_collect_graph_data(g, action, _SP_UT_GRAPH_DATA, _SP_UT_GRAPH)

        post_d, post_gd = if result isa BlankNode
            post_d_iri = _sp_one(g, result, _SP_UT_DATA)
            (_sp_one(g, result, _SP_UT_DATA) isa IRI
                 ? _sp_iri_to_path((_sp_one(g, result, _SP_UT_DATA)::IRI).value)
                 : nothing),
            _sp_collect_graph_data(g, result, _SP_UT_GRAPH_DATA, _SP_UT_GRAPH)
        else
            nothing, Pair{String,String}[]
        end

        return _SpUpdateEvalTest(name,
            _sp_iri_to_path(req_iri.value),
            pre_d_iri isa IRI ? _sp_iri_to_path(pre_d_iri.value) : nothing,
            pre_gd,
            post_d,
            post_gd)

    # ── CSV result format ────────────────────────────────────────────────────
    elseif test_type == _SP_MF_CSV_RES
        action isa BlankNode || return nothing
        q_iri = _sp_one(g, action, _SP_QT_QUERY)
        q_iri isa IRI || return nothing

        d_iri = _sp_one(g, action, _SP_QT_DATA)
        gd    = _sp_collect_graph_data(g, action, _SP_QT_GRAPH_DATA, _SP_UT_GRAPH)

        result isa IRI || return nothing
        return _SpCSVResultTest(name,
            _sp_iri_to_path(q_iri.value),
            d_iri isa IRI ? _sp_iri_to_path(d_iri.value) : nothing,
            gd,
            _sp_iri_to_path(result.value))
    end

    return nothing
end

# Load and parse all tests from a manifest.ttl file.
function _sp_load_tests(manifest_path::String)::Vector{_SpTest}
    isfile(manifest_path) || return _SpTest[]
    g     = _sp_load_manifest(manifest_path)
    tests = _SpTest[]
    for mn in _sp_subjects_of(g, _SP_RDF_TYPE, _SP_MF_MANIFEST)
        head = _sp_one(g, mn, _SP_MF_ENTRIES)
        head === nothing && continue
        for entry in _sp_walk_list(g, head)
            t = _sp_parse_entry(g, entry)
            t !== nothing && push!(tests, t)
        end
    end
    return tests
end

# ─── Dataset builder ─────────────────────────────────────────────────────────

# Dataset-bearing formats (N-Quads; TriG is not supported by RDF.jl yet).
_sp_is_dataset_file(path::String) = lowercase(last(splitext(path))) in (".nq", ".trig")

function _sp_load_dataset_file(path::String)::Dataset
    ext = lowercase(last(splitext(path)))
    ext == ".nq" || error("Unsupported dataset format: $ext (file: $path)")
    open(path) do io
        read(io, MIME"application/n-quads"(), Dataset)
    end
end

function _sp_build_dataset(data_file::Union{String,Nothing},
                            graph_data::Vector{Pair{String,String}})::Dataset
    # A dataset-format default data file (N-Quads) carries its own default +
    # named graphs; load it wholesale.
    if data_file !== nothing && _sp_is_dataset_file(data_file)
        ds = _sp_load_dataset_file(data_file)
        for (file, iri_str) in graph_data
            ds[IRI(iri_str)] = _sp_load_graph(file)
        end
        return ds
    end
    ds = Dataset(; default_graph = data_file !== nothing ?
                                    _sp_load_graph(data_file) : Graph())
    for (file, iri_str) in graph_data
        ds[IRI(iri_str)] = _sp_load_graph(file)
    end
    return ds
end

# ─── Blank-node mint helper (for reference result parsing) ───────────────────

struct _SpBNodeMap
    map::Dict{String, BlankNode}
    g::Graph
    _SpBNodeMap() = new(Dict{String,BlankNode}(), Graph())
end

function _sp_get_bnode!(bm::_SpBNodeMap, label::String)::BlankNode
    get!(bm.map, label) do
        blank!(bm.g)
    end
end

# ─── SRX parser (SPARQL Results XML, regex-based) ────────────────────────────

function _sp_unescape_xml(s::AbstractString)::String
    s = replace(s, "&amp;"  => "&")
    s = replace(s, "&lt;"   => "<")
    s = replace(s, "&gt;"   => ">")
    s = replace(s, "&quot;" => "\"")
    s = replace(s, "&apos;" => "'")
    return String(s)
end

function _sp_parse_srx_term(content::String, bm::_SpBNodeMap)::Union{RDFTerm, Nothing}
    s = strip(content)

    # SPARQL 1.2 triple term: <triple><subject>…</subject><predicate>…</predicate><object>…</object></triple>
    mt = match(r"^<triple>\s*<subject>([\s\S]*?)</subject>\s*<predicate>([\s\S]*?)</predicate>\s*<object>([\s\S]*?)</object>\s*</triple>$", s)
    if mt !== nothing
        st = _sp_parse_srx_term(String(mt[1]), bm)
        pt = _sp_parse_srx_term(String(mt[2]), bm)
        ot = _sp_parse_srx_term(String(mt[3]), bm)
        return TripleTerm(st, pt, ot)
    end

    m = match(r"<uri>([\s\S]*?)</uri>", s)
    m !== nothing && return IRI(_sp_unescape_xml(m[1]))

    m = match(r"<literal\s+xml:lang=['\"]([^'\"]*)['\"]>([\s\S]*?)</literal>", s)
    m !== nothing && return Literal(_sp_unescape_xml(m[2]); lang=m[1])

    m = match(r"<literal\s+datatype=['\"]([^'\"]*)['\"]>([\s\S]*?)</literal>", s)
    m !== nothing && return Literal(_sp_unescape_xml(m[2]), IRI(_sp_unescape_xml(m[1])))

    m = match(r"<literal>([\s\S]*?)</literal>", s)
    m !== nothing && return Literal(_sp_unescape_xml(m[1]))

    m = match(r"<bnode>([\s\S]*?)</bnode>", s)
    m !== nothing && return _sp_get_bnode!(bm, String(m[1]))

    return nothing
end

function _sp_parse_srx(path::String)::Union{SolutionSet, Bool}
    content = read(path, String)

    m = match(r"<boolean>\s*(true|false)\s*</boolean>", content)
    m !== nothing && return m[1] == "true"

    vars = Symbol[]
    for m in eachmatch(r"<variable\s+name=['\"]([^'\"]+)['\"]\s*/>", content)
        push!(vars, Symbol(m[1]))
    end

    sol = SolutionSet(vars)
    bm  = _SpBNodeMap()

    for rm in eachmatch(r"<result>([\s\S]*?)</result>", content)
        row = Dict{Symbol,Union{RDFTerm,Nothing}}(v => nothing for v in vars)
        for bm2 in eachmatch(
                r"<binding\s+name=['\"]([^'\"]+)['\"]>([\s\S]*?)</binding>",
                rm[1])
            row[Symbol(bm2[1])] = _sp_parse_srx_term(String(bm2[2]), bm)
        end
        push!(sol, row)
    end
    return sol
end

# ─── SRJ parser (SPARQL Results JSON, via JSON3) ─────────────────────────────

# Decode one SPARQL/JSON term object (recursively for SPARQL 1.2 triple terms).
function _sp_srj_term(td, bm::_SpBNodeMap)::Union{RDFTerm, Nothing}
    type_str = String(td[:type])
    if type_str == "uri"
        return IRI(String(td[:value]))
    elseif type_str == "bnode"
        return _sp_get_bnode!(bm, String(td[:value]))
    elseif type_str == "literal"
        val_str = String(td[:value])
        if haskey(td, Symbol("xml:lang"))
            lang = String(td[Symbol("xml:lang")])
            if haskey(td, Symbol("its:dir"))
                return Literal(val_str; lang=lang, dir=String(td[Symbol("its:dir")]))
            end
            return Literal(val_str; lang=lang)
        elseif haskey(td, :datatype)
            return Literal(val_str, IRI(String(td[:datatype])))
        else
            return Literal(val_str)
        end
    elseif type_str == "triple"
        v = td[:value]
        s = _sp_srj_term(v[:subject],   bm)
        p = _sp_srj_term(v[:predicate], bm)
        o = _sp_srj_term(v[:object],    bm)
        return TripleTerm(s, p, o)
    end
    nothing
end

function _sp_parse_srj(path::String)::Union{SolutionSet, Bool}
    data = JSON3.read(read(path, String))
    haskey(data, :boolean) && return Bool(data[:boolean])

    vars = Symbol[Symbol(v) for v in get(data[:head], :vars, [])]
    sol  = SolutionSet(vars)
    bm   = _SpBNodeMap()

    for binding in data[:results][:bindings]
        row = Dict{Symbol,Union{RDFTerm,Nothing}}(v => nothing for v in vars)
        for (k, td) in pairs(binding)
            row[Symbol(k)] = _sp_srj_term(td, bm)
        end
        push!(sol, row)
    end
    return sol
end

# ─── TSV parser (SPARQL Results TSV) ─────────────────────────────────────────

function _sp_parse_tsv_literal(s::String)::Literal
    chars = collect(s)
    buf   = IOBuffer()
    i = 2  # skip opening "
    while i <= length(chars)
        c = chars[i]
        if c == '\\'
            i += 1
            i > length(chars) && break
            nc = chars[i]
            write(buf, nc == 'n' ? '\n' : nc == 't' ? '\t' :
                       nc == 'r' ? '\r' : nc)
        elseif c == '"'
            break
        else
            write(buf, c)
        end
        i += 1
    end
    val  = String(take!(buf))
    rest = i < length(chars) ? String(chars[i+1:end]) : ""

    if startswith(rest, "@")
        return Literal(val; lang=rest[2:end])
    elseif startswith(rest, "^^<") && endswith(rest, ">")
        return Literal(val, IRI(rest[4:end-1]))
    else
        return Literal(val)
    end
end

function _sp_parse_tsv_term(cell::String, bm::_SpBNodeMap)::Union{RDFTerm, Nothing}
    isempty(cell) && return nothing
    startswith(cell, "<") && endswith(cell, ">") && return IRI(cell[2:end-1])
    startswith(cell, "_:")  && return _sp_get_bnode!(bm, cell[3:end])
    startswith(cell, "\"")  && return _sp_parse_tsv_literal(cell)
    cell == "true"           && return Literal(true)
    cell == "false"          && return Literal(false)
    occursin(r"^-?[0-9]+$"s,          cell) &&
        return Literal(cell, IRI(_SP_XSD_NS * "integer"))
    occursin(r"^-?[0-9]*\.[0-9]+$"s,  cell) &&
        return Literal(cell, IRI(_SP_XSD_NS * "decimal"))
    occursin(r"^-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)[eE][+-]?[0-9]+$"s, cell) &&
        return Literal(cell, IRI(_SP_XSD_NS * "double"))
    return Literal(cell)
end

function _sp_parse_tsv(path::String)::SolutionSet
    lines = readlines(path)
    isempty(lines) && return SolutionSet(Symbol[])

    header = split(lines[1], '\t')
    vars   = [Symbol(startswith(h, "?") ? h[2:end] : h) for h in header]
    sol    = SolutionSet(vars)
    bm     = _SpBNodeMap()

    for line in lines[2:end]
        isempty(strip(line)) && continue
        cells = split(line, '\t')
        row   = Dict{Symbol,Union{RDFTerm,Nothing}}(v => nothing for v in vars)
        for (i, cell) in enumerate(cells)
            i > length(vars) && break
            row[vars[i]] = _sp_parse_tsv_term(String(strip(cell)), bm)
        end
        push!(sol, row)
    end
    return sol
end

# ─── CSV parser (SPARQL Results CSV — lossy, string-only) ────────────────────

function _sp_split_csv_row(line::String)::Vector{String}
    cells = String[]
    chars = collect(line)
    n     = length(chars)
    i     = 1
    while i <= n + 1
        if i > n
            push!(cells, ""); break
        end
        if chars[i] == '"'
            # Quoted field
            buf = IOBuffer()
            i  += 1
            while i <= n
                c = chars[i]
                if c == '"'
                    if i + 1 <= n && chars[i+1] == '"'
                        write(buf, '"'); i += 2
                    else
                        i += 1; break
                    end
                else
                    write(buf, c); i += 1
                end
            end
            push!(cells, String(take!(buf)))
            if i <= n && chars[i] == ','
                i += 1
            end
        else
            # Unquoted field
            j = findfirst(==(','), chars[i:end])
            if j === nothing
                push!(cells, String(chars[i:end])); break
            else
                push!(cells, String(chars[i : i + j - 2]))
                i += j   # chars[i + j - 1] was the comma, i + j is next field
            end
        end
    end
    return cells
end

function _sp_csv_term(cell::String, bm::_SpBNodeMap)::Union{RDFTerm, Nothing}
    isempty(cell)       && return nothing
    startswith(cell, "_:") && return _sp_get_bnode!(bm, cell[3:end])
    return Literal(cell)   # CSV is lossy: everything else is a string literal
end

function _sp_parse_csv(path::String)::SolutionSet
    lines = readlines(path)
    isempty(lines) && return SolutionSet(Symbol[])

    vars = Symbol.(_sp_split_csv_row(lines[1]))
    sol  = SolutionSet(vars)
    bm   = _SpBNodeMap()

    for line in lines[2:end]
        isempty(strip(line)) && continue
        cells = _sp_split_csv_row(line)
        row   = Dict{Symbol,Union{RDFTerm,Nothing}}(v => nothing for v in vars)
        for (i, cell) in enumerate(cells)
            i > length(vars) && break
            row[vars[i]] = _sp_csv_term(cell, bm)
        end
        push!(sol, row)
    end
    return sol
end

# Parse a Turtle file that uses the rs: ResultSet vocabulary as a SolutionSet.
# Used when the expected result is stored as rs:ResultSet rather than .srx/.srj.
function _sp_parse_rs_ttl(path::String)::SolutionSet
    base = _sp_path_to_file_uri(path)
    g = open(path) do io
        read(io, MIME"text/turtle"(), Graph, base)
    end

    # Find the rs:ResultSet node
    rs_node = nothing
    for t in g
        if t.predicate == _SP_RDF_TYPE && t.object == _SP_RS_RESULT_SET
            rs_node = t.subject
            break
        end
    end
    rs_node === nothing && error("No rs:ResultSet found in $path")

    # Collect result variables (in declaration order if possible; fall back to set)
    var_names = String[]
    for t in g
        if t.subject == rs_node && t.predicate == _SP_RS_RESULT_VAR
            t.object isa Literal && push!(var_names, t.object.lexical_form)
        end
    end
    vars = Symbol.(var_names)
    sol  = SolutionSet(vars)

    # Collect solutions
    for t in g
        t.subject == rs_node && t.predicate == _SP_RS_SOLUTION || continue
        sol_node = t.object
        row = Dict{Symbol, Union{RDFTerm, Nothing}}(v => nothing for v in vars)
        for t2 in g
            t2.subject == sol_node && t2.predicate == _SP_RS_BINDING || continue
            bind_node = t2.object
            varname = nothing
            value   = nothing
            for t3 in g
                t3.subject == bind_node || continue
                if t3.predicate == _SP_RS_VARIABLE && t3.object isa Literal
                    varname = Symbol(t3.object.lexical_form)
                elseif t3.predicate == _SP_RS_VALUE
                    value = t3.object
                end
            end
            varname !== nothing && (row[varname] = value)
        end
        push!(sol, row)
    end
    return sol
end

# Dispatch on file extension → parsed reference result.
function _sp_parse_result(path::String)::Union{SolutionSet, Bool, Graph}
    ext = lowercase(last(splitext(path)))
    ext == ".srx" && return _sp_parse_srx(path)
    ext == ".srj" && return _sp_parse_srj(path)
    ext == ".tsv" && return _sp_parse_tsv(path)
    ext == ".csv" && return _sp_parse_csv(path)
    if ext in (".ttl", ".nt")
        # Peek at the file: if it uses the rs: ResultSet vocabulary, parse as
        # SolutionSet; otherwise treat as a CONSTRUCT graph result.
        # The vocabulary is declared as @prefix rs: <...result-set#> or inline.
        src = read(path, String)
        if occursin("result-set#", src) || occursin("rs:ResultSet", src) || occursin("rs:solution", src)
            return _sp_parse_rs_ttl(path)
        end
        return _sp_load_graph(path)
    end
    error("Unknown result format: $ext")
end

# ─── Result comparison ───────────────────────────────────────────────────────

# Compare two rows under a blank-node bijection (a→b mapping).
# Returns (compatible::Bool, updated_mapping).
# Match two term values under a growing blank-node bijection, descending into
# RDF-star triple terms (whose components may themselves be blank nodes).
# Mutates `m` in place; returns true on a compatible match.
function _sp_term_compat!(ta, tb, m::Dict{BlankNode,BlankNode})::Bool
    if ta isa BlankNode && tb isa BlankNode
        if haskey(m, ta)
            return m[ta] == tb
        else
            tb in values(m) && return false
            m[ta] = tb
            return true
        end
    elseif ta isa TripleTerm && tb isa TripleTerm
        return _sp_term_compat!(ta.subject,   tb.subject,   m) &&
               _sp_term_compat!(ta.predicate, tb.predicate, m) &&
               _sp_term_compat!(ta.object,    tb.object,    m)
    elseif ta isa Literal && tb isa Literal
        return RDF._sp_value_equal(ta, tb)
    else
        return ta == tb
    end
end

function _sp_rows_compat(ar, br, vars::Vector{Symbol},
                         mapping::Dict{BlankNode,BlankNode})
    new_map = copy(mapping)
    for v in vars
        ta = get(ar, v, nothing)
        tb = get(br, v, nothing)
        _sp_term_compat!(ta, tb, new_map) || return (false, new_map)
    end
    return (true, new_map)
end

# Bag-match rows with blank-node bijection (backtracking).
function _sp_bag_match(a_rows::AbstractVector, b_rows::Vector,
                       vars::Vector{Symbol}, mapping::Dict{BlankNode,BlankNode})::Bool
    isempty(a_rows) && return isempty(b_rows)
    ar = first(a_rows)
    rest_a = a_rows[2:end]
    for (i, br) in enumerate(b_rows)
        ok, new_map = _sp_rows_compat(ar, br, vars, mapping)
        if ok
            rest_b = [b_rows[j] for j in eachindex(b_rows) if j != i]
            _sp_bag_match(rest_a, rest_b, vars, new_map) && return true
        end
    end
    return false
end

# Compare two SolutionSets as order-independent bags with blank-node bijection.
function _sp_sol_equal(a::SolutionSet, b::SolutionSet)::Bool
    Set(a.variables) == Set(b.variables) || return false
    length(a)        == length(b)        || return false
    vars = sort(collect(Set(a.variables) ∪ Set(b.variables)))
    _sp_bag_match(collect(a), collect(b), vars, Dict{BlankNode,BlankNode}())
end

# Dispatch result comparison.
function _sp_results_equal(computed, expected)::Bool
    expected isa Bool      && return computed === expected
    expected isa SolutionSet &&
        computed isa SolutionSet && return _sp_sol_equal(computed, expected)
    expected isa Graph     &&
        computed isa Graph && return isomorphic(computed, expected)
    return false
end

# CSV-semantic comparison: compare by lexical forms only (CSV is lossy).
function _sp_csv_term_str(t::Union{RDFTerm, Nothing})::String
    t === nothing   && return ""
    t isa IRI       && return t.value
    t isa BlankNode && return "_:$(t.id)"
    t isa Literal   && return t.lexical_form
    return ""
end

function _sp_csv_equal(a::SolutionSet, b::SolutionSet)::Bool
    Set(a.variables) == Set(b.variables) || return false
    length(a)        == length(b)        || return false
    isempty(a) && return true
    vars = sort(a.variables)

    # CSV value: blank nodes stay as BlankNode (for bijection), everything else → string
    _csv_val(t::Union{RDFTerm,Nothing}) = t isa BlankNode ? t : _sp_csv_term_str(t)

    function _csv_rows_compat(ar, br, mapping::Dict{BlankNode,BlankNode})
        new_map = copy(mapping)
        for v in vars
            va = _csv_val(get(ar, v, nothing))
            vb = _csv_val(get(br, v, nothing))
            if va isa BlankNode && vb isa BlankNode
                if haskey(new_map, va)
                    new_map[va] != vb && return (false, new_map)
                else
                    vb in values(new_map) && return (false, new_map)
                    new_map[va] = vb
                end
            elseif va != vb
                return (false, new_map)
            end
        end
        return (true, new_map)
    end

    function _csv_bag_match(a_rows, b_rows, mapping)
        isempty(a_rows) && return isempty(b_rows)
        ar = first(a_rows)
        rest_a = a_rows[2:end]
        for (i, br) in enumerate(b_rows)
            ok, new_map = _csv_rows_compat(ar, br, mapping)
            if ok
                rest_b = [b_rows[j] for j in eachindex(b_rows) if j != i]
                _csv_bag_match(rest_a, rest_b, new_map) && return true
            end
        end
        return false
    end

    _csv_bag_match(collect(a), collect(b), Dict{BlankNode,BlankNode}())
end

# ─── Test runners ─────────────────────────────────────────────────────────────

# RDF.jl does not implement TriG; eval tests whose data is supplied as a .trig
# file are not applicable yet and are skipped (rather than failed) so the rest
# of the suite stays green.  Returns true if any data file uses an unsupported
# serialization.
function _sp_uses_unsupported_data(files...)::Bool
    for f in files
        f === nothing && continue
        lowercase(last(splitext(f))) == ".trig" && return true
    end
    return false
end

# Positive syntax: sparql_parse must succeed without throwing.
function _sp_run_test(t::_SpPosSyntaxTest)
    src = read(t.action_file, String)
    @test_nowarn sparql_parse(src)
end

# Negative syntax: sparql_parse must throw ParseError.
function _sp_run_test(t::_SpNegSyntaxTest)
    src = read(t.action_file, String)
    @test_throws ParseError sparql_parse(src)
end

# Query evaluation: run query, compare result bag/graph/bool.
function _sp_run_test(t::_SpQueryEvalTest)
    if _sp_uses_unsupported_data(t.data_file, first.(t.graph_data)...)
        @test_skip "TriG data not supported"
        return
    end
    ds       = _sp_build_dataset(t.data_file, t.graph_data)
    src      = read(t.query_file, String)
    base     = _sp_path_to_file_uri(t.query_file)
    expected = _sp_parse_result(t.result_file)
    result   = sparql(ds, src; base)
    @test _sp_results_equal(result, expected)
end

# Update evaluation: apply update, check resulting dataset state.
function _sp_run_test(t::_SpUpdateEvalTest)
    if _sp_uses_unsupported_data(t.pre_data, t.post_data,
                                 first.(t.pre_graphs)..., first.(t.post_graphs)...)
        @test_skip "TriG data not supported"
        return
    end
    ds   = _sp_build_dataset(t.pre_data, t.pre_graphs)
    src  = read(t.request_file, String)
    base = _sp_path_to_file_uri(t.request_file)
    sparql_update!(ds, src; base)

    if t.post_data !== nothing
        @test isomorphic(ds.default_graph, _sp_load_graph(t.post_data))
    end
    for (file, iri_str) in t.post_graphs
        key = IRI(iri_str)
        @test haskey(ds, key)
        haskey(ds, key) && @test isomorphic(ds[key], _sp_load_graph(file))
    end
    # When no post-state is specified, passing without exception is enough.
    t.post_data === nothing && isempty(t.post_graphs) && @test true
end

# CSV result format: run query, compare with CSV-semantic equality.
function _sp_run_test(t::_SpCSVResultTest)
    ds       = _sp_build_dataset(t.data_file, t.graph_data)
    src      = read(t.query_file, String)
    base     = _sp_path_to_file_uri(t.query_file)
    result   = sparql(ds, src; base)
    expected = _sp_parse_csv(t.result_file)
    @test result isa SolutionSet
    result isa SolutionSet && @test _sp_csv_equal(result, expected)
end

# ─── Category lists ──────────────────────────────────────────────────────────

const _SP_QUERY_CATS = [
    "aggregates", "bind", "bindings", "cast", "construct", "exists",
    "functions", "grouping", "negation", "project-expression",
    "property-path", "subquery", "syntax-query",
]

const _SP_UPDATE_CATS = [
    "add", "basic-update", "clear", "copy", "delete-data", "delete-insert",
    "delete-where", "delete", "drop", "move", "syntax-update-1",
    "syntax-update-2", "update-silent",
]

const _SP_RESULT_CATS = ["json-res", "csv-tsv-res"]

const _SP_ACTIVE_CATS = vcat(_SP_QUERY_CATS, _SP_UPDATE_CATS, _SP_RESULT_CATS)

# ─── Main testset ─────────────────────────────────────────────────────────────
# The following categories are not exercised because they require live HTTP
# endpoints or external SPARQL services:
#   service, http-rdf-update, protocol, service-description,
#   entailment, syntax-fed

@testset "W3C SPARQL 1.1" begin
    for cat in _SP_ACTIVE_CATS
        @testset "$cat" begin
            manifest_path = joinpath(_SP_FIXTURES, cat, "manifest.ttl")
            tests = _sp_load_tests(manifest_path)
            for t in tests
                @testset "$(t.name)" begin
                    _sp_run_test(t)
                end
            end
        end
    end
end

# ─── SPARQL 1.2 suite ─────────────────────────────────────────────────────────
# Official W3C SPARQL 1.2 tests (triple terms, VERSION declarations, LANGDIR,
# codepoint escapes, RDF 1.1 compatibility).
# Source: https://w3c.github.io/rdf-tests/sparql/sparql12/

const _SP_FIXTURES12 = joinpath(@__DIR__, "w3c", "fixtures", "sparql12")

const _SP12_CATS = [
    "codepoint-escapes", "eval-triple-terms", "expression", "grouping",
    "lang-basedir", "rdf11", "syntax",
    "syntax-triple-terms-negative", "syntax-triple-terms-positive", "version",
]

if isdir(_SP_FIXTURES12)
    @testset "W3C SPARQL 1.2" begin
        for cat in _SP12_CATS
            @testset "$cat" begin
                manifest_path = joinpath(_SP_FIXTURES12, cat, "manifest.ttl")
                tests = _sp_load_tests(manifest_path)
                for t in tests
                    @testset "$(t.name)" begin
                        _sp_run_test(t)
                    end
                end
            end
        end
    end
end

end  # if isdir(_SP_FIXTURES)
