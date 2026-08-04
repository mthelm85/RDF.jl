"""
RDFXMLExt — RDF/XML 1.1 parser for RDF.jl
===========================================

Activated automatically when both RDF and EzXML are loaded:

    using RDF, EzXML

Implements the W3C "RDF 1.1 XML Syntax" recommendation (§7, the productions
of the RDF/XML grammar) on top of EzXML's DOM.  Provides:

  - `Base.read(io, MIME"application/rdf+xml"(), Graph)`
  - `Base.read(io, MIME"application/rdf+xml"(), Graph, base)`
  - `RDF.parse_triples(f, io, MIME"application/rdf+xml"())`

Design notes
------------
RDF/XML requires a full DOM (element nesting drives grammar productions,
`xml:lang`/`xml:base` inherit down the tree, `rdf:parseType="Literal"` needs
the raw child markup, etc.) so — unlike the streaming N-Triples parser — this
implementation always builds the whole document with `EzXML.parsexml` first.
`parse_triples` is therefore "streaming" only at the API level: it parses the
full graph, then invokes the callback once per triple.

Term identity (predicates, node types, `rdf:li`) is resolved by comparing
each element/attribute's **namespace URI**, not by assuming a literal `rdf:`
prefix — a document is free to bind the RDF namespace to any prefix.
"""
module RDFXMLExt

using RDF
using EzXML

# ── Namespace constants ──────────────────────────────────────────────────────

const _RDF_NS   = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
const _XML_NS   = "http://www.w3.org/XML/1998/namespace"
const _XMLNS_NS = "http://www.w3.org/2000/xmlns/"

const _MIME_RDFXML = MIME"application/rdf+xml"

# Terms that are structural to the RDF/XML grammar and can never be used as
# a node-element name, a property-element name (other than `rdf:li`, handled
# separately), or a property-attribute name.
const _CORE_SYNTAX_TERMS = Set([
    "RDF", "ID", "about", "parseType", "resource", "nodeID", "datatype",
])
const _SYNTAX_TERMS = union(_CORE_SYNTAX_TERMS, Set(["Description", "li"]))

# Removed-in-RDF-1.1 constructs. Encountering any of these anywhere (element
# name or attribute name) in the `rdf:` namespace is a hard parse error.
const _OLD_TERMS = Set(["aboutEach", "aboutEachPrefix", "bagID"])

# Commonly used RDF vocabulary IRIs, pre-built to avoid re-validating/interning
# the same string on every triple.
const _IRI_TYPE       = RDF.IRI(_RDF_NS * "type")
const _IRI_STATEMENT  = RDF.IRI(_RDF_NS * "Statement")
const _IRI_SUBJECT    = RDF.IRI(_RDF_NS * "subject")
const _IRI_PREDICATE  = RDF.IRI(_RDF_NS * "predicate")
const _IRI_OBJECT     = RDF.IRI(_RDF_NS * "object")
const _IRI_FIRST      = RDF.IRI(_RDF_NS * "first")
const _IRI_REST       = RDF.IRI(_RDF_NS * "rest")
const _IRI_NIL        = RDF.IRI(_RDF_NS * "nil")
const _IRI_XMLLITERAL = RDF.IRI(_RDF_NS * "XMLLiteral")

# ── Parser state ──────────────────────────────────────────────────────────────

"""
    _RDFXMLParser

Mutable state threaded through the recursive-descent walk of the DOM.

- `graph`       — accumulates triples as they're discovered.
- `base`        — the base URI in effect for the document root (informational;
                   the *effective* base at any point is threaded through the
                   parse functions as an explicit argument since it changes
                   per-subtree via `xml:base`).
- `blank_map`   — `rdf:nodeID` label → the `BlankNode` it denotes (document-scoped).
- `used_ids`    — resolved `base#id` strings already claimed by an `rdf:ID`,
                   used to reject duplicates.
"""
mutable struct _RDFXMLParser
    graph::RDF.Graph
    base::String
    blank_map::Dict{String, RDF.BlankNode}
    used_ids::Set{String}
end

_RDFXMLParser(base::String) =
    _RDFXMLParser(RDF.Graph(), base, Dict{String, RDF.BlankNode}(), Set{String}())

