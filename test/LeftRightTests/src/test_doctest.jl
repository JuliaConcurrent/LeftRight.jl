module TestDoctest

using Documenter
using LeftRight

function test_leftright()
    doctest(LeftRight; manual = false)
end

const DUMMY = nothing

let path = joinpath(@__DIR__, "../../../README.md")
    include_dependency(path)
    doc = read(path, String)
    doc = replace(doc, r"^```julia"m => "```jldoctest README")
    @doc doc DUMMY
end

function test_leftrighttests()
    doctest(parentmodule(@__MODULE__); manual = false)
end

end  # module
