"""
RDF.jl performance benchmarks.

Run with:
    julia --project=bench bench/benchmarks.jl

Or for a single suite:
    julia --project=bench -e 'include("bench/benchmarks.jl"); run(SUITE["write/ntriples"], verbose=true)'
"""

using BenchmarkTools
using RDF

# ── Shared fixtures ────────────────────────────────────────────────────────────

const ex   = Namespace("http://example.org/")
const foaf = Namespace("http://xmlns.com/foaf/0.1/")
const xsd_ns = Namespace("http://www.w3.org/2001/XMLSchema#")

# Build a graph with N triples covering the common term shapes:
#   - IRI subject, IRI predicate, IRI object
#   - IRI subject, IRI predicate, xsd:integer literal
#   - IRI subject, IRI predicate, xsd:string literal
function make_graph(n::Int)::Graph
    g = Graph()
    triples = Vector{Triple}(undef, n)
    for i in 1:n
        kind = mod(i, 3)
        subj = ex["person_$i"]
        if kind == 0
            triples[i] = Triple(subj, rdf.type, ex.Person)
        elseif kind == 1
            triples[i] = Triple(subj, foaf.age, Literal(i))
        else
            triples[i] = Triple(subj, foaf.name, Literal("Person $i"))
        end
    end
    bulk_load!(g, triples)
    g
end

const G_10K  = make_graph(10_000)
const G_100K = make_graph(100_000)

# Build a raw N-Triples string for parse benchmarks
function make_nt_string(n::Int)::String
    buf = IOBuffer(sizehint = n * 80)
    g = make_graph(n)
    write(buf, MIME"application/n-triples"(), g)
    String(take!(buf))
end

const NT_10K  = make_nt_string(10_000)
const NT_100K = make_nt_string(100_000)

# ── Suite ──────────────────────────────────────────────────────────────────────

const SUITE = BenchmarkGroup()

# ── Graph construction (push! / bulk_load!) ────────────────────────────────────

SUITE["build"] = BenchmarkGroup(["construction"])

SUITE["build"]["push!/1k"] = @benchmarkable begin
    g = Graph()
    for i in 1:1000
        push!(g, Triple(ex["s$i"], rdf.type, ex.Thing))
    end
end

SUITE["build"]["push!/10k"] = @benchmarkable begin
    g = Graph()
    for i in 1:10_000
        push!(g, Triple(ex["s$i"], rdf.type, ex.Thing))
    end
end

SUITE["build"]["bulk_load!/10k"] = @benchmarkable begin
    ts = [Triple(ex["s$i"], rdf.type, ex.Thing) for i in 1:10_000]
    bulk_load!(Graph(), ts)
end

SUITE["build"]["bulk_load!/100k"] = @benchmarkable begin
    ts = [Triple(ex["s$i"], rdf.type, ex.Thing) for i in 1:100_000]
    bulk_load!(Graph(), ts)
end

# ── IRI construction ───────────────────────────────────────────────────────────

SUITE["terms"] = BenchmarkGroup(["terms"])

SUITE["terms"]["IRI/construct"] = @benchmarkable IRI("http://example.org/alice")

SUITE["terms"]["Literal/string"] = @benchmarkable Literal("hello world")

SUITE["terms"]["Literal/integer"] = @benchmarkable Literal(42)

SUITE["terms"]["intern!/iri"] = @benchmarkable RDF._intern!(IRI("http://example.org/bench_subject"))

# ── Pattern matching ───────────────────────────────────────────────────────────

SUITE["match"] = BenchmarkGroup(["query"])

SUITE["match"]["all/10k"]       = @benchmarkable collect($(G_10K))
SUITE["match"]["all/100k"]      = @benchmarkable collect($(G_100K))

SUITE["match"]["by_pred/10k"]   = @benchmarkable collect(match($(G_10K);  predicate=rdf.type))
SUITE["match"]["by_pred/100k"]  = @benchmarkable collect(match($(G_100K); predicate=rdf.type))

SUITE["match"]["by_subj/10k"]   = @benchmarkable collect(match($(G_10K);  subject=ex.person_1))
SUITE["match"]["by_subj/100k"]  = @benchmarkable collect(match($(G_100K); subject=ex.person_1))

# ── N-Triples write ────────────────────────────────────────────────────────────

SUITE["write"] = BenchmarkGroup(["serialization"])

