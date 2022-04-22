# TODO: maybe use "NO_WAITERS_MASK" so that depart can use `iszero`
const HAS_WAITER_MASK = ~(typemax(UInt) >> 1)

mutable struct ReadIndicator
    # The highest bit of `state` indicates that there is a waiter waiting for all readers to
    # exit.  The rest of 63 bits represent the number of readers.
    @atomic state::UInt

    @const _pad1::NTuple{7,UInt}
    waiter::Union{Task,Nothing}
end

ReadIndicator() = ReadIndicator(0, pad7(), nothing)

const OFFSET_STATE =
    fieldoffset(ReadIndicator, findfirst(==(:state), fieldnames(ReadIndicator)))

function arrive!(ind::ReadIndicator)
    #=
    @atomic ind.state += UInt(1)  # [^seq_cst_state_leftright]
    =#
    ptr = Ptr{UInt}(pointer_from_objref(ind) + OFFSET_STATE)
    GC.@preserve ind begin
        UnsafeAtomics.modify!(ptr, +, UInt(1), seq_cst)
    end
    return ind
end

function depart!(ind::ReadIndicator)
    #=
    state = @atomic(
        :acquire_release,  # [^acq_rel_ind_state] [^acq_rel_ind_waiter]
        ind.state -= UInt(1)
    )
    =#
    ptr = Ptr{UInt}(pointer_from_objref(ind) + OFFSET_STATE)
    GC.@preserve ind begin
        _old, state = UnsafeAtomics.modify!(ptr, -, UInt(1), acq_rel)
    end
    if state == HAS_WAITER_MASK  # no readers, one waiter
        # Choosing at most one reader task that wakes up the waiter using CAS [^cas_waker].
        _, ok = @atomicreplace(
            :acquire_release,  # [^acq_rel_ind_state] [^acq_rel_ind_waiter]
            :monotonic,
            ind.state,
            HAS_WAITER_MASK => UInt(0),  # [^cas_waker]
        )
        ok || return
        waiter = ind.waiter::Task  # [^acq_rel_ind_waiter]
        schedule(waiter::Task)
    end
end
# [^cas_waker]: This CAS potentially races with other readers and the writer.  Note that
# this reader may wake up the writer of a future "epoch" (i.e., there can be multiple
# writers entering and exiting the critical sections after the `ind.state` field is updated
# and the CAS succeeds).  However, this is OK since there is still one and only one reader
# task waking the writer for each time the `HAS_WAITER_MASK` bit is flipped.
#
# This CAS alone potentially can cause starvation on the writer side if new readers are keep
# arriving.  However, this is avoided by toggling the indicator [^toggle_version] before the
# writer is waiting for readers.  That is to say, the writer ensures that there is no more
# "new" readers arriving to this indicator.  Thus, all readers eventually depart from this
# indicator and a CAS will succeed.

function wait_empty(ind::ReadIndicator; nspins = 100_000)
    n = 0
    while true
        state = @atomic ind.state  # [^seq_cst_state_leftright] [^acq_rel_ind_state]
        nreaders = state  # no waiter bit is set at this point
        iszero(nreaders) && return
        @assert iszero(state & HAS_WAITER_MASK)
        n += 1
        n < nspins || break
        spinloop()
    end

    ind.waiter = current_task()  # [^acq_rel_ind_waiter]
    state = @atomic(
        :acquire_release,  # [^acq_rel_ind_state] [^acq_rel_ind_waiter]
        ind.state |= HAS_WAITER_MASK
    )
    if state == HAS_WAITER_MASK  # no readers, one waiter
        # There may not be any readers waking up this writer.  Trying to cancel:
        _, ok = @atomicreplace(
            :acquire_release,  # [^acq_rel_ind_state]
            :monotonic,
            ind.state,
            HAS_WAITER_MASK => UInt(0),  # [^cas_waker]
        )
        if ok
            ind.waiter = nothing
            return
        end
    end
    wait()
    ind.waiter = nothing
end
# [^acq_rel_ind_state]: The `.state` field is stored/loaded using release/acquire ordering
# so that loads in the readers have the happens-before edges to the mutations by the writer.
#
# [^acq_rel_ind_waiter]: The stores/loads to/from `.state` that access the "waiter bit" also
# used for establishing the happens-before edge required for non-atomic store/load of
# `ind.waiter` field.

@enum LeftOrRight LEFT_READABLE RIGHT_READABLE

flip(x::LeftOrRight) = x == LEFT_READABLE ? RIGHT_READABLE : LEFT_READABLE

abstract type AbstractReadWriteGuard end  # TODO: Move it to ConcurrentUtils

mutable struct Guard{Data} <: AbstractReadWriteGuard
    @const left::Data
    @const right::Data
    @atomic versionindex::Int
    @atomic leftright::LeftOrRight
    @const indicators::NTuple{2,ReadIndicator}
    @const lock::ReentrantLock

    global function _Guard(left, right)
        right = right::typeof(left)
        indicators = (ReadIndicator(), ReadIndicator())
        lock = ReentrantLock()
        return new{typeof(left)}(left, right, 1, LEFT_READABLE, indicators, lock)
    end
end

function Guard{Data}(f = Data) where {Data}
    left = f()::Data
    right = f()::Data
    return _Guard(left, right)::Guard{Data}
end

Guard(f) = _Guard(f(), f())

function acquire_read(g::Guard)
    versionindex = @atomic :monotonic g.versionindex  # [^monotonic_versionindex]
    token = arrive!(g.indicators[versionindex])

    leftright = @atomic g.leftright  # [^seq_cst_state_leftright]
    data = leftright == LEFT_READABLE ? g.left : g.right
    return (token, data)
