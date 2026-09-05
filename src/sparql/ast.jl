# ── SPARQL 1.1 Abstract Syntax Tree ──────────────────────────────────────────
#
# Julia types representing a parsed SPARQL 1.1 query or update request.
# No file-level module declaration; this file is included into the RDF module.
#
# Naming conventions
# ──────────────────
#   SpExpr   — expression nodes (values, operators, function calls)
#   SpPat    — graph-pattern nodes (BGP, Filter, Optional, …)
#   SpPath   — property-path nodes
#   Sp*Query — top-level query forms
#   SpUpdate*— update operation types

# ── Abstract roots ────────────────────────────────────────────────────────────

abstract type SpExpr end   # any SPARQL expression
abstract type SpPat  end   # any graph-pattern element
abstract type SpPath end   # any property-path element

# ── RDF Term nodes ────────────────────────────────────────────────────────────

"""A SPARQL variable ?name or \$name."""
struct SpVar <: SpExpr
    name::Symbol          # without the leading ? / $
end

"""An IRI, already resolved to its absolute string value."""
struct SpIRI <: SpExpr
    value::String         # absolute IRI string
end

"""A blank node with label `_:label`."""
struct SpBNode <: SpExpr
    label::String
end

"""An anonymous blank node `[]`.  Each instance has a unique id so that
the evaluator can distinguish different anonymous nodes in a CONSTRUCT template."""
struct SpAnonBNode <: SpExpr
    id::UInt64
end

"""An embedded triple term `<<( subject predicate object )>>` used as subject or
object in an RDF-star triple pattern.  Each inner field is itself an `SpExpr`
(typically `SpVar`, `SpIRI`, or `SpLiteral`); nested `SpTripleTerm` values are
allowed for deeply nested annotations."""
struct SpTripleTerm <: SpExpr
    subject::SpExpr
    predicate::SpExpr   # must resolve to an IRI at evaluation time
    object::SpExpr
end

# Global counter for SpAnonBNode IDs (separate from RDF blank-node counter)
const _SP_ANON_COUNTER = Threads.Atomic{UInt64}(0)
SpAnonBNode() = SpAnonBNode(Threads.atomic_add!(_SP_ANON_COUNTER, UInt64(1)))

"""An RDF literal."""
struct SpLiteral <: SpExpr
    lexical::String
    datatype::String      # absolute IRI string (xsd:string if no explicit type)
    lang::String          # "" unless language-tagged; lowercase
end

"""A pre-evaluated constant RDFTerm — produced by the constant-folding pass in
_bt_apply_filter so that literals and IRIs are not re-constructed on every row."""
struct SpConst <: SpExpr
    term::RDFTerm
end

# ── Expression operators ──────────────────────────────────────────────────────

"""Unary expression: `!e`, `-e`, `+e`."""
struct SpUnary <: SpExpr
    op::Symbol            # :not, :neg, :pos  (i.e. !, -, +)
    arg::SpExpr
end

"""Binary expression: arithmetic, comparison, logical."""
struct SpBinary <: SpExpr
    op::Symbol            # :add, :sub, :mul, :div, :eq, :neq, :lt, :le, :gt, :ge, :and, :or
    left::SpExpr
    right::SpExpr
end

"""Function / built-in call."""
struct SpCall <: SpExpr
    func::String          # absolute IRI or lowercase built-in keyword
    args::Vector{SpExpr}
end

"""Aggregate function."""
struct SpAggregate <: SpExpr
    func::Symbol          # :count, :sum, :avg, :min, :max, :group_concat, :sample
    distinct::Bool
    arg::Union{SpExpr, Nothing}     # nothing means COUNT(*)
    separator::Union{String, Nothing}  # for GROUP_CONCAT only
end

"""EXISTS { pattern }."""
struct SpExists <: SpExpr
    pattern::SpPat
end

"""NOT EXISTS { pattern }."""
struct SpNotExists <: SpExpr
    pattern::SpPat
end

"""expr IN (list) or expr NOT IN (list)."""
struct SpIn <: SpExpr
    expr::SpExpr
    list::Vector{SpExpr}
    negated::Bool
end

"""IF(cond, then, else)."""
struct SpIf <: SpExpr
    cond::SpExpr
    then_::SpExpr
    else_::SpExpr
end

