struct BufferTemplate
    type::Union{DataType, UnionAll}
    length::Int
end

function BufferTemplate(s::Type{<:Symbolics.Struct}, length::Int)
    T = Symbolics.juliatype(s)
    BufferTemplate(T, length)
end

struct Nonnumeric <: SciMLStructures.AbstractPortion end
const NONNUMERIC_PORTION = Nonnumeric()

struct ParameterIndex{P, I}
    portion::P
    idx::I
    validate_size::Bool
end

ParameterIndex(portion, idx) = ParameterIndex(portion, idx, false)
ParameterIndex(p::ParameterIndex) = ParameterIndex(p.portion, p.idx, false)

struct DiscreteIndex
    # of all buffers corresponding to types, which one
    buffer_idx::Int
    # Index in the above buffer
    idx_in_buffer::Int
    # Which clock (corresponds to Block of BlockedArray)
    clock_idx::Int
    # Which index in `buffer[Block(clockidx)]`
    idx_in_clock::Int
end

const ParamIndexMap = Dict{BasicSymbolic, Tuple{Int, Int}}
const NonnumericMap = Dict{
    Union{BasicSymbolic, Symbolics.CallWithMetadata}, Tuple{Int, Int}}
const UnknownIndexMap = Dict{
    BasicSymbolic, Union{Int, UnitRange{Int}, AbstractArray{Int}}}
const TunableIndexMap = Dict{BasicSymbolic,
    Union{Int, UnitRange{Int}, Base.ReshapedArray{Int, N, UnitRange{Int}} where {N}}}

struct IndexCache
    unknown_idx::UnknownIndexMap
    # sym => (bufferidx, idx_in_buffer)
    discrete_idx::Dict{BasicSymbolic, DiscreteIndex}
    # sym => (clockidx, idx_in_clockbuffer)
    callback_to_clocks::Dict{Any, Vector{Int}}
    tunable_idx::TunableIndexMap
    constant_idx::ParamIndexMap
    nonnumeric_idx::NonnumericMap
    observed_syms::Set{BasicSymbolic}
    dependent_pars::Set{BasicSymbolic}
    discrete_buffer_sizes::Vector{Vector{BufferTemplate}}
    tunable_buffer_size::BufferTemplate
    constant_buffer_sizes::Vector{BufferTemplate}
    nonnumeric_buffer_sizes::Vector{BufferTemplate}
    symbol_to_variable::Dict{Symbol, Union{BasicSymbolic, CallWithMetadata}}
end

