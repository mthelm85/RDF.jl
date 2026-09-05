# W3C RDF/XML conformance tests
#
# The fixtures are vendored in the repository under test/w3c/fixtures/rdfxml/
# and run unconditionally — like every other W3C suite.
#
# Test types (from the W3C manifest):
#   TestXMLEval:           .rdf + matching .nt → parse .rdf, compare with .nt (isomorphic)
#   TestXMLNegativeSyntax: .rdf with "error" in name → must throw
#
# File naming convention:  <category>-<testname>.rdf / .nt
# Negative tests have "error" in the name and no paired .nt file.

using EzXML   # triggers the RDFXMLExt extension

const _RDFXML_FIXTURES_DIR = joinpath(@__DIR__, "w3c", "fixtures", "rdfxml")

# W3C base URI prefix for the RDF/XML test suite.
# Each test file's base URI is derived from this prefix + the original
# path (category/filename).  Many tests use relative URIs that resolve
# against this base, so getting it right is essential.
const _RDFXML_BASE_PREFIX = "http://www.w3.org/2013/RDFXMLTests/"

# Reconstruct the W3C base URI for a test file from its vendored flat name.
# The flat name is `<category>-<filename>`, e.g. `amp-in-url-test001.rdf`.
# The original W3C path was `<category>/<filename>`, so the base is:
#   http://www.w3.org/2013/RDFXMLTests/<category>/<filename>
#
# Categories in the test suite (each maps to a subdirectory):
const _RDFXML_CATEGORIES = [
    "amp-in-url",
    "datatypes",
    "rdf-charmod-literals",
    "rdf-charmod-uris",
    "rdf-containers-syntax-vs-schema",
    "rdf-element-not-mandatory",
    "rdf-ns-prefix-confusion",
    "rdfms-abouteach",
    "rdfms-difference-between-ID-and-about",
    "rdfms-duplicate-member-props",
    "rdfms-empty-property-elements",
    "rdfms-identity-anon-resources",
    "rdfms-not-id-and-resource-attr",
    "rdfms-para196",
    "rdfms-rdf-id",
    "rdfms-rdf-names-use",
    "rdfms-reification-required",
    "rdfms-seq-representation",
    "rdfms-syntax-incomplete",
    "rdfms-uri-substructure",
    "rdfms-xml-literal-namespaces",
    "rdfms-xmllang",
    "rdfs-domain-and-range",
    "unrecognised-xml-attributes",
    "xml-canon",
    "xmlbase",
]

function _rdfxml_base_uri(flat_name::AbstractString)::String
    stem = replace(flat_name, r"\.(rdf|nt)$" => "")
    # Try each category as a prefix (longest match first — some categories
    # share a common prefix, e.g. "rdfms-rdf-id" vs "rdfms-rdf-names-use").
    for cat in sort(_RDFXML_CATEGORIES, by=length, rev=true)
        prefix = cat * "-"
        if startswith(stem, prefix)
            filename = stem[length(prefix)+1:end]
            return _RDFXML_BASE_PREFIX * cat * "/" * filename * ".rdf"
        end
    end
    # Fallback (shouldn't happen with our vendored set): use the flat name.
    return _RDFXML_BASE_PREFIX * flat_name
end

function _parse_rdfxml_file(path::AbstractString, base::String)::Graph
    open(path, "r") do io
        read(io, MIME"application/rdf+xml"(), Graph, base)
    end
end

function _parse_nt_rdfxml_file(path::AbstractString)::Graph
    open(path, "r") do io
        read(io, MIME"application/n-triples"(), Graph)
    end
end

# Some test files have names like `datatypes-._test002.rdf` (an artifact of
# the flattening process — the original directory contained a dot-prefixed
# test entry).  We skip these non-standard filenames.
_is_artifact(name::AbstractString) = contains(name, "._")

