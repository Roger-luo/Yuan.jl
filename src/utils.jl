"""
    @make_codeinfo begin
        <stmt>::<type>
    end

Create a typed `CodeInfo` object, if field `<type>` is not specified, it will
use `Any`.
"""
macro make_codeinfo(ex)
    esc(make_codeinfo_m(ex))
end

"""
    @make_ircode begin
        <stmt>::<type>
    end

Create a typed `IRCode` object, if field `<type>` is not specified, it will
use `Any`. See also [`make_codeinfo`](@ref).
"""
macro make_ircode(ex)
    quote
        let
            ci = $(make_codeinfo_m(ex))
            Core.Compiler.inflate_ir(ci)
        end
    end |> esc
end

function make_codeinfo_m(ex)
    Meta.isexpr(ex, :block) || error("expect a begin ... end")
    
    code = Expr(:ref, :Any)
    ssavaluetypes = Expr(:ref, :Any)

    for each in ex.args
        @switch each begin
            @case :($stmt::$type)
                push!(code.args, stmt)
                push!(ssavaluetypes.args, type)
            @case ::LineNumberNode
                continue
            @case _
                push!(code.args, each)
                push!(ssavaluetypes.args, :Any)
        end
    end

    @gensym ci nstmts
    quote
        let ci = (Meta.@lower 1 + 1).args[1]
            ci.code = $code
            nstmts = length(ci.code)
            ci.ssavaluetypes = $ssavaluetypes
            ci.codelocs = fill(Int32(1), nstmts)
            ci.ssaflags = fill(Int32(0), nstmts)
            ci
        end
    end
end

"""
    method_instance(f, tt, world=Base.get_world_counter())

Return the `MethodInstance`, unlike `Base.method_instances`, `tt` must be specified type.
"""
function method_instance(@nospecialize(f), @nospecialize(tt), world=Base.get_world_counter())
    # get the method instance
    meth = which(f, tt)
    sig = Base.signature_type(f, tt)::Type
    (ti, env) = ccall(:jl_type_intersection_with_env, Any, (Any, Any), sig,
        meth.sig)::Core.SimpleVector
    meth = Base.func_for_method_checked(meth, ti, env)
    return ccall(:jl_specializations_get_linfo, Ref{Core.MethodInstance},
        (Any, Any, Any, UInt), meth, ti, env, world)
end

macro test_codeinfo(ci, ex)
    esc(test_codeinfo_m(ci, ex))
end

function rm_code_coverage_effect(ci::CodeInfo)
    # make sure we don't change original one
    new = NewCodeInfo(copy(ci))
    for (v, stmt) in new
        if Meta.isexpr(stmt, :code_coverage_effect)
            delete!(new, v)
        elseif stmt isa GotoIfNot
            # idx always exists since code_coverage_effect was inserted
            idx = findfirst(stmt.dest:length(ci.code)) do k
                !Meta.isexpr(ci.code[k], :code_coverage_effect)
            end
            new[v] = GotoIfNot(stmt.cond, stmt.dest+idx-1)
        elseif stmt isa GotoNode
            # idx always exists since code_coverage_effect was inserted
            idx = findfirst(stmt.label:length(ci.code)) do k
                !Meta.isexpr(ci.code[k], :code_coverage_effect)
            end
            new[v] = GotoNode(stmt.label+idx-1)
        end
    end
    new_ci = finish(new)

    if ci.ssavaluetypes isa Vector
        types = []
        for (v, stmt) in enumerate(ci.code)
            if !Meta.isexpr(stmt, :code_coverage_effect)
                push!(types, ci.ssavaluetypes[v])
            end
        end

        new_ci.ssavaluetypes = types
        new_ci.inferred = ci.inferred
    end
    return new_ci
end

function test_codeinfo_m(ci, ex::Expr)
    Meta.isexpr(ex, :block) || error("expect a begin ... end")
    @gensym nocodedov_ci

    ret = quote
        $nocodedov_ci = $CompilerPluginTools.rm_code_coverage_effect($ci)
    end
    stmt_count = 1
    for each in ex.args
        @switch each begin
            @case :($stmt::$type)
                push!(ret.args, quote
                    @test $MLStyle.@match $nocodedov_ci.code[$stmt_count] begin
                        $stmt => true
                        _ => false
                    end
                end)
                push!(ret.args, quote
                    @test $nocodedov_ci.ssavaluetypes[$stmt_count] == $type
                end)
                stmt_count += 1
            @case ::LineNumberNode
                continue
            @case _
                push!(ret.args, quote
                    @test $MLStyle.@match $nocodedov_ci.code[$stmt_count] begin
                        $each => true
                        _ => false
                    end
                end)
                stmt_count += 1
        end
    end
    return ret
end
