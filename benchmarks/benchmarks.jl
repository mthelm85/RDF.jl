"""
RDF.jl benchmark suite
======================

Standalone run:
    julia --project=benchmarks benchmarks/benchmarks.jl

With comparison against a saved baseline:
    julia --project=benchmarks benchmarks/benchmarks.jl --compare=baseline.json

Save results for later comparison:
    julia --project=benchmarks benchmarks/benchmarks.jl --save=baseline.json

Via PkgBenchmark (for CI regression tracking):
    using PkgBenchmark
    results = benchmarkpkg(RDF)
    export_markdown(stdout, results)

Sections:
  intern         — term-registry lookup throughput (IRI, Literal, BlankNode)
  insertion      — triple insertion into a fresh Graph
  match          — hexastore pattern matching (all 7 binding patterns + full scan)
  literal        — Literal construction and value() coercion
  union          — graph union with blank-node renaming
  isomorphism    — blank-node isomorphism check
  ntriples       — N-Triples read/write
  nquads         — N-Quads read/write
  turtle         — Turtle parse and write
  jsonld         — JSON-LD parse and write
  sparql_results — SPARQL result format serialization (JSON, XML, CSV, TSV)
  inference      — RDFS forward-chaining closure
  validation     — literal datatype validation
  sparql/parse   — SPARQL query and update parsing
  sparql/bgp     — basic graph pattern evaluation
  sparql/agg     — GROUP BY + aggregates
  sparql/path    — property path evaluation (transitive closure)
  sparql/subq    — subquery with ORDER BY + LIMIT
  sparql/update  — SPARQL UPDATE (INSERT DATA, DELETE/INSERT/WHERE)
"""

using BenchmarkTools, Dates, Printf, RDF

const SUITE = BenchmarkGroup()

# ── Helpers ────────────────────────────────────────────────────────────────────

function make_triples(n::Int)
    ex = Namespace("http://example.org/")
    [Triple(ex["s$i"], ex["p$(i % 100)"], ex["o$i"]) for i in 1:n]
end

function make_graph(n::Int)
    g = Graph()
    for t in make_triples(n); push!(g, t); end
    g
end

# Social-network graph: n people with foaf:name, foaf:age, foaf:knows (chain)
function make_social_graph(n::Int)
    ex   = Namespace("http://example.org/")
    foaf = Namespace("http://xmlns.com/foaf/0.1/")
    g    = Graph()
    for i in 1:n
        s = ex["person$i"]
        push!(g, Triple(s, foaf.name,     Literal("Person $i")))
        push!(g, Triple(s, foaf.age,      Literal(20 + i % 60)))
        push!(g, Triple(s, rdf.type,      foaf.Person))
        i < n && push!(g, Triple(s, foaf.knows, ex["person$(i+1)"]))
    end
    g
end

# Hierarchical class graph: n nodes in a binary-tree subClassOf hierarchy
function make_class_graph(n::Int)
    ex = Namespace("http://example.org/")
    g  = Graph()
    for i in 2:n
        push!(g, Triple(ex["c$i"], rdfs.subClassOf, ex["c$(div(i,2))"]))
    end
    g
end

# JSON-LD document with n subjects
function make_jsonld_bytes(n::Int)
    io = IOBuffer()
    print(io, """{"@context":{"ex":"http://bench.example/","foaf":"http://xmlns.com/foaf/0.1/","name":"foaf:name","age":{"@id":"foaf:age","@type":"http://www.w3.org/2001/XMLSchema#integer"}},"@graph":[""")
    for i in 1:n
        i > 1 && print(io, ",")
        print(io, """{"@id":"ex:p$i","@type":"ex:Person","name":"Person $i","age":$(20 + i % 60)}""")
    end
    print(io, "]}")
    take!(io)
end

# ── 1. Intern table ────────────────────────────────────────────────────────────
# Measures the intern-table lookup path for already-interned terms (hot path
# during graph construction when the same vocabulary IRIs are reused).