# ── Small helpers ─────────────────────────────────────────────────────────────

# Resolve `ref` against `base` per RFC 3986 §5.2.2 (shared with the Turtle parser).
_resolve(base::String, ref::AbstractString)::String = RDF._ttl_resolve(base, String(ref))

# Build an IRI, converting a validation failure into a ParseError with useful
# context instead of a bare IRIError.
function _mk_iri(value::String)::RDF.IRI
    try
        RDF.IRI(value)
    catch e
        e isa RDF.IRIError &&
            throw(RDF.ParseError("Invalid IRI $(repr(value)): $(e.reason)", 0, 0, _MIME_RDFXML()))
        rethrow()
    end
end

# Plain / language-tagged literal, matching the currently inherited xml:lang.
_mk_literal(text::String, lang::String)::RDF.Literal =
    isempty(lang) ? RDF.Literal(text) : RDF.Literal(text; lang=lang)

# The "full name" of an element or attribute: namespace URI concatenated with
# local name (no colon — this is not a QName, it's the resolved term string).
# Attributes with no namespace (e.g. a bare `foo="bar"`) get "" as the URI,
# which never matches an RDF/XML-significant term.
function _full_uri(node)::String
    ns = EzXML.hasnamespace(node) ? EzXML.namespace(node) : ""
    ns * EzXML.nodename(node)
end

_ns_of(node)::String = EzXML.hasnamespace(node) ? EzXML.namespace(node) : ""

# Look up an `rdf:`-namespaced attribute by local name; nothing if absent.
function _attr_rdf(el, local_name::String)::Union{String, Nothing}
    for a in EzXML.attributes(el)
        if _ns_of(a) == _RDF_NS && EzXML.nodename(a) == local_name
            return EzXML.nodecontent(a)
        end
    end
    nothing
end

# Look up an `xml:`-namespaced attribute (xml:lang, xml:base) by local name.
function _attr_xml(el, local_name::String)::Union{String, Nothing}
    for a in EzXML.attributes(el)
        if _ns_of(a) == _XML_NS && EzXML.nodename(a) == local_name
            return EzXML.nodecontent(a)
        end
    end
    nothing
end

# xml:lang is inherited from the parent, overridden (including cleared, via
# xml:lang="") by a value on this element.
function _get_lang(el, parent_lang::String)::String
    v = _attr_xml(el, "lang")
    v === nothing ? parent_lang : v
end

# xml:base is inherited from the parent and resolved against it if relative.
function _get_base(el, parent_base::String)::String
    v = _attr_xml(el, "base")
    v === nothing ? parent_base : _resolve(parent_base, v)
end

# Reject `rdf:aboutEach` / `rdf:aboutEachPrefix` / `rdf:bagID` wherever they
# appear as an attribute — these RDF 1.0 constructs were removed in RDF 1.1.
function _reject_old_term_attrs(el)
    for a in EzXML.attributes(el)
        if _ns_of(a) == _RDF_NS && EzXML.nodename(a) in _OLD_TERMS
            throw(RDF.ParseError(
                "rdf:$(EzXML.nodename(a)) is not supported (removed in RDF 1.1)",
                0, 0, _MIME_RDFXML()))
        end
    end
end

# ── rdf:ID / rdf:nodeID validation ────────────────────────────────────────────

# XML NCName: (Letter | '_') (Letter | Digit | '.' | '-' | '_')*
# `isletter`/`isdigit` are Unicode-aware, which is a reasonable superset of the
# XML NameStartChar/NameChar productions for our purposes.
function _valid_ncname(s::AbstractString)::Bool
    isempty(s) && return false
    first_char = true
    for c in s
        if first_char
            (isletter(c) || c == '_') || return false
            first_char = false
        else
            (isletter(c) || isdigit(c) || c == '.' || c == '-' || c == '_') || return false
        end
    end
    true
end

