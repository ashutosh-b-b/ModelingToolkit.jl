"""
    lin_fun, simplified_sys = linearization_function(sys::AbstractSystem, inputs, outputs; simplify = false, initialize = true, initialization_solver_alg = TrustRegion(), kwargs...)

Return a function that linearizes the system `sys`. The function [`linearize`](@ref) provides a higher-level and easier to use interface.

`lin_fun` is a function `(variables, p, t) -> (; f_x, f_z, g_x, g_z, f_u, g_u, h_x, h_z, h_u)`, i.e., it returns a NamedTuple with the Jacobians of `f,g,h` for the nonlinear `sys` (technically for `simplified_sys`) on the form

```math
\\begin{aligned}
ẋ &= f(x, z, u) \\\\
0 &= g(x, z, u) \\\\
y &= h(x, z, u)
\\end{aligned}
```

where `x` are differential unknown variables, `z` algebraic variables, `u` inputs and `y` outputs. To obtain a linear statespace representation, see [`linearize`](@ref). The input argument `variables` is a vector defining the operating point, corresponding to `unknowns(simplified_sys)` and `p` is a vector corresponding to the parameters of `simplified_sys`. Note: all variables in `inputs` have been converted to parameters in `simplified_sys`.

The `simplified_sys` has undergone [`structural_simplify`](@ref) and had any occurring input or output variables replaced with the variables provided in arguments `inputs` and `outputs`. The unknowns of this system also indicate the order of the unknowns that holds for the linearized matrices.

# Arguments:

  - `sys`: An [`ODESystem`](@ref). This function will automatically apply simplification passes on `sys` and return the resulting `simplified_sys`.
  - `inputs`: A vector of variables that indicate the inputs of the linearized input-output model.
  - `outputs`: A vector of variables that indicate the outputs of the linearized input-output model.
  - `simplify`: Apply simplification in tearing.
  - `initialize`: If true, a check is performed to ensure that the operating point is consistent (satisfies algebraic equations). If the op is not consistent, initialization is performed.
  - `initialization_solver_alg`: A NonlinearSolve algorithm to use for solving for a feasible set of state and algebraic variables that satisfies the specified operating point.
  - `kwargs`: Are passed on to `find_solvables!`

See also [`linearize`](@ref) which provides a higher-level interface.
"""
function linearization_function(sys::AbstractSystem, inputs,
        outputs; simplify = false,
        initialize = true,
        initializealg = nothing,
        initialization_abstol = 1e-5,
        initialization_reltol = 1e-3,
        op = Dict(),
        p = DiffEqBase.NullParameters(),
        zero_dummy_der = false,
        initialization_solver_alg = TrustRegion(),
        eval_expression = false, eval_module = @__MODULE__,
        warn_initialize_determined = true,
        kwargs...)
    op = Dict(op)
    inputs isa AbstractVector || (inputs = [inputs])
    outputs isa AbstractVector || (outputs = [outputs])
    inputs = mapreduce(vcat, inputs; init = []) do var
        symbolic_type(var) == ArraySymbolic() ? collect(var) : [var]
    end
    outputs = mapreduce(vcat, outputs; init = []) do var
        symbolic_type(var) == ArraySymbolic() ? collect(var) : [var]
    end
    ssys, diff_idxs, alge_idxs, input_idxs = io_preprocessing(sys, inputs, outputs;
        simplify,
        kwargs...)
    if zero_dummy_der
        dummyder = setdiff(unknowns(ssys), unknowns(sys))
        defs = Dict(x => 0.0 for x in dummyder)
        @set! ssys.defaults = merge(defs, defaults(ssys))
        op = merge(defs, op)
    end
    sys = ssys

    if initializealg === nothing
        initializealg = initialize ? OverrideInit() : NoInit()
    end

    fun, u0, p = process_SciMLProblem(
        ODEFunction{true, SciMLBase.FullSpecialize}, sys, merge(
            defaults_and_guesses(sys), op), p;
        t = 0.0, build_initializeprob = initializealg isa OverrideInit,
        allow_incomplete = true, algebraic_only = true)
    prob = ODEProblem(fun, u0, (nothing, nothing), p)

    ps = parameters(sys)
    h = build_explicit_observed_function(sys, outputs; eval_expression, eval_module)
    lin_fun = let diff_idxs = diff_idxs,
        alge_idxs = alge_idxs,
        input_idxs = input_idxs,
        sts = unknowns(sys),
        fun = fun,
        prob = prob,
        sys_ps = p,
        h = h,
        integ_cache = (similar(u0)),
        chunk = ForwardDiff.Chunk(input_idxs),
        initializealg = initializealg,
        initialization_abstol = initialization_abstol,
        initialization_reltol = initialization_reltol,
        initialization_solver_alg = initialization_solver_alg,
        sys = sys

        function (u, p, t)
            if !isa(p, MTKParameters)
                p = todict(p)
                newps = deepcopy(sys_ps)
                for (k, v) in p
                    if is_parameter(sys, k)
                        v = fixpoint_sub(v, p)
                        setp(sys, k)(newps, v)
                    end
                end
                p = newps
            end

            if u !== nothing # Handle systems without unknowns
                length(sts) == length(u) ||
                    error("Number of unknown variables ($(length(sts))) does not match the number of input unknowns ($(length(u)))")

                integ = MockIntegrator{true}(u, p, t, integ_cache)
                u, p, success = SciMLBase.get_initial_values(
                    prob, integ, fun, initializealg, Val(true);
                    abstol = initialization_abstol, reltol = initialization_reltol,
                    nlsolve_alg = initialization_solver_alg)
                if !success
                    error("Initialization algorithm $(initializealg) failed with `u = $u` and `p = $p`.")
                end
                uf = SciMLBase.UJacobianWrapper(fun, t, p)
                fg_xz = ForwardDiff.jacobian(uf, u)
                h_xz = ForwardDiff.jacobian(
                    let p = p, t = t
                        xz -> h(xz, p, t)
                    end, u)
                pf = SciMLBase.ParamJacobianWrapper(fun, t, u)
                fg_u = jacobian_wrt_vars(pf, p, input_idxs, chunk)
            else
                length(sts) == 0 ||
                    error("Number of unknown variables (0) does not match the number of input unknowns ($(length(u)))")
                fg_xz = zeros(0, 0)
                h_xz = fg_u = zeros(0, length(inputs))
            end
            hp = let u = u, t = t
                _hp(p) = h(u, p, t)
                _hp
            end
            h_u = jacobian_wrt_vars(hp, p, input_idxs, chunk)
            (f_x = fg_xz[diff_idxs, diff_idxs],
                f_z = fg_xz[diff_idxs, alge_idxs],
                g_x = fg_xz[alge_idxs, diff_idxs],
                g_z = fg_xz[alge_idxs, alge_idxs],
                f_u = fg_u[diff_idxs, :],
                g_u = fg_u[alge_idxs, :],
                h_x = h_xz[:, diff_idxs],
                h_z = h_xz[:, alge_idxs],
                h_u = h_u)
        end
    end
    return lin_fun, sys
