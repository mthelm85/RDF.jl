"""
RDF.jl benchmark suite
======================

Run with:
    julia --project=benchmarks benchmarks/benchmarks.jl

Covers:
  insertion    — triple insertion throughput
  match        — hexastore pattern matching (all 7 binding patterns + full scan)
  union        — graph union with blank-node renaming
  ntriples     — N-Triples read/write throughput
  turtle       — Turtle parse throughput
  inference    — RDFS forward-chaining closure
  sparql/parse — SPARQL query parsing (lexer + recursive-descent parser)
  sparql/bgp   — basic graph pattern evaluation at various graph sizes
  sparql/agg   — GROUP BY + aggregate (COUNT, SUM)
  sparql/path  — property path evaluation (transitive closure)
  sparql/subq  — subquery with ORDER BY + LIMIT
  sparql/update — SPARQL UPDATE (INSERT DATA, DELETE/INSERT/WHERE)
"""

using BenchmarkTools, Printf, RDF

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

# Social-network graph: n people connected via foaf:knows in a chain,
# each with a foaf:name literal and a foaf:age integer.
function make_social_graph(n::Int)
    ex   = Namespace("http://example.org/")
    foaf = Namespace("http://xmlns.com/foaf/0.1/")
    g    = Graph()
    for i in 1:n
        s = ex["person$i"]
        push!(g, Triple(s, foaf.name, Literal("Person $i")))
        push!(g, Triple(s, foaf.age,  Literal(20 + i % 60)))
        push!(g, Triple(s, RDF.rdf.type, foaf.Person))
        if i < n
            push!(g, Triple(s, foaf.knows, ex["person$(i+1)"]))
        end
    end
    g
end

# Hierarchical class graph: n nodes in a binary-tree subClassOf hierarchy
function make_class_graph(n::Int)
    ex   = Namespace("http://example.org/")
    g    = Graph()
    for i in 1:n
        if i > 1
            push!(g, Triple(ex["c$i"], RDF.rdfs.subClassOf, ex["c$(div(i,2))"]))
        end
    end
    g
end

# ── 1. Triple insertion ────────────────────────────────────────────────────────

SUITE["insertion"] = BenchmarkGroup()
for n in (1_000, 10_000, 100_000)
    ts = make_triples(n)
    SUITE["insertion"]["n=$n"] = @benchmarkable begin
        g = Graph()
        for t in $ts; push!(g, t); end
    end
end

# ── 2. Pattern matching ────────────────────────────────────────────────────────

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

# ── 3. Graph set operations ────────────────────────────────────────────────────

SUITE["union"] = BenchmarkGroup()
let
    g1 = Graph(); g2 = Graph()
    for i in 1:1_000
        b1 = blank!(g1); b2 = blank!(g2)
        ex = Namespace("http://example.org/")
        push!(g1, Triple(b1, ex["p"], ex["o$i"]))
        push!(g2, Triple(b2, ex["p"], ex["o$i"]))
    end
    SUITE["union"]["blank_rename_1k"] = @benchmarkable union($g1, $g2)
end

# ── 4. N-Triples serialization ────────────────────────────────────────────────

SUITE["ntriples"] = BenchmarkGroup()
let
    g        = make_graph(10_000)
    buf      = IOBuffer(); write(buf, MIME"application/n-triples"(), g)
    nt_bytes = take!(buf)

    SUITE["ntriples"]["write_10k"] = @benchmarkable begin
        b = IOBuffer(); write(b, MIME"application/n-triples"(), $g)
    end
    SUITE["ntriples"]["read_10k"]  = @benchmarkable begin
        read(IOBuffer($nt_bytes), MIME"application/n-triples"(), Graph)
    end
end

# ── 5. Turtle parsing ─────────────────────────────────────────────────────────

SUITE["turtle"] = BenchmarkGroup()
let
    # Build a Turtle document with semicolon-chained triples
    ex   = Namespace("http://example.org/")
    foaf = Namespace("http://xmlns.com/foaf/0.1/")
    lines = String["@prefix ex: <http://example.org/> .",
                   "@prefix foaf: <http://xmlns.com/foaf/0.1/> ."]
    for i in 1:1_000
        push!(lines, "ex:person$i foaf:name \"Person $i\" ; foaf:age $(20 + i % 60) .")
    end
    src = join(lines, "\n") |> x -> Vector{UInt8}(x)

    SUITE["turtle"]["parse_1k_subjects"] = @benchmarkable begin
        read(IOBuffer($src), MIME"text/turtle"(), Graph)
    end
end

# ── 6. RDFS inference ─────────────────────────────────────────────────────────