# Validate + resolve an rdf:ID, enforcing document-wide uniqueness of the
# resulting URI (RDF/XML §7.2.7: "It is an error for a URI [...] generated by
# an rdf:ID [...] to be the same as another one").
function _check_rdf_id!(p::_RDFXMLParser, id::String, base::String)::String
    _valid_ncname(id) ||
        throw(RDF.ParseError("rdf:ID value $(repr(id)) is not a valid XML NCName", 0, 0, _MIME_RDFXML()))
    resolved = _resolve(base, "#" * id)
    resolved in p.used_ids &&
        throw(RDF.ParseError("Duplicate rdf:ID $(repr(id)) (resolves to <$resolved>)", 0, 0, _MIME_RDFXML()))
    push!(p.used_ids, resolved)
    resolved
end

# Get-or-create the BlankNode denoted by an rdf:nodeID label (document-scoped:
# the same label always refers to the same blank node).
function _get_blank!(p::_RDFXMLParser, nodeid::String)::RDF.BlankNode
    _valid_ncname(nodeid) ||
        throw(RDF.ParseError("rdf:nodeID value $(repr(nodeid)) is not a valid XML NCName", 0, 0, _MIME_RDFXML()))
    get!(p.blank_map, nodeid) do
        RDF.blank!(p.graph)
    end
end

# Reification: rdf:ID on a *property* element generates four extra triples
# describing the statement itself (RDF/XML §7.2.16).
function _reify!(p::_RDFXMLParser, id_val::Union{String, Nothing}, base::String,
                 subject, predicate::RDF.IRI, obj)
    id_val === nothing && return nothing
    stmt = _mk_iri(_check_rdf_id!(p, id_val, base))
    push!(p.graph, RDF.Triple(stmt, _IRI_TYPE, _IRI_STATEMENT))
    push!(p.graph, RDF.Triple(stmt, _IRI_SUBJECT, subject))
    push!(p.graph, RDF.Triple(stmt, _IRI_PREDICATE, predicate))
    push!(p.graph, RDF.Triple(stmt, _IRI_OBJECT, obj))
    nothing
end

# ── rdf:parseType="Literal" — Exclusive Canonical XML serialization ──────────
#
# Serialize the child content of a property element as Exclusive Canonical XML
# per RDF/XML §7.2.15 / the parseTypeLiteralPropertyElt production.
#
# Key Exclusive C14N rules:
# • Namespace declarations appear only for *visibly utilized* prefixes.
# • Empty elements are serialized as start-tag + end-tag: <br></br>.
# • Attributes are sorted by (namespace URI, local name).
# • The xml: prefix is always in scope and never declared.

# Extract the qualified name (e.g. "html:h1" or "br") of an element, preserving
# the original document prefix via EzXML/libxml2's serialization.
function _element_qname(el)::String
    s = sprint(print, el)
    m = match(r"^<([^\s/>]+)", s)
    m === nothing ? EzXML.nodename(el) : String(m.captures[1])
end

# Extract the prefix portion of a qualified name ("html" from "html:h1", "" from "br").
function _qname_prefix(qname::String)::String
    i = findfirst(':', qname)
    i === nothing ? "" : qname[1:prevind(qname, i)]
end

# Get the qualified name of an attribute, using in-scope namespace declarations
# to reconstruct the prefix for namespaced attributes.
function _c14n_attr_qname(a, inscope::Vector{Pair{String,String}})::String
    local_name = EzXML.nodename(a)
    EzXML.hasnamespace(a) || return local_name
    ns = EzXML.namespace(a)
    for (p, h) in inscope
        h == ns && !isempty(p) && return p * ":" * local_name
    end
    local_name
end

# Escape text content per Canonical XML (§5.4)
function _c14n_escape_text(s::String)::String
    s = replace(s, "&" => "&amp;")
    s = replace(s, "<" => "&lt;")
    s = replace(s, ">" => "&gt;")
    s = replace(s, "\r" => "&#xD;")
    s
end

# Escape attribute values per Canonical XML (§5.4)
function _c14n_escape_attr(s::String)::String
    s = replace(s, "&" => "&amp;")
    s = replace(s, "<" => "&lt;")
    s = replace(s, "\"" => "&quot;")
    s = replace(s, "\t" => "&#x9;")
    s = replace(s, "\n" => "&#xA;")
    s = replace(s, "\r" => "&#xD;")
    s