end
# [^monotonic_versionindex]: Since `g.versionindex` is just a "performance hint," it can be
# loaded using `:monotonic`.

function release_read(::Guard, token)
    depart!(token)
    return
end

function LeftRight.guarding_read(f, g::Guard)
    token, data = acquire_read(g)
    try
        return f(data)
    finally
        release_read(g, token)
    end
end

function LeftRight.guarding(f!, g::Guard)
    lock(g.lock)
    try
        # No need to use `:acquire` since the lock already has ordered the access:
        leftright = @atomic :monotonic g.leftright
        f!(leftright == LEFT_READABLE ? g.right : g.left)

        leftright = flip(leftright)
        @atomic g.leftright = leftright  # [^seq_cst_state_leftright] [^toggle_leftright]

        toggle_and_wait(g)

        return f!(leftright == LEFT_READABLE ? g.right : g.left)
    finally
        unlock(g.lock)
    end
end
# [^toggle_leftright]: "publish" the data
#
# [^seq_cst_state_leftright]: Some accesses to `ind.state` and `g.leftright` must have
# sequential consistent ordering.  See discussion below for more details.

function toggle_and_wait(g::Guard)
    prev = @atomic :monotonic g.versionindex  # [^monotonic_versionindex]
    next = mod1(prev + 1, 2)
    wait_empty(g.indicators[next])  # [^w1]
    @atomic :monotonic g.versionindex = next  # [^monotonic_versionindex] [^toggle_version]
    wait_empty(g.indicators[prev])  # [^w2]
end
# ## Idea
#
# Since `g.versionindex` and `g.leftright` are loaded independently, there are no direct
# "relationships" between these values.  The OS may pause executing the worker thread after
# the reader task loads `g.versionindex` but before completing `arrive!` while writers
# acquire the guard multiple times.  As such, to ensure that no readers access the guarded
# object while the writer is mutating it, the writer must observe that *both* indicators are
# emptied at least once [^w1] [^w2].  Then the writer can know that the readers arriving
# after these waits will observe the updated value of `g.leftright` (and depart before the
# waits during a writer acquire the guard after the readers arrived).
#
# Side notes (TODO: verify this): When using sharded counters for an indicator, the writer
# does not have to wait for the state in which no readers are using the indicator.  Rather,
# the writer only has to observe an empty state at least once for every sub-counter.  The
# writer does not have to wait for the state in which all the counters are zero
# simultaneously.  Thus, the name `wait_empty` may not be the best name.  Maybe `end_epoch`
# is a better name?
#
# Multiple indicators are used rather for the performance ("starvation-freedom").  By
# toggling the indicator before waiting for emptiness, the writer can bound the number of
# readers that the writer has to wait (to some extent, depending on how the guard is used
# and how the scheduler works).  For example, if the critical sections of the readers are
# yield-free, the number of readers that the writer has to wait is at most `2 * nthreads()`.
#
# ## Memory orderings
#
# Since `g.leftright` and `ind.state` are stored and loaded independently, the sequentially
# consistent (SC) ordering must be used in several places to avoid "store-load reordering"
# [^seq_cst_state_leftright].  More precisely, consider the following execution (to be
# proven impossible).
#
# Initially:
#
# ```julia
#                                         # Event:
# @assert g.leftright == LEFT_READABLE    # (i1)
# @assert ind.state == 0                  # (i2)
# ```
#
# Writer:
#
# ```julia
#                                         # Event:
# @atomic g.leftright = RIGHT_READABLE    # (w1) write
# nreaders = @atomic ind.state            # (w2) read
# @assert nreaders == 0                   #  => (w2) reads-from (i2)
# ```
#
# Reader:
#
# ```julia
#                                         # Event:
# nreaders = @atomic ind.state += 1       # (r1) read; (r2) write
# @assert nreaders == 1                   #  => (r1) reads-from (i2)
# leftright = @atomic g.leftright         # (r3) read
# @assert leftright = LEFT_READABLE       #  => (r3) reads-from (i1)
# ```
#
# That is to say, the writer misses that the reader arrived using the indicator `ind` and
# the reader misses that the writer toggled the `g.leftright` flag.
#
# The following edges can be obtained from the annotated behavior of the above execution.
#
# Sequenced-before (sb):
# * (w1) -> (w2)
# * (r1) -> (r2) -> (r3)
#
# Reads-from (rf) due to the values read:
# * (i1) -> (r3)
# * (i2) -> (w2)
# * (i2) -> (r1)  (not relevant)
#
# Modification order (mo):
# * (i1) -> (w1)
# * (i2) -> (r2)
#
# From the rf and mo, reads-before (rb) edges can also be found:
# * (r3) -> (w1)
# * (w2) -> (r2)
#
# These edges form a cycle:
# * (w1) -sb-> (w2) -rb-> (r2) -sb-> (r3) -rb-> (w1)
#
# Since these events use the SC ordering, these edges are part of the partial SC relations
# (psc).  However, psc is acyclic in the C++ memory model.  Thus, the execution above is
# impossible.
#
# ## Performance considerations
#
# In x86, there are no extra instructions for seq_cst reads. For fetch-and-add, relaxed and
# seq_cst orderings generate identical code (https://godbolt.org/z/cvc533ha1).  As such,
# sec_cst on the reader side is "free."  On the writer side, an mfence seems to be
# unavoidable.
