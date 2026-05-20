struct Namespace
    base::String
end

Base.getproperty(ns::Namespace, name::Symbol) =
    IRI(getfield(ns, :base) * String(name))

Base.getindex(ns::Namespace, name::AbstractString) = IRI(getfield(ns, :base) * name)
Base.string(ns::Namespace) = getfield(ns, :base)
Base.show(io::IO, ns::Namespace) = print(io, "Namespace(", repr(getfield(ns, :base)), ")")
