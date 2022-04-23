module TestCore

using LeftRight
using LeftRight.Internal: SimpleGuard
using Test

function check_serial(Guard)
    g = Guard{Dict{Symbol,Int}}()
    LeftRight.guarding(g) do dict
        dict[:a] = 111
    end
    @test LeftRight.guarding_read(g) do dict
        dict[:a]
    end == 111
    LeftRight.guarding(g) do dict
        dict[:a] += 111
    end
    @test LeftRight.guarding_read(g) do dict
        dict[:a]
    end == 222
    LeftRight.guarding(g) do dict
        dict[:a] += 111
    end
    @test LeftRight.guarding_read(g) do dict
        dict[:a]
    end == 333
end

test_serial() = check_serial(LeftRight.Guard)
test_serial_simple() = check_serial(SimpleGuard)

function check_concurrency(Guard; ntasks = Threads.nthreads(), ntries = 10_000_000)
    g = Guard() do
        Dict(:a => 0, :b => 2)
    end

    done = Threads.Atomic{Bool}(false)
    ok = Threads.Atomic{Bool}(true)
    @sync begin
        for _ in 2:ntasks
            Threads.@spawn begin
                while !done[] && ok[]
                    LeftRight.guarding_read(g) do dict
                        if dict[:b] - dict[:a] != 2
                            ok[] = false
                        end
                    end
                end
            end
        end
        try
            for _ in 1:ntries
                LeftRight.guarding(g) do dict
                    dict[:a] += 1
                    dict[:b] += 1
                end
            end
        finally
            done[] = true
        end
    end

    @test ok[]
end

test_concurrency(; options...) = check_concurrency(LeftRight.Guard; options...)
test_concurrency_simple(; options...) = check_concurrency(SimpleGuard; options...)

end  # module
