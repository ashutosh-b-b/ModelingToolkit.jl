"""
$(TYPEDEF)
A system of difference equations.
# Fields
$(FIELDS)
# Example
```
using ModelingToolkit
using ModelingToolkit: t_nounits as t
@parameters σ=28.0 ρ=10.0 β=8/3 δt=0.1
@variables x(t)=1.0 y(t)=0.0 z(t)=0.0
k = ShiftIndex(t)
eqs = [x(k+1) ~ σ*(y-x),
       y(k+1) ~ x*(ρ-z)-y,
       z(k+1) ~ x*y - β*z]
@named de = DiscreteSystem(eqs,t,[x,y,z],[σ,ρ,β]; tspan = (0, 1000.0)) # or
@named de = DiscreteSystem(eqs)
```
"""
struct DiscreteSystem <: AbstractTimeDependentSystem
    """
    A tag for the system. If two systems have the same tag, then they are
    structurally identical.
    """
    tag::UInt
    """The differential equations defining the discrete system."""
    eqs::Vector{Equation}
    """Independent variable."""
    iv::BasicSymbolic{Real}
    """Dependent (state) variables. Must not contain the independent variable."""
    unknowns::Vector
    """Parameter variables. Must not contain the independent variable."""
    ps::Vector
    """Time span."""
    tspan::Union{NTuple{2, Any}, Nothing}
    """Array variables."""
    var_to_name::Any
    """Observed states."""
    observed::Vector{Equation}
    """
    The name of the system
    """
    name::Symbol
    """
    A description of the system.
    """
    description::String
    """
    The internal systems. These are required to have unique names.
    """
    systems::Vector{DiscreteSystem}
    """
    The default values to use when initial conditions and/or
    parameters are not supplied in `DiscreteProblem`.
    """
    defaults::Dict
    """
    Inject assignment statements before the evaluation of the RHS function.
    """
    preface::Any
    """
    Type of the system.
    """
    connector_type::Any
    """
    Topologically sorted parameter dependency equations, where all symbols are parameters and
    the LHS is a single parameter.
    """
    parameter_dependencies::Vector{Equation}
    """
    Metadata for the system, to be used by downstream packages.
    """
    metadata::Any
    """
    Metadata for MTK GUI.
    """
    gui_metadata::Union{Nothing, GUIMetadata}
    """
    Cache for intermediate tearing state.
    """
    tearing_state::Any
    """
    Substitutions generated by tearing.
    """
    substitutions::Any
    """
    If a model `sys` is complete, then `sys.x` no longer performs namespacing.
    """
    complete::Bool
    """
    Cached data for fast symbolic indexing.
    """
    index_cache::Union{Nothing, IndexCache}
    """
    The hierarchical parent system before simplification.
    """
    parent::Any
    isscheduled::Bool

    function DiscreteSystem(tag, discreteEqs, iv, dvs, ps, tspan, var_to_name,
            observed,
            name, description,
            systems, defaults, preface, connector_type, parameter_dependencies = Equation[],
            metadata = nothing, gui_metadata = nothing,
            tearing_state = nothing, substitutions = nothing,
            complete = false, index_cache = nothing, parent = nothing,
            isscheduled = false;
            checks::Union{Bool, Int} = true)
        if checks == true || (checks & CheckComponents) > 0
            check_independent_variables([iv])
            check_variables(dvs, iv)
            check_parameters(ps, iv)
        end
        if checks == true || (checks & CheckUnits) > 0
            u = __get_unit_type(dvs, ps, iv)
            check_units(u, discreteEqs)
        end
        new(tag, discreteEqs, iv, dvs, ps, tspan, var_to_name, observed, name, description,
            systems,
            defaults,
            preface, connector_type, parameter_dependencies, metadata, gui_metadata,
            tearing_state, substitutions, complete, index_cache, parent, isscheduled)
    end
end