end

# Serialize one element in Exclusive Canonical XML form.
# `rendered_ns` tracks prefix→URI bindings already emitted by an ancestor
# WITHIN the XML literal (so child elements don't re-declare them).
function _c14n_element!(buf::IOBuffer, el, rendered_ns::Dict{String,String})
    inscope = EzXML.namespaces(el)          # all in-scope ns (inherited + declared here)
    qname   = _element_qname(el)
    prefix  = _qname_prefix(qname)
    el_ns   = EzXML.hasnamespace(el) ? EzXML.namespace(el) : ""

    # ── Collect visibly utilized prefixes ────────────────────────────────────
    utilized = Set{String}()
    if !isempty(prefix)
        push!(utilized, prefix)           # prefixed element name
    elseif !isempty(el_ns)
        push!(utilized, "")              # default namespace is utilized
    end
    for a in EzXML.attributes(el)
        ap = _qname_prefix(_c14n_attr_qname(a, inscope))
        !isempty(ap) && push!(utilized, ap)
    end

    # ── Determine which namespace declarations to emit ───────────────────────
    ns_to_emit = Pair{String,String}[]
    for p in sort!(collect(utilized))
        p == "xml" && continue            # xml: is always implicitly in scope
        href = ""
        for (ip, ih) in inscope
            ip == p && (href = ih; break)
        end
        rendered_href = get(rendered_ns, p, nothing)
        (rendered_href === nothing || rendered_href != href) &&
            push!(ns_to_emit, p => href)
    end

    child_rendered_ns = copy(rendered_ns)
    for (p, h) in ns_to_emit
        child_rendered_ns[p] = h
    end

    # ── Start tag ────────────────────────────────────────────────────────────
    write(buf, "<", qname)

    # Namespace declarations (sorted alphabetically by prefix; "" sorts first)
    for (p, h) in ns_to_emit
        if isempty(p)
            write(buf, " xmlns=\"", _c14n_escape_attr(h), "\"")
        else
            write(buf, " xmlns:", p, "=\"", _c14n_escape_attr(h), "\"")
        end
    end

    # Attributes (sorted by namespace URI then local name)
    sorted_attrs = sort(
        [(qa  = _c14n_attr_qname(a, inscope),
          ns  = EzXML.hasnamespace(a) ? EzXML.namespace(a) : "",
          ln  = EzXML.nodename(a),
          val = EzXML.nodecontent(a)) for a in EzXML.attributes(el)],
        by = x -> (x.ns, x.ln))
    for a in sorted_attrs
        write(buf, " ", a.qa, "=\"", _c14n_escape_attr(a.val), "\"")
    end

    write(buf, ">")

    # ── Children ─────────────────────────────────────────────────────────────
    for child in EzXML.nodes(el)
        nt = EzXML.nodetype(child)
        if nt == EzXML.ELEMENT_NODE
            _c14n_element!(buf, child, child_rendered_ns)
        elseif nt == EzXML.TEXT_NODE || nt == EzXML.CDATA_SECTION_NODE
            write(buf, _c14n_escape_text(EzXML.nodecontent(child)))
        end
    end

    # ── End tag (always — canonical XML never uses self-closing tags) ─────────
    write(buf, "</", qname, ">")
end

# Top-level XML literal serializer: walks the children of a property element
# and produces the Exclusive Canonical XML form.
function _serialize_xml_literal(pel)::String
    buf = IOBuffer()
    for n in EzXML.nodes(pel)
        nt = EzXML.nodetype(n)
        if nt == EzXML.ELEMENT_NODE
            _c14n_element!(buf, n, Dict{String,String}())
        elseif nt == EzXML.TEXT_NODE || nt == EzXML.CDATA_SECTION_NODE
            write(buf, _c14n_escape_text(EzXML.nodecontent(n)))
        end
    end
    String(take!(buf))
end

# ── Node elements (§7.2.11 nodeElement) ───────────────────────────────────────