end

"""
    $(TYPEDEF)

Mock `DEIntegrator` to allow using `CheckInit` without having to create a new integrator
(and consequently depend on `OrdinaryDiffEq`).

# Fields

$(TYPEDFIELDS)
"""
struct MockIntegrator{iip, U, P, T, C} <: SciMLBase.DEIntegrator{Nothing, iip, U, T}
    """
    The state vector.
    """
    u::U
    """
    The parameter object.
    """
    p::P
    """
    The current time.
    """
    t::T
    """
    The integrator cache.
    """
    cache::C
end

function MockIntegrator{iip}(u::U, p::P, t::T, cache::C) where {iip, U, P, T, C}
    return MockIntegrator{iip, U, P, T, C}(u, p, t, cache)
end

SymbolicIndexingInterface.state_values(integ::MockIntegrator) = integ.u
SymbolicIndexingInterface.parameter_values(integ::MockIntegrator) = integ.p
SymbolicIndexingInterface.current_time(integ::MockIntegrator) = integ.t
SciMLBase.get_tmp_cache(integ::MockIntegrator) = integ.cache

"""
    (; A, B, C, D), simplified_sys = linearize_symbolic(sys::AbstractSystem, inputs, outputs; simplify = false, allow_input_derivatives = false, kwargs...)

Similar to [`linearize`](@ref), but returns symbolic matrices `A,B,C,D` rather than numeric. While `linearize` uses ForwardDiff to perform the linearization, this function uses `Symbolics.jacobian`.

See [`linearize`](@ref) for a description of the arguments.

# Extended help
The named tuple returned as the first argument additionally contains the jacobians `f_x, f_z, g_x, g_z, f_u, g_u, h_x, h_z, h_u` of
```math
\\begin{aligned}
ẋ &= f(x, z, u) \\\\
0 &= g(x, z, u) \\\\
y &= h(x, z, u)
\\end{aligned}
```
where `x` are differential unknown variables, `z` algebraic variables, `u` inputs and `y` outputs.
"""
function linearize_symbolic(sys::AbstractSystem, inputs,
        outputs; simplify = false, allow_input_derivatives = false,
        eval_expression = false, eval_module = @__MODULE__,
        kwargs...)
    sys, diff_idxs, alge_idxs, input_idxs = io_preprocessing(
        sys, inputs, outputs; simplify,
        kwargs...)
    sts = unknowns(sys)
    t = get_iv(sys)
    ps = parameters(sys; initial_parameters = true)
    p = reorder_parameters(sys, ps)

    fun_expr = generate_function(sys, sts, ps; expression = Val{true})[1]
    fun = eval_or_rgf(fun_expr; eval_expression, eval_module)
    dx = fun(sts, p, t)

    h = build_explicit_observed_function(sys, outputs; eval_expression, eval_module)
    y = h(sts, p, t)

    fg_xz = Symbolics.jacobian(dx, sts)
    fg_u = Symbolics.jacobian(dx, inputs)
    h_xz = Symbolics.jacobian(y, sts)
    h_u = Symbolics.jacobian(y, inputs)
    f_x = fg_xz[diff_idxs, diff_idxs]
    f_z = fg_xz[diff_idxs, alge_idxs]
    g_x = fg_xz[alge_idxs, diff_idxs]
    g_z = fg_xz[alge_idxs, alge_idxs]
    f_u = fg_u[diff_idxs, :]
    g_u = fg_u[alge_idxs, :]
    h_x = h_xz[:, diff_idxs]
    h_z = h_xz[:, alge_idxs]

    nx, nu = size(f_u)
    nz = size(f_z, 2)
    ny = size(h_x, 1)

    D = h_u

    if isempty(g_z) # ODE
        A = f_x
        B = f_u
        C = h_x
    else
        gz = lu(g_z; check = false)
        issuccess(gz) ||
            error("g_z not invertible, this indicates that the DAE is of index > 1.")
        gzgx = -(gz \ g_x)
        A = [f_x f_z
             gzgx*f_x gzgx*f_z]
        B = [f_u
             gzgx * f_u] # The cited paper has zeros in the bottom block, see derivation in https://github.com/SciML/ModelingToolkit.jl/pull/1691 for the correct formula

        C = [h_x h_z]
        Bs = -(gz \ g_u) # This equation differ from the cited paper, the paper is likely wrong since their equaiton leads to a dimension mismatch.
        if !iszero(Bs)
            if !allow_input_derivatives
                der_inds = findall(vec(any(!iszero, Bs, dims = 1)))
                @show typeof(der_inds)
                error("Input derivatives appeared in expressions (-g_z\\g_u != 0), the following inputs appeared differentiated: $(ModelingToolkit.inputs(sys)[der_inds]). Call `linearize_symbolic` with keyword argument `allow_input_derivatives = true` to allow this and have the returned `B` matrix be of double width ($(2nu)), where the last $nu inputs are the derivatives of the first $nu inputs.")
            end
            B = [B [zeros(nx, nu); Bs]]
            D = [D zeros(ny, nu)]
        end
    end

    (; A, B, C, D, f_x, f_z, g_x, g_z, f_u, g_u, h_x, h_z, h_u), sys