"""
    $(TYPEDSIGNATURES)
Constructs a DiscreteSystem.
"""
function DiscreteSystem(eqs::AbstractVector{<:Equation}, iv, dvs, ps;
        observed = Num[],
        systems = DiscreteSystem[],
        tspan = nothing,
        name = nothing,
        description = "",
        default_u0 = Dict(),
        default_p = Dict(),
        defaults = _merge(Dict(default_u0), Dict(default_p)),
        preface = nothing,
        connector_type = nothing,
        parameter_dependencies = Equation[],
        metadata = nothing,
        gui_metadata = nothing,
        kwargs...)
    name === nothing &&
        throw(ArgumentError("The `name` keyword must be provided. Please consider using the `@named` macro"))
    iv′ = value(iv)
    dvs′ = value.(dvs)
    ps′ = value.(ps)
    if any(hasderiv, eqs) || any(hashold, eqs) || any(hassample, eqs) || any(hasdiff, eqs)
        error("Equations in a `DiscreteSystem` can only have `Shift` operators.")
    end
    if !(isempty(default_u0) && isempty(default_p))
        Base.depwarn(
            "`default_u0` and `default_p` are deprecated. Use `defaults` instead.",
            :DiscreteSystem, force = true)
    end
    defaults = todict(defaults)
    defaults = Dict(value(k) => value(v)
    for (k, v) in pairs(defaults) if value(v) !== nothing)

    var_to_name = Dict()
    process_variables!(var_to_name, defaults, dvs′)
    process_variables!(var_to_name, defaults, ps′)
    isempty(observed) || collect_var_to_name!(var_to_name, (eq.lhs for eq in observed))

    sysnames = nameof.(systems)
    if length(unique(sysnames)) != length(sysnames)
        throw(ArgumentError("System names must be unique."))
    end
    DiscreteSystem(Threads.atomic_add!(SYSTEM_COUNT, UInt(1)),
        eqs, iv′, dvs′, ps′, tspan, var_to_name, observed, name, description, systems,
        defaults, preface, connector_type, parameter_dependencies, metadata, gui_metadata, kwargs...)
end

function DiscreteSystem(eqs, iv; kwargs...)
    eqs = collect(eqs)
    diffvars = OrderedSet()
    allunknowns = OrderedSet()
    ps = OrderedSet()
    iv = value(iv)
    for eq in eqs
        collect_vars!(allunknowns, ps, eq, iv; op = Shift)
        if iscall(eq.lhs) && operation(eq.lhs) isa Shift
            isequal(iv, operation(eq.lhs).t) ||
                throw(ArgumentError("A DiscreteSystem can only have one independent variable."))
            eq.lhs in diffvars &&
                throw(ArgumentError("The shift variable $(eq.lhs) is not unique in the system of equations."))
            push!(diffvars, eq.lhs)
        end
    end
    for eq in get(kwargs, :parameter_dependencies, Equation[])
        if eq isa Pair
            collect_vars!(allunknowns, ps, eq, iv)
        else
            collect_vars!(allunknowns, ps, eq, iv)
        end
    end
    new_ps = OrderedSet()
    for p in ps
        if iscall(p) && operation(p) === getindex
            par = arguments(p)[begin]
            if Symbolics.shape(Symbolics.unwrap(par)) !== Symbolics.Unknown() &&
               all(par[i] in ps for i in eachindex(par))
                push!(new_ps, par)
            else
                push!(new_ps, p)
            end
        else
            push!(new_ps, p)
        end
    end
    return DiscreteSystem(eqs, iv,
        collect(allunknowns), collect(new_ps); kwargs...)
end

function flatten(sys::DiscreteSystem, noeqs = false)
    systems = get_systems(sys)
    if isempty(systems)
        return sys
    else
        return DiscreteSystem(noeqs ? Equation[] : equations(sys),
            get_iv(sys),
            unknowns(sys),
            parameters(sys),
            observed = observed(sys),
            defaults = defaults(sys),
            name = nameof(sys),
            description = description(sys),
            metadata = get_metadata(sys),
            checks = false)
    end
end

function generate_function(
        sys::DiscreteSystem, dvs = unknowns(sys), ps = parameters(sys); wrap_code = identity, kwargs...)
    exprs = [eq.rhs for eq in equations(sys)]
    wrap_code = wrap_code .∘ wrap_array_vars(sys, exprs) .∘
                wrap_parameter_dependencies(sys, false)
    generate_custom_function(sys, exprs, dvs, ps; wrap_code, kwargs...)
end

function shift_u0map_forward(sys::DiscreteSystem, u0map, defs)
    iv = get_iv(sys)
    updated = AnyDict()
    for k in collect(keys(u0map))
        v = u0map[k]
        if !((op = operation(k)) isa Shift)
            error("Initial conditions must be for the past state of the unknowns. Instead of providing the condition for $k, provide the condition for $(Shift(iv, -1)(k)).")
        end
        updated[Shift(iv, op.steps + 1)(arguments(k)[1])] = v
    end
    for var in unknowns(sys)
        op = operation(var)
        op isa Shift || continue
        haskey(updated, var) && continue
        root = first(arguments(var))
        haskey(defs, root) || error("Initial condition for $var not provided.")
        updated[var] = defs[root]
    end
    return updated
end

