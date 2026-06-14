using Test
using RDF
using Dates
import RDF: Graph

# ── Schema introspection for text-to-SPARQL ────────────────────────────────────
#
# TDD spec.  Contract under test:
#
#   • describe_schema(g; max_examples=3) -> SchemaSummary
#       Introspects a graph's *actual* shape (from the data, not an ontology):
#         - classes:    objects of rdf:type, with instance counts + labels
#         - predicates: every non-rdf:type predicate, with usage count, the
#                       rdf:type(s) of its subjects (domain), the datatypes of
#                       its literal objects and rdf:type(s) of its IRI objects
#                       (range), a few example values, whether it is
#                       single- or multi-valued, and label/comment if present.
#   • SchemaSummary fields: classes::Vector{ClassInfo},
#       predicates::Vector{PredicateInfo}, ntriples::Int
#       (classes sorted by instance count desc, then IRI; predicates likewise)
#   • to_prompt(::SchemaSummary; budget=nothing, prefixes=Dict()) -> String
#       Compact, deterministic, token-budget-aware text for an LLM prompt.

const _sc_ex   = Namespace("http://schema-test.example.org/")
const _sc_foaf = Namespace("http://xmlns.com/foaf/0.1/")

# Fixture: a small social graph with two classes, typed literals, an object
# property, a multi-valued property, and some rdfs labels.
function _sc_fixture()
    g = Graph()
    # People
    for (i, name, age) in [(1, "Alice", 30), (2, "Bob", 25), (3, "Carol", 41)]
        s = _sc_ex["p$i"]
        push!(g, Triple(s, rdf.type, _sc_foaf.Person))
        push!(g, Triple(s, _sc_foaf.name, Literal(name)))
        push!(g, Triple(s, _sc_ex.age, Literal(age)))            # xsd:integer
    end
    # Alice knows Bob and Carol (multi-valued object property)
    push!(g, Triple(_sc_ex.p1, _sc_foaf.knows, _sc_ex.p2))
    push!(g, Triple(_sc_ex.p1, _sc_foaf.knows, _sc_ex.p3))
    # One organization with a founding date (xsd:date) and a label
    push!(g, Triple(_sc_ex.acme, rdf.type, _sc_ex.Organization))
    push!(g, Triple(_sc_ex.acme, _sc_ex.founded, Literal(Date(1990, 1, 1))))
    push!(g, Triple(_sc_ex.p1, _sc_ex.worksAt, _sc_ex.acme))     # Person → Organization
    # Schema-level labels/comments
    push!(g, Triple(_sc_foaf.Person, rdfs.label, Literal("Person")))
    push!(g, Triple(_sc_ex.age, rdfs.label, Literal("age in years")))
    push!(g, Triple(_sc_ex.age, rdfs.comment, Literal("Integer age")))
    g
end

