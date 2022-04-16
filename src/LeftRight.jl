baremodule LeftRight

module Internal

using ..LeftRight: LeftRight

include("internal.jl")

end  # module Internal

end  # baremodule LeftRight
