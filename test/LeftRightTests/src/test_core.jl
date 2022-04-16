module TestCore

using LeftRight
using Test

function test_simple()
    g = LeftRight.Guard{Dict{Symbol,Int}}()
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

function test_concurrency(; ntasks = Threads.nthreads(), ntries = 100_000)
    g = LeftRight.Guard() do
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

end  # module
