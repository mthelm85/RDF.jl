"""
Before/after comparison for the three write-path optimizations introduced in
the performance sprint:

  1. Pre-computed N-Triples term string cache (_NT_TERM_STRINGS)
  2. Byte-span literal writer (avoid per-character print calls)
  3. Trusted IRI constructor + inline scheme validation in the parser

Run with:
    julia --project=bench bench/compare.jl
"""

using BenchmarkTools
using RDF
using Printf

# ── Re-implement the PRE-optimization write path inline ───────────────────────
# This mirrors exactly what Base.write(io, MIME"application/n-triples"(), g)
# did before the cache was added: iterate the Graph (which calls _resolve()
# and constructs a Triple per row) then dispatch through _write_triple_old.

function _write_iri_old(io, iri::RDF.IRI)
    print(io, '<', iri.value, '>')
end
function _write_blank_old(io, bn::RDF.BlankNode)
    print(io, "_:b", bn.id)
end
function _write_literal_old(io, lit::RDF.Literal)
    print(io, '"')
    for c in lit.lexical_form
        if     c == '"';   print(io, "\\\"")
        elseif c == '\\';  print(io, "\\\\")
        elseif c == '\n';  print(io, "\\n")
        elseif c == '\r';  print(io, "\\r")
        elseif c == '\t';  print(io, "\\t")
        else
            cp = UInt32(c)
            if cp <= 0x08 || cp == 0x0B || cp == 0x0C ||
               (0x0E <= cp <= 0x1F) || cp == 0x7F
                @printf(io, "\\u%04X", cp)
            elseif cp > 0xFFFF
                @printf(io, "\\U%08X", cp)
            else
                print(io, c)
            end
        end
    end
    print(io, '"')
    if !isempty(lit.language_tag)
        print(io, '@', lit.language_tag)
    else
        print(io, "^^<", lit.datatype.value, '>')
    end
end
function _write_subject_old(io, s)
    s isa RDF.IRI       ? _write_iri_old(io, s) :
    s isa RDF.BlankNode ? _write_blank_old(io, s) :
    error("unexpected subject type")
end
function _write_object_old(io, o)
    o isa RDF.IRI       ? _write_iri_old(io, o) :
    o isa RDF.BlankNode ? _write_blank_old(io, o) :
    o isa RDF.Literal   ? _write_literal_old(io, o) :
    error("unexpected object type")
end
function write_nt_old(io::IO, g::RDF.Graph)
    for t in g                         # _resolve() + Triple alloc per row
        _write_subject_old(io, t.subject)
        print(io, ' ')
        _write_iri_old(io, t.predicate)
        print(io, ' ')
        _write_object_old(io, t.object)
        println(io, " .")
    end
end

# ── Fixtures ──────────────────────────────────────────────────────────────────

const ex   = Namespace("http://example.org/")
const foaf = Namespace("http://xmlns.com/foaf/0.1/")

function make_graph(n::Int)
    triples = [
        if mod(i,3)==0; Triple(ex["p$i"], rdf.type,   ex.Person)
        elseif mod(i,3)==1; Triple(ex["p$i"], foaf.age,  Literal(i))
        else                Triple(ex["p$i"], foaf.name, Literal("Person $i"))
        end for i in 1:n
    ]
    bulk_load!(Graph(), triples)
end

# Build a graph that exercises the IRI parser: generate an .nt string and
# re-parse it.
function make_nt_bytes(n::Int)
    g = make_graph(n)
    buf = IOBuffer()
    write(buf, MIME"application/n-triples"(), g)
    take!(buf)
end

const G1K   = make_graph(1_000)
const G10K  = make_graph(10_000)
const G100K = make_graph(100_000)

const NT1K   = make_nt_bytes(1_000)
const NT10K  = make_nt_bytes(10_000)
const NT100K = make_nt_bytes(100_000)

# ── Benchmark suites ──────────────────────────────────────────────────────────

println("Tuning (may take a moment)…\n")

suite_old = BenchmarkGroup()
suite_new = BenchmarkGroup()

# Write benchmarks
for (label, g) in [("1k", G1K), ("10k", G10K), ("100k", G100K)]
    suite_old["write/$label"] = @benchmarkable begin
        buf = IOBuffer()
        write_nt_old(buf, $g)
    end
    suite_new["write/$label"] = @benchmarkable begin
        buf = IOBuffer()
        write(buf, MIME"application/n-triples"(), $g)
    end
end

# Read/parse benchmarks
for (label, nt) in [("1k", NT1K), ("10k", NT10K), ("100k", NT100K)]
    suite_old["read/$label"] = @benchmarkable read(IOBuffer($nt), MIME"application/n-triples"(), Graph)
    suite_new["read/$label"] = @benchmarkable read(IOBuffer($nt), MIME"application/n-triples"(), Graph)
end

tune!(suite_old)
tune!(suite_new)

r_old = run(suite_old; verbose=false)
r_new = run(suite_new; verbose=false)

# ── Pretty-print comparison table ─────────────────────────────────────────────

function fmt_time(ns::Float64)
    ns < 1_000     && return @sprintf("%6.1f ns", ns)
    ns < 1_000_000 && return @sprintf("%6.1f μs", ns / 1e3)
    ns < 1e9       && return @sprintf("%6.1f ms", ns / 1e6)
    return @sprintf("%6.3f s",  ns / 1e9)
end

fmt_allocs(n::Int) = n == 0 ? "     0" : @sprintf("%6d", n)
fmt_mem(b::Int)    = b < 1024 ? @sprintf("%5d B", b) :
                     b < 1024^2 ? @sprintf("%5.1f KB", b/1024) :
                     @sprintf("%5.1f MB", b/1024^2)

println("\n", "="^90)
println(@sprintf("  %-20s  %10s  %10s  %8s  %8s  %6s  %8s",
    "Benchmark", "OLD time", "NEW time", "Speedup", "Old allocs", "New allocs", "Mem saved"))
println("="^90)

all_keys = sort(collect(keys(r_old)))
for k in all_keys
    haskey(r_new, k) || continue
    to = median(r_old[k])
    tn = median(r_new[k])
    speedup  = to.time / tn.time
    mem_diff = to.memory - tn.memory
    println(@sprintf("  %-20s  %10s  %10s  %7.2fx  %8s  %8s  %8s",
        k,
        fmt_time(to.time),
        fmt_time(tn.time),
        speedup,
        fmt_allocs(to.allocs),
        fmt_allocs(tn.allocs),
        fmt_mem(mem_diff)))
end
println("="^90)
println()

# Summarise write-path improvement
write_keys = filter(k -> startswith(k, "write/"), all_keys)
if !isempty(write_keys)
    avg_speedup = mean(
        median(r_old[k]).time / median(r_new[k]).time for k in write_keys
    )
    avg_alloc_reduction = mean(
        1 - median(r_new[k]).allocs / max(median(r_old[k]).allocs, 1)
        for k in write_keys
    )
    @printf("  Write speedup (geometric mean): %.1fx\n", exp(mean(log(
        median(r_old[k]).time / median(r_new[k]).time) for k in write_keys)))
    @printf("  Write allocation reduction:     %.0f%%\n\n", avg_alloc_reduction * 100)
end
