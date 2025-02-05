abstract type AbstractBorderedLinearSolver <: AbstractLinearSolver end

# the following stuctures, say `struct BDLS;...;end` rely on the hypotheses:
# - the constructor must provide BDLS() and BDLS(::AbstractLinearSolver)
# - the method (ls::BDLS)(J, dR, dzu, dzp, R, n, ξu, ξp; shift = nothing) must be provided

# call for using BorderedArray input, specific to Arclength Continuation
(lbs::AbstractBorderedLinearSolver)(J, dR,
							dz::BorderedArray, R,
							n::T, theta::T;
							shift::Ts = nothing) where {T, Ts} = (lbs)(J, dR,
																	dz.u, dz.p,
																	R, n,
																	theta / length(dz.u), one(T) - theta;
																	shift = shift)

####################################################################################################
"""
$(TYPEDEF)

This struct is used to provide the bordered linear solver based on the Bordering Method.

$(TYPEDFIELDS)
"""
@with_kw struct BorderingBLS{S <: Union{AbstractLinearSolver, Nothing}, Ttol} <: AbstractBorderedLinearSolver
	"Linear solver used for the Bordering method."
	solver::S = nothing

	"Tolerance for checking precision"
	tol::Ttol = 1e-12

	"Check precision of the linear solve?"
	checkPrecision::Bool = false
end

# dummy constructor to simplify user passing options to continuation
BorderingBLS(ls::AbstractLinearSolver) = BorderingBLS(solver = ls)

# solve in dX, dl
# ┌                           ┐┌  ┐   ┌   ┐
# │ (shift⋅I + J)     dR      ││dX│ = │ R │
# │  ξu * dz.u'    ξp * dz.p  ││dl│   │ n │
# └                           ┘└  ┘   └   ┘
function (lbs::BorderingBLS)(  J, dR,
								dzu, dzp::T, R, n::T,
								ξu::Tξ = 1, ξp::Tξ = 1; shift::Ts = nothing)  where {T, Tξ, Ts}
	# the following parameters are used for the pseudo arc length continuation
	# ξu = θ / length(dz.u)
	# ξp = 1 - θ

	# we make this branching to avoid applying a zero shift
	if isnothing(shift)
		x1, x2, _, (it1, it2) = lbs.solver(J, R, dR)
	else
		x1, x2, _, (it1, it2) = lbs.solver(J, R, dR; a₀ = shift)
	end

	dl = (n - dot(dzu, x1) * ξu) / (dzp * ξp - dot(dzu, x2) * ξu)

	# dX = x1 .- dl .* x2
	axpy!(-dl, x2, x1)

	# we check the precision of the solution from the bordering algorithm
	# mainly for debugging purposes
	if lbs.checkPrecision
		# at this point, x2 is not used anymore, we can use it for computing the residual
		# hence x2 = J*x1 + dl*dR - R
		x2 = apply(J, x1)
		axpy!(dl, dR, x2)
		axpy!(-1, R, x2)
		if norm(x2) > lbs.tol || abs(n - ξp * dzp * dl -ξu * dot(dzu, x1)) > lbs.tol
			@warn "BorderingBLS did not achieve tolerance"
		end
	end
	return x1, dl, true, (it1, it2)
end
####################################################################################################
# this interface should work for Sparse Matrices as well as for Matrices
"""
$(TYPEDEF)
This struct is used to  provide the bordered linear solver based on inverting the full matrix.
$(TYPEDFIELDS)
"""
struct MatrixBLS{S <: Union{AbstractLinearSolver, Nothing}} <: AbstractBorderedLinearSolver
	"Linear solver used to invert the full matrix."
	solver::S
end

# dummy constructor to simplify user passing options to continuation
MatrixBLS() = MatrixBLS(nothing)

