# LeftRight: a concurrency technique for wait-free read access

LeftRight.jl is a Julia package implementing the *left-right technique* ([Ramalhete and
Correia, 2015]) to provide an efficient mechanism for sharing mutable objects where **the
majority of accesses is read-only**.

The left-right technique works by maintaining two equivalent copies of objects.  The
high-level idea is that the writer mutates one of the object while the reader is accessing
another object.  The writer repeats the identical operations to maintain the equivalence of
two objects.  For more explanations, see [Ramalhete's CppCon 2015 talk].

[Ramalhete and Correia, 2015]: https://hal.archives-ouvertes.fr/hal-01207881
[Ramalhete's CppCon 2015 talk]: https://www.youtube.com/watch?v=FtaD0maxwec

## Examples

```julia
julia> using LeftRight

julia> guard = LeftRight.Guard() do
           Dict{Symbol,Int}()  # create a guarded object
       end;

julia> guarding(guard) do dict  # mutate the guarded object `dict`
           dict[:a] = 111
       end;

julia> guarding_read(guard) do dict  # read from the guarded object `dict`
           dict[:a]
       end
111
```

## Limitation

The function `f!` used as in `guarding(f!, guard)` is executed twice.  Its
side-effects on the argument must be "repeatable" in the sense that two equivalent objects
must stay equivalent after the mutation.  Schematically,

```JULIA
# Precondition:
@assert o1 !== o2  # this also applies to any internal mutable objects
@assert o1 ==′ o2  # e.g., ==′ = isequal

f!(o1)
f!(o2)

# Postcondition:
@assert o1 ==′ o2
```

The same caveat applies to the factory function passed to `LeftRight.Guard` constructor;
i.e., it has to create objects that are equivalent.

## Notes

The left-right technique itself is *[wait-free] population oblivious* for read accesses
([Ramalhete and Correia, 2015]).  Like many nonblocking algorithm, the wait-free property
does not apply directly to LeftRight.jl because Julia does not have wait-free garbage
collector.  However, LeftRight.jl is still useful for low-latency and high-throughput read
operations.  This is especially relevant when the shared object has to maintain complex
invariance (i.e., there is no out-of-the-box concurrent data structure implementation).
Furthermore, it is safe to read the shared objects using LeftRight.jl inside of a finalizer
because the read is wait-free.

For write accesses, LeftRight.jl is *starvation-free* ([Ramalhete and Correia, 2015]).  In
particular, if the critical section of the read accesses have no yield points, the writer
only needs to wait for up to `2 * nthreads()` tasks.  In LeftRight.jl implementation, the
writer waits for the readers in the Julia scheduler (after spinning for a while) so that
other tasks can be scheduled.

[wait-free]: https://en.wikipedia.org/wiki/Non-blocking_algorithm#Wait-freedom
[starvation-free]: https://en.wikipedia.org/wiki/Starvation_(computer_science)

## Links

* Ramalhete, Pedro, and Andreia Correia. “Brief Announcement: Left-Right - A Concurrency Control Technique with Wait-Free Population Oblivious Reads.” In DISC 2015, edited by Yoram Moses and Matthieu Roy, Vol. LNCS 9363. 29th International Symposium on Distributed Computing. Tokyo, Japan: Springer-Verlag Berlin Heidelberg, 2015. https://hal.archives-ouvertes.fr/hal-01207881.
* [CppCon 2015: Pedro Ramalhete “How to make your data structures wait-free for reads" - YouTube](https://www.youtube.com/watch?v=FtaD0maxwec)