SUITE["write"]["ntriples/10k"]  = @benchmarkable begin
    buf = IOBuffer(sizehint = 800_000)
    write(buf, MIME"application/n-triples"(), $(G_10K))
end

SUITE["write"]["ntriples/100k"] = @benchmarkable begin
    buf = IOBuffer(sizehint = 8_000_000)
    write(buf, MIME"application/n-triples"(), $(G_100K))
end

# ── N-Triples read ─────────────────────────────────────────────────────────────

SUITE["read"] = BenchmarkGroup(["parsing"])

SUITE["read"]["ntriples/10k"]  = @benchmarkable begin
    io = IOBuffer($(NT_10K))
    read(io, MIME"application/n-triples"(), Graph)
end

SUITE["read"]["ntriples/100k"] = @benchmarkable begin
    io = IOBuffer($(NT_100K))
    read(io, MIME"application/n-triples"(), Graph)
end

# ── N-Quads write ──────────────────────────────────────────────────────────────

function make_dataset(n::Int)::Dataset
    ds = Dataset()
    g1 = IRI("http://example.org/graph1")
    g2 = IRI("http://example.org/graph2")
    for i in 1:n
        name = i % 2 == 0 ? g1 : g2
        if !haskey(ds, name); ds[name] = Graph(); end
        t = if mod(i,3)==0;   Triple(ex["person_$i"], rdf.type,   ex.Person)
            elseif mod(i,3)==1; Triple(ex["person_$i"], foaf.age,  Literal(i))
            else                Triple(ex["person_$i"], foaf.name, Literal("Person $i"))
            end
        push!(ds[name], t)
    end
    ds
end

const DS_10K  = make_dataset(10_000)
const DS_100K = make_dataset(100_000)

SUITE["write"]["nquads/10k"]  = @benchmarkable begin
    buf = IOBuffer(sizehint = 900_000)
    write(buf, MIME"application/n-quads"(), $(DS_10K))
end

SUITE["write"]["nquads/100k"] = @benchmarkable begin
    buf = IOBuffer(sizehint = 9_000_000)
    write(buf, MIME"application/n-quads"(), $(DS_100K))
end

# ── N-Quads read ───────────────────────────────────────────────────────────────

function make_nq_string(n::Int)::String
    ds  = make_dataset(n)
    buf = IOBuffer(sizehint = n * 100)
    write(buf, MIME"application/n-quads"(), ds)
    String(take!(buf))
end

const NQ_10K  = make_nq_string(10_000)
const NQ_100K = make_nq_string(100_000)

SUITE["read"]["nquads/10k"]  = @benchmarkable begin
    io = IOBuffer($(NQ_10K))
    read(io, MIME"application/n-quads"(), Dataset)
end

SUITE["read"]["nquads/100k"] = @benchmarkable begin
    io = IOBuffer($(NQ_100K))
    read(io, MIME"application/n-quads"(), Dataset)
end

# ── Turtle write ───────────────────────────────────────────────────────────────

SUITE["write"]["turtle/10k"]  = @benchmarkable begin
    buf = IOBuffer(sizehint = 800_000)
    write(buf, MIME"text/turtle"(), $(G_10K))
end

SUITE["write"]["turtle/100k"] = @benchmarkable begin
    buf = IOBuffer(sizehint = 8_000_000)
    write(buf, MIME"text/turtle"(), $(G_100K))
end

# ── eachid zero-alloc iteration ────────────────────────────────────────────────

SUITE["match"]["eachid/100k"] = @benchmarkable begin
    n = 0
    for _ in eachid($(G_100K))
        n += 1
    end
    n
end

# ── Run if invoked directly ────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    println("Tuning benchmarks (this may take a minute)…")
    tune!(SUITE)

    println("\nRunning benchmarks…\n")
    results = run(SUITE; verbose=true)

    println("\n=== Results ===\n")
    for (group_name, group) in sort(collect(results), by=first)
        println("[$group_name]")
        for (name, trial) in sort(collect(group), by=first)
            t = median(trial)
            alloc_str = t.allocs > 0 ? ", $(t.allocs) allocs ($(Base.format_bytes(t.memory)))" : ", 0 allocs"
            println("  $(rpad(name, 24))  $(BenchmarkTools.prettytime(t.time))$alloc_str")
        end
        println()
    end
end