function IndexCache(sys::AbstractSystem)
    unks = solved_unknowns(sys)
    unk_idxs = UnknownIndexMap()
    symbol_to_variable = Dict{Symbol, Union{BasicSymbolic, CallWithMetadata}}()

    let idx = 1
        for sym in unks
            usym = unwrap(sym)
            rsym = renamespace(sys, usym)
            sym_idx = if Symbolics.isarraysymbolic(sym)
                reshape(idx:(idx + length(sym) - 1), size(sym))
            else
                idx
            end
            unk_idxs[usym] = sym_idx
            unk_idxs[rsym] = sym_idx
            idx += length(sym)
        end
        for sym in unks
            usym = unwrap(sym)
            iscall(sym) && operation(sym) === getindex || continue
            arrsym = arguments(sym)[1]
            all(haskey(unk_idxs, arrsym[i]) for i in eachindex(arrsym)) || continue

            idxs = [unk_idxs[arrsym[i]] for i in eachindex(arrsym)]
            if idxs == idxs[begin]:idxs[end]
                idxs = reshape(idxs[begin]:idxs[end], size(idxs))
            end
            rsym = renamespace(sys, arrsym)
            unk_idxs[arrsym] = idxs
            unk_idxs[rsym] = idxs
        end
    end

    observed_syms = Set{BasicSymbolic}()
    for eq in observed(sys)
        if symbolic_type(eq.lhs) != NotSymbolic()
            sym = eq.lhs
            ttsym = default_toterm(sym)
            rsym = renamespace(sys, sym)
            rttsym = renamespace(sys, ttsym)
            push!(observed_syms, sym)
            push!(observed_syms, ttsym)
            push!(observed_syms, rsym)
            push!(observed_syms, rttsym)
        end
    end

    tunable_buffers = Dict{Any, Set{BasicSymbolic}}()
    constant_buffers = Dict{Any, Set{BasicSymbolic}}()
    nonnumeric_buffers = Dict{Any, Set{Union{BasicSymbolic, CallWithMetadata}}}()

    function insert_by_type!(buffers::Dict{Any, S}, sym, ctype) where {S}
        sym = unwrap(sym)
        buf = get!(buffers, ctype, S())
        push!(buf, sym)
    end

    disc_param_callbacks = Dict{BasicSymbolic, Set{Int}}()
    events = vcat(continuous_events(sys), discrete_events(sys))
    for (i, event) in enumerate(events)
        discs = Set{BasicSymbolic}()
        affs = affects(event)
        if !(affs isa AbstractArray)
            affs = [affs]
        end
        for affect in affs
            if affect isa Equation
                is_parameter(sys, affect.lhs) && push!(discs, affect.lhs)
            elseif affect isa FunctionalAffect
                union!(discs, unwrap.(discretes(affect)))
            else
                error("Unhandled affect type $(typeof(affect))")
            end
        end

        for sym in discs
            is_parameter(sys, sym) ||
                error("Expected discrete variable $sym in callback to be a parameter")

            # Only `foo(t)`-esque parameters can be saved
            if iscall(sym) && length(arguments(sym)) == 1 &&
               isequal(only(arguments(sym)), get_iv(sys))
                clocks = get!(() -> Set{Int}(), disc_param_callbacks, sym)
                push!(clocks, i)
            else
                insert_by_type!(constant_buffers, sym, symtype(sym))
            end
        end
    end
    clock_partitions = unique(collect(values(disc_param_callbacks)))
    disc_symtypes = unique(symtype.(keys(disc_param_callbacks)))
    disc_symtype_idx = Dict(disc_symtypes .=> eachindex(disc_symtypes))
    disc_syms_by_symtype = [BasicSymbolic[] for _ in disc_symtypes]
    for sym in keys(disc_param_callbacks)
        push!(disc_syms_by_symtype[disc_symtype_idx[symtype(sym)]], sym)
    end
    disc_syms_by_symtype_by_partition = [Vector{BasicSymbolic}[] for _ in disc_symtypes]
    for (i, buffer) in enumerate(disc_syms_by_symtype)
        for partition in clock_partitions
            push!(disc_syms_by_symtype_by_partition[i],
                [sym for sym in buffer if disc_param_callbacks[sym] == partition])
        end
    end
    disc_idxs = Dict{BasicSymbolic, DiscreteIndex}()
    callback_to_clocks = Dict{
        Union{SymbolicContinuousCallback, SymbolicDiscreteCallback}, Set{Int}}()
    for (typei, disc_syms_by_partition) in enumerate(disc_syms_by_symtype_by_partition)
        symi = 0
        for (parti, disc_syms) in enumerate(disc_syms_by_partition)
            for clockidx in clock_partitions[parti]
                buffer = get!(() -> Set{Int}(), callback_to_clocks, events[clockidx])
                push!(buffer, parti)
            end
            clocki = 0
            for sym in disc_syms
                symi += 1
                clocki += 1
                ttsym = default_toterm(sym)
                rsym = renamespace(sys, sym)
                rttsym = renamespace(sys, ttsym)
                for cursym in (sym, ttsym, rsym, rttsym)
                    disc_idxs[cursym] = DiscreteIndex(typei, symi, parti, clocki)
                end
            end
        end
    end
    callback_to_clocks = Dict{
        Union{SymbolicContinuousCallback, SymbolicDiscreteCallback}, Vector{Int}}(k => collect(v)
    for (k, v) in callback_to_clocks)

    disc_buffer_templates = Vector{BufferTemplate}[]
    for (symtype, disc_syms_by_partition) in zip(
        disc_symtypes, disc_syms_by_symtype_by_partition)
        push!(disc_buffer_templates,
            [BufferTemplate(symtype, length(buf)) for buf in disc_syms_by_partition])
    end

    for p in parameters(sys)
        p = unwrap(p)
        ctype = symtype(p)
        if ctype <: FnType
            ctype = fntype_to_function_type(ctype)
        end
        haskey(disc_idxs, p) && continue
        haskey(constant_buffers, ctype) && p in constant_buffers[ctype] && continue
        insert_by_type!(
            if ctype <: Real || ctype <: AbstractArray{<:Real}
                if istunable(p, true) && Symbolics.shape(p) != Symbolics.Unknown() &&
                   (ctype == Real || ctype <: AbstractFloat ||
                    ctype <: AbstractArray{Real} ||
                    ctype <: AbstractArray{<:AbstractFloat})
                    tunable_buffers
                else
                    constant_buffers
                end
            else
                nonnumeric_buffers
            end,
            p,
            ctype
        )
    end

    function get_buffer_sizes_and_idxs(T, buffers::Dict)
        idxs = T()
        buffer_sizes = BufferTemplate[]
        for (i, (T, buf)) in enumerate(buffers)
            for (j, p) in enumerate(buf)
                ttp = default_toterm(p)
                rp = renamespace(sys, p)
                rttp = renamespace(sys, ttp)
                idxs[p] = (i, j)
                idxs[ttp] = (i, j)
                idxs[rp] = (i, j)
                idxs[rttp] = (i, j)
            end
            if T <: Symbolics.FnType
                T = Any
            end
            push!(buffer_sizes, BufferTemplate(T, length(buf)))
        end
        return idxs, buffer_sizes
    end

    const_idxs, const_buffer_sizes = get_buffer_sizes_and_idxs(
        ParamIndexMap, constant_buffers)
    nonnumeric_idxs, nonnumeric_buffer_sizes = get_buffer_sizes_and_idxs(
        NonnumericMap, nonnumeric_buffers)

    tunable_idxs = TunableIndexMap()
    tunable_buffer_size = 0
    for (i, (_, buf)) in enumerate(tunable_buffers)
        for (j, p) in enumerate(buf)
            idx = if size(p) == ()
                tunable_buffer_size + 1
            else
                reshape(
                    (tunable_buffer_size + 1):(tunable_buffer_size + length(p)), size(p))
            end
            tunable_buffer_size += length(p)
            tunable_idxs[p] = idx
            tunable_idxs[default_toterm(p)] = idx
            if hasname(p) && (!iscall(p) || operation(p) !== getindex)
                symbol_to_variable[getname(p)] = p
                symbol_to_variable[getname(default_toterm(p))] = p
            end
        end
    end

    for sym in Iterators.flatten((keys(unk_idxs), keys(disc_idxs), keys(tunable_idxs),
        keys(const_idxs), keys(nonnumeric_idxs),
        observed_syms, independent_variable_symbols(sys)))
        if hasname(sym) && (!iscall(sym) || operation(sym) !== getindex)
            symbol_to_variable[getname(sym)] = sym
        end
    end

    dependent_pars = Set{BasicSymbolic}()
    for eq in parameter_dependencies(sys)
        push!(dependent_pars, eq.lhs)
    end

    return IndexCache(
        unk_idxs,
        disc_idxs,
        callback_to_clocks,
        tunable_idxs,
        const_idxs,
        nonnumeric_idxs,
        observed_syms,
        dependent_pars,
        disc_buffer_templates,
        BufferTemplate(Real, tunable_buffer_size),
        const_buffer_sizes,
        nonnumeric_buffer_sizes,
        symbol_to_variable
    )
