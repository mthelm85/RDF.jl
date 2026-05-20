Base.string(iri::IRI) = iri.value

function Base.show(io::IO, iri::IRI)
    print(io, '<', iri.value, '>')
end

function Base.show(io::IO, bn::BlankNode)
    print(io, "_:b", bn.id)
end

function Base.show(io::IO, lit::Literal)
    print(io, '"')
    _escape_string(io, lit.lexical_form)
    print(io, '"')
    if !isempty(lit.language_tag)
        print(io, '@', lit.language_tag)
    elseif lit.datatype != _XSD_STRING
        print(io, "^^<", lit.datatype.value, '>')
    end
end

function _escape_string(io::IO, s::String)
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        else
            print(io, c)
        end
    end
end

function Base.show(io::IO, t::Triple)
    show(io, t.subject)
    print(io, ' ')
    show(io, t.predicate)
    print(io, ' ')
    show(io, t.object)
    print(io, " .")
end

function Base.show(io::IO, q::Quad)
    show(io, q.subject)
    print(io, ' ')
    show(io, q.predicate)
    print(io, ' ')
    show(io, q.object)
    if q.graph !== nothing
        print(io, ' ')
        show(io, q.graph)
    end
    print(io, " .")
end

function Base.show(io::IO, g::Graph)
    print(io, "RDF.Graph with ", g._size, " triple", g._size == 1 ? "" : "s")
end

function Base.show(io::IO, ::MIME"text/plain", g::Graph)
    show(io, g)
end

function Base.show(io::IO, ds::Dataset)
    ng = length(ds.named_graphs)
    total = ntriples(ds)
    print(io, "RDF.Dataset with ", total, " triple", total == 1 ? "" : "s",
              " (", ng, " named graph", ng == 1 ? "" : "s", ")")
end

function Base.show(io::IO, p::TriplePattern)
    _show_pat_term(io, p.subject)
    print(io, ' ')
    _show_pat_term(io, p.predicate)
    print(io, ' ')
    _show_pat_term(io, p.object)
end

_show_pat_term(io, ::Nothing) = print(io, "?")
_show_pat_term(io, t) = show(io, t)