SUITE["inference"] = BenchmarkGroup()
let
    g_small = make_class_graph(63)   # 6-level balanced binary tree → dense subClassOf
    g_large = make_class_graph(255)
    SUITE["inference"]["subclass_63"]  = @benchmarkable infer_rdfs($g_small)
    SUITE["inference"]["subclass_255"] = @benchmarkable infer_rdfs($g_large)
end

# ── 7. SPARQL parsing ─────────────────────────────────────────────────────────

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

# ── 8. SPARQL BGP evaluation ──────────────────────────────────────────────────

SUITE["sparql"]["bgp"] = BenchmarkGroup()
let
    foaf = Namespace("http://xmlns.com/foaf/0.1/")

    for n in (100, 1_000, 10_000)
        g  = make_social_graph(n)
        ds = Dataset(; default_graph=g)

        # Single-triple BGP — one predicate scan
        q1 = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?s WHERE { ?s foaf:name ?n }"
        # Two-triple BGP — join on ?s
        q2 = """PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                SELECT ?name ?age WHERE { ?s foaf:name ?name ; foaf:age ?age }"""
        # Three-triple BGP with FILTER
        q3 = """PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                SELECT ?name ?age WHERE {
                  ?s foaf:name ?name ; foaf:age ?age .
                  FILTER(?age > 40)
                }"""
        # OPTIONAL
        q4 = """PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                PREFIX ex:   <http://example.org/>
                SELECT ?name ?friend WHERE {
                  ?s foaf:name ?name .
                  OPTIONAL { ?s foaf:knows ?friend }
                }"""

        SUITE["sparql"]["bgp"]["single_triple/n=$n"]    = @benchmarkable sparql($ds, $q1)
        SUITE["sparql"]["bgp"]["two_triple_join/n=$n"]  = @benchmarkable sparql($ds, $q2)
        SUITE["sparql"]["bgp"]["filter/n=$n"]           = @benchmarkable sparql($ds, $q3)
        SUITE["sparql"]["bgp"]["optional/n=$n"]         = @benchmarkable sparql($ds, $q4)
    end
end

# ── 9. SPARQL aggregates ──────────────────────────────────────────────────────

SUITE["sparql"]["aggregate"] = BenchmarkGroup()
let
    ds_1k  = Dataset(; default_graph=make_social_graph(1_000))
    ds_10k = Dataset(; default_graph=make_social_graph(10_000))

    count_q = """PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                 SELECT (COUNT(?s) AS ?n) WHERE { ?s a foaf:Person }"""

    groupby_q = """PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                   SELECT ?age (COUNT(?s) AS ?n) WHERE {
                     ?s a foaf:Person ; foaf:age ?age
                   } GROUP BY ?age ORDER BY ?age"""

    having_q = """PREFIX foaf: <http://xmlns.com/foaf/0.1/>
                  SELECT ?age (COUNT(?s) AS ?n) WHERE {
                    ?s a foaf:Person ; foaf:age ?age
                  } GROUP BY ?age HAVING(COUNT(?s) > 5) ORDER BY DESC(?n)"""

    SUITE["sparql"]["aggregate"]["count/n=1k"]    = @benchmarkable sparql($ds_1k, $count_q)
    SUITE["sparql"]["aggregate"]["count/n=10k"]   = @benchmarkable sparql($ds_10k, $count_q)
    SUITE["sparql"]["aggregate"]["groupby/n=1k"]  = @benchmarkable sparql($ds_1k, $groupby_q)
    SUITE["sparql"]["aggregate"]["groupby/n=10k"] = @benchmarkable sparql($ds_10k, $groupby_q)
    SUITE["sparql"]["aggregate"]["having/n=10k"]  = @benchmarkable sparql($ds_10k, $having_q)
end

# ── 10. SPARQL property paths ─────────────────────────────────────────────────