# Reject core-syntax terms (and old RDF 1.0 terms) used as an element name —
# a coreSyntaxTerm can never *be* a node element or property element.
function _reject_bad_element_name(el, extra_forbidden::Set{String})
    ns    = _ns_of(el)
    local_name = EzXML.nodename(el)
    ns != _RDF_NS && return nothing
    if local_name in _OLD_TERMS
        throw(RDF.ParseError("rdf:$local_name is not supported (removed in RDF 1.1)", 0, 0, _MIME_RDFXML()))
    end
    if local_name in _CORE_SYNTAX_TERMS || local_name in extra_forbidden
        throw(RDF.ParseError("rdf:$local_name cannot be used as an element name here", 0, 0, _MIME_RDFXML()))
    end
    nothing
end

# Parse one nodeElement, returning its subject (IRI or BlankNode).
#
# `parent_lang`/`parent_base` are the *inherited* xml:lang/xml:base from the
# enclosing context; this function resolves `el`'s own xml:lang/xml:base
# attributes against them itself (rather than trusting the caller to have
# done so) — self-resolving here means every call site is correct by
# construction, including nested nodeElements reached via a
# resourcePropertyElt or an rdf:parseType="Collection" member, both of which
# may carry their own xml:lang/xml:base.
function _parse_node_element!(p::_RDFXMLParser, el, parent_lang::String, parent_base::String)::Union{RDF.IRI, RDF.BlankNode}
    lang = _get_lang(el, parent_lang)
    base = _get_base(el, parent_base)

    # rdf:li is not a valid node-element name (only coreSyntaxTerms + li are
    # excluded from nodeElementURIs).
    _reject_bad_element_name(el, Set(["li"]))
    _reject_old_term_attrs(el)

    about_val   = _attr_rdf(el, "about")
    id_val      = _attr_rdf(el, "ID")
    nodeid_val  = _attr_rdf(el, "nodeID")

    n_subject_attrs = count(x -> x !== nothing, (about_val, id_val, nodeid_val))
    n_subject_attrs > 1 &&
        throw(RDF.ParseError(
            "at most one of rdf:about, rdf:ID, rdf:nodeID is allowed on a node element",
            0, 0, _MIME_RDFXML()))

    subject = if about_val !== nothing
        _mk_iri(_resolve(base, about_val))
    elseif id_val !== nothing
        _mk_iri(_check_rdf_id!(p, id_val, base))
    elseif nodeid_val !== nothing
        _get_blank!(p, nodeid_val)
    else
        RDF.blank!(p.graph)
    end

    # A typed node element (anything other than rdf:Description) asserts
    # rdf:type of the element's own resolved URI.
    ns = _ns_of(el)
    local_name = EzXML.nodename(el)
    if !(ns == _RDF_NS && local_name == "Description")
        push!(p.graph, RDF.Triple(subject, _IRI_TYPE, _mk_iri(ns * local_name)))
    end

    # rdf:type as an ATTRIBUTE is resource-valued (a URI), unlike every other
    # attribute-as-property-shortcut which is literal-valued.
    type_attr = _attr_rdf(el, "type")
    if type_attr !== nothing
        push!(p.graph, RDF.Triple(subject, _IRI_TYPE, _mk_iri(_resolve(base, type_attr))))
    end

    # Property-attribute shortcuts: any other attribute on a node element is
    # (subject, attr-URI, Literal(value; lang)).
    for a in EzXML.attributes(el)
        a_ns    = _ns_of(a)
        a_local = EzXML.nodename(a)
        a_ns == _XML_NS   && continue        # xml:lang / xml:base / xml:*
        a_ns == _XMLNS_NS && continue        # namespace declarations
        if a_ns == _RDF_NS
            (a_local in _CORE_SYNTAX_TERMS || a_local == "type" ||
             a_local == "Description") && continue
            # rdf:li is NOT a valid property-attribute URI (§7.2.5)
            a_local == "li" &&
                throw(RDF.ParseError("rdf:li is not allowed as a property attribute", 0, 0, _MIME_RDFXML()))
        end
        isempty(a_ns) && continue            # unprefixed attribute: no namespace, not a valid predicate
        push!(p.graph, RDF.Triple(subject, _mk_iri(a_ns * a_local), _mk_literal(EzXML.nodecontent(a), lang)))
    end

    _parse_property_element_list!(p, subject, el, lang, base)
    subject
