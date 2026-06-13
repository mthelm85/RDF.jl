module rdf

using ..RDF: IRI

const _BASE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

const type            = IRI(_BASE * "type")
const Property        = IRI(_BASE * "Property")
const Statement       = IRI(_BASE * "Statement")
const subject         = IRI(_BASE * "subject")
const predicate       = IRI(_BASE * "predicate")
const object          = IRI(_BASE * "object")
const Bag             = IRI(_BASE * "Bag")
const Seq             = IRI(_BASE * "Seq")
const Alt             = IRI(_BASE * "Alt")
const value           = IRI(_BASE * "value")
const List            = IRI(_BASE * "List")
const first           = IRI(_BASE * "first")
const rest            = IRI(_BASE * "rest")
const nil             = IRI(_BASE * "nil")
const langString      = IRI(_BASE * "langString")
const HTML            = IRI(_BASE * "HTML")
const XMLLiteral      = IRI(_BASE * "XMLLiteral")
const PlainLiteral    = IRI(_BASE * "PlainLiteral")
const JSON            = IRI(_BASE * "JSON")
const CompoundLiteral = IRI(_BASE * "CompoundLiteral")
const language        = IRI(_BASE * "language")
const direction       = IRI(_BASE * "direction")

# RDF 1.2
const dirLangString   = IRI(_BASE * "dirLangString")  # directional language-tagged string
const reifies         = IRI(_BASE * "reifies")         # reification predicate

end # module rdf