"""COALESCE(e1, e2, …)."""
struct SpCoalesce <: SpExpr
    args::Vector{SpExpr}
end

# ── Property paths ────────────────────────────────────────────────────────────

struct SpPathIRI <: SpPath
    value::String         # absolute IRI
end

struct SpPathA <: SpPath end   # rdf:type shorthand

struct SpPathSeq <: SpPath
    left::SpPath
    right::SpPath
end

struct SpPathAlt <: SpPath
    left::SpPath
    right::SpPath
end

struct SpPathInverse <: SpPath
    child::SpPath
end

struct SpPathZeroOrMore <: SpPath
    child::SpPath
end

struct SpPathOneOrMore <: SpPath
    child::SpPath
end

struct SpPathZeroOrOne <: SpPath
    child::SpPath
end

struct SpPathRange <: SpPath
    child::SpPath
    min_::Int
    max_::Union{Int, Nothing}   # nothing = unbounded
end

"""Negated property set: !(iri | iri …)"""
struct SpPathNeg <: SpPath
    elements::Vector{SpPath}    # SpPathIRI, SpPathA, or SpPathInverse of those
end

# ── Triple pattern ────────────────────────────────────────────────────────────

"""A single triple pattern (subject, predicate/path, object)."""
struct SpTriple
    subject::SpExpr
    predicate::Union{SpExpr, SpPath}
    object::SpExpr
end

# ── Graph patterns ────────────────────────────────────────────────────────────

"""Basic Graph Pattern: a list of triple patterns."""
struct SpBGP <: SpPat
    triples::Vector{SpTriple}
end

SpBGP() = SpBGP(SpTriple[])

"""A sequence of graph-pattern elements (the body of { })."""
struct SpGroup <: SpPat
    elements::Vector{SpPat}
end

SpGroup() = SpGroup(SpPat[])

"""FILTER(expr)."""
struct SpFilter <: SpPat
    expr::SpExpr
end

"""OPTIONAL { pattern }."""
struct SpOptional <: SpPat
    pattern::SpPat
end

"""{ P } UNION { Q }."""
struct SpUnion <: SpPat
    left::SpPat
    right::SpPat
end

"""MINUS { pattern }."""
struct SpMinus <: SpPat
    pattern::SpPat
end

"""GRAPH iri-or-var { pattern }."""
struct SpGraph <: SpPat
    name::SpExpr          # SpIRI or SpVar
    pattern::SpPat
end

"""SERVICE [SILENT] iri-or-var { pattern }."""
struct SpService <: SpPat
    silent::Bool
    endpoint::SpExpr
    pattern::SpPat
end

"""BIND(expr AS ?var)."""
struct SpBind <: SpPat
    expr::SpExpr
    var::SpVar
end

"""Inline VALUES: VALUES ?x { v1 v2 } or VALUES (?x ?y) { (v1 v2) }."""
struct SpValues <: SpPat
    vars::Vector{SpVar}
    rows::Vector{Vector{Union{SpExpr, Nothing}}}   # nothing = UNDEF
end

"""A SELECT sub-query embedded in a group graph pattern."""
struct SpSubQuery <: SpPat
    query::Any   # SpSelectQuery — use Any to avoid forward-reference issues
end

# ── Solution modifiers ────────────────────────────────────────────────────────

struct SpOrderCond
    ascending::Bool
    expr::SpExpr
end

struct SpGroupCond
    expr::SpExpr
    var::Union{SpVar, Nothing}   # for (expr AS ?var) form
end

# ── Dataset clause ────────────────────────────────────────────────────────────

struct SpDatasetClause
    named::Bool
    iri::String
end

# ── SELECT result columns ─────────────────────────────────────────────────────

"""One SELECT column: `?x` or `(expr AS ?var)`."""
struct SpSelectColumn
    expr::SpExpr
    as_var::Union{SpVar, Nothing}
end

# ── Prologue elements ─────────────────────────────────────────────────────────

struct SpPrefixDecl
    prefix::String          # "" for the default (bare colon) prefix
    iri::String
end

# ── Query forms ───────────────────────────────────────────────────────────────