if isdir(_RDFXML_FIXTURES_DIR)

    all_names = readdir(_RDFXML_FIXTURES_DIR; join=false)
    nt_stems  = Set(n[1:end-3] for n in all_names if endswith(n, ".nt"))

    # ── Eval tests ────────────────────────────────────────────────────────────
    @testset "W3C RDF/XML eval tests" begin
        for name in sort(all_names)
            endswith(name, ".rdf") || continue
            _is_artifact(name)    && continue
            stem = name[1:end-4]
            stem in nt_stems || continue          # only paired files

            rdf_file = joinpath(_RDFXML_FIXTURES_DIR, name)
            nt_file  = joinpath(_RDFXML_FIXTURES_DIR, stem * ".nt")
            base     = _rdfxml_base_uri(name)

            @testset "$name" begin
                g_rdf = _parse_rdfxml_file(rdf_file, base)
                g_nt  = _parse_nt_rdfxml_file(nt_file)
                @test g_rdf ≅ g_nt
            end
        end
    end

    # ── Negative syntax tests ────────────────────────────────────────────────
    @testset "W3C RDF/XML negative syntax" begin
        for name in sort(all_names)
            endswith(name, ".rdf") || continue
            _is_artifact(name)    && continue
            contains(name, "error") || continue
            # If there's a paired .nt, it's an eval test, not a negative test
            name[1:end-4] in nt_stems && continue

            rdf_file = joinpath(_RDFXML_FIXTURES_DIR, name)
            base     = _rdfxml_base_uri(name)

            @testset "$name" begin
                @test_throws Exception _parse_rdfxml_file(rdf_file, base)
            end
        end
    end

    # ── Positive syntax tests ────────────────────────────────────────────────
    # .rdf files that are NOT paired with .nt and NOT negative → must parse OK
    @testset "W3C RDF/XML positive syntax" begin
        for name in sort(all_names)
            endswith(name, ".rdf") || continue
            _is_artifact(name)    && continue
            name[1:end-4] in nt_stems && continue
            contains(name, "error")   && continue

            rdf_file = joinpath(_RDFXML_FIXTURES_DIR, name)
            base     = _rdfxml_base_uri(name)

            @testset "$name" begin
                @test_nowarn _parse_rdfxml_file(rdf_file, base)
            end
        end
    end

else
    @warn "RDF/XML fixtures not found at $_RDFXML_FIXTURES_DIR — skipping W3C RDF/XML tests"
end

# ── RDF 1.2 RDF/XML ───────────────────────────────────────────────────────────
#
# Source: https://w3c.github.io/rdf-tests/rdf/rdf12/rdf-xml/
#
# Covers what RDF 1.2 adds to the syntax: rdf:annotation reifiers, rdf:dir
# directional language tags, and triple terms. Unlike the 1.1 fixtures above —
# which were flattened, so their base URIs have to be reconstructed from the
# filename — this suite keeps its manifest, so it is driven from that.

const _RDFXML12_DIR  = joinpath(@__DIR__, "w3c", "fixtures", "rdfxml12", "eval")
const _RDFXML12_BASE = "https://w3c.github.io/rdf-tests/rdf/rdf12/rdf-xml/eval/"

