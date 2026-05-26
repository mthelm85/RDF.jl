using RDF
using Test
using Dates

# Build a reusable Dataset for most tests
function _sparql_ds()
    ex   = Namespace("http://example.org/")
    foaf = Namespace("http://xmlns.com/foaf/0.1/")

    ttl = """
      PREFIX ex:   <http://example.org/>
      PREFIX foaf: <http://xmlns.com/foaf/0.1/>

      ex:alice a foaf:Person ;
               foaf:name "Alice" ;
               foaf:age  30 ;
               foaf:knows ex:bob .

      ex:bob   a foaf:Person ;
               foaf:name "Bob" ;
               foaf:age  25 .

      ex:carol a foaf:Person ;
               foaf:name "Carol" ;
               foaf:age  35 .
    """
    Dataset(; default_graph=read(IOBuffer(ttl), MIME"text/turtle"(), Graph))
end

@testset "SPARQL 1.1" begin

    ex   = Namespace("http://example.org/")
    foaf = Namespace("http://xmlns.com/foaf/0.1/")

    # ── sparql_parse ──────────────────────────────────────────────────────────

    @testset "sparql_parse — SELECT" begin
        ast = sparql_parse("SELECT ?s WHERE { ?s ?p ?o }")
        @test ast !== nothing
    end

    @testset "sparql_parse — ASK" begin
        ast = sparql_parse("ASK { ?s ?p ?o }")
        @test ast !== nothing
    end

    @testset "sparql_parse — CONSTRUCT" begin
        ast = sparql_parse("CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }")
        @test ast !== nothing
    end

    @testset "sparql_parse — syntax error throws ParseError" begin
        @test_throws ParseError sparql_parse("SELECT WHERE { }")     # missing projection
        @test_throws ParseError sparql_parse("SLECT ?x WHERE { }")   # typo
    end

    # ── SELECT ────────────────────────────────────────────────────────────────

    @testset "SELECT — basic projection" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name WHERE { ?s foaf:name ?name }
        """)
        @test result isa SolutionSet
        @test result.variables == [:name]
        @test length(result) == 3
        names = [value(String, row[:name]) for row in result]
        @test "Alice" in names
        @test "Bob"   in names
        @test "Carol" in names
    end

    @testset "SELECT — multiple projected variables" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name ?age WHERE {
            ?s foaf:name ?name ;
               foaf:age  ?age .
          }
        """)
        @test result.variables == [:name, :age]
        @test length(result) == 3
        for row in result
            @test row[:name] isa Literal
            @test row[:age]  isa Literal
        end
    end

    @testset "SELECT — FILTER" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name ?age WHERE {
            ?s foaf:name ?name ; foaf:age ?age .
            FILTER(?age > 26)
          }
        """)
        @test length(result) == 2
        names = [value(String, row[:name]) for row in result]
        @test "Alice" in names
        @test "Carol" in names
        @test "Bob" ∉ names
    end

    @testset "SELECT — ORDER BY" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name WHERE { ?s foaf:name ?name } ORDER BY ?name
        """)
        names = [value(String, row[:name]) for row in result]
        @test names == sort(names)
    end

    @testset "SELECT — ORDER BY DESC" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name WHERE { ?s foaf:name ?name } ORDER BY DESC(?name)
        """)
        names = [value(String, row[:name]) for row in result]
        @test names == sort(names; rev=true)
    end

    @testset "SELECT — LIMIT and OFFSET" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name WHERE { ?s foaf:name ?name } ORDER BY ?name LIMIT 2
        """)
        @test length(result) == 2

        result2 = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name WHERE { ?s foaf:name ?name } ORDER BY ?name LIMIT 2 OFFSET 1
        """)
        @test length(result2) == 2
        @test result[1][:name] != result2[1][:name]
    end

    @testset "SELECT — DISTINCT" begin
        ds = _sparql_ds()
        # Add a duplicate triple to test DISTINCT
        push!(ds.default_graph, Triple(ex.alice, foaf.name, Literal("Alice")))

        result_all      = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name WHERE { ?s foaf:name ?name }
        """)
        result_distinct = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT DISTINCT ?name WHERE { ?s foaf:name ?name }
        """)
        @test length(result_distinct) <= length(result_all)
        names = [value(String, row[:name]) for row in result_distinct]
        @test length(names) == length(unique(names))
    end

    @testset "SELECT — wildcard *" begin
        ds = _sparql_ds()
        result = sparql(ds, "SELECT * WHERE { ?s ?p ?o } LIMIT 1")
        @test result isa SolutionSet
        @test :s in result.variables
        @test :p in result.variables
        @test :o in result.variables
    end

    @testset "SELECT — empty result" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX ex: <http://example.org/>
          SELECT ?x WHERE { ex:nobody ?p ?x }
        """)
        @test result isa SolutionSet
        @test length(result) == 0
        @test isempty(result)
    end

    @testset "SELECT — OPTIONAL" begin
        ds = _sparql_ds()
        # carol doesn't foaf:know anyone — optional binding is unbound
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name ?friend WHERE {
            ?s foaf:name ?name .
            OPTIONAL { ?s foaf:knows ?friend }
          } ORDER BY ?name
        """)
        @test length(result) == 3
        # Alice knows Bob — bound
        alice_row = first(filter(r -> value(String, r[:name]) == "Alice", collect(result)))
        @test alice_row[:friend] isa IRI
        # Carol has no friend — unbound
        carol_row = first(filter(r -> value(String, r[:name]) == "Carol", collect(result)))
        @test carol_row[:friend] === nothing
    end

    @testset "SELECT — UNION" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?x WHERE {
            { ex:alice foaf:name ?x }
            UNION
            { ex:bob   foaf:name ?x }
          }
        """)
        @test length(result) == 2
        names = [value(String, row[:x]) for row in result]
        @test "Alice" in names
        @test "Bob"   in names
    end

    @testset "SELECT — GROUP BY + COUNT" begin
        ds = _sparql_ds()
        # Count people per age (should be 1 each since ages are distinct)
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?age (COUNT(?s) AS ?n) WHERE {
            ?s foaf:age ?age
          } GROUP BY ?age ORDER BY ?age
        """)
        @test length(result) == 3
        for row in result
            @test value(Int64, row[:n]) == 1
        end
    end

    @testset "SELECT — GROUP BY + HAVING" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT (AVG(?age) AS ?avg) WHERE { ?s foaf:age ?age }
        """)
        @test length(result) == 1
        avg = tryvalue(Float64, result[1][:avg])
        @test avg isa Float64
        @test avg ≈ (30.0 + 25.0 + 35.0) / 3
    end

    @testset "SELECT — BIND" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name ?agePlus1 WHERE {
            ?s foaf:name ?name ; foaf:age ?age .
            BIND(?age + 1 AS ?agePlus1)
          } ORDER BY ?name
        """)
        @test length(result) == 3
        for row in result
            age_plus_1 = value(Int64, row[:agePlus1])
            @test age_plus_1 > 25
        end
    end

    @testset "SELECT — VALUES" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name WHERE {
            VALUES ?s { ex:alice ex:bob }
            ?s foaf:name ?name
          }
        """)
        @test length(result) == 2
        names = [value(String, row[:name]) for row in result]
        @test "Alice" in names
        @test "Bob"   in names
    end

    @testset "SELECT — subquery" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name WHERE {
            { SELECT ?s WHERE { ?s foaf:age ?a . FILTER(?a >= 30) } }
            ?s foaf:name ?name
          }
        """)
        @test length(result) == 2
        names = [value(String, row[:name]) for row in result]
        @test "Alice" in names
        @test "Carol" in names
    end

    @testset "SELECT — EXISTS / NOT EXISTS" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name WHERE {
            ?s foaf:name ?name .
            FILTER EXISTS { ?s foaf:knows ?o }
          }
        """)
        # Only Alice has foaf:knows
        @test length(result) == 1
        @test value(String, result[1][:name]) == "Alice"

        result2 = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name WHERE {
            ?s foaf:name ?name .
            FILTER NOT EXISTS { ?s foaf:knows ?o }
          }
        """)
        @test length(result2) == 2
        names2 = [value(String, row[:name]) for row in result2]
        @test "Bob"   in names2
        @test "Carol" in names2
    end

    @testset "SELECT — MINUS" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?s WHERE {
            ?s a foaf:Person .
            MINUS { ?s foaf:knows ?o }
          }
        """)
        # Alice is excluded (she foaf:knows bob)
        @test length(result) == 2
        subjects = [row[:s] for row in result]
        @test ex.alice ∉ subjects
    end

    @testset "SELECT — property path (zero-or-more *)" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?friend WHERE { ex:alice foaf:knows* ?friend }
        """)
        @test result isa SolutionSet
        @test length(result) >= 1
        friends = [row[:friend] for row in result]
        @test ex.alice in friends   # zero steps (alice knows* alice)
    end

    @testset "SELECT — property path (one-or-more +)" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?friend WHERE { ex:alice foaf:knows+ ?friend }
        """)
        friends = [row[:friend] for row in result]
        @test ex.bob in friends
        @test ex.alice ∉ friends   # + requires at least one step
    end

    @testset "SELECT — FROM NAMED (named graph dataset semantics)" begin
        ds = Dataset()
        g1 = Graph()
        push!(g1, Triple(ex.alice, foaf.name, Literal("Alice")))
        ds[IRI("http://example.org/g1")] = g1

        g2 = Graph()
        push!(g2, Triple(ex.bob, foaf.name, Literal("Bob")))
        ds[IRI("http://example.org/g2")] = g2

        # FROM NAMED restricts which named graphs are visible to GRAPH patterns
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name FROM NAMED <http://example.org/g1> WHERE {
            GRAPH <http://example.org/g1> { ?s foaf:name ?name }
          }
        """)
        @test length(result) == 1
        @test value(String, result[1][:name]) == "Alice"
    end

    @testset "SELECT — GRAPH clause" begin
        ds = Dataset()
        g1 = Graph()
        push!(g1, Triple(ex.alice, foaf.name, Literal("Alice")))
        ds[IRI("http://example.org/g1")] = g1

        g2 = Graph()
        push!(g2, Triple(ex.bob, foaf.name, Literal("Bob")))
        ds[IRI("http://example.org/g2")] = g2

        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?g ?name WHERE {
            GRAPH ?g { ?s foaf:name ?name }
          } ORDER BY ?name
        """)
        @test length(result) == 2
        graphs = [row[:g] for row in result]
        @test IRI("http://example.org/g1") in graphs
        @test IRI("http://example.org/g2") in graphs
    end

    # ── ASK ───────────────────────────────────────────────────────────────────

    @testset "ASK — true result" begin
        ds = _sparql_ds()
        r = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          ASK { ?s foaf:age 30 }
        """)
        @test r === true
    end

    @testset "ASK — false result" begin
        ds = _sparql_ds()
        r = sparql(ds, """
          PREFIX ex: <http://example.org/>
          ASK { ex:nobody ?p ?o }
        """)
        @test r === false
    end

    # ── CONSTRUCT ─────────────────────────────────────────────────────────────

    @testset "CONSTRUCT — basic" begin
        ds = _sparql_ds()
        g = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          CONSTRUCT { ?s foaf:name ?n } WHERE { ?s foaf:name ?n }
        """)
        @test g isa Graph
        @test length(g) == 3
        preds = Set(t.predicate for t in g)
        @test only(preds) == foaf.name
    end

    @testset "CONSTRUCT — with FILTER" begin
        ds = _sparql_ds()
        g = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          CONSTRUCT { ?s foaf:name ?n } WHERE {
            ?s foaf:name ?n ; foaf:age ?a .
            FILTER(?a >= 30)
          }
        """)
        @test g isa Graph
        @test length(g) == 2
    end

    @testset "CONSTRUCT — empty result is empty Graph" begin
        ds = _sparql_ds()
        g = sparql(ds, """
          PREFIX ex: <http://example.org/>
          CONSTRUCT { ex:nobody ?p ?o } WHERE { ex:nobody ?p ?o }
        """)
        @test g isa Graph
        @test isempty(g)
    end

    # ── DESCRIBE ──────────────────────────────────────────────────────────────

    @testset "DESCRIBE — returns Graph" begin
        ds = _sparql_ds()
        g = sparql(ds, """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          DESCRIBE ex:alice WHERE { ex:alice foaf:name ?n }
        """)
        @test g isa Graph
        @test length(g) >= 1
    end

    # ── SolutionSet / SolutionRow interface ───────────────────────────────────

    @testset "SolutionSet — iteration" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name WHERE { ?s foaf:name ?name }
        """)

        count = 0
        for row in result
            @test row isa SolutionRow
            @test row[:name] isa Literal
            count += 1
        end
        @test count == 3
    end

    @testset "SolutionSet — integer indexing" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name WHERE { ?s foaf:name ?name } ORDER BY ?name
        """)

        @test result[1]  isa SolutionRow
        @test result[1][:name] isa Literal
        @test_throws BoundsError result[0]
        @test_throws BoundsError result[length(result) + 1]
    end

    @testset "SolutionSet — isempty and length" begin
        vars = [:x]
        ss = SolutionSet(vars)
        @test isempty(ss)
        @test length(ss) == 0

        push!(ss, Dict{Symbol,Union{RDFTerm,Nothing}}(:x => Literal(1)))
        @test !isempty(ss)
        @test length(ss) == 1
    end

    @testset "SolutionRow — get with default" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name ?friend WHERE {
            ?s foaf:name ?name .
            OPTIONAL { ?s foaf:knows ?friend }
          }
        """)

        for row in result
            # :name is always bound
            n = get(row, :name, nothing)
            @test n isa Literal

            # :notakey is never in the SolutionSet
            fallback = get(row, :notakey, :default_val)
            @test fallback === :default_val
        end
    end

    @testset "SolutionRow — keys" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name ?age WHERE { ?s foaf:name ?name ; foaf:age ?age }
        """)
        @test length(result) > 0
        k = keys(result[1])
        @test :name in k
        @test :age  in k
    end

    @testset "SolutionRow — unbound variable returns nothing" begin
        ds = _sparql_ds()
        result = sparql(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name ?friend WHERE {
            ?s foaf:name ?name .
            OPTIONAL { ?s foaf:knows ?friend }
          }
        """)
        # Bob and Carol have no foaf:knows
        has_unbound = any(row -> row[:friend] === nothing, result)
        @test has_unbound
    end

    # ── SPARQL UPDATE ─────────────────────────────────────────────────────────

    @testset "sparql_update! — INSERT DATA" begin
        ds = Dataset()
        sparql_update!(ds, """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          INSERT DATA {
            ex:alice foaf:name "Alice" ;
                     foaf:age  30 .
          }
        """)
        @test length(ds.default_graph) == 2
        @test Triple(ex.alice, foaf.name, Literal("Alice")) in ds.default_graph
    end

    @testset "sparql_update! — DELETE DATA" begin
        ds = _sparql_ds()
        n_before = length(ds.default_graph)

        sparql_update!(ds, """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          DELETE DATA {
            ex:alice foaf:age 30 .
          }
        """)
        @test length(ds.default_graph) == n_before - 1
        @test Triple(ex.alice, foaf.age, Literal(30)) ∉ ds.default_graph
    end

    @testset "sparql_update! — DELETE/INSERT WHERE" begin
        ds = _sparql_ds()

        sparql_update!(ds, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          DELETE { ?s foaf:age ?old }
          INSERT { ?s foaf:age ?new }
          WHERE  {
            ?s foaf:name "Alice" ;
               foaf:age  ?old .
            BIND(?old + 1 AS ?new)
          }
        """)

        result = sparql(ds, """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?age WHERE { ex:alice foaf:age ?age }
        """)
        @test length(result) == 1
        @test value(Int64, result[1][:age]) == 31
    end

    @testset "sparql_update! — INSERT DATA into named graph" begin
        ds = Dataset()
        sparql_update!(ds, """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          INSERT DATA {
            GRAPH ex:g1 {
              ex:alice foaf:name "Alice" .
            }
          }
        """)
        gname = IRI("http://example.org/g1")
        @test haskey(ds, gname)
        @test Triple(ex.alice, foaf.name, Literal("Alice")) in ds[gname]
    end

    @testset "sparql_update! — chained updates (semicolon separator)" begin
        ds = Dataset()
        sparql_update!(ds, """
          PREFIX ex:   <http://example.org/>
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          INSERT DATA { ex:alice foaf:name "Alice" } ;
          INSERT DATA { ex:bob   foaf:name "Bob"   }
        """)
        @test length(ds.default_graph) == 2
    end

    @testset "sparql_update! — CLEAR DEFAULT" begin
        ds = _sparql_ds()
        @test !isempty(ds.default_graph)

        sparql_update!(ds, "CLEAR DEFAULT")
        @test isempty(ds.default_graph)
    end

    # ── Query against Graph directly ──────────────────────────────────────────

    @testset "sparql — accepts Graph directly (wraps in Dataset)" begin
        g = Graph()
        push!(g, Triple(ex.alice, foaf.name, Literal("Alice")))
        push!(g, Triple(ex.bob,   foaf.name, Literal("Bob")))

        result = sparql(g, """
          PREFIX foaf: <http://xmlns.com/foaf/0.1/>
          SELECT ?name WHERE { ?s foaf:name ?name }
        """)
        @test length(result) == 2
    end

    # ── Error cases ───────────────────────────────────────────────────────────

    @testset "sparql — unknown prefix raises error" begin
        ds = _sparql_ds()
        @test_throws Exception sparql(ds,
            "SELECT ?s WHERE { ?s unknownprefix:prop ?o }")
    end

    @testset "sparql — passing update to sparql() raises error" begin
        ds = _sparql_ds()
        @test_throws Exception sparql(ds,
            "INSERT DATA { <http://example.org/x> <http://example.org/p> <http://example.org/o> }")
    end

end
