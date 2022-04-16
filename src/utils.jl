macro _const(ex)
    ex = esc(ex)
    if VERSION < v"1.8.0-DEV.1148"
        return ex
    else
        return Expr(:const, ex)
    end
end

const var"@const" = var"@_const"

pad7() = ntuple(_ -> 0, Val(7))

function spinloop()
    GC.safepoint()
    ccall(:jl_cpu_pause, Cvoid, ())
end
