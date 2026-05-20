using RDF
using Test

@testset "Namespaces and Vocabularies" begin

    @testset "Namespace construction and IRI generation" begin
        ns = Namespace("http://example.org/")
        @test ns isa Namespace
        @test string(ns) == "http://example.org/"

        # Property access generates IRI
        @test ns.alice == IRI("http://example.org/alice")
        @test ns.Person == IRI("http://example.org/Person")
        @test ns.type == IRI("http://example.org/type")

        # Index access for non-identifier names
        @test ns["birth-date"] == IRI("http://example.org/birth-date")
        @test ns["123"] == IRI("http://example.org/123")
        @test_throws IRIError ns["has space"]
    end

    @testset "Namespace with hash fragment base" begin
        ns = Namespace("http://example.org/vocab#")
        @test ns.Person == IRI("http://example.org/vocab#Person")
        @test ns.type == IRI("http://example.org/vocab#type")
    end

    @testset "Namespace IRI is correct type" begin
        ns = Namespace("http://example.org/")
        @test ns.alice isa IRI
        @test ns.alice isa RDFTerm
        @test ns.alice isa SubjectTerm
        @test ns.alice isa ObjectTerm
    end

    @testset "RDF vocabulary module" begin
        # Core terms
        @test rdf.type        == IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        @test rdf.subject     == IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#subject")
        @test rdf.predicate   == IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#predicate")
        @test rdf.object      == IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#object")
        @test rdf.value       == IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#value")
        @test rdf.first       == IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
        @test rdf.rest        == IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
        @test rdf.nil         == IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
        @test rdf.langString  == IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#langString")
        @test rdf.HTML        == IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#HTML")
        @test rdf.XMLLiteral  == IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#XMLLiteral")

        # All terms are IRIs
        @test rdf.type isa IRI
        @test rdf.langString isa IRI
    end

    @testset "RDFS vocabulary module" begin
        @test rdfs.subClassOf    == IRI("http://www.w3.org/2000/01/rdf-schema#subClassOf")
        @test rdfs.subPropertyOf == IRI("http://www.w3.org/2000/01/rdf-schema#subPropertyOf")
        @test rdfs.domain        == IRI("http://www.w3.org/2000/01/rdf-schema#domain")
        @test rdfs.range         == IRI("http://www.w3.org/2000/01/rdf-schema#range")
        @test rdfs.label         == IRI("http://www.w3.org/2000/01/rdf-schema#label")
        @test rdfs.comment       == IRI("http://www.w3.org/2000/01/rdf-schema#comment")
        @test rdfs.Class         == IRI("http://www.w3.org/2000/01/rdf-schema#Class")
        @test rdfs.Resource      == IRI("http://www.w3.org/2000/01/rdf-schema#Resource")
        @test rdfs.Literal       == IRI("http://www.w3.org/2000/01/rdf-schema#Literal")
        @test rdfs.Datatype      == IRI("http://www.w3.org/2000/01/rdf-schema#Datatype")
        @test rdfs.isDefinedBy   == IRI("http://www.w3.org/2000/01/rdf-schema#isDefinedBy")
        @test rdfs.seeAlso       == IRI("http://www.w3.org/2000/01/rdf-schema#seeAlso")
        @test rdfs.member        == IRI("http://www.w3.org/2000/01/rdf-schema#member")
        @test rdfs.Container     == IRI("http://www.w3.org/2000/01/rdf-schema#Container")
    end

    @testset "XSD vocabulary module — all 32 RDF-compatible types (spec §5.1)" begin
        # Core types
        @test xsd.string  == IRI("http://www.w3.org/2001/XMLSchema#string")
        @test xsd.boolean == IRI("http://www.w3.org/2001/XMLSchema#boolean")
        @test xsd.decimal == IRI("http://www.w3.org/2001/XMLSchema#decimal")
        @test xsd.integer == IRI("http://www.w3.org/2001/XMLSchema#integer")

        # IEEE floating-point
        @test xsd.double == IRI("http://www.w3.org/2001/XMLSchema#double")
        @test xsd.float  == IRI("http://www.w3.org/2001/XMLSchema#float")

        # Time and date
        @test xsd.date          == IRI("http://www.w3.org/2001/XMLSchema#date")
        @test xsd.time          == IRI("http://www.w3.org/2001/XMLSchema#time")
        @test xsd.dateTime      == IRI("http://www.w3.org/2001/XMLSchema#dateTime")
        @test xsd.dateTimeStamp == IRI("http://www.w3.org/2001/XMLSchema#dateTimeStamp")

        # Recurring and partial dates
        @test xsd.gYear      == IRI("http://www.w3.org/2001/XMLSchema#gYear")
        @test xsd.gMonth     == IRI("http://www.w3.org/2001/XMLSchema#gMonth")
        @test xsd.gDay       == IRI("http://www.w3.org/2001/XMLSchema#gDay")
        @test xsd.gYearMonth == IRI("http://www.w3.org/2001/XMLSchema#gYearMonth")
        @test xsd.gMonthDay  == IRI("http://www.w3.org/2001/XMLSchema#gMonthDay")
        @test xsd.duration             == IRI("http://www.w3.org/2001/XMLSchema#duration")
        @test xsd.yearMonthDuration    == IRI("http://www.w3.org/2001/XMLSchema#yearMonthDuration")
        @test xsd.dayTimeDuration      == IRI("http://www.w3.org/2001/XMLSchema#dayTimeDuration")

        # Limited-range integers
        @test xsd.byte              == IRI("http://www.w3.org/2001/XMLSchema#byte")
        @test xsd.short             == IRI("http://www.w3.org/2001/XMLSchema#short")
        @test xsd.int               == IRI("http://www.w3.org/2001/XMLSchema#int")
        @test xsd.long              == IRI("http://www.w3.org/2001/XMLSchema#long")
        @test xsd.unsignedByte      == IRI("http://www.w3.org/2001/XMLSchema#unsignedByte")
        @test xsd.unsignedShort     == IRI("http://www.w3.org/2001/XMLSchema#unsignedShort")
        @test xsd.unsignedInt       == IRI("http://www.w3.org/2001/XMLSchema#unsignedInt")
        @test xsd.unsignedLong      == IRI("http://www.w3.org/2001/XMLSchema#unsignedLong")
        @test xsd.positiveInteger   == IRI("http://www.w3.org/2001/XMLSchema#positiveInteger")
        @test xsd.nonNegativeInteger == IRI("http://www.w3.org/2001/XMLSchema#nonNegativeInteger")
        @test xsd.negativeInteger   == IRI("http://www.w3.org/2001/XMLSchema#negativeInteger")
        @test xsd.nonPositiveInteger == IRI("http://www.w3.org/2001/XMLSchema#nonPositiveInteger")

        # Encoded binary
        @test xsd.hexBinary    == IRI("http://www.w3.org/2001/XMLSchema#hexBinary")
        @test xsd.base64Binary == IRI("http://www.w3.org/2001/XMLSchema#base64Binary")

        # Miscellaneous
        @test xsd.anyURI           == IRI("http://www.w3.org/2001/XMLSchema#anyURI")
        @test xsd.language         == IRI("http://www.w3.org/2001/XMLSchema#language")
        @test xsd.normalizedString == IRI("http://www.w3.org/2001/XMLSchema#normalizedString")
        @test xsd.token            == IRI("http://www.w3.org/2001/XMLSchema#token")
        @test xsd.NMTOKEN          == IRI("http://www.w3.org/2001/XMLSchema#NMTOKEN")
        @test xsd.Name             == IRI("http://www.w3.org/2001/XMLSchema#Name")
        @test xsd.NCName           == IRI("http://www.w3.org/2001/XMLSchema#NCName")
    end

    @testset "OWL vocabulary module (IRIs only)" begin
        @test owl.Class           == IRI("http://www.w3.org/2002/07/owl#Class")
        @test owl.ObjectProperty  == IRI("http://www.w3.org/2002/07/owl#ObjectProperty")
        @test owl.DatatypeProperty == IRI("http://www.w3.org/2002/07/owl#DatatypeProperty")
        @test owl.equivalentClass == IRI("http://www.w3.org/2002/07/owl#equivalentClass")
        @test owl.equivalentProperty == IRI("http://www.w3.org/2002/07/owl#equivalentProperty")
        @test owl.sameAs          == IRI("http://www.w3.org/2002/07/owl#sameAs")
        @test owl.differentFrom   == IRI("http://www.w3.org/2002/07/owl#differentFrom")
        @test owl.inverseOf       == IRI("http://www.w3.org/2002/07/owl#inverseOf")
        @test owl.Ontology        == IRI("http://www.w3.org/2002/07/owl#Ontology")
        @test owl.Thing           == IRI("http://www.w3.org/2002/07/owl#Thing")
        @test owl.Nothing         == IRI("http://www.w3.org/2002/07/owl#Nothing")
    end

    @testset "SKOS vocabulary module" begin
        ns = "http://www.w3.org/2004/02/skos/core#"
        @test skos.Concept        == IRI(ns * "Concept")
        @test skos.prefLabel      == IRI(ns * "prefLabel")
        @test skos.altLabel       == IRI(ns * "altLabel")
        @test skos.broader        == IRI(ns * "broader")
        @test skos.narrower       == IRI(ns * "narrower")
        @test skos.related        == IRI(ns * "related")
        @test skos.inScheme       == IRI(ns * "inScheme")
        @test skos.ConceptScheme  == IRI(ns * "ConceptScheme")
        @test skos.definition     == IRI(ns * "definition")
    end

    @testset "FOAF vocabulary module" begin
        ns = "http://xmlns.com/foaf/0.1/"
        @test foaf.Person      == IRI(ns * "Person")
        @test foaf.name        == IRI(ns * "name")
        @test foaf.mbox        == IRI(ns * "mbox")
        @test foaf.knows       == IRI(ns * "knows")
        @test foaf.homepage    == IRI(ns * "homepage")
        @test foaf.depiction   == IRI(ns * "depiction")
        @test foaf.Organization == IRI(ns * "Organization")
    end

    @testset "DC / Dublin Core vocabulary modules" begin
        @test dc.title       == IRI("http://purl.org/dc/elements/1.1/title")
        @test dc.creator     == IRI("http://purl.org/dc/elements/1.1/creator")
        @test dc.subject     == IRI("http://purl.org/dc/elements/1.1/subject")
        @test dc.description == IRI("http://purl.org/dc/elements/1.1/description")
        @test dc.date        == IRI("http://purl.org/dc/elements/1.1/date")

        @test dcterms.title       == IRI("http://purl.org/dc/terms/title")
        @test dcterms.creator     == IRI("http://purl.org/dc/terms/creator")
        @test dcterms.created     == IRI("http://purl.org/dc/terms/created")
        @test dcterms.modified    == IRI("http://purl.org/dc/terms/modified")
        @test dcterms.description == IRI("http://purl.org/dc/terms/description")
    end

    @testset "Schema.org vocabulary module" begin
        @test schema.Person       == IRI("https://schema.org/Person")
        @test schema.Organization == IRI("https://schema.org/Organization")
        @test schema.name         == IRI("https://schema.org/name")
        @test schema.email        == IRI("https://schema.org/email")
        @test schema.url          == IRI("https://schema.org/url")
    end

    @testset "Vocabulary constants are const IRIs (no allocation on access)" begin
        # Accessing the same constant twice gives the identical object
        @test rdf.type === rdf.type
        @test xsd.integer === xsd.integer
        @test rdfs.subClassOf === rdfs.subClassOf
    end

end
