using RDF
using Test

@testset "RDFS Inference" begin

    const ex = Namespace("http://example.org/")

    @testset "infer_rdfs — returns new graph, does not mutate" begin
        g = Graph()
        push!(g, Triple(ex.Dog, rdfs.subClassOf, ex.Animal))
        push!(g, Triple(ex.fido, rdf.type, ex.Dog))

        original_size = length(g)
        ig = infer_rdfs(g)

        # Original unchanged
        @test length(g) == original_size

        # Inferred graph is larger
        @test length(ig) >= original_size
        @test ig isa Graph
    end

    @testset "infer_rdfs! — mutates graph in place" begin
        g = Graph()
        push!(g, Triple(ex.Dog, rdfs.subClassOf, ex.Animal))
        push!(g, Triple(ex.fido, rdf.type, ex.Dog))

        original_size = length(g)
        result = infer_rdfs!(g)

        @test result === g  # returns the same graph
        @test length(g) >= original_size
    end

    @testset "subClassOf — transitivity" begin
        g = Graph()
        push!(g, Triple(ex.Poodle, rdfs.subClassOf, ex.Dog))
        push!(g, Triple(ex.Dog,    rdfs.subClassOf, ex.Animal))

        ig = infer_rdfs(g)

        # Direct subclass entailments
        @test Triple(ex.Poodle, rdfs.subClassOf, ex.Dog)    in ig
        @test Triple(ex.Dog,    rdfs.subClassOf, ex.Animal) in ig

        # Transitive entailment
        @test Triple(ex.Poodle, rdfs.subClassOf, ex.Animal) in ig

        # Reflexive — every class is a subclass of itself (RDFS entailment)
        @test Triple(ex.Poodle, rdfs.subClassOf, ex.Poodle) in ig
        @test Triple(ex.Dog,    rdfs.subClassOf, ex.Dog)    in ig
        @test Triple(ex.Animal, rdfs.subClassOf, ex.Animal) in ig
    end

    @testset "subClassOf — type propagation" begin
        g = Graph()
        push!(g, Triple(ex.Dog,   rdfs.subClassOf, ex.Animal))
        push!(g, Triple(ex.fido,  rdf.type,        ex.Dog))

        ig = infer_rdfs(g)

        # fido is a Dog → fido is an Animal
        @test Triple(ex.fido, rdf.type, ex.Animal) in ig
    end

    @testset "subClassOf — multi-level type propagation" begin
        g = Graph()
        push!(g, Triple(ex.Poodle, rdfs.subClassOf, ex.Dog))
        push!(g, Triple(ex.Dog,    rdfs.subClassOf, ex.Animal))
        push!(g, Triple(ex.Animal, rdfs.subClassOf, ex.LivingThing))
        push!(g, Triple(ex.fido,   rdf.type,        ex.Poodle))

        ig = infer_rdfs(g)

        @test Triple(ex.fido, rdf.type, ex.Dog)         in ig
        @test Triple(ex.fido, rdf.type, ex.Animal)      in ig
        @test Triple(ex.fido, rdf.type, ex.LivingThing) in ig
    end

    @testset "subPropertyOf — transitivity" begin
        g = Graph()
        push!(g, Triple(ex.hasMother,  rdfs.subPropertyOf, ex.hasParent))
        push!(g, Triple(ex.hasParent,  rdfs.subPropertyOf, ex.hasAncestor))
        push!(g, Triple(ex.alice, ex.hasMother, ex.eve))

        ig = infer_rdfs(g)

        # Transitivity
        @test Triple(ex.hasMother, rdfs.subPropertyOf, ex.hasParent)   in ig
        @test Triple(ex.hasMother, rdfs.subPropertyOf, ex.hasAncestor) in ig

        # Property propagation: alice hasMother eve → alice hasParent eve
        @test Triple(ex.alice, ex.hasParent,  ex.eve) in ig
        @test Triple(ex.alice, ex.hasAncestor, ex.eve) in ig
    end

    @testset "domain — type inference from predicate use" begin
        g = Graph()
        push!(g, Triple(ex.age, rdfs.domain, ex.Person))
        push!(g, Triple(ex.alice, ex.age, Literal(30)))

        ig = infer_rdfs(g)

        # Using ex.age as a predicate implies ex.alice is a Person
        @test Triple(ex.alice, rdf.type, ex.Person) in ig
    end

    @testset "range — type inference from object use" begin
        g = Graph()
        push!(g, Triple(ex.knows, rdfs.range, ex.Person))
        push!(g, Triple(ex.alice, ex.knows, ex.bob))

        ig = infer_rdfs(g)

        # The object of ex.knows is entailed to be a Person
        @test Triple(ex.bob, rdf.type, ex.Person) in ig
    end

    @testset "domain and range together" begin
        g = Graph()
        push!(g, Triple(ex.teaches, rdfs.domain, ex.Teacher))
        push!(g, Triple(ex.teaches, rdfs.range,  ex.Student))
        push!(g, Triple(ex.alice, ex.teaches, ex.bob))

        ig = infer_rdfs(g)

        @test Triple(ex.alice, rdf.type, ex.Teacher) in ig
        @test Triple(ex.bob,   rdf.type, ex.Student) in ig
    end

    @testset "Selective rule application" begin
        g = Graph()
        push!(g, Triple(ex.Dog,   rdfs.subClassOf, ex.Animal))
        push!(g, Triple(ex.age,   rdfs.domain,     ex.Person))
        push!(g, Triple(ex.fido,  rdf.type,        ex.Dog))
        push!(g, Triple(ex.alice, ex.age,           Literal(30)))

        # Only subClassOf rules
        ig = infer_rdfs(g, rules=[:subClassOf])
        @test Triple(ex.fido, rdf.type, ex.Animal) in ig
        @test Triple(ex.alice, rdf.type, ex.Person) ∉ ig

        # Only domain rules
        ig = infer_rdfs(g, rules=[:domain])
        @test Triple(ex.alice, rdf.type, ex.Person) in ig
        @test Triple(ex.fido, rdf.type, ex.Animal) ∉ ig
    end

    @testset "Inference on empty graph returns empty graph" begin
        g = Graph()
        ig = infer_rdfs(g)
        @test isempty(ig)
    end

    @testset "Inference is idempotent" begin
        g = Graph()
        push!(g, Triple(ex.Dog, rdfs.subClassOf, ex.Animal))
        push!(g, Triple(ex.fido, rdf.type, ex.Dog))

        ig1 = infer_rdfs(g)
        ig2 = infer_rdfs(ig1)

        # A second pass produces no new triples
        @test length(ig1) == length(ig2)
        @test ig1 == ig2
    end

    @testset "entails — RDFS regime" begin
        g = Graph()
        push!(g, Triple(ex.Dog,   rdfs.subClassOf, ex.Animal))
        push!(g, Triple(ex.fido,  rdf.type,        ex.Dog))

        # Directly asserted
        @test entails(g, Triple(ex.fido, rdf.type, ex.Dog); regime=:rdfs)

        # Entailed by subClassOf + type
        @test entails(g, Triple(ex.fido, rdf.type, ex.Animal); regime=:rdfs)

        # Not entailed
        @test !entails(g, Triple(ex.fido, rdf.type, ex.Person); regime=:rdfs)

        # Default regime is :rdfs
        @test entails(g, Triple(ex.fido, rdf.type, ex.Animal))
    end

    @testset "entails — simple (no inference)" begin
        g = Graph()
        push!(g, Triple(ex.Dog,   rdfs.subClassOf, ex.Animal))
        push!(g, Triple(ex.fido,  rdf.type,        ex.Dog))

        @test  entails(g, Triple(ex.fido, rdf.type, ex.Dog);    regime=:simple)
        @test !entails(g, Triple(ex.fido, rdf.type, ex.Animal); regime=:simple)
    end

    @testset "Inference preserves original triples" begin
        g = Graph()
        push!(g, Triple(ex.Dog, rdfs.subClassOf, ex.Animal))
        push!(g, Triple(ex.fido, rdf.type, ex.Dog))

        ig = infer_rdfs(g)

        # All original triples present in the inferred graph
        for t in g
            @test t in ig
        end
    end

end
