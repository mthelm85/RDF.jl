using RDF
using Documenter

DocMeta.setdocmeta!(RDF, :DocTestSetup, :(using RDF); recursive=true)

makedocs(;
    modules=[RDF],
    authors="Matthew Helm",
    sitename="RDF.jl",
    format=Documenter.HTML(;
        canonical="https://mthelm85.github.io/RDF.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/mthelm85/RDF.jl",
    devbranch="main",
)