SUITE["intern"] = BenchmarkGroup()
let
    ex   = Namespace("http://example.org/")
    foaf = Namespace("http://xmlns.com/foaf/0.1/")

    # Pre-intern 1 000 IRIs so they're in the table
    pre_iris  = [ex["r$i"] for i in 1:1_000]
    pre_lits  = [Literal(i) for i in 1:1_000]

    # Build a graph with those terms so the table is warmed
    g_warm = Graph()
    for (i, iri) in enumerate(pre_iris)
        push!(g_warm, Triple(iri, foaf.name, pre_lits[i]))
    end

    # Benchmark: re-insert the same triples (all terms already interned → pure lookup)
    SUITE["intern"]["iri_lookup/n=1k"] = @benchmarkable begin
        g = Graph()
        for t in $pre_iris
            push!(g, Triple(t, rdf.type, IRI("http://example.org/Thing")))
        end
    end

    # Benchmark: intern brand-new literals at insertion time
    fresh_lits = [Literal("value_$i"; lang="en") for i in 10_001:11_000]
    SUITE["intern"]["literal_new/n=1k"] = @benchmarkable begin
        g = Graph()
        ex2 = Namespace("http://intern-bench-new.example/")
        for (i, lit) in enumerate($fresh_lits)
            push!(g, Triple(ex2["s$i"], rdf.type, IRI("http://intern-bench-new.example/C")))
        end
    end
end

# ── 2. Triple insertion ────────────────────────────────────────────────────────

SUITE["insertion"] = BenchmarkGroup()
for n in (1_000, 10_000, 100_000)
    ts = make_triples(n)
    SUITE["insertion"]["n=$n"] = @benchmarkable begin
        g = Graph()
        for t in $ts; push!(g, t); end
    end
end

# ── 3. Pattern matching ────────────────────────────────────────────────────────

SUITE["match"] = BenchmarkGroup()
let
    ex = Namespace("http://example.org/")
    g  = make_graph(10_000)
    s0 = ex["s1"]; p0 = ex["p1"]; o0 = ex["o1"]

    SUITE["match"]["S__"]  = @benchmarkable collect(match($g; subject=$s0))
    SUITE["match"]["_P_"]  = @benchmarkable collect(match($g; predicate=$p0))
    SUITE["match"]["__O"]  = @benchmarkable collect(match($g; object=$o0))
    SUITE["match"]["SP_"]  = @benchmarkable collect(match($g; subject=$s0, predicate=$p0))
    SUITE["match"]["S_O"]  = @benchmarkable collect(match($g; subject=$s0, object=$o0))
    SUITE["match"]["_PO"]  = @benchmarkable collect(match($g; predicate=$p0, object=$o0))
    SUITE["match"]["SPO"]  = @benchmarkable collect(match($g; subject=$s0, predicate=$p0, object=$o0))
    SUITE["match"]["___"]  = @benchmarkable collect(match($g))
end

# ── 4. Literal construction and coercion ──────────────────────────────────────

SUITE["literal"] = BenchmarkGroup()
let
    int_lits  = [Literal(i)           for i in 1:1_000]
    dbl_lits  = [Literal(Float64(i))  for i in 1:1_000]
    str_lits  = [Literal("value $i")  for i in 1:1_000]
    lang_lits = [Literal("val $i"; lang="en") for i in 1:1_000]
    date_lits = [Literal(Dates.Date(2020, 1, 1) + Dates.Day(i)) for i in 1:1_000]

    SUITE["literal"]["construct_int/n=1k"]  = @benchmarkable [Literal(i) for i in 1:1_000]
    SUITE["literal"]["construct_str/n=1k"]  = @benchmarkable [Literal("value $i") for i in 1:1_000]
    SUITE["literal"]["construct_lang/n=1k"] = @benchmarkable [Literal("val $i"; lang="en") for i in 1:1_000]

    SUITE["literal"]["value_int/n=1k"]  = @benchmarkable [value(Int64,   l) for l in $int_lits]
    SUITE["literal"]["value_dbl/n=1k"]  = @benchmarkable [value(Float64, l) for l in $dbl_lits]
    SUITE["literal"]["value_str/n=1k"]  = @benchmarkable [value(String,  l) for l in $str_lits]
    SUITE["literal"]["value_date/n=1k"] = @benchmarkable [value(Dates.Date, l) for l in $date_lits]
end

# ── 5. Graph set operations ────────────────────────────────────────────────────

SUITE["union"] = BenchmarkGroup()
let
    g1 = Graph(); g2 = Graph()
    ex = Namespace("http://example.org/")
    for i in 1:1_000
        b1 = blank!(g1); b2 = blank!(g2)
        push!(g1, Triple(b1, ex.p, ex["o$i"]))
        push!(g2, Triple(b2, ex.p, ex["o$i"]))
    end
    SUITE["union"]["blank_rename_1k"] = @benchmarkable union($g1, $g2)
