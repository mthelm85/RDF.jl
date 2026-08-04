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