@testset "describe_schema" begin
    g = _sc_fixture()
    s = describe_schema(g)

    @testset "summary basics" begin
        @test s isa SchemaSummary
        @test s.ntriples == length(g)
    end

    @testset "classes" begin
        names = [c.iri for c in s.classes]
        @test _sc_foaf.Person in names
        @test _sc_ex.Organization in names
        # Person has 3 instances, Organization 1 → Person first (count desc)
        @test s.classes[1].iri == _sc_foaf.Person
        person = s.classes[1]
        @test person.count == 3
        @test person.label == "Person"
        org = s.classes[findfirst(c -> c.iri == _sc_ex.Organization, s.classes)]
        @test org.count == 1
        @test org.label === nothing
        # rdf:type / rdfs:* schema triples do not create spurious classes
        @test !(rdfs.Class in names)
    end

    @testset "predicates — counts and ordering" begin
        preds = Dict(p.iri => p for p in s.predicates)
        # rdf:type is structural and excluded from the predicate list
        @test !haskey(preds, rdf.type)
        @test haskey(preds, _sc_foaf.name)
        @test haskey(preds, _sc_foaf.knows)
        @test haskey(preds, _sc_ex.age)
        @test haskey(preds, _sc_ex.worksAt)
        @test haskey(preds, _sc_ex.founded)
        @test preds[_sc_foaf.name].count == 3
        @test preds[_sc_foaf.knows].count == 2
        # sorted by count desc
        counts = [p.count for p in s.predicates]
        @test issorted(counts; rev=true)
    end

    @testset "predicates — domain (subject classes)" begin
        preds = Dict(p.iri => p for p in s.predicates)
        @test preds[_sc_foaf.name].subject_classes == [_sc_foaf.Person]
        @test preds[_sc_ex.founded].subject_classes == [_sc_ex.Organization]
        @test preds[_sc_ex.worksAt].subject_classes == [_sc_foaf.Person]
    end

    @testset "predicates — range (datatypes and object classes)" begin
        preds = Dict(p.iri => p for p in s.predicates)
        # literal-valued
        @test xsd.integer in preds[_sc_ex.age].datatypes
        @test xsd.date in preds[_sc_ex.founded].datatypes
        @test xsd.string in preds[_sc_foaf.name].datatypes
        @test isempty(preds[_sc_ex.age].object_classes)
        # object-property valued: knows → Person, worksAt → Organization
        @test preds[_sc_foaf.knows].object_classes == [_sc_foaf.Person]
        @test preds[_sc_ex.worksAt].object_classes == [_sc_ex.Organization]
        @test isempty(preds[_sc_foaf.knows].datatypes)
    end

    @testset "predicates — cardinality (single vs multi valued)" begin
        preds = Dict(p.iri => p for p in s.predicates)
        @test preds[_sc_foaf.name].max_per_subject == 1   # each person, one name
        @test preds[_sc_foaf.knows].max_per_subject == 2  # Alice knows 2 people
    end

    @testset "predicates — examples and metadata" begin
        preds = Dict(p.iri => p for p in s.predicates)
        # examples are drawn from actual object values
        name_ex = preds[_sc_foaf.name].examples
        @test !isempty(name_ex)
        @test all(e -> e in Set(t.object for t in match(g; predicate=_sc_foaf.name)),
                  name_ex)
        @test length(preds[_sc_foaf.name].examples) <= 3
        # rdfs:label / rdfs:comment on the predicate are captured
        @test preds[_sc_ex.age].label == "age in years"
        @test preds[_sc_ex.age].comment == "Integer age"
        @test preds[_sc_foaf.knows].label === nothing
    end

    @testset "max_examples keyword" begin
        s1 = describe_schema(g; max_examples=1)
        p = s1.predicates[findfirst(p -> p.iri == _sc_foaf.name, s1.predicates)]
        @test length(p.examples) == 1
    end

    @testset "empty graph" begin
        s0 = describe_schema(Graph())
        @test s0.ntriples == 0
        @test isempty(s0.classes)
        @test isempty(s0.predicates)
    end

    # ── to_prompt ─────────────────────────────────────────────────────────────
    @testset "to_prompt rendering" begin
        txt = to_prompt(s)
        @test txt isa String
        @test !isempty(txt)
        # class and predicate names appear
        @test occursin("Organization", txt)
        @test occursin("knows", txt)
        @test occursin("age", txt)
        # deterministic
        @test txt == to_prompt(s)
        # empty schema → empty string
        @test to_prompt(describe_schema(Graph())) == ""
    end

    @testset "to_prompt — prefixes compact IRIs" begin
        txt = to_prompt(s; prefixes=Dict("ex" => "http://schema-test.example.org/",
                                         "foaf" => "http://xmlns.com/foaf/0.1/"))
        @test occursin("foaf:Person", txt)
        @test occursin("ex:age", txt)
        @test !occursin("http://schema-test.example.org/age", txt)
    end

    @testset "to_prompt — budget caps size" begin
        full = to_prompt(s)
        budget = cld(ncodeunits(full), 4) - 5
        capped = to_prompt(s; budget=budget)
        @test ncodeunits(capped) <= 4 * budget
        @test ncodeunits(capped) <= ncodeunits(full)
    end
end