end

# ── 6. Graph isomorphism ───────────────────────────────────────────────────────

SUITE["isomorphism"] = BenchmarkGroup()
let
    # Two isomorphic graphs (blank-node bijection must be found)
    g1 = Graph(); g2 = Graph()
    ex = Namespace("http://example.org/")
    bns1 = [blank!(g1) for _ in 1:50]
    bns2 = [blank!(g2) for _ in 1:50]
    for i in 1:50
        push!(g1, Triple(bns1[i], ex.p, ex["o$i"]))
        push!(g2, Triple(bns2[i], ex.p, ex["o$i"]))
    end

    # Non-isomorphic graph (one extra triple)
    g3 = Graph()
    bns3 = [blank!(g3) for _ in 1:51]
    for i in 1:51
        push!(g3, Triple(bns3[i], ex.p, ex["o$i"]))
    end

    SUITE["isomorphism"]["iso_50bn"]     = @benchmarkable isomorphic($g1, $g2)
    SUITE["isomorphism"]["non_iso_50bn"] = @benchmarkable isomorphic($g1, $g3)
end

# ── 7. N-Triples serialization ────────────────────────────────────────────────

SUITE["ntriples"] = BenchmarkGroup()
let
    g        = make_graph(10_000)
    buf      = IOBuffer(); write(buf, MIME"application/n-triples"(), g)
    nt_bytes = take!(buf)

    SUITE["ntriples"]["write_10k"] = @benchmarkable write(IOBuffer(), MIME"application/n-triples"(), $g)
    SUITE["ntriples"]["read_10k"]  = @benchmarkable read(IOBuffer($nt_bytes), MIME"application/n-triples"(), Graph)
end

# ── 8. N-Quads serialization ──────────────────────────────────────────────────

SUITE["nquads"] = BenchmarkGroup()
let
    ex = Namespace("http://example.org/")
    ds = Dataset()
    for gi in 1:5
        g = Graph()
        for i in 1:2_000
            push!(g, Triple(ex["s$i"], ex["p$(i%100)"], ex["o$i"]))
        end
        ds[ex["graph$gi"]] = g
    end
    buf      = IOBuffer(); write(buf, MIME"application/n-quads"(), ds)
    nq_bytes = take!(buf)

    SUITE["nquads"]["write_10k"] = @benchmarkable write(IOBuffer(), MIME"application/n-quads"(), $ds)
    SUITE["nquads"]["read_10k"]  = @benchmarkable read(IOBuffer($nq_bytes), MIME"application/n-quads"(), Dataset)
end

# ── 9. Turtle parse and write ─────────────────────────────────────────────────

SUITE["turtle"] = BenchmarkGroup()
let
    lines = String["@prefix ex: <http://example.org/> .",
                   "@prefix foaf: <http://xmlns.com/foaf/0.1/> ."]
    for i in 1:1_000
        push!(lines, "ex:person$i foaf:name \"Person $i\" ; foaf:age $(20 + i%60) .")
    end
    src = Vector{UInt8}(join(lines, "\n"))
    g   = read(IOBuffer(src), MIME"text/turtle"(), Graph)

    SUITE["turtle"]["parse_1k"] = @benchmarkable read(IOBuffer($src), MIME"text/turtle"(), Graph)
    SUITE["turtle"]["write_1k"] = @benchmarkable write(IOBuffer(), MIME"text/turtle"(), $g)
end

# ── 10. JSON-LD parse and write ───────────────────────────────────────────────

SUITE["jsonld"] = BenchmarkGroup()
let
    bytes_100  = make_jsonld_bytes(100)
    bytes_1k   = make_jsonld_bytes(1_000)
    g_1k       = read(IOBuffer(bytes_1k), MIME"application/ld+json"(), Graph)

    SUITE["jsonld"]["parse/n=100"]  = @benchmarkable read(IOBuffer($bytes_100), MIME"application/ld+json"(), Graph)
    SUITE["jsonld"]["parse/n=1k"]   = @benchmarkable read(IOBuffer($bytes_1k),  MIME"application/ld+json"(), Graph)
    SUITE["jsonld"]["write/n=1k"]   = @benchmarkable write(IOBuffer(), MIME"application/ld+json"(), $g_1k)
end

# ── 11. SPARQL result format serialization ────────────────────────────────────