if isdir(_RDFXML12_DIR)

    const _RX12_MF        = "http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#"
    const _RX12_TYPE      = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    const _RX12_FIRST     = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
    const _RX12_REST      = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
    const _RX12_NIL       = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
    const _RX12_ENTRIES   = IRI(_RX12_MF * "entries")
    const _RX12_NAME      = IRI(_RX12_MF * "name")
    const _RX12_ACTION    = IRI(_RX12_MF * "action")
    const _RX12_RESULT    = IRI(_RX12_MF * "result")
    const _RX12_EVAL      = IRI("http://www.w3.org/ns/rdftest#TestXMLEval")
    const _RX12_NEGSYNTAX = IRI("http://www.w3.org/ns/rdftest#TestXMLNegativeSyntax")

    # RDF 1.2 additions the RDF/XML parser does not implement. Turtle,
    # N-Triples and N-Quads support all three — their RDF 1.2 suites pass — so
    # this is an RDF/XML gap, not a data-model one. The list is explicit rather
    # than a blanket skip so the tests light up the moment a feature lands:
    # delete a group and its entries start running.
    const _RX12_UNIMPLEMENTED = Set([
        # rdf:annotation="IRI" on a property element: the triple gets a reifier,
        # emitting `<reifier> rdf:reifies <<( s p o )>>` alongside it.
        "rdf12-xml-an-01", "rdf12-xml-an-02", "rdf12-xml-an-03", "rdf12-xml-an-04",
        "rdf12-xml-an-05", "rdf12-xml-an-06", "rdf12-xml-an-07", "rdf12-xml-an-08",
        "rdf12-xml-an-09", "rdf12-xml-an-10", "rdf12-xml-an-11", "rdf12-xml-an-12",
        "rdf12-xml-an-13", "rdf12-xml-an-14", "rdf12-xml-an-15", "rdf12-xml-an-16",
        "rdf12-xml-an-reif-01.rdf",
        # rdf:parseType="Triple": the property value is a triple term.
        "rdf12-xml-tt-01", "rdf12-xml-tt-02", "rdf12-xml-tt-03", "rdf12-xml-tt-04",
        "rdf12-xml-tt-05", "rdf12-xml-tt-06", "rdf12-xml-tt-07", "rdf12-xml-tt-08",
        # its:dir / rdf:dir: directional language tags, inherited down the tree
        # like xml:lang and combining with it ("bar"@en--ltr).
        "rdf12-xml-dir-01", "rdf12-xml-dir-03", "rdf12-xml-dir-04",
        "rdf12-xml-dir-05",
    ])

    _rx12_one(g, s, p) = begin
        for t in match(g; subject=s, predicate=p); return t.object; end
        nothing
    end

    function _rx12_list(g, head)
        out = RDFTerm[]
        node = head
        while node !== nothing && node != _RX12_NIL
            v = _rx12_one(g, node, _RX12_FIRST)
            v === nothing && break
            push!(out, v)
            node = _rx12_one(g, node, _RX12_REST)
        end
        out
    end

    # Manifest IRIs are absolute against the assumed test base; map back to disk.
    _rx12_file(iri::AbstractString) =
        joinpath(_RDFXML12_DIR, basename(iri))

    let mpath = joinpath(_RDFXML12_DIR, "manifest.ttl")
        g = open(io -> read(io, :ttl, Graph, _RDFXML12_BASE), mpath)

        head = nothing
        for t in match(g; predicate=_RX12_ENTRIES); head = t.object; break; end

        entries = head === nothing ? RDFTerm[] : _rx12_list(g, head)

        @testset "W3C RDF 1.2 RDF/XML" begin
            @test !isempty(entries)
            for entry in entries
                types = Set(t.object for t in match(g; subject=entry, predicate=_RX12_TYPE))
                nm_l  = _rx12_one(g, entry, _RX12_NAME)
                name  = nm_l isa Literal ? nm_l.lexical_form : string(entry)
                act   = _rx12_one(g, entry, _RX12_ACTION)
                act isa IRI || continue
                action = _rx12_file(act.value)
                base   = _RDFXML12_BASE * basename(act.value)

                @testset "$name" begin
                    if name in _RX12_UNIMPLEMENTED
                        @test_skip "RDF 1.2 RDF/XML feature not implemented"
                    elseif _RX12_EVAL in types
                        res = _rx12_one(g, entry, _RX12_RESULT)
                        if !(res isa IRI) || !isfile(_rx12_file(res.value))
                            @test_skip "no result fixture"
                        else
                            g_rdf = _parse_rdfxml_file(action, base)
                            g_nt  = _parse_nt_rdfxml_file(_rx12_file(res.value))
                            @test g_rdf ≅ g_nt
                        end
                    elseif _RX12_NEGSYNTAX in types
                        @test_throws Exception _parse_rdfxml_file(action, base)
                    end
                end
            end
        end
    end

else
    @warn "RDF 1.2 RDF/XML fixtures not found at $_RDFXML12_DIR — skipping"
end