# case of a scalar additional linear equation
function (lbs::MatrixBLS)(J, dR,
						dzu, dzp::T, R::AbstractVecOrMat, n::T,
						ξu::T = T(1), ξp::T = T(1);
						shift::Ts = nothing)  where {T <: Number, S, Ts}

	if isnothing(shift)
		A = J
	else
		A = J + shift * I
	end

	A = hcat(A, dR)
	A = vcat(A, hcat((dzu .* ξu)', dzp * ξp))

	# solve the equations and return the result
	rhs = vcat(R, n)
	res = A \ rhs
	return res[1:end-1], res[end], true, 1
end

####################################################################################################
# composite type to save the bordered linear system with expression
# ┌         ┐
# │  J    a │
# │  b'   c │
# └         ┘
# It then solved using Matrix Free algorithm applied to the full operator and not just J as for MatrixFreeBLS
#
struct MatrixFreeBLSmap{Tj, Ta, Tb, Tc, Ts}
	J::Tj
	a::Ta
	b::Tb
	c::Tc
	shift::Ts
end

function (lbmap::MatrixFreeBLSmap{Tj, Ta, Tb, Tc, Ts})(x::BorderedArray{Ta, Tc}) where {Tj, Ta, Tb, Tc <: Number, Ts}
	# This implements the case where Tc is a number, ie there is one scalar constraint in the
	# bordered linear system
	out = similar(x)
	copyto!(out.u, apply(lbmap.J, x.u))
	axpy!(x.p, lbmap.a, out.u)
	if isnothing(lbmap.shift) == false
		axpy!(lbmap.shift, x.u, out.u)
	end
	out.p = dot(lbmap.b, x.u)  + lbmap.c  * x.p
	return out
end

function (lbmap::MatrixFreeBLSmap)(x::AbstractArray)
	# This implements the case where Tc is a number, ie there is one scalar constraint in the
	# bordered linear system
	out = similar(x)
	xu = @view x[1:end-1]
	xp = x[end]
	# copyto!(out.u, apply(lbmap.J, x.u))
	if isnothing(lbmap.shift)
		out[1:end-1] .= apply(lbmap.J, xu) .+ xp .* lbmap.a
	else
		out[1:end-1] .= apply(lbmap.J, xu) .+ xp .* lbmap.a .+ xu .* lbmap.shift
	end
	out[end] = dot(lbmap.b, xu)  + lbmap.c  * xp
	return out
end

"""
$(TYPEDEF)

This struct is used to  provide the bordered linear solver based a matrix free operator for the full system in `(x,p)`.

$(TYPEDFIELDS)
"""
struct MatrixFreeBLS{S <: Union{AbstractLinearSolver, Nothing}} <: AbstractBorderedLinearSolver
	"Linear solver used to solve the extended linear system"
	solver::S
	"What is the structure used to hold `(x,p)`. If `true`, this is achieved using `BorderedArray`. If `false`, a `Vector` is used."
	useBorderedArray::Bool
end

# dummy constructor to simplify user passing options to continuation
MatrixFreeBLS(useBorderedArray::Bool = true) = MatrixFreeBLS(nothing, useBorderedArray)
MatrixFreeBLS(::Nothing) = MatrixFreeBLS()
MatrixFreeBLS(S::AbstractLinearSolver) = MatrixFreeBLS(S, ~(S isa GMRESIterativeSolvers))

extractVecBLS(x::AbstractVector) = @view x[1:end-1]
extractVecBLS(x::BorderedArray)  = x.u

extractParBLS(x::AbstractVector) = x[end]
extractParBLS(x::BorderedArray)  = x.p

# We restrict to bordered systems where the added component is scalar
function (lbs::MatrixFreeBLS{S})(J, 	dR,
								dzu, 	dzp::T, R, n::T,
								ξu::Tξ = 1, ξp::Tξ = 1; shift = nothing) where {T <: Number, Tξ, S}
	~isnothing(shift) && @warn "Shift is not implemented for the bordered linear solver MatrixFreeBLS"
	linearmap = MatrixFreeBLSmap(J, dR, rmul!(copy(dzu), ξu), dzp * ξp, shift)
	# what is the vector type used?
	rhs = lbs.useBorderedArray ? BorderedArray(copy(R), n) : vcat(R, n)
	sol, cv, it = lbs.solver(linearmap, rhs)
	return extractVecBLS(sol), extractParBLS(sol), cv, it
end
####################################################################################################
# Linear Solvers based on a bordered solver
# !!!! This one is used as a linear Solver, not as a Bordered one
####################################################################################################
"""
$(TYPEDEF)

This structure is used to provide the following linear solver. To solve (1) J⋅x = rhs, one decomposes J using Matrix by blocks and then use a bordering strategy to solve (1).

$(TYPEDFIELDS)

!!! warn "Warning"
    The solver only works for `AbstractMatrix`
"""
struct LSFromBLS{Ts} <: AbstractLinearSolver
	"Linear solver used to solve the smaller linear systems."
	solver::Ts
end

LSFromBLS() = LSFromBLS(BorderingBLS(DefaultLS(useFactorization = false)))

function (l::LSFromBLS)(J, rhs)
	F = factorize(J[1:end-1, 1:end-1])
	x1, x2, flag, it = l.solver(F, Array(J[1:end-1,end]), Array(J[end,1:end-1]), J[end, end], (@view rhs[1:end-1]), rhs[end])
	return vcat(x1,x2), flag, sum(it)
end

function  (l::LSFromBLS)(J, rhs1, rhs2)
	F = factorize(J[1:end-1,1:end-1])
	x1, x2, flag1, it1 = l.solver(F, Array(J[1:end-1,end]), Array(J[end,1:end-1]), J[end, end], (@view rhs1[1:end-1]), rhs1[end])

	y1, y2, flag2, it2 = l.solver(F, Array(J[1:end-1,end]), Array(J[end,1:end-1]), J[end, end], (@view rhs2[1:end-1]), rhs2[end])

	return vcat(x1,x2), vcat(y1,y2), flag1 & flag2, (1, 1)
end
