module rdfs

using ..RDF: IRI

const _BASE = "http://www.w3.org/2000/01/rdf-schema#"

const Resource       = IRI(_BASE * "Resource")
const Class          = IRI(_BASE * "Class")
const subClassOf     = IRI(_BASE * "subClassOf")
const subPropertyOf  = IRI(_BASE * "subPropertyOf")
const comment        = IRI(_BASE * "comment")
const label          = IRI(_BASE * "label")
const domain         = IRI(_BASE * "domain")
const range          = IRI(_BASE * "range")
const seeAlso        = IRI(_BASE * "seeAlso")
const isDefinedBy    = IRI(_BASE * "isDefinedBy")
const Literal        = IRI(_BASE * "Literal")
const Container      = IRI(_BASE * "Container")
const ContainerMembershipProperty = IRI(_BASE * "ContainerMembershipProperty")
const Datatype       = IRI(_BASE * "Datatype")
const member         = IRI(_BASE * "member")

end # module rdfs
