baremodule LeftRight

export guarding_read, guarding

# TODO: Move them to ConcurrentUtils
function guarding_read end
function guarding end

module Internal

using ..LeftRight: LeftRight

include("utils.jl")
include("core.jl")

end  # module Internal

const Guard = Internal.Guard

end  # baremodule LeftRight