end

function SymbolicIndexingInterface.is_variable(ic::IndexCache, sym)
    variable_index(ic, sym) !== nothing
end

function SymbolicIndexingInterface.variable_index(ic::IndexCache, sym)
    if sym isa Symbol
        sym = get(ic.symbol_to_variable, sym, nothing)
        sym === nothing && return nothing
    end
    idx = check_index_map(ic.unknown_idx, sym)
    idx === nothing || return idx
    iscall(sym) && operation(sym) == getindex || return nothing
    args = arguments(sym)
    idx = variable_index(ic, args[1])
    idx === nothing && return nothing
    return idx[args[2:end]...]
end

function SymbolicIndexingInterface.is_parameter(ic::IndexCache, sym)
    parameter_index(ic, sym) !== nothing
end

function SymbolicIndexingInterface.parameter_index(ic::IndexCache, sym)
    if sym isa Symbol
        sym = get(ic.symbol_to_variable, sym, nothing)
        sym === nothing && return nothing
    end
    sym = unwrap(sym)
    validate_size = Symbolics.isarraysymbolic(sym) && symtype(sym) <: AbstractArray &&
                    Symbolics.shape(sym) !== Symbolics.Unknown()
    return if (idx = check_index_map(ic.tunable_idx, sym)) !== nothing
        ParameterIndex(SciMLStructures.Tunable(), idx, validate_size)
    elseif (idx = check_index_map(ic.discrete_idx, sym)) !== nothing
        ParameterIndex(
            SciMLStructures.Discrete(), (idx.buffer_idx, idx.idx_in_buffer), validate_size)
    elseif (idx = check_index_map(ic.constant_idx, sym)) !== nothing
        ParameterIndex(SciMLStructures.Constants(), idx, validate_size)
    elseif (idx = check_index_map(ic.nonnumeric_idx, sym)) !== nothing
        ParameterIndex(NONNUMERIC_PORTION, idx, validate_size)
    elseif iscall(sym) && operation(sym) == getindex
        args = arguments(sym)
        pidx = parameter_index(ic, args[1])
        pidx === nothing && return nothing
        if pidx.portion == SciMLStructures.Tunable()
            ParameterIndex(pidx.portion, reshape(pidx.idx, size(args[1]))[args[2:end]...],
                pidx.validate_size)
        else
            ParameterIndex(pidx.portion, (pidx.idx..., args[2:end]...), pidx.validate_size)
        end
    end
