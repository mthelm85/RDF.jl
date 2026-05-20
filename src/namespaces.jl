"""
    Namespace(base::String)

A namespace prefix for constructing `IRI`s using dot notation or bracket indexing.

```julia
ex  = Namespace("http://example.org/")
ex.Alice          # => IRI("http://example.org/Alice")
ex["first-name"]  # => IRI("http://example.org/first-name")
```
"""
struct Namespace
    base::String
end

Base.getproperty(ns::Namespace, name::Symbol) =
    IRI(getfield(ns, :base) * String(name))

Base.getindex(ns::Namespace, name::AbstractString) = IRI(getfield(ns, :base) * name)
Base.string(ns::Namespace) = getfield(ns, :base)
Base.show(io::IO, ns::Namespace) = print(io, "Namespace(", repr(getfield(ns, :base)), ")")