SUITE["sparql_results"] = BenchmarkGroup()
let
    ds  = Dataset(; default_graph=make_social_graph(1_000))
    sol = sparql(ds, "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?s ?name ?age WHERE { ?s foaf:name ?name ; foaf:age ?age }")

    SUITE["sparql_results"]["json/n=1k"] = @benchmarkable write(IOBuffer(), MIME"application/sparql-results+json"(), $sol)
    SUITE["sparql_results"]["xml/n=1k"]  = @benchmarkable write(IOBuffer(), MIME"application/sparql-results+xml"(),  $sol)
    SUITE["sparql_results"]["csv/n=1k"]  = @benchmarkable write(IOBuffer(), MIME"text/csv"(),                        $sol)
    SUITE["sparql_results"]["tsv/n=1k"]  = @benchmarkable write(IOBuffer(), MIME"text/tab-separated-values"(),       $sol)
end

# ── 12. RDFS inference ────────────────────────────────────────────────────────

SUITE["inference"] = BenchmarkGroup()
let
    g_small = make_class_graph(63)    # 6-level binary tree
    g_large = make_class_graph(255)   # 8-level binary tree
    SUITE["inference"]["subclass_63"]  = @benchmarkable infer_rdfs($g_small)
    SUITE["inference"]["subclass_255"] = @benchmarkable infer_rdfs($g_large)
end

# ── 13. Validation ────────────────────────────────────────────────────────────

SUITE["validation"] = BenchmarkGroup()
let
    ex  = Namespace("http://example.org/")
    g   = Graph()
    for i in 1:1_000
        push!(g, Triple(ex["s$i"], ex.age,  Literal(i)))
        push!(g, Triple(ex["s$i"], ex.name, Literal("Person $i")))
        push!(g, Triple(ex["s$i"], ex.score, Literal(Float64(i) / 100.0)))
    end
    SUITE["validation"]["validate_3k_triples"] = @benchmarkable validate($g)
end

# ── 14. SPARQL parsing ────────────────────────────────────────────────────────

SUITE["sparql"] = BenchmarkGroup()
SUITE["sparql"]["parse"] = BenchmarkGroup()

let
    simple_bgp = """
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        SELECT ?name ?age WHERE { ?s foaf:name ?name ; foaf:age ?age . FILTER(?age > 25) }
    """
    complex_q = """
        PREFIX ex:   <http://example.org/>
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        SELECT ?name (COUNT(?friend) AS ?nfriends) WHERE {
          ?person a foaf:Person ;
                  foaf:name ?name .
          OPTIONAL { ?person foaf:knows ?friend }
        } GROUP BY ?name ORDER BY DESC(?nfriends) LIMIT 10
    """
    path_q = """
        PREFIX ex:   <http://example.org/>
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        SELECT ?reachable WHERE { ex:person1 foaf:knows+ ?reachable }
    """
    update_q = """
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        DELETE { ?s foaf:age ?old }
        INSERT { ?s foaf:age ?new }
        WHERE  { ?s foaf:name "Alice" ; foaf:age ?old . BIND(?old + 1 AS ?new) }
    """

    SUITE["sparql"]["parse"]["simple_bgp"]    = @benchmarkable sparql_parse($simple_bgp)
    SUITE["sparql"]["parse"]["complex_query"] = @benchmarkable sparql_parse($complex_q)
    SUITE["sparql"]["parse"]["path_query"]    = @benchmarkable sparql_parse($path_q)
    SUITE["sparql"]["parse"]["update"]        = @benchmarkable sparql_parse($update_q)
end

# ── 15. SPARQL BGP evaluation ─────────────────────────────────────────────────

SUITE["sparql"]["bgp"] = BenchmarkGroup()
let
    for n in (100, 1_000, 10_000)
        ds = Dataset(; default_graph=make_social_graph(n))

        q1 = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?s WHERE { ?s foaf:name ?n }"
        q2 = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?name ?age WHERE { ?s foaf:name ?name ; foaf:age ?age }"
        q3 = """PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                SELECT ?name ?age WHERE {
                  ?s foaf:name ?name ; foaf:age ?age .
                  FILTER(?age > 40)
                }"""
        q4 = """PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                SELECT ?name ?friend WHERE {
                  ?s foaf:name ?name .
                  OPTIONAL { ?s foaf:knows ?friend }
                }"""

        SUITE["sparql"]["bgp"]["single_triple/n=$n"]   = @benchmarkable sparql($ds, $q1)
        SUITE["sparql"]["bgp"]["two_triple_join/n=$n"] = @benchmarkable sparql($ds, $q2)
        SUITE["sparql"]["bgp"]["filter/n=$n"]          = @benchmarkable sparql($ds, $q3)
        SUITE["sparql"]["bgp"]["optional/n=$n"]        = @benchmarkable sparql($ds, $q4)
    end