end

function SymbolicIndexingInterface.is_timeseries_parameter(ic::IndexCache, sym)
    timeseries_parameter_index(ic, sym) !== nothing
end

function SymbolicIndexingInterface.timeseries_parameter_index(ic::IndexCache, sym)
    if sym isa Symbol
        sym = get(ic.symbol_to_variable, sym, nothing)
        sym === nothing && return nothing
    end
    idx = check_index_map(ic.discrete_idx, sym)
    idx === nothing ||
        return ParameterTimeseriesIndex(idx.clock_idx, (idx.buffer_idx, idx.idx_in_clock))
    iscall(sym) && operation(sym) == getindex || return nothing
    args = arguments(sym)
    idx = timeseries_parameter_index(ic, args[1])
    idx === nothing && return nothing
    ParameterIndex(idx.portion, (idx.idx..., args[2:end]...), idx.validate_size)
end

function check_index_map(idxmap, sym)
    if (idx = get(idxmap, sym, nothing)) !== nothing
        return idx
    elseif !isa(sym, Symbol) && (!iscall(sym) || operation(sym) !== getindex) &&
           hasname(sym) && (idx = get(idxmap, getname(sym), nothing)) !== nothing
        return idx
    end
    dsym = default_toterm(sym)
    isequal(sym, dsym) && return nothing
    if (idx = get(idxmap, dsym, nothing)) !== nothing
        idx
    elseif !isa(dsym, Symbol) && (!iscall(dsym) || operation(dsym) !== getindex) &&
           hasname(dsym) && (idx = get(idxmap, getname(dsym), nothing)) !== nothing
        idx
    else
        nothing
    end
end

function reorder_parameters(sys::AbstractSystem, ps; kwargs...)
    if has_index_cache(sys) && get_index_cache(sys) !== nothing
        reorder_parameters(get_index_cache(sys), ps; kwargs...)
    elseif ps isa Tuple
        ps
    else
        (ps,)
    end