end

# rdf:RDF's direct children are all nodeElements. `lang`/`base` are the
# container's own effective values; _parse_node_element! resolves each
# child's own xml:lang/xml:base against them.
function _parse_node_element_list!(p::_RDFXMLParser, container_el, lang::String, base::String)
    for child in EzXML.elements(container_el)
        _parse_node_element!(p, child, lang, base)
    end
    nothing
end

# ── Property elements (§7.2.14-7.2.21) ────────────────────────────────────────

function _parse_property_element_list!(p::_RDFXMLParser, subject, el, lang::String, base::String)
    li_counter = 0     # rdf:li numbering is per-element, NOT per-subject (W3C test008)
    for pel in EzXML.elements(el)
        prop_lang = _get_lang(pel, lang)
        prop_base = _get_base(pel, base)

        ns    = _ns_of(pel)
        local_name = EzXML.nodename(pel)
        predicate = if ns == _RDF_NS && local_name == "li"
            li_counter += 1
            _mk_iri(_RDF_NS * "_" * string(li_counter))
        else
            # propertyElementURIs excludes coreSyntaxTerms, rdf:Description,
            # and oldTerms (rdf:li is handled above, so it's not forbidden here).
            _reject_bad_element_name(pel, Set(["Description"]))
            _mk_iri(ns * local_name)
        end

        _parse_property_element!(p, subject, predicate, pel, prop_lang, prop_base)
    end
    nothing
end

# Collect the "other" attributes of an emptyPropertyElt (property-attribute
# shortcuts), separating out rdf:type (which is resource-valued, not literal).
# Returns (type_value_or_nothing, Vector{Tuple{IRI,String}}).
function _collect_property_attrs(pel)
    type_val = nothing
    out = Tuple{RDF.IRI, String}[]
    for a in EzXML.attributes(pel)
        a_ns    = _ns_of(a)
        a_local = EzXML.nodename(a)
        a_ns == _XML_NS   && continue
        a_ns == _XMLNS_NS && continue
        if a_ns == _RDF_NS
            if a_local == "type"
                type_val = EzXML.nodecontent(a)
                continue
            end
            (a_local in _CORE_SYNTAX_TERMS || a_local == "Description" || a_local == "li") && continue
            # rdf:_1 etc. are legitimate property-attribute predicates
            push!(out, (_mk_iri(_RDF_NS * a_local), EzXML.nodecontent(a)))
            continue
        end
        isempty(a_ns) && continue
        push!(out, (_mk_iri(a_ns * a_local), EzXML.nodecontent(a)))
    end
    type_val, out
end

# Fail if a parseType-bearing element carries anything beyond rdf:parseType,
# rdf:ID, and xml:lang/xml:base — parseType is mutually exclusive with
# rdf:resource, rdf:nodeID, rdf:datatype, and property-attribute shortcuts.
function _check_parsetype_exclusive!(pel)
    for a in EzXML.attributes(pel)
        a_ns    = _ns_of(a)
        a_local = EzXML.nodename(a)
        a_ns == _XML_NS   && continue
        a_ns == _XMLNS_NS && continue
        if a_ns == _RDF_NS
            a_local in ("parseType", "ID") && continue
            throw(RDF.ParseError("rdf:parseType cannot be combined with rdf:$a_local", 0, 0, _MIME_RDFXML()))
        end
        throw(RDF.ParseError("rdf:parseType cannot be combined with property attribute $(repr(a_local))", 0, 0, _MIME_RDFXML()))
    end
    nothing
end

# Split a property element's children into (element children, concatenated
# raw text/CDATA). Comments and PIs are ignored for content-classification
# purposes.
function _split_content(pel)
    child_els = EzXML.Node[]
    text_buf  = IOBuffer()
    for n in EzXML.nodes(pel)
        nt = EzXML.nodetype(n)
        if nt == EzXML.ELEMENT_NODE
            push!(child_els, n)
        elseif nt == EzXML.TEXT_NODE || nt == EzXML.CDATA_SECTION_NODE
            write(text_buf, EzXML.nodecontent(n))
        end
    end
    child_els, String(take!(text_buf))
