using BenchmarkTools
using RDF

const SUITE = BenchmarkGroup()

# ── Helpers ───────────────────────────────────────────────────────────────────

function make_triples(n::Int)
    ex = Namespace("http://example.org/")
    [Triple(ex["s$i"], ex["p$(i % 100)"], ex["o$i"]) for i in 1:n]
end

function make_graph(n::Int)
    g = Graph()
    for t in make_triples(n); push!(g, t); end
    g
end

# ── Triple insertion throughput ───────────────────────────────────────────────

SUITE["insertion"] = BenchmarkGroup()
for n in (1_000, 10_000, 100_000)
    ts = make_triples(n)
    SUITE["insertion"]["n=$n"] = @benchmarkable begin
        g = Graph()
        for t in $ts; push!(g, t); end
    end
end

# ── Pattern matching — all 7 binding patterns (S__, _P_, __O, SP_, S_O, _PO, SPO)

SUITE["match"] = BenchmarkGroup()
let
    ex = Namespace("http://example.org/")
    g  = make_graph(10_000)

    # pick a term that exists
    s0 = ex["s1"]
    p0 = ex["p1"]
    o0 = ex["o1"]

    SUITE["match"]["S__"] = @benchmarkable collect(match($g; subject=$s0))
    SUITE["match"]["_P_"] = @benchmarkable collect(match($g; predicate=$p0))
    SUITE["match"]["__O"] = @benchmarkable collect(match($g; object=$o0))
    SUITE["match"]["SP_"] = @benchmarkable collect(match($g; subject=$s0, predicate=$p0))
    SUITE["match"]["S_O"] = @benchmarkable collect(match($g; subject=$s0, object=$o0))
    SUITE["match"]["_PO"] = @benchmarkable collect(match($g; predicate=$p0, object=$o0))
    SUITE["match"]["SPO"] = @benchmarkable collect(match($g; subject=$s0, predicate=$p0, object=$o0))
    SUITE["match"]["___"] = @benchmarkable collect(match($g))
end

# ── Graph union with blank node renaming ──────────────────────────────────────

SUITE["union"] = BenchmarkGroup()
let
    g1 = Graph()
    g2 = Graph()
    for i in 1:1_000
        b1 = blank!(g1); b2 = blank!(g2)
        ex = Namespace("http://example.org/")
        push!(g1, Triple(b1, ex["p"], ex["o$i"]))
        push!(g2, Triple(b2, ex["p"], ex["o$i"]))
    end
    SUITE["union"]["blank_rename_1k"] = @benchmarkable union($g1, $g2)
end

# ── N-Triples round-trip ──────────────────────────────────────────────────────

SUITE["ntriples"] = BenchmarkGroup()
let
    g = make_graph(10_000)
    buf = IOBuffer()
    write(buf, MIME"application/n-triples"(), g)
    nt_bytes = take!(buf)

    SUITE["ntriples"]["write_10k"] = @benchmarkable begin
        b = IOBuffer()
        write(b, MIME"application/n-triples"(), $g)
    end
    SUITE["ntriples"]["read_10k"] = @benchmarkable begin
        read(IOBuffer($nt_bytes), MIME"application/n-triples"(), Graph)
    end
end

# ── Run when executed directly ────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    results = run(SUITE; verbose=true)
    display(results)
end