struct SpSelectQuery
    distinct::Bool
    reduced::Bool
    star::Bool
    columns::Vector{SpSelectColumn}
    datasets::Vector{SpDatasetClause}
    pattern::SpPat
    group_by::Vector{SpGroupCond}
    having::Vector{SpExpr}
    order_by::Vector{SpOrderCond}
    limit::Union{Int, Nothing}
    offset::Union{Int, Nothing}
    values::Union{SpValues, Nothing}
end

struct SpConstructQuery
    template::Union{Vector{SpTriple}, Nothing}   # nothing = CONSTRUCT WHERE short form
    datasets::Vector{SpDatasetClause}
    pattern::SpPat
    group_by::Vector{SpGroupCond}
    having::Vector{SpExpr}
    order_by::Vector{SpOrderCond}
    limit::Union{Int, Nothing}
    offset::Union{Int, Nothing}
    values::Union{SpValues, Nothing}
end

struct SpAskQuery
    datasets::Vector{SpDatasetClause}
    pattern::SpPat
    values::Union{SpValues, Nothing}
end

struct SpDescribeQuery
    resources::Vector{SpExpr}
    star::Bool
    datasets::Vector{SpDatasetClause}
    pattern::Union{SpPat, Nothing}
    group_by::Vector{SpGroupCond}
    having::Vector{SpExpr}
    order_by::Vector{SpOrderCond}
    limit::Union{Int, Nothing}
    offset::Union{Int, Nothing}
    values::Union{SpValues, Nothing}
end

const SpQueryForm = Union{SpSelectQuery, SpConstructQuery, SpAskQuery, SpDescribeQuery}

"""Top-level parsed query."""
struct SpQueryUnit
    base::Union{String, Nothing}
    prefixes::Vector{SpPrefixDecl}
    query::SpQueryForm
end

# ── UPDATE operations ─────────────────────────────────────────────────────────

abstract type SpUpdateOp end

# Graph reference used in management operations
abstract type SpGraphRef end
struct SpGraphRefDefault <: SpGraphRef end
struct SpGraphRefNamed   <: SpGraphRef end
struct SpGraphRefAll     <: SpGraphRef end
struct SpGraphRefIRI     <: SpGraphRef; iri::String end

# Quads (for data operations): each entry is (graph_iri_or_nothing, triples)
# where nothing = default graph.
# The graph of a quad block: an IRI, a variable (SPARQL 1.1
# `QuadsNotTriples ::= 'GRAPH' VarOrIri '{' TriplesTemplate? '}'`), or nothing
# for the default graph. A variable is resolved per solution when the template
# is instantiated.
const SpQuadBlock = Vector{Pair{Union{String, SpVar, Nothing}, Vector{SpTriple}}}

struct SpInsertData <: SpUpdateOp
    quads::SpQuadBlock
end

struct SpDeleteData <: SpUpdateOp
    quads::SpQuadBlock
end

struct SpDeleteWhere <: SpUpdateOp
    pattern::SpPat
end

"""
INSERT / DELETE … USING … WHERE …
(WITH iri)?
(DELETE { template })?
(INSERT { template })?
(USING dataset)*
WHERE { pattern }
"""
struct SpModify <: SpUpdateOp
    with_iri::Union{String, Nothing}
    delete_quads::SpQuadBlock
    insert_quads::SpQuadBlock
    using_::Vector{SpDatasetClause}
    pattern::SpPat
end

struct SpLoad <: SpUpdateOp
    silent::Bool
    source::String
    into_graph::Union{String, Nothing}
end

struct SpClear <: SpUpdateOp
    silent::Bool
    target::SpGraphRef
end

struct SpDrop <: SpUpdateOp
    silent::Bool
    target::SpGraphRef
end

struct SpCreate <: SpUpdateOp
    silent::Bool
    iri::String
end

struct SpAdd <: SpUpdateOp
    silent::Bool
    src::SpGraphRef
    dst::SpGraphRef
end

struct SpMove <: SpUpdateOp
    silent::Bool
    src::SpGraphRef
    dst::SpGraphRef
end

struct SpCopy <: SpUpdateOp
    silent::Bool
    src::SpGraphRef
    dst::SpGraphRef
end

"""Top-level parsed update."""
struct SpUpdateUnit
    base::Union{String, Nothing}
    prefixes::Vector{SpPrefixDecl}
    ops::Vector{SpUpdateOp}
end

const SpUnit = Union{SpQueryUnit, SpUpdateUnit}
