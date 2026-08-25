using RDF
using Documenter
using MaterialDocs

DocMeta.setdocmeta!(RDF, :DocTestSetup, :(using RDF); recursive=true)

makedocs(;
    modules=[RDF],
    authors="Matthew Helm",
    sitename="RDF.jl",
    checkdocs = :exports,   # only warn about public API, not internal AST types
    format=Material3(dark_mode=:light),
    pages=[
        "Home"                    => "index.md",
        "Terms"                   => "terms.md",
        "Graphs & Datasets"       => "graphs.md",
        "Serialization"           => "serialization.md",
        "Querying"                => "querying.md",
        "AI & GraphRAG"           => "ai.md",
        "Vocabulary API"          => "vocabulary.md",
        "Inference & Validation"  => "inference.md",
    ],
)

deploydocs(;
    repo="github.com/mthelm85/RDF.jl",
    devbranch="main",
)