end

function markio!(state, orig_inputs, inputs, outputs; check = true)
    fullvars = get_fullvars(state)
    inputset = Dict{Any, Bool}(i => false for i in inputs)
    outputset = Dict{Any, Bool}(o => false for o in outputs)
    for (i, v) in enumerate(fullvars)
        if v in keys(inputset)
            if v in keys(outputset)
                v = setio(v, true, true)
                outputset[v] = true
            else
                v = setio(v, true, false)
            end
            inputset[v] = true
            fullvars[i] = v
        elseif v in keys(outputset)
            v = setio(v, false, true)
            outputset[v] = true
            fullvars[i] = v
        else
            if isinput(v)
                push!(orig_inputs, v)
            end
            v = setio(v, false, false)
            fullvars[i] = v
        end
    end
    if check
        ikeys = keys(filter(!last, inputset))
        if !isempty(ikeys)
            error(
                "Some specified inputs were not found in system. The following variables were not found ",
                ikeys)
        end
    end
    check && (all(values(outputset)) ||
     error(
        "Some specified outputs were not found in system. The following Dict indicates the found variables ",
        outputset))
    state, orig_inputs
end

"""
    (; A, B, C, D), simplified_sys = linearize(sys, inputs, outputs;    t=0.0, op = Dict(), allow_input_derivatives = false, zero_dummy_der=false, kwargs...)
    (; A, B, C, D)                 = linearize(simplified_sys, lin_fun; t=0.0, op = Dict(), allow_input_derivatives = false, zero_dummy_der=false)

Linearize `sys` between `inputs` and `outputs`, both vectors of variables. Return a NamedTuple with the matrices of a linear statespace representation
on the form

```math
\\begin{aligned}
ẋ &= Ax + Bu\\\\
y &= Cx + Du
\\end{aligned}
```

The first signature automatically calls [`linearization_function`](@ref) internally,
while the second signature expects the outputs of [`linearization_function`](@ref) as input.

`op` denotes the operating point around which to linearize. If none is provided,
the default values of `sys` are used.

If `allow_input_derivatives = false`, an error will be thrown if input derivatives (``u̇``) appear as inputs in the linearized equations. If input derivatives are allowed, the returned `B` matrix will be of double width, corresponding to the input `[u; u̇]`.

`zero_dummy_der` can be set to automatically set the operating point to zero for all dummy derivatives.

See also [`linearization_function`](@ref) which provides a lower-level interface, [`linearize_symbolic`](@ref) and [`ModelingToolkit.reorder_unknowns`](@ref).

See extended help for an example.

The implementation and notation follows that of
["Linear Analysis Approach for Modelica Models", Allain et al. 2009](https://ep.liu.se/ecp/043/075/ecp09430097.pdf)

# Extended help

This example builds the following feedback interconnection and linearizes it from the input of `F` to the output of `P`.

```

  r ┌─────┐       ┌─────┐     ┌─────┐
───►│     ├──────►│     │  u  │     │
    │  F  │       │  C  ├────►│  P  │ y
    └─────┘     ┌►│     │     │     ├─┬─►
                │ └─────┘     └─────┘ │
                │                     │
                └─────────────────────┘
```

```julia
using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D
function plant(; name)
    @variables x(t) = 1
    @variables u(t)=0 y(t)=0
    eqs = [D(x) ~ -x + u
           y ~ x]
    ODESystem(eqs, t; name = name)
end

function ref_filt(; name)
    @variables x(t)=0 y(t)=0
    @variables u(t)=0 [input = true]
    eqs = [D(x) ~ -2 * x + u
           y ~ x]
    ODESystem(eqs, t, name = name)
end

function controller(kp; name)
    @variables y(t)=0 r(t)=0 u(t)=0
    @parameters kp = kp
    eqs = [
        u ~ kp * (r - y),
    ]
    ODESystem(eqs, t; name = name)
end

@named f = ref_filt()
@named c = controller(1)
@named p = plant()

connections = [f.y ~ c.r # filtered reference to controller reference
               c.u ~ p.u # controller output to plant input
               p.y ~ c.y]

@named cl = ODESystem(connections, t, systems = [f, c, p])

lsys0, ssys = linearize(cl, [f.u], [p.x])
desired_order = [f.x, p.x]
lsys = ModelingToolkit.reorder_unknowns(lsys0, unknowns(ssys), desired_order)

@assert lsys.A == [-2 0; 1 -2]
@assert lsys.B == [1; 0;;]
@assert lsys.C == [0 1]
@assert lsys.D[] == 0

## Symbolic linearization
lsys_sym, _ = ModelingToolkit.linearize_symbolic(cl, [f.u], [p.x])

@assert substitute(lsys_sym.A, ModelingToolkit.defaults(cl)) == lsys.A
```
"""
function linearize(sys, lin_fun; t = 0.0, op = Dict(), allow_input_derivatives = false,
        p = DiffEqBase.NullParameters())
    x0 = merge(defaults(sys), Dict(missing_variable_defaults(sys)), op)
    u0, defs = get_u0(sys, x0, p)
    if has_index_cache(sys) && get_index_cache(sys) !== nothing
        if p isa SciMLBase.NullParameters
            p = op
        elseif p isa Dict
            p = merge(p, op)
        elseif p isa Vector && eltype(p) <: Pair
            p = merge(Dict(p), op)
        elseif p isa Vector
            p = merge(Dict(parameters(sys) .=> p), op)
        end
    end
    linres = lin_fun(u0, p, t)
    f_x, f_z, g_x, g_z, f_u, g_u, h_x, h_z, h_u = linres

    nx, nu = size(f_u)
    nz = size(f_z, 2)
    ny = size(h_x, 1)

    D = h_u

    if isempty(g_z)
        A = f_x
        B = f_u
        C = h_x
        @assert iszero(g_x)
        @assert iszero(g_z)
        @assert iszero(g_u)
    else
        gz = lu(g_z; check = false)
        issuccess(gz) ||
            error("g_z not invertible, this indicates that the DAE is of index > 1.")
        gzgx = -(gz \ g_x)
        A = [f_x f_z
             gzgx*f_x gzgx*f_z]
        B = [f_u
             gzgx * f_u] # The cited paper has zeros in the bottom block, see derivation in https://github.com/SciML/ModelingToolkit.jl/pull/1691 for the correct formula

        C = [h_x h_z]
        Bs = -(gz \ g_u) # This equation differ from the cited paper, the paper is likely wrong since their equaiton leads to a dimension mismatch.
        if !iszero(Bs)
            if !allow_input_derivatives
                der_inds = findall(vec(any(!=(0), Bs, dims = 1)))
                error("Input derivatives appeared in expressions (-g_z\\g_u != 0), the following inputs appeared differentiated: $(inputs(sys)[der_inds]). Call `linearize` with keyword argument `allow_input_derivatives = true` to allow this and have the returned `B` matrix be of double width ($(2nu)), where the last $nu inputs are the derivatives of the first $nu inputs.")
            end
            B = [B [zeros(nx, nu); Bs]]
            D = [D zeros(ny, nu)]
        end
    end

    (; A, B, C, D)
