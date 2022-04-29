baremodule LeftRight

export guarding_read, guarding

module Internal

using UnsafeAtomics: UnsafeAtomics, acq_rel, seq_cst
using ConcurrentUtils: ConcurrentUtils, guarding_read, guarding, spinloop

using ..LeftRight: LeftRight

include("utils.jl")
include("core.jl")

end  # module Internal

const guarding = Internal.guarding
const guarding_read = Internal.guarding_read
const Guard = Internal.Guard
# const SimpleGuard = Internal.SimpleGuard

end  # baremodule LeftRight