end

# Parse one property element, given its already-resolved `predicate` IRI.
function _parse_property_element!(p::_RDFXMLParser, subject, predicate::RDF.IRI, pel, lang::String, base::String)
    _reject_old_term_attrs(pel)

    parse_type = _attr_rdf(pel, "parseType")

    # ── Forms 3–5: rdf:parseType ──────────────────────────────────────────
    if parse_type !== nothing
        _check_parsetype_exclusive!(pel)
        id_val = _attr_rdf(pel, "ID")

        if parse_type == "Resource"
            # Implicit blank node; this element's own children become ITS
            # property elements (form 4, §7.2.18).
            obj = RDF.blank!(p.graph)
            push!(p.graph, RDF.Triple(subject, predicate, obj))
            _reify!(p, id_val, base, subject, predicate, obj)
            _parse_property_element_list!(p, obj, pel, lang, base)

        elseif parse_type == "Collection"
            # rdf:first/rdf:rest chain over the child nodeElements (form 5,
            # §7.2.19). Each child element is itself a nodeElement.
            children = EzXML.elements(pel)
            if isempty(children)
                obj = _IRI_NIL
                push!(p.graph, RDF.Triple(subject, predicate, obj))
                _reify!(p, id_val, base, subject, predicate, obj)
            else
                head = RDF.blank!(p.graph)
                push!(p.graph, RDF.Triple(subject, predicate, head))
                _reify!(p, id_val, base, subject, predicate, head)
                cur = head
                n = length(children)
                for (i, child) in enumerate(children)
                    child_subject = _parse_node_element!(p, child, lang, base)
                    push!(p.graph, RDF.Triple(cur, _IRI_FIRST, child_subject))
                    if i < n
                        nxt = RDF.blank!(p.graph)
                        push!(p.graph, RDF.Triple(cur, _IRI_REST, nxt))
                        cur = nxt
                    else
                        push!(p.graph, RDF.Triple(cur, _IRI_REST, _IRI_NIL))
                    end
                end
            end

        else
            # "Literal", or any unrecognized parseType value — both are
            # treated as an XML literal per §7.2.15.
            lexical = _serialize_xml_literal(pel)
            obj = RDF.Literal(lexical, _IRI_XMLLITERAL)
            push!(p.graph, RDF.Triple(subject, predicate, obj))
            _reify!(p, id_val, base, subject, predicate, obj)
        end

        return nothing
    end

    # ── Forms 1, 2, 6: no rdf:parseType ────────────────────────────────────
    resource_val = _attr_rdf(pel, "resource")
    nodeid_val   = _attr_rdf(pel, "nodeID")
    datatype_val = _attr_rdf(pel, "datatype")
    id_val       = _attr_rdf(pel, "ID")

    resource_val !== nothing && nodeid_val !== nothing &&
        throw(RDF.ParseError("cannot use both rdf:resource and rdf:nodeID on the same element", 0, 0, _MIME_RDFXML()))

    child_els, raw_text = _split_content(pel)
    trimmed = strip(raw_text)

    if length(child_els) >= 1 && !isempty(trimmed)
        throw(RDF.ParseError("property element cannot mix a child element with non-whitespace text content", 0, 0, _MIME_RDFXML()))
    end
    if length(child_els) > 1
        throw(RDF.ParseError("property element has more than one child element (use rdf:parseType=\"Collection\" for a list)", 0, 0, _MIME_RDFXML()))
    end

    if length(child_els) == 1
        # Form 1: resourcePropertyElt — object is the nested nodeElement.
        obj = _parse_node_element!(p, child_els[1], lang, base)
        push!(p.graph, RDF.Triple(subject, predicate, obj))
        _reify!(p, id_val, base, subject, predicate, obj)

    elseif !isempty(raw_text) || datatype_val !== nothing
        # Form 2: literalPropertyElt.
        obj = if datatype_val !== nothing
            RDF.Literal(raw_text, _mk_iri(_resolve(base, datatype_val)))
        else
            _mk_literal(raw_text, lang)
        end
        push!(p.graph, RDF.Triple(subject, predicate, obj))
        _reify!(p, id_val, base, subject, predicate, obj)

    else
        # Form 6: emptyPropertyElt.
        type_val, prop_attrs = _collect_property_attrs(pel)

        obj = if resource_val !== nothing
            _mk_iri(_resolve(base, resource_val))
        elseif nodeid_val !== nothing
            _get_blank!(p, nodeid_val)
        elseif type_val !== nothing || !isempty(prop_attrs)
            RDF.blank!(p.graph)
        else
            _mk_literal("", lang)
        end

        push!(p.graph, RDF.Triple(subject, predicate, obj))
        _reify!(p, id_val, base, subject, predicate, obj)

        # Property attributes (and an rdf:type attribute) on an
        # emptyPropertyElt describe the OBJECT, not the enclosing subject —
        # this is the "compressed" form of a nested rdf:Description.
        if obj isa RDF.IRI || obj isa RDF.BlankNode
            type_val !== nothing &&
                push!(p.graph, RDF.Triple(obj, _IRI_TYPE, _mk_iri(_resolve(base, type_val))))
            for (pa_pred, pa_val) in prop_attrs
                push!(p.graph, RDF.Triple(obj, pa_pred, _mk_literal(pa_val, lang)))
            end
        end
    end

    nothing