end

# ── 16. SPARQL aggregates ─────────────────────────────────────────────────────

SUITE["sparql"]["aggregate"] = BenchmarkGroup()
let
    ds_1k  = Dataset(; default_graph=make_social_graph(1_000))
    ds_10k = Dataset(; default_graph=make_social_graph(10_000))

    count_q   = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT (COUNT(?s) AS ?n) WHERE { ?s a foaf:Person }"
    groupby_q = """PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                   SELECT ?age (COUNT(?s) AS ?n) WHERE {
                     ?s a foaf:Person ; foaf:age ?age
                   } GROUP BY ?age ORDER BY ?age"""
    having_q  = """PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                   SELECT ?age (COUNT(?s) AS ?n) WHERE {
                     ?s a foaf:Person ; foaf:age ?age
                   } GROUP BY ?age HAVING(COUNT(?s) > 5) ORDER BY DESC(?n)"""

    SUITE["sparql"]["aggregate"]["count/n=1k"]    = @benchmarkable sparql($ds_1k,  $count_q)
    SUITE["sparql"]["aggregate"]["count/n=10k"]   = @benchmarkable sparql($ds_10k, $count_q)
    SUITE["sparql"]["aggregate"]["groupby/n=1k"]  = @benchmarkable sparql($ds_1k,  $groupby_q)
    SUITE["sparql"]["aggregate"]["groupby/n=10k"] = @benchmarkable sparql($ds_10k, $groupby_q)
    SUITE["sparql"]["aggregate"]["having/n=10k"]  = @benchmarkable sparql($ds_10k, $having_q)
end

# ── 17. SPARQL property paths ─────────────────────────────────────────────────

