```@meta
CurrentModule = RDF
```

# Querying

## Pattern matching

```@docs
match
subjects
predicates
objects
```

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

## SPARQL 1.1

SPARQL is the W3C standard query language for RDF. RDF.jl implements the full
SPARQL 1.1 query and update specification with 100% W3C test suite conformance
(657/657 tests passing).

```@docs
sparql
sparql_parse
sparql_update!
SolutionSet
```

### SELECT

Returns a `SolutionSet` — an ordered sequence of solution mappings from variable
names (`Symbol`) to `RDFTerm` values (or `nothing` for unbound variables).

```julia
result = sparql(ds, """
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  SELECT ?name ?age WHERE {
    ?person foaf:name ?name ;
            foaf:age  ?age .
    FILTER(?age > 26)
  } ORDER BY ?name
""")

for row in result
    println(row[:name], " is ", row[:age])
end

# With DataFrames
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

## SPARQL result format serialization

`SolutionSet` can be serialized to any of the four W3C standard result formats.

### SPARQL/JSON

```julia
io = IOBuffer()
write(io, MIME"application/sparql-results+json"(), result)   # SELECT
write(io, MIME"application/sparql-results+json"(), true)     # ASK
```

Output follows the [W3C SPARQL 1.1 JSON format](https://www.w3.org/TR/sparql11-results-json/).

### SPARQL/XML

```julia
write(io, MIME"application/sparql-results+xml"(), result)
write(io, MIME"application/sparql-results+xml"(), false)
```

Output follows the [W3C SPARQL 1.1 XML format](https://www.w3.org/TR/rdf-sparql-XMLres/).

### SPARQL/CSV

```julia
write(io, MIME"text/csv"(), result)
```

Fields containing commas or double-quotes are quoted per RFC 4180. Unbound
variables produce empty fields.

### SPARQL/TSV

```julia
write(io, MIME"text/tab-separated-values"(), result)
```

Header uses `?`-prefixed variable names; term values use N-Triples syntax
(`<iri>`, `_:bnode`, `"literal"^^<dt>`).

---

## Supported SPARQL 1.1 features

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
| SERVICE (federated queries) | ❌ not yet |
