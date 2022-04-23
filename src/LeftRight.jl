baremodule LeftRight

export guarding_read, guarding

# TODO: Move them to ConcurrentUtils
function guarding_read end
function guarding end

module Internal

using UnsafeAtomics: UnsafeAtomics, acq_rel, seq_cst

using ..LeftRight: LeftRight

include("utils.jl")
include("core.jl")

end  # module Internal

const Guard = Internal.Guard
# const SimpleGuard = Internal.SimpleGuard

end  # baremodule LeftRight
