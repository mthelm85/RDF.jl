abstract type RDFError <: Exception end

struct IRIError <: RDFError
    value::String
    reason::String
end

struct ParseError <: RDFError
    message::String
    line::Int
    column::Int
    format::MIME
end

struct LiteralValueError <: RDFError
    literal  # Literal — forward-declared
    target_type::Type
end

struct BlankNodeScopeError <: RDFError
    node  # BlankNode — forward-declared
    message::String
end

"""
    RemoteEndpointError <: RDFError

A remote SPARQL endpoint operation failed: the HTTP transport is unavailable,
the endpoint returned an error status or an unparseable response, or a
federated `SERVICE` clause could not be evaluated.  `endpoint` is the endpoint
URL (or a placeholder such as `"(variable)"` when no concrete URL exists).
"""
struct RemoteEndpointError <: RDFError
    endpoint::String
    message::String
end

Base.showerror(io::IO, e::IRIError) =
    print(io, "IRIError: ", e.reason, " (value: ", repr(e.value), ")")

Base.showerror(io::IO, e::ParseError) =
    print(io, "ParseError (", e.format, ") at line ", e.line, ", col ", e.column, ": ", e.message)

Base.showerror(io::IO, e::LiteralValueError) =
    print(io, "LiteralValueError: cannot convert ", e.literal, " to ", e.target_type)

Base.showerror(io::IO, e::BlankNodeScopeError) =
    print(io, "BlankNodeScopeError: ", e.message)

function Base.showerror(io::IO, e::RemoteEndpointError)
    print(io, "RemoteEndpointError")
    isempty(e.endpoint) || print(io, " (", e.endpoint, ")")
    print(io, ": ", e.message)
end