end

# ── Top-level entry point ─────────────────────────────────────────────────────

function _parse_rdfxml(bytes::Vector{UInt8}, base::String)::RDF.Graph
    doc = try
        EzXML.parsexml(bytes)
    catch e
        throw(RDF.ParseError("XML parse error: $(sprint(showerror, e))", 0, 0, _MIME_RDFXML()))
    end

    root_el = EzXML.root(doc)
    p = _RDFXMLParser(base)

    root_lang = _get_lang(root_el, "")
    root_base = _get_base(root_el, base)

    if _full_uri(root_el) == _RDF_NS * "RDF"
        _reject_old_term_attrs(root_el)
        _parse_node_element_list!(p, root_el, root_lang, root_base)
    else
        # A standalone nodeElement — the whole document is a single node.
        _parse_node_element!(p, root_el, root_lang, root_base)
    end

    p.graph
end

# ── Public API ─────────────────────────────────────────────────────────────────

"""
    read(io::IO, ::MIME"application/rdf+xml", ::Type{RDF.Graph}) -> RDF.Graph
    read(io::IO, ::MIME"application/rdf+xml", ::Type{RDF.Graph}, base::AbstractString) -> RDF.Graph

Parse an RDF/XML document into a `Graph`. The two-argument-base form resolves
relative `rdf:about`/`rdf:resource`/`rdf:ID`/`rdf:datatype` values against
`base` (further overridden by any `xml:base` attributes in the document);
without it, the base starts empty, matching the Turtle/N-Triples readers.

Requires `EzXML.jl` to be loaded:

```julia
using RDF, EzXML
g = open("data.rdf") do io
    read(io, MIME"application/rdf+xml"(), Graph)
end
```
"""
function Base.read(io::IO, ::_MIME_RDFXML, ::Type{RDF.Graph})::RDF.Graph
    _parse_rdfxml(Base.read(io), "")
end

function Base.read(io::IO, ::_MIME_RDFXML, ::Type{RDF.Graph}, base::AbstractString)::RDF.Graph
    _parse_rdfxml(Base.read(io), String(base))
end

"""
    parse_triples(f, io, ::MIME"application/rdf+xml")

Parse an RDF/XML document and invoke `f(triple)` once per triple. RDF/XML's
grammar requires the full document tree (element nesting, `xml:base`/`xml:lang`
inheritance, `rdf:parseType="Literal"`, etc.), so — unlike the N-Triples
streaming reader — this builds the complete `Graph` first and then replays
its triples through the callback; it is a streaming *API*, not a
constant-memory *implementation*.
"""
function RDF.parse_triples(f::Function, io::IO, ::_MIME_RDFXML)
    g = _parse_rdfxml(Base.read(io), "")
    for t in g
        f(t)
    end
    nothing
end

end # module RDFXMLExt