end

function reorder_parameters(ic::IndexCache, ps; drop_missing = false)
    isempty(ps) && return ()
    param_buf = if ic.tunable_buffer_size.length == 0
        ()
    else
        (BasicSymbolic[unwrap(variable(:DEF))
                       for _ in 1:(ic.tunable_buffer_size.length)],)
    end

    disc_buf = Tuple(BasicSymbolic[unwrap(variable(:DEF))
                                   for _ in 1:(sum(x -> x.length, temp))]
    for temp in ic.discrete_buffer_sizes)
    const_buf = Tuple(BasicSymbolic[unwrap(variable(:DEF)) for _ in 1:(temp.length)]
    for temp in ic.constant_buffer_sizes)
    nonnumeric_buf = Tuple(Union{BasicSymbolic, CallWithMetadata}[unwrap(variable(:DEF))
                                                                  for _ in 1:(temp.length)]
    for temp in ic.nonnumeric_buffer_sizes)
    for p in ps
        p = unwrap(p)
        if haskey(ic.discrete_idx, p)
            idx = ic.discrete_idx[p]
            disc_buf[idx.buffer_idx][idx.idx_in_buffer] = p
        elseif haskey(ic.tunable_idx, p)
            i = ic.tunable_idx[p]
            if i isa Int
                param_buf[1][i] = unwrap(p)
            else
                param_buf[1][i] = unwrap.(collect(p))
            end
        elseif haskey(ic.constant_idx, p)
            i, j = ic.constant_idx[p]
            const_buf[i][j] = p
        elseif haskey(ic.nonnumeric_idx, p)
            i, j = ic.nonnumeric_idx[p]
            nonnumeric_buf[i][j] = p
        else
            error("Invalid parameter $p")
        end
    end

    result = broadcast.(
        unwrap, (param_buf..., disc_buf..., const_buf..., nonnumeric_buf...))
    if drop_missing
        result = map(result) do buf
            filter(buf) do sym
                return !isequal(sym, unwrap(variable(:DEF)))
            end
        end
    end
    if all(isempty, result)
        return ()
    end
    return result
end

# Given a parameter index, find the index of the buffer it is in when
# `MTKParameters` is iterated
function iterated_buffer_index(ic::IndexCache, ind::ParameterIndex)
    idx = 0
    if ind.portion isa SciMLStructures.Tunable
        return idx + 1
    elseif ic.tunable_buffer_size.length > 0
        idx += 1
    end
    if ind.portion isa SciMLStructures.Discrete
        return idx + ind.idx[1]
    elseif !isempty(ic.discrete_buffer_sizes)
        idx += length(ic.discrete_buffer_sizes)
    end
    if ind.portion isa SciMLStructures.Constants
        return idx + ind.idx[1]
    elseif !isempty(ic.constant_buffer_sizes)
        idx += length(ic.constant_buffer_sizes)
    end
    if ind.portion == NONNUMERIC_PORTION
        return idx + ind.idx[1]
    end
    error("Unhandled portion $(ind.portion)")
end

function get_buffer_template(ic::IndexCache, pidx::ParameterIndex)
    (; portion, idx) = pidx

    if portion isa SciMLStructures.Tunable
        return ic.tunable_buffer_size
    elseif portion isa SciMLStructures.Discrete
        return ic.discrete_buffer_sizes[idx[1]][1]
    elseif portion isa SciMLStructures.Constants
        return ic.constant_buffer_sizes[idx[1]]
    elseif portion isa Nonnumeric
        return ic.nonnumeric_buffer_sizes[idx[1]]
    else
        error("Unhandled portion $portion")
    end
end

fntype_to_function_type(::Type{FnType{A, R, T}}) where {A, R, T} = T
fntype_to_function_type(::Type{FnType{A, R, Nothing}}) where {A, R} = FunctionWrapper{R, A}
fntype_to_function_type(::Type{FnType{A, R}}) where {A, R} = FunctionWrapper{R, A}
