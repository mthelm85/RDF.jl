using Test
using RDF

# Joining a triple pattern against solutions in which one of its variables is
# unbound (UNDEF in VALUES, or left unbound by OPTIONAL).  The variable acts as
# a wildcard, and every result must bind it to the matched term — SPARQL 1.1
# §18.5 Join: μ1 ∪ μ2 for compatible μ1, μ2.
#
# Regression: the columnar BGP join kept the existing (zero = unbound) column
# value instead of writing the matched term, so such rows came back with the
# variable unbound.

const _uj = Namespace("http://uj.example.org/")

function _uj_rows(r::SolutionSet, vars::Vector{Symbol})
    sort([Tuple(row[v] === nothing ? nothing : string(row[v]) for v in vars) for row in r];
         by = string)
end
_uj_exp(rows) = sort([Tuple(x === nothing ? nothing : string(x) for x in row) for row in rows];
                     by = string)

@testset "joins on variables unbound in some solutions" begin
    g = Graph()
    push!(g, Triple(_uj.a, _uj.p, Literal(1)))
    push!(g, Triple(_uj.b, _uj.p, Literal(2)))
    push!(g, Triple(_uj.a, _uj.r, _uj.b))
    one, two = Literal(1), Literal(2)
    pre = "PREFIX : <http://uj.example.org/>\n"
    vals = "VALUES (?i ?s) { (1 UNDEF) (2 :a) }"

    @testset "VALUES with UNDEF joined with a nested group" begin
        r = sparql(g, pre * "SELECT * WHERE { $vals { ?s :p ?o } }")
        @test _uj_rows(r, [:i, :s, :o]) ==
              _uj_exp([(one, _uj.a, one), (one, _uj.b, two), (two, _uj.a, one)])
    end

    @testset "VALUES with UNDEF joined in the same group" begin
        r = sparql(g, pre * "SELECT * WHERE { $vals ?s :p ?o }")
        @test _uj_rows(r, [:i, :s, :o]) ==
              _uj_exp([(one, _uj.a, one), (one, _uj.b, two), (two, _uj.a, one)])
    end

    @testset "OPTIONAL single triple over an unbound variable" begin
        r = sparql(g, pre * "SELECT * WHERE { $vals OPTIONAL { ?s :p ?o } }")
        @test _uj_rows(r, [:i, :s, :o]) ==
              _uj_exp([(one, _uj.a, one), (one, _uj.b, two), (two, _uj.a, one)])
    end

    @testset "OPTIONAL multi-triple BGP over an unbound variable" begin
        r = sparql(g, pre * "SELECT * WHERE { $vals OPTIONAL { ?s :p ?o . ?s :r ?t } }")
        @test _uj_rows(r, [:i, :s, :o, :t]) ==
              _uj_exp([(one, _uj.a, one, _uj.b), (two, _uj.a, one, _uj.b)])
    end

    @testset "variable left unbound by OPTIONAL, then joined" begin
        r = sparql(g, pre * "SELECT ?x ?s ?o WHERE { ?x :p ?v OPTIONAL { ?x :r ?s } { ?s :p ?o } }")
        @test _uj_rows(r, [:x, :s, :o]) ==
              _uj_exp([(_uj.a, _uj.b, two), (_uj.b, _uj.a, one), (_uj.b, _uj.b, two)])
    end
end
