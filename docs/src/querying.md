```@meta
CurrentModule = RDF
```

# Querying

## Pattern matching

[`match`](@ref), [`subjects`](@ref), [`predicates`](@ref), and [`objects`](@ref)
are documented in the [Graphs & Datasets](@ref) page.

`match` returns a lazy iterator of `Triple` (for a `Graph`) or `Quad` (for a
`Dataset`) values. Any combination of the `subject`, `predicate`, and `object`
keyword arguments can be provided; omitting one means "wildcard".

```julia
# All triples
for t in match(g)
    println(t)
end

# By predicate — finds all type assertions
for t in match(g; predicate=rdf.type)
    println(t.subject, " is a ", t.object)
end

# By subject — all properties of alice
for t in match(g; subject=ex.alice)
    println(t.predicate, " => ", t.object)
end

# By object — who has name "Alice"?
for t in match(g; predicate=foaf.name, object=Literal("Alice"))
    println(t.subject)
end
```

Match results implement the Tables.jl interface:

```julia
using DataFrames
df = DataFrame(match(g; predicate=rdf.type))
```

---

## SPARQL 1.1 and 1.2

SPARQL is the W3C standard query language for RDF. RDF.jl implements the full
SPARQL 1.1 query and update specification with 100% W3C test suite conformance
(657/657 tests passing), plus SPARQL 1.2 / RDF-star — triple terms
(`<<( s p o )>>`), reified triples (`<< s p o >>`), reifiers (`~`), annotation
blocks (`{| … |}`), the triple-term builtins (`TRIPLE`, `isTRIPLE`, `SUBJECT`,
`PREDICATE`, `OBJECT`), and directional language tags
(`LANGDIR`/`hasLANG`/`hasLANGDIR`/`STRLANGDIR`) — passing 263/263 of the
applicable W3C SPARQL 1.2 tests (the remainder require TriG input, which is
not yet supported).

```@docs
sparql
sparql_parse
SolutionSet
SolutionRow
read_sparql_json
```

### SELECT

Returns a `SolutionSet` — a columnar store of solution mappings from variable
names (`Symbol`) to `RDFTerm` values (`nothing` for unbound / OPTIONAL variables).

Iterating a `SolutionSet` yields [`SolutionRow`](@ref) views; individual rows
are accessible by integer index (`result[i]`).

```julia
result = sparql(ds, """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  SELECT ?name ?age WHERE {
    ?person foaf:name ?name ;
            foaf:age  ?age .
    FILTER(?age > 26)
  } ORDER BY ?name
""")

# Iterate rows
for row in result
    println(row[:name], " is ", row[:age])
end

# Integer indexing
first_row = result[1]
first_row[:name]              # => Literal("Alice")

# get() with a default (safe for OPTIONAL variables)
age = get(row, :age, nothing)

# Coerce literal values with value()
value(Int64, row[:age])       # => 30

# With DataFrames (unbound variables become `missing`)
using DataFrames
df = DataFrame(result)
```

### ASK

Returns a `Bool`.

```julia
sparql(ds, """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  ASK { ?s foaf:age 30 }
""")   # => true or false
```

### CONSTRUCT

Returns a new `Graph` built from the CONSTRUCT template.

```julia
g2 = sparql(ds, """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  CONSTRUCT { ?s foaf:name ?n } WHERE { ?s foaf:name ?n }
""")
```

### DESCRIBE

Returns a `Graph` describing the requested resources.

```julia
g_desc = sparql(ds, "DESCRIBE <http://example.org/alice>")
```

### Aggregates, subqueries, and property paths

```julia
# GROUP BY / COUNT
sparql(ds, """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  SELECT ?age (COUNT(?person) AS ?n) WHERE {
    ?person foaf:age ?age
  } GROUP BY ?age ORDER BY DESC(?n)
""")

# Property path: transitive foaf:knows closure
sparql(ds, """
  PREFIX ex:   <http://example.org/>
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  SELECT ?friend WHERE { ex:alice foaf:knows+ ?friend }
""")

# Subquery with LIMIT
sparql(ds, """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  SELECT ?name WHERE {
    { SELECT ?person WHERE { ?person a foaf:Person } LIMIT 5 }
    ?person foaf:name ?name
  }
""")
```

### SPARQL UPDATE

```@docs
sparql_update!
```

```julia
# INSERT DATA
sparql_update!(ds, """
  PREFIX ex:   <http://example.org/>
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  INSERT DATA { ex:carol foaf:name "Carol" ; foaf:age 28 }
""")

# DELETE / INSERT with WHERE
sparql_update!(ds, """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  DELETE { ?s foaf:age ?old }
  INSERT { ?s foaf:age ?new }
  WHERE  { ?s foaf:name "Alice" ; foaf:age ?old . BIND(?old + 1 AS ?new) }
""")

# CLEAR a named graph
sparql_update!(ds, "CLEAR GRAPH <http://example.org/g1>")
```

