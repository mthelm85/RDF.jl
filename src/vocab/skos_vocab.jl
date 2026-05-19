module skos

using ..RDF: IRI

const _BASE = "http://www.w3.org/2004/02/skos/core#"

const Concept             = IRI(_BASE * "Concept")
const ConceptScheme       = IRI(_BASE * "ConceptScheme")
const Collection          = IRI(_BASE * "Collection")
const OrderedCollection   = IRI(_BASE * "OrderedCollection")
const inScheme            = IRI(_BASE * "inScheme")
const hasTopConcept       = IRI(_BASE * "hasTopConcept")
const topConceptOf        = IRI(_BASE * "topConceptOf")
const prefLabel           = IRI(_BASE * "prefLabel")
const altLabel            = IRI(_BASE * "altLabel")
const hiddenLabel         = IRI(_BASE * "hiddenLabel")
const notation            = IRI(_BASE * "notation")
const note                = IRI(_BASE * "note")
const changeNote          = IRI(_BASE * "changeNote")
const definition          = IRI(_BASE * "definition")
const editorialNote       = IRI(_BASE * "editorialNote")
const example             = IRI(_BASE * "example")
const historyNote         = IRI(_BASE * "historyNote")
const scopeNote           = IRI(_BASE * "scopeNote")
const broader             = IRI(_BASE * "broader")
const narrower            = IRI(_BASE * "narrower")
const related             = IRI(_BASE * "related")
const broaderTransitive   = IRI(_BASE * "broaderTransitive")
const narrowerTransitive  = IRI(_BASE * "narrowerTransitive")
const semanticRelation    = IRI(_BASE * "semanticRelation")
const mappingRelation     = IRI(_BASE * "mappingRelation")
const closeMatch          = IRI(_BASE * "closeMatch")
const exactMatch          = IRI(_BASE * "exactMatch")
const broadMatch          = IRI(_BASE * "broadMatch")
const narrowMatch         = IRI(_BASE * "narrowMatch")
const relatedMatch        = IRI(_BASE * "relatedMatch")
const member              = IRI(_BASE * "member")
const memberList          = IRI(_BASE * "memberList")

end # module skos
