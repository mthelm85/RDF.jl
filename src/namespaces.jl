struct Namespace
    base::String
end

Base.getproperty(ns::Namespace, name::Symbol) =
    name === :base ? getfield(ns, :base) : IRI(getfield(ns, :base) * String(name))

Base.getindex(ns::Namespace, name::AbstractString) = IRI(ns.base * name)
Base.string(ns::Namespace) = ns.base
Base.show(io::IO, ns::Namespace) = print(io, "Namespace(", repr(ns.base), ")")