---

## Remote SPARQL endpoints

Load [HTTP.jl](https://github.com/JuliaWeb/HTTP.jl) alongside RDF.jl and the
same `sparql` function works against any remote SPARQL 1.1 endpoint — Wikidata,
UniProt, DBpedia, your own triplestore, or anything else that speaks the W3C
SPARQL Protocol.

```julia
using RDF, HTTP

# Query Wikidata for chemical elements
results = sparql("https://query.wikidata.org/sparql", """
  PREFIX wd:   <http://www.wikidata.org/entity/>
  PREFIX wdt:  <http://www.wikidata.org/prop/direct/>
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
  SELECT ?element ?name WHERE {
    ?element wdt:P31 wd:Q11344 ;
             rdfs:label ?name .
    FILTER(LANG(?name) = "en")
  } ORDER BY ?name LIMIT 20
""")

for row in results
    println(value(String, row[:name]))
end

# Into a DataFrame
using DataFrames
df = DataFrame(results)
```

The return types are identical to local queries:

| Query form  | Return type   |
|-------------|---------------|
| SELECT      | `SolutionSet` |
| ASK         | `Bool`        |
| CONSTRUCT   | `Graph`       |
| DESCRIBE    | `Graph`       |

### Keyword options

| Keyword         | Default    | Description |
|-----------------|------------|-------------|
| `timeout`       | `60`       | Read timeout in seconds |
| `auth`          | `nothing`  | `("user","pass")` for Basic auth; `"token"` for Bearer |
| `prefixes`      | `Dict()`   | Extra `PREFIX k => v` declarations prepended to the query |
| `default_graph` | `nothing`  | `default-graph-uri` SPARQL Protocol parameter |
| `named_graph`   | `nothing`  | `named-graph-uri` SPARQL Protocol parameter |
| `method`        | `:auto`    | `:get`, `:post`, or `:auto` (GET ≤ 2 kB, POST otherwise) |
| `retries`       | `2`        | Retry attempts on transient 5xx errors |

### Common endpoint URLs

| Dataset | Endpoint |
|---------|----------|
| Wikidata | `https://query.wikidata.org/sparql` |
| DBpedia | `https://dbpedia.org/sparql` |
| UniProt | `https://sparql.uniprot.org/sparql` |
| ChEMBL | `https://chembl.bio2rdf.org/sparql` |
| Linked Data for Life Sciences | `https://lod.openlinksw.com/sparql` |

### Extra prefix shortcuts

```julia
# Avoid repeating PREFIX declarations in every query
results = sparql("https://query.wikidata.org/sparql",
    "SELECT ?item WHERE { ?item wdt:P31 wd:Q11344 } LIMIT 10";
    prefixes = Dict(
        "wd"  => "http://www.wikidata.org/entity/",
        "wdt" => "http://www.wikidata.org/prop/direct/"))
```

### Authentication

```julia
# Basic auth
sparql("https://my-endpoint.example/sparql", query;
       auth = ("username", "password"))

# Bearer token
sparql("https://my-endpoint.example/sparql", query;
       auth = "eyJhbGci...")
```

### Federated queries — SERVICE

With HTTP.jl loaded, the standard SPARQL 1.1 `SERVICE` clause works inside
local queries: the inner pattern is sent to the remote endpoint and the
remote solutions are joined with the local ones on their shared variables.

```julia
using RDF, HTTP

# Join local data with Wikidata
result = sparql(local_graph, """
  PREFIX wdt: <http://www.wikidata.org/prop/direct/>
  PREFIX ex:  <http://example.org/>
  SELECT ?city ?population WHERE {
    ?city ex:officeLocation true .              # local
    SERVICE <https://query.wikidata.org/sparql> {
      ?city wdt:P1082 ?population               # remote
    }
  }
""")
```

`SERVICE SILENT` tolerates failures: if the endpoint is unreachable (or
HTTP.jl is not loaded), the outer solutions pass through unchanged with the
service variables left unbound. Without `SILENT`, failures raise an error —
never silently empty results.

### RemoteGraph — endpoint-backed graph view

```@docs
RemoteGraph
RemoteEndpointError
```

[`RemoteGraph`](@ref) wraps an endpoint in the familiar Graph API, translating
operations into SPARQL Protocol requests so the data never has to fit in local
memory:

```julia
using RDF, HTTP

wd = RemoteGraph("https://query.wikidata.org/sparql")

douglas_adams = IRI("http://www.wikidata.org/entity/Q42")
instance_of   = IRI("http://www.wikidata.org/prop/direct/P31")

match(wd; subject=douglas_adams, predicate=instance_of)  # SELECT under the hood
Triple(douglas_adams, instance_of, IRI("http://www.wikidata.org/entity/Q5")) in wd  # ASK
sparql(wd, "SELECT ?s WHERE { ?s ?p ?o } LIMIT 5")       # direct forwarding
```

`RemoteGraph` is read-only; supported operations are `match`, `length`,
`isempty`, `in`, iteration, and `sparql`. Keyword arguments given to the
constructor (`auth`, `headers`, `timeout`, …) are forwarded with every request.

---

## SPARQL result format serialization

`SolutionSet` can be serialized to any of the four W3C standard result formats.
Name one with a symbol — `:json` (`:srj`), `:xml` (`:srx`), `:csv`, `:tsv` — or
with the corresponding MIME value, which is what the symbol dispatches to.

Note that `:json` and `:xml` mean *SPARQL results* JSON and XML here, not
JSON-LD and RDF/XML; result formats and graph formats are separate namespaces
because they never appear at the same call site.

### SPARQL/JSON

```julia
io = IOBuffer()
write(io, :json, result)                                     # SELECT
write(io, MIME"application/sparql-results+json"(), result)   # equivalently

# ASK results are a plain `Bool`, which the symbol form does not cover — a
# `write(io, ::Symbol, ::Bool)` method would be type piracy over Base.
write(io, MIME"application/sparql-results+json"(), true)     # ASK
```

Output follows the [W3C SPARQL 1.1 JSON format](https://www.w3.org/TR/sparql11-results-json/).

### SPARQL/XML

```julia
write(io, :xml, result)
write(io, MIME"application/sparql-results+xml"(), false)     # ASK
```

Output follows the [W3C SPARQL 1.1 XML format](https://www.w3.org/TR/rdf-sparql-XMLres/).

### SPARQL/CSV

```julia
write(io, :csv, result)
```

Fields containing commas or double-quotes are quoted per RFC 4180. Unbound
variables produce empty fields.

### SPARQL/TSV

```julia
write(io, :tsv, result)
```

Header uses `?`-prefixed variable names; term values use N-Triples syntax
(`<iri>`, `_:bnode`, `"literal"^^<dt>`).

---

## Supported SPARQL 1.1 / 1.2 features

| Feature | Supported |
|---|---|
| SELECT, CONSTRUCT, ASK, DESCRIBE | ✅ |
| OPTIONAL, UNION, MINUS | ✅ |
| FILTER (all functions and operators) | ✅ |
| BIND, VALUES | ✅ |
| GROUP BY, HAVING, aggregates | ✅ |
| ORDER BY, LIMIT, OFFSET, DISTINCT, REDUCED | ✅ |
| Subqueries | ✅ |
| Property paths (`/`, `|`, `*`, `+`, `?`, `^`, `!`) | ✅ |
| EXISTS / NOT EXISTS | ✅ |
| GRAPH, FROM, FROM NAMED | ✅ |
| INSERT DATA, DELETE DATA | ✅ |
| INSERT/DELETE with WHERE | ✅ |
| LOAD, CLEAR, DROP, COPY, MOVE, ADD | ✅ |
| Built-in functions (str, lang, datatype, isIRI, isLiteral, …) | ✅ |
| Numeric, string, date/time functions | ✅ |
| Hash functions (MD5, SHA1, SHA256, SHA384, SHA512) | ✅ |
| SERVICE / SERVICE SILENT (federated queries) | ✅ requires HTTP.jl |
| **SPARQL 1.2**: triple terms `<<( s p o )>>` (patterns, VALUES, expressions) | ✅ |
| **SPARQL 1.2**: reified triples `<< s p o >>`, reifiers `~`, annotation blocks `{\| … \|}` | ✅ |
| **SPARQL 1.2**: `TRIPLE`, `isTRIPLE`, `SUBJECT`, `PREDICATE`, `OBJECT` | ✅ |
| **SPARQL 1.2**: directional language tags, `LANGDIR`, `hasLANG`, `hasLANGDIR`, `STRLANGDIR` | ✅ |
| **SPARQL 1.2**: `VERSION` declaration | ✅ |

## Query optimization

The SPARQL engine reorders the triple patterns inside each basic graph pattern
before evaluation, so the order you write patterns in does not affect
performance (or results). The optimizer uses **exact** cardinalities — the
hexastore answers "how many triples match this pattern?" in O(log n) with two
binary searches — and greedily evaluates the most selective pattern first,
preferring patterns that share a variable with the already-bound set so that
Cartesian products are avoided. No statistics, configuration, or query hints
are needed.