"""
    $(TYPEDSIGNATURES)
Generates an DiscreteProblem from an DiscreteSystem.
"""
function SciMLBase.DiscreteProblem(
        sys::DiscreteSystem, u0map = [], tspan = get_tspan(sys),
        parammap = SciMLBase.NullParameters();
        eval_module = @__MODULE__,
        eval_expression = false,
        use_union = false,
        kwargs...
)
    if !iscomplete(sys)
        error("A completed `DiscreteSystem` is required. Call `complete` or `structural_simplify` on the system before creating a `DiscreteProblem`")
    end
    dvs = unknowns(sys)
    ps = parameters(sys)
    eqs = equations(sys)
    iv = get_iv(sys)

    u0map = to_varmap(u0map, dvs)
    u0map = shift_u0map_forward(sys, u0map, defaults(sys))
    f, u0, p = process_SciMLProblem(
        DiscreteFunction, sys, u0map, parammap; eval_expression, eval_module)
    u0 = f(u0, p, tspan[1])
    DiscreteProblem(f, u0, tspan, p; kwargs...)
end

function SciMLBase.DiscreteFunction(sys::DiscreteSystem, args...; kwargs...)
    DiscreteFunction{true}(sys, args...; kwargs...)
end

function SciMLBase.DiscreteFunction{true}(sys::DiscreteSystem, args...; kwargs...)
    DiscreteFunction{true, SciMLBase.AutoSpecialize}(sys, args...; kwargs...)
end

function SciMLBase.DiscreteFunction{false}(sys::DiscreteSystem, args...; kwargs...)
    DiscreteFunction{false, SciMLBase.FullSpecialize}(sys, args...; kwargs...)
end
function SciMLBase.DiscreteFunction{iip, specialize}(
        sys::DiscreteSystem,
        dvs = unknowns(sys),
        ps = parameters(sys),
        u0 = nothing;
        version = nothing,
        p = nothing,
        t = nothing,
        eval_expression = false,
        eval_module = @__MODULE__,
        analytic = nothing,
        kwargs...) where {iip, specialize}
    if !iscomplete(sys)
        error("A completed `DiscreteSystem` is required. Call `complete` or `structural_simplify` on the system before creating a `DiscreteProblem`")
    end
    f_gen = generate_function(sys, dvs, ps; expression = Val{true},
        expression_module = eval_module, kwargs...)
    f_oop, f_iip = eval_or_rgf.(f_gen; eval_expression, eval_module)
    f(u, p, t) = f_oop(u, p, t)
    f(du, u, p, t) = f_iip(du, u, p, t)

    if specialize === SciMLBase.FunctionWrapperSpecialize && iip
        if u0 === nothing || p === nothing || t === nothing
            error("u0, p, and t must be specified for FunctionWrapperSpecialize on DiscreteFunction.")
        end
        f = SciMLBase.wrapfun_iip(f, (u0, u0, p, t))
    end

    observedfun = ObservedFunctionCache(sys)

    DiscreteFunction{iip, specialize}(f;
        sys = sys,
        observed = observedfun,
        analytic = analytic)
end

"""
```julia
DiscreteFunctionExpr{iip}(sys::DiscreteSystem, dvs = states(sys),
                          ps = parameters(sys);
                          version = nothing,
                          kwargs...) where {iip}
```

Create a Julia expression for an `DiscreteFunction` from the [`DiscreteSystem`](@ref).
The arguments `dvs` and `ps` are used to set the order of the dependent
variable and parameter vectors, respectively.
"""
struct DiscreteFunctionExpr{iip} end
struct DiscreteFunctionClosure{O, I} <: Function
    f_oop::O
    f_iip::I
end
(f::DiscreteFunctionClosure)(u, p, t) = f.f_oop(u, p, t)
(f::DiscreteFunctionClosure)(du, u, p, t) = f.f_iip(du, u, p, t)

function DiscreteFunctionExpr{iip}(sys::DiscreteSystem, dvs = unknowns(sys),
        ps = parameters(sys), u0 = nothing;
        version = nothing, p = nothing,
        linenumbers = false,
        simplify = false,
        kwargs...) where {iip}
    f_oop, f_iip = generate_function(sys, dvs, ps; expression = Val{true}, kwargs...)

    fsym = gensym(:f)
    _f = :($fsym = $DiscreteFunctionClosure($f_oop, $f_iip))

    ex = quote
        $_f
        DiscreteFunction{$iip}($fsym)
    end
    !linenumbers ? Base.remove_linenums!(ex) : ex
end

function DiscreteFunctionExpr(sys::DiscreteSystem, args...; kwargs...)
    DiscreteFunctionExpr{true}(sys, args...; kwargs...)
end