end

function linearize(sys, inputs, outputs; op = Dict(), t = 0.0,
        allow_input_derivatives = false,
        zero_dummy_der = false,
        kwargs...)
    lin_fun, ssys = linearization_function(sys,
        inputs,
        outputs;
        zero_dummy_der,
        op,
        kwargs...)
    linearize(ssys, lin_fun; op, t, allow_input_derivatives), ssys
end

"""
    (; Ã, B̃, C̃, D̃) = similarity_transform(sys, T; unitary=false)

Perform a similarity transform `T : Tx̃ = x` on linear system represented by matrices in NamedTuple `sys` such that

```
Ã = T⁻¹AT
B̃ = T⁻¹ B
C̃ = CT
D̃ = D
```

If `unitary=true`, `T` is assumed unitary and the matrix adjoint is used instead of the inverse.
"""
function similarity_transform(sys::NamedTuple, T; unitary = false)
    if unitary
        A = T'sys.A * T
        B = T'sys.B
    else
        Tf = lu(T)
        A = Tf \ sys.A * T
        B = Tf \ sys.B
    end
    C = sys.C * T
    D = sys.D
    (; A, B, C, D)
end

"""
    reorder_unknowns(sys::NamedTuple, old, new)

Permute the state representation of `sys` obtained from [`linearize`](@ref) so that the state unknown is changed from `old` to `new`
Example:

```
lsys, ssys = linearize(pid, [reference.u, measurement.u], [ctr_output.u])
desired_order = [int.x, der.x] # Unknowns that are present in unknowns(ssys)
lsys = ModelingToolkit.reorder_unknowns(lsys, unknowns(ssys), desired_order)
```

See also [`ModelingToolkit.similarity_transform`](@ref)
"""
function reorder_unknowns(sys::NamedTuple, old, new)
    nx = length(old)
    length(new) == nx || error("old and new must have the same length")
    perm = [findfirst(isequal(n), old) for n in new]
    issorted(perm) && return sys # shortcut return, no reordering
    P = zeros(Int, nx, nx)
    for i in 1:nx # Build permutation matrix
        P[i, perm[i]] = 1
    end
    similarity_transform(sys, P; unitary = true)
end