SUITE["sparql"]["path"] = BenchmarkGroup()
let
    # Linear chain: person1 → person2 → … → personN
    # transitive closure is O(N) with varying reachability
    foaf = Namespace("http://xmlns.com/foaf/0.1/")
    ex   = Namespace("http://example.org/")

    for n in (50, 200)
        g  = make_social_graph(n)
        ds = Dataset(; default_graph=g)

        # One-hop
        q_hop1 = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?f WHERE { <http://example.org/person1> foaf:knows ?f }"
        # Transitive closure from root (visits all n-1 nodes)
        q_star = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?f WHERE { <http://example.org/person1> foaf:knows+ ?f }"
        # Zero-or-more from root
        q_zom  = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?f WHERE { <http://example.org/person1> foaf:knows* ?f }"

        SUITE["sparql"]["path"]["1-hop/n=$n"]    = @benchmarkable sparql($ds, $q_hop1)
        SUITE["sparql"]["path"]["plus/n=$n"]     = @benchmarkable sparql($ds, $q_star)
        SUITE["sparql"]["path"]["star/n=$n"]     = @benchmarkable sparql($ds, $q_zom)
    end

    # Inverse path
    ds50 = Dataset(; default_graph=make_social_graph(50))
    q_inv = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?s WHERE { ?s ^foaf:knows <http://example.org/person50> }"
    q_seq = "PREFIX foaf: <http://xmlns.com/foaf/0.1/> SELECT ?f WHERE { <http://example.org/person1> foaf:knows/foaf:knows ?f }"

    SUITE["sparql"]["path"]["inverse/n=50"]  = @benchmarkable sparql($ds50, $q_inv)
    SUITE["sparql"]["path"]["sequence/n=50"] = @benchmarkable sparql($ds50, $q_seq)
end

# ── 11. SPARQL subqueries ─────────────────────────────────────────────────────

SUITE["sparql"]["subquery"] = BenchmarkGroup()
let
    ds = Dataset(; default_graph=make_social_graph(1_000))

    # Subquery with LIMIT — only join top-10 people
    q_limit = """
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        SELECT ?name WHERE {
          { SELECT ?s WHERE { ?s a foaf:Person } ORDER BY ?s LIMIT 10 }
          ?s foaf:name ?name
        }
    """

    # Nested subquery (two levels)
    q_nested = """
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        SELECT ?name ?age WHERE {
          {
            SELECT ?s WHERE {
              { SELECT ?s WHERE { ?s a foaf:Person } ORDER BY ?s LIMIT 20 }
              ?s foaf:age ?a . FILTER(?a > 30)
            }
          }
          ?s foaf:name ?name ; foaf:age ?age
        }
    """

    # VALUES (inline data join)
    q_values = """
        PREFIX ex:   <http://example.org/>
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        SELECT ?name WHERE {
          VALUES ?s { ex:person1 ex:person2 ex:person3 ex:person4 ex:person5 }
          ?s foaf:name ?name
        }
    """

    SUITE["sparql"]["subquery"]["limit_subq"]  = @benchmarkable sparql($ds, $q_limit)
    SUITE["sparql"]["subquery"]["nested_subq"] = @benchmarkable sparql($ds, $q_nested)
    SUITE["sparql"]["subquery"]["values_join"] = @benchmarkable sparql($ds, $q_values)
end

# ── 12. SPARQL UPDATE ─────────────────────────────────────────────────────────

SUITE["sparql"]["update"] = BenchmarkGroup()
let
    foaf = Namespace("http://xmlns.com/foaf/0.1/")
    ex   = Namespace("http://example.org/")

    insert_data = """
        PREFIX ex:   <http://example.org/>
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        INSERT DATA {
          ex:newperson foaf:name "New Person" ;
                       foaf:age 35 .
        }
    """

    # Delete/insert conditional update
    update_age = """
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        DELETE { ?s foaf:age ?old }
        INSERT { ?s foaf:age ?new }
        WHERE  {
          ?s foaf:age ?old .
          FILTER(?old < 30)
          BIND(?old + 1 AS ?new)
        }
    """

    # Note: each benchmark run gets a fresh graph copy so mutations don't accumulate
    SUITE["sparql"]["update"]["insert_data"] = @benchmarkable begin
        ds = Dataset(; default_graph=make_social_graph(100))
        sparql_update!(ds, $insert_data)
    end

    SUITE["sparql"]["update"]["delete_insert_where/n=100"] = @benchmarkable begin
        ds = Dataset(; default_graph=make_social_graph(100))
        sparql_update!(ds, $update_age)
    end

    SUITE["sparql"]["update"]["delete_insert_where/n=1k"] = @benchmarkable begin
        ds = Dataset(; default_graph=make_social_graph(1_000))
        sparql_update!(ds, $update_age)
    end
end

# ── Run ────────────────────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    println("Warming up Julia JIT…")
    # One quick warm-up run so timings reflect steady state
    run(SUITE; verbose=false, seconds=1)

    println("\nRunning benchmarks (this may take a few minutes)…\n")
    results = run(SUITE; verbose=true, seconds=3)

    println("\n", "─"^80)
    println(rpad("Benchmark", 55), rpad("  Min time", 14), rpad("Allocs", 10), "Memory")
    println("─"^80)
    for (path, trial) in sort(collect(BenchmarkTools.leaves(results)); by=first)
        t = minimum(trial)
        @printf("%-55s  %10s  %6d  %s\n",
            join(path, "/"),
            BenchmarkTools.prettytime(t.time),
            t.allocs,
            BenchmarkTools.prettymemory(t.memory))
    end
    println("─"^80)
end