SUITE["sparql"]["path"] = BenchmarkGroup()
let
    for n in (50, 200)
        ds = Dataset(; default_graph=make_social_graph(n))

        q_hop1 = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?f WHERE { <http://example.org/person1> foaf:knows ?f }"
        q_plus = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?f WHERE { <http://example.org/person1> foaf:knows+ ?f }"
        q_star = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?f WHERE { <http://example.org/person1> foaf:knows* ?f }"

        SUITE["sparql"]["path"]["1-hop/n=$n"]  = @benchmarkable sparql($ds, $q_hop1)
        SUITE["sparql"]["path"]["plus/n=$n"]   = @benchmarkable sparql($ds, $q_plus)
        SUITE["sparql"]["path"]["star/n=$n"]   = @benchmarkable sparql($ds, $q_star)
    end

    ds50  = Dataset(; default_graph=make_social_graph(50))
    q_inv = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?s WHERE { ?s ^foaf:knows <http://example.org/person50> }"
    q_seq = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?f WHERE { <http://example.org/person1> foaf:knows/foaf:knows ?f }"
    SUITE["sparql"]["path"]["inverse/n=50"]  = @benchmarkable sparql($ds50, $q_inv)
    SUITE["sparql"]["path"]["sequence/n=50"] = @benchmarkable sparql($ds50, $q_seq)
end

# ── 18. SPARQL subqueries ─────────────────────────────────────────────────────

SUITE["sparql"]["subquery"] = BenchmarkGroup()
let
    ds = Dataset(; default_graph=make_social_graph(1_000))

    q_limit  = """PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                  SELECT ?name WHERE {
                    { SELECT ?s WHERE { ?s a foaf:Person } ORDER BY ?s LIMIT 10 }
                    ?s foaf:name ?name
                  }"""
    q_nested = """PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                  SELECT ?name ?age WHERE {
                    {
                      SELECT ?s WHERE {
                        { SELECT ?s WHERE { ?s a foaf:Person } ORDER BY ?s LIMIT 20 }
                        ?s foaf:age ?a . FILTER(?a > 30)
                      }
                    }
                    ?s foaf:name ?name ; foaf:age ?age
                  }"""
    q_values = """PREFIX ex:   <http://example.org/>
                  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                  SELECT ?name WHERE {
                    VALUES ?s { ex:person1 ex:person2 ex:person3 ex:person4 ex:person5 }
                    ?s foaf:name ?name
                  }"""

    SUITE["sparql"]["subquery"]["limit_subq"]  = @benchmarkable sparql($ds, $q_limit)
    SUITE["sparql"]["subquery"]["nested_subq"] = @benchmarkable sparql($ds, $q_nested)
    SUITE["sparql"]["subquery"]["values_join"] = @benchmarkable sparql($ds, $q_values)
end

# ── 19. SPARQL UPDATE ─────────────────────────────────────────────────────────
# Use setup= so graph construction cost is excluded from the measurement.

SUITE["sparql"]["update"] = BenchmarkGroup()
let
    insert_data = """
        PREFIX ex:   <http://example.org/>
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        INSERT DATA { ex:newperson foaf:name "New Person" ; foaf:age 35 . }
    """
    update_age = """
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        DELETE { ?s foaf:age ?old }
        INSERT { ?s foaf:age ?new }
        WHERE  { ?s foaf:age ?old . FILTER(?old < 30) . BIND(?old + 1 AS ?new) }
    """

    # Insert: graph created fresh each sample so inserts don't accumulate
    SUITE["sparql"]["update"]["insert_data/n=100"] =
        @benchmarkable sparql_update!(ds, $insert_data) setup=(ds=Dataset(; default_graph=make_social_graph(100)))

    # Delete/insert on 100-person graph
    SUITE["sparql"]["update"]["delete_insert/n=100"] =
        @benchmarkable sparql_update!(ds, $update_age) setup=(ds=Dataset(; default_graph=make_social_graph(100)))

    # Delete/insert on 1k-person graph (measures join + filter + mutation scaling)
    SUITE["sparql"]["update"]["delete_insert/n=1k"] =
        @benchmarkable sparql_update!(ds, $update_age) setup=(ds=Dataset(; default_graph=make_social_graph(1_000)))
end

# ── Runner ─────────────────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    let
        # Parse CLI arguments
        local save_path    = nothing
        local compare_path = nothing
        for arg in ARGS
            if startswith(arg, "--save=")
                save_path = arg[8:end]
            elseif startswith(arg, "--compare=")
                compare_path = arg[11:end]
            end
        end

        println("RDF.jl Benchmark Suite")
        println("Julia $(VERSION)  •  $(Threads.nthreads()) thread(s)  •  $(Dates.now())")
        println()

        println("Tuning sample counts…")
        tune!(SUITE)

        println("Warming up JIT…")
        run(SUITE; verbose=false, seconds=1)

        println("Running benchmarks (this may take a few minutes)…\n")
        local results = run(SUITE; verbose=true, seconds=5)

        # ── Print summary table ────────────────────────────────────────────────────
        println()
        println("─"^90)
        @printf("%-58s  %12s  %8s  %8s  %s\n",
                "Benchmark", "Median", "Min", "Allocs", "Memory")
        println("─"^90)

        for (path, trial) in sort(collect(BenchmarkTools.leaves(results)); by=first)
            t = BenchmarkTools.median(trial)
            m = BenchmarkTools.minimum(trial)
            @printf("%-58s  %12s  %8s  %6d  %s\n",
                join(path, "/"),
                BenchmarkTools.prettytime(t.time),
                BenchmarkTools.prettytime(m.time),
                t.allocs,
                BenchmarkTools.prettymemory(t.memory))
        end
        println("─"^90)

        # ── Save results ───────────────────────────────────────────────────────────
        if save_path !== nothing
            BenchmarkTools.save(save_path, results)
            println("\nResults saved to: $save_path")
        end

        # ── Compare against baseline ───────────────────────────────────────────────
        if compare_path !== nothing && isfile(compare_path)
            baseline = BenchmarkTools.load(compare_path)[1]
            judgment = judge(results, baseline; time_tolerance=0.10, memory_tolerance=0.05)

            println("\nRegression report (vs $(compare_path)):")
            println("─"^90)
            local has_regression = false
            for (path, j) in sort(collect(BenchmarkTools.leaves(judgment)); by=first)
                ratio = j.ratio.time
                mark  = if ratio > 1.10
                    has_regression = true
                    "  ⚠  REGRESSION"
                elseif ratio < 0.90
                    "  ✓  improvement"
                else
                    ""
                end
                isempty(mark) || @printf("%-58s  %+.1f%%%s\n", join(path, "/"), (ratio-1)*100, mark)
            end
            has_regression || println("  No regressions detected (±10% tolerance).")
            println("─"^90)
        end
    end
end
