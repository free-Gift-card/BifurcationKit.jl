using KrylovKit, ArnoldiMethod, LinearMaps, LinearAlgebra, RecursiveArrayTools
import LinearAlgebra: ldiv!, \

struct PrecPartialSchur{Ts, Tu, Tsm1, Teigen}
	S::Ts
	U::Tu
	Sm1::Tsm1
	eigenvalues::Teigen
end

function ldiv!(out, Pl::PrecPartialSchur, rhs::AbstractArray)
	########################################################
	# U * Sm1 * Ut + (I - U Ut)
	# U(Sm1 - I)Ut + I
	########################################################
	# y = (Pl.U * Pl.Sm1 * transpose(Pl.U) .+ (I - Pl.U * transpose(Pl.U))) * rhs
	y = transpose(Pl.U) * rhs
	y .= Pl.Sm1 * y .- y
	out .= rhs .+ Pl.U * y
end

function ldiv!(Pl::PrecPartialSchur, rhs::AbstractArray)
	########################################################
	# U * Sm1 * Ut + (I - U Ut)
	# U(Sm1 - I)Ut + I
	########################################################
	# y = (Pl.U * Pl.Sm1 * transpose(Pl.U) .+ (I - Pl.U * transpose(Pl.U))) * rhs
	y = transpose(Pl.U) * rhs
	y .= Pl.Sm1 * y .- y
	rhs .= rhs .+ Pl.U * y
end

function \(Pl::PrecPartialSchur, rhs::AbstractArray)
	out = similar(rhs)
	ldiv!(out, Pl, rhs)
	return out
end

"""
	PrecPartialSchurKrylovKit(J, x0, nev, which = :LM; krylovdim = max(2nev, 20), verbosity = 0)

Builds a preconditioner based on deflation of `nev` eigenvalues chosen according to `which`. A partial Schur decomposition is computed (Matrix-Free), using the package `KrylovKit.jl`, from which a projection is built. The options are similar to the ones of `EigKrylovKit()`.
"""
function PrecPartialSchurKrylovKit(J, x0, nev, which = :LM; krylovdim = max(2nev, 20), verbosity = 0)
	H, V, vals, info = KrylovKit.schursolve(J, x0, nev, which, Arnoldi(krylovdim = krylovdim, verbosity = verbosity))
	Q, S = qr(H)
	U = VectorOfArray(V) * Q
	return PrecPartialSchur(S, U, inv(S), vals)
end

"""
	PrecPartialSchurArnoldiMethod(J, N, nev, which = LM(); tol = 1e-9, kwargs...)

Builds a preconditioner based on deflation of `nev` eigenvalues chosen according to `which`. A partial Schur decomposition is computed (Matrix-Free), using the package `ArnoldiMethod.jl`, from which a projection is built. See the package `ArnoldiMethod.jl` for how to pass the proper options.
"""
function PrecPartialSchurArnoldiMethod(J, N, nev, which = LM(); tol = 1e-9, kwargs...)
	if J isa AbstractMatrix
		decomp, history = ArnoldiMethod.partialschur(J; nev = nev, tol=tol, which=which, kwargs...)
	else
		Jmap = LinearMap{Float64}(J, N, N ; ismutating = false)
		decomp, history = ArnoldiMethod.partialschur(Jmap; nev = nev, tol=tol, which=which, kwargs...)
	end
	return PrecPartialSchur(decomp.R, decomp.Q, inv(decomp.R), decomp.eigenvalues)
end

PrecPartialSchurArnoldiMethod(J::AbstractArray, nev, which = LM(); tol = 1e-9, kwargs...) = PrecPartialSchurArnoldiMethod(J, size(J)[1], nev, which ; tol = tol, kwargs...)