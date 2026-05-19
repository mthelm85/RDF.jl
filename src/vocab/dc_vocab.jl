module dc

using ..RDF: IRI

const _BASE = "http://purl.org/dc/elements/1.1/"

const contributor  = IRI(_BASE * "contributor")
const coverage     = IRI(_BASE * "coverage")
const creator      = IRI(_BASE * "creator")
const date         = IRI(_BASE * "date")
const description  = IRI(_BASE * "description")
const format       = IRI(_BASE * "format")
const identifier   = IRI(_BASE * "identifier")
const language     = IRI(_BASE * "language")
const publisher    = IRI(_BASE * "publisher")
const relation     = IRI(_BASE * "relation")
const rights       = IRI(_BASE * "rights")
const source       = IRI(_BASE * "source")
const subject      = IRI(_BASE * "subject")
const title        = IRI(_BASE * "title")
const type         = IRI(_BASE * "type")

end # module dc
