

#=
module Gaugefields_4D_mpi_module
    using LinearAlgebra
    import ..AbstractGaugefields_module:AbstractGaugefields,Shifted_Gaugefields,shift_U,
                        Adjoint_Gaugefields,set_wing_U!,Abstractfields,construct_staple!,clear_U!,
                        calculate_Plaquette
    import Base
    import ..Gaugefields_4D_module:Gaugefields_4D

    using MPI
    =#

#const comm = MPI.COMM_WORLD

"""
`Gaugefields_4D_nowing_mpi{NC} <: Gaugefields_4D{NC}`

MPI version of SU(N) Gauge fields in four dimensional lattice. 
"""
struct Gaugefields_4D_nowing_mpi{NC} <: Gaugefields_4D{NC}
    U::Array{ComplexF64,6}
    NX::Int64
    NY::Int64
    NZ::Int64
    NT::Int64
    NDW::Int64
    NV::Int64
    NC::Int64
    PEs::NTuple{4,Int64}
    PN::NTuple{4,Int64}
    mpiinit::Bool
    myrank::Int64
    nprocs::Int64
    myrank_xyzt::NTuple{4,Int64}
    mpi::Bool
    verbose_print::Verbose_print
    Ushifted::Array{ComplexF64,6}
    tempmatrix::Array{ComplexF64,3}
    positions::Vector{Int64}
    send_ranks::Dict{Int64,Data_sent{NC}}
    win::MPI.Win
    win_i::MPI.Win
    win_1i::MPI.Win
    countvec::Vector{Int64}
    otherranks::Vector{Int64}
    win_other::MPI.Win
    your_ranks::Matrix{Int64}
    comm::MPI.Comm


    function Gaugefields_4D_nowing_mpi(
        NC::T,
        NX::T,
        NY::T,
        NZ::T,
        NT::T,
        PEs;
        mpiinit = true,
        verbose_level = 2,
        comm = MPI.COMM_WORLD,
    ) where {T<:Integer}
        NV = NX * NY * NZ * NT
        NDW = 0
        @assert NX % PEs[1] == 0 "NX % PEs[1] should be 0. Now NX = $NX and PEs = $PEs"
        @assert NY % PEs[2] == 0 "NY % PEs[2] should be 0. Now NY = $NY and PEs = $PEs"
        @assert NZ % PEs[3] == 0 "NZ % PEs[3] should be 0. Now NZ = $NZ and PEs = $PEs"
        @assert NT % PEs[4] == 0 "NT % PEs[4] should be 0. Now NT = $NT and PEs = $PEs"

        PN = (NX ÷ PEs[1], NY ÷ PEs[2], NZ ÷ PEs[3], NT ÷ PEs[4])

        if mpiinit == false
            MPI.Init()
            mpiinit = true
        end

        #comm = MPI.COMM_WORLD

        nprocs = MPI.Comm_size(comm)
        @assert prod(PEs) == nprocs "num. of MPI process should be prod(PEs). Now nprocs = $nprocs and PEs = $PEs"
        myrank = MPI.Comm_rank(comm)

        verbose_print = Verbose_print(verbose_level, myid = myrank)

        myrank_xyzt = get_myrank_xyzt(myrank, PEs)

        #println("Hello world, I am $(MPI.Comm_rank(comm)) of $(MPI.Comm_size(comm))")

        U = zeros(
            ComplexF64,
            NC,
            NC,
            PN[1] + 2NDW,
            PN[2] + 2NDW,
            PN[3] + 2NDW,
            PN[4] + 2NDW,
        )
        Ushifted = zero(U)
        #U = Array{Array{ComplexF64,6}}(undef,4)
        #for μ=1:4
        #    U[μ] = zeros(ComplexF64,NC,NC,NX+2NDW,NY+2NDW,NZ+2NDW,NT+2NDW)
        #end
        tempmatrix = zeros(ComplexF64, NC, NC, prod(PN))
        positions = zeros(Int64, prod(PN))
        send_ranks = Dict{Int64,Data_sent{NC}}()
        mpi = true
        win = MPI.Win_create(tempmatrix, comm)
        win_i = MPI.Win_create(positions, comm)
        countvec = zeros(Int64, 1)
        win_1i = MPI.Win_create(countvec, comm)

        otherranks = zeros(Int64, nprocs)
        otherranks .= 0
        win_other = MPI.Win_create(otherranks, comm)
        your_ranks = zeros(Int64, nprocs, nprocs)


        return new{NC}(
            U,
            NX,
            NY,
            NZ,
            NT,
            NDW,
            NV,
            NC,
            Tuple(PEs),
            PN,
            mpiinit,
            myrank,
            nprocs,
            myrank_xyzt,
            mpi,
            verbose_print,
            Ushifted,
            tempmatrix,
            positions,
            send_ranks,
            win,
            win_i,
            win_1i,
            countvec,
            otherranks,
            win_other,
            your_ranks,
            comm,
        )
    end
end

function get_myrank(U::T) where {T<:Gaugefields_4D_nowing_mpi}
    return U.myrank
end

function get_myrank(U::Array{T,1}) where {T<:Gaugefields_4D_nowing_mpi}
    return U[1].myrank
end

function get_nprocs(U::T) where {T<:Gaugefields_4D_nowing_mpi}
    return U.nprocs
end

function get_nprocs(U::Array{T,1}) where {T<:Gaugefields_4D_nowing_mpi}
    return U[1].nprocs
end

function calc_rank_and_indices(x::Gaugefields_4D_nowing_mpi, ix, iy, iz, it)
    pex = (ix - 1) ÷ x.PN[1]
    ix_local = (ix - 1) % x.PN[1] + 1

    pey = (iy - 1) ÷ x.PN[2]
    iy_local = (iy - 1) % x.PN[2] + 1

    pez = (iz - 1) ÷ x.PN[3]
    iz_local = (iz - 1) % x.PN[3] + 1

    pet = (it - 1) ÷ x.PN[4]
    it_local = (it - 1) % x.PN[4] + 1
    myrank = get_myrank((pex, pey, pez, pet), x.PEs)
    return myrank, ix_local, iy_local, iz_local, it_local
end

function barrier(x::T) where {T<:Gaugefields_4D_nowing_mpi}
    #println("ba")
    MPI.Barrier(x.comm)
end

function Base.setindex!(x::Gaugefields_4D_nowing_mpi, v, i1, i2, i3, i4, i5, i6)
    error(
        "Each element can not be accessed by global index in $(typeof(x)). Use setvalue! function",
    )
    #x.U[i1,i2,i3 + x.NDW,i4 + x.NDW,i5 + x.NDW,i6 + x.NDW] = v
end

function Base.getindex(x::Gaugefields_4D_nowing_mpi, i1, i2, i3, i4, i5, i6)
    error(
        "Each element can not be accessed by global index in $(typeof(x)) Use getvalue function",
    )
    #return x.U[i1,i2,i3 .+ x.NDW,i4 .+ x.NDW,i5 .+ x.NDW,i6 .+ x.NDW]
end

function Base.setindex!(
    x::Adjoint_Gaugefields{T},
    v,
    i1,
    i2,
    i3,
    i4,
    i5,
    i6,
) where {T<:Gaugefields_4D_nowing_mpi} #U'
    error("type $(typeof(U)) has no setindex method. This type is read only.")
    #x.U[i1,i2,i3 + x.NDW,i4 + x.NDW,i5 + x.NDW,i6 + x.NDW] = v
end

function Base.getindex(
    x::Adjoint_Gaugefields{T},
    i1,
    i2,
    i3,
    i4,
    i5,
    i6,
) where {T<:Gaugefields_4D_nowing_mpi} #U'
    error(
        "Each element can not be accessed by global index in $(typeof(x)) Use getvalue function",
    )
    #return x.U[i1,i2,i3 .+ x.NDW,i4 .+ x.NDW,i5 .+ x.NDW,i6 .+ x.NDW]
end


@inline function getvalue(x::Gaugefields_4D_nowing_mpi, i1, i2, i3, i4, i5, i6)
    @inbounds return x.U[i1, i2, i3, i4, i5, i6]
end

@inline function setvalue!(x::Gaugefields_4D_nowing_mpi, v, i1, i2, i3, i4, i5, i6)
    @inbounds x.U[i1, i2, i3, i4, i5, i6] = v
end





function identityGaugefields_4D_nowing_mpi(
    NC,
    NX,
    NY,
    NZ,
    NT,
    PEs;
    mpiinit = true,
    verbose_level = 2,
    randomnumber = "Random",
    comm = MPI.COMM_WORLD,
)
    U = Gaugefields_4D_nowing_mpi(
        NC,
        NX,
        NY,
        NZ,
        NT,
        PEs,
        mpiinit = mpiinit,
        verbose_level = verbose_level,
        comm = comm,
    )
    v = 1

    for it = 1:U.PN[4]
        for iz = 1:U.PN[3]
            for iy = 1:U.PN[2]
                for ix = 1:U.PN[1]
                    @simd for ic = 1:NC
                        setvalue!(U, v, ic, ic, ix, iy, iz, it)
                    end
                end
            end
        end
    end
    #println("setwing")
    set_wing_U!(U)

    return U
end

function randomGaugefields_4D_nowing_mpi(
    NC,
    NX,
    NY,
    NZ,
    NT,
    PEs;
    mpiinit = true,
    verbose_level = 2,
    randomnumber = "Random",
    comm = MPI.COMM_WORLD,
)
    U = Gaugefields_4D_nowing_mpi(
        NC,
        NX,
        NY,
        NZ,
        NT,
        PEs,
        mpiinit = mpiinit,
        verbose_level = verbose_level,
        comm = comm,
    )
    v = 1

    for it = 1:U.PN[4]
        for iz = 1:U.PN[3]
            for iy = 1:U.PN[2]
                for ix = 1:U.PN[1]
                    for jc = 1:NC
                        @simd for ic = 1:NC
                            v = rand() - 0.5 + im * (rand() - 0.5)
                            setvalue!(U, v, ic, jc, ix, iy, iz, it)
                        end
                    end
                end
            end
        end
    end
    #println("setwing")
    normalize_U!(U)
    set_wing_U!(U)

    return U
end

function clear_U!(U::Gaugefields_4D_nowing_mpi{NC}) where {NC}
    for it = 1:U.PN[4]
        for iz = 1:U.PN[3]
            for iy = 1:U.PN[2]
                for ix = 1:U.PN[1]
                    for jc = 1:NC
                        @simd for ic = 1:NC
                            v = 0
                            @inbounds setvalue!(U, v, ic, jc, ix, iy, iz, it)
                            #@inbounds Uμ[k1,k2,ix,iy,iz,it] = 0
                        end
                    end
                end
            end
        end
    end
    set_wing_U!(U)
end

function clear_U!(U::Gaugefields_4D_nowing_mpi{NC}, iseven::Bool) where {NC}
    for it = 1:U.PN[4]
        for iz = 1:U.PN[3]
            for iy = 1:U.PN[2]
                for ix = 1:U.PN[1]
                    evenodd = ifelse((ix + iy + iz + it) % 2 == 0, true, false)
                    if evenodd == iseven
                        for k2 = 1:NC
                            for k1 = 1:NC
                                v = 0
                                @inbounds setvalue!(U, v, k1, k2, ix, iy, iz, it)
                            end
                        end
                    end
                end
            end
        end
    end
    set_wing_U!(U)
end

function clear_U!(
    U::Gaugefields_4D_nowing_mpi{NC},
    filternumber::N,
    filterindex::N,
) where {NC,N<:Integer}
    for it = 1:U.PN[4]
        for iz = 1:U.PN[3]
            for iy = 1:U.PN[2]
                for ix = 1:U.PN[1]
                    filter = ((ix + iy + iz + it)) % filternumber
                    #evenodd = ifelse( (ix+iy+iz+it) % filternumber ==0, true,false)
                    if filter == filterindex
                        for k2 = 1:NC
                            for k1 = 1:NC
                                v = 0
                                @inbounds setvalue!(U, v, k1, k2, ix, iy, iz, it)
                            end
                        end
                    end
                end
            end
        end
    end
    set_wing_U!(U)
end

function add_U!(c::Gaugefields_4D_nowing_mpi{NC}, a::T1) where {NC,T1<:Abstractfields}
    for it = 1:c.PN[4]
        for iz = 1:c.PN[3]
            for iy = 1:c.PN[2]
                for ix = 1:c.PN[1]

                    for k2 = 1:NC
                        @simd for k1 = 1:NC
                            av = getvalue(a, k1, k2, ix, iy, iz, it)
                            cv = getvalue(c, k1, k2, ix, iy, iz, it)
                            v = cv + av
                            setvalue!(c, v, k1, k2, ix, iy, iz, it)
                            #c[k1,k2,ix,iy,iz,it] += a[k1,k2,ix,iy,iz,it]
                        end
                    end
                end
            end
        end
    end
    #set_wing_U!(c)
end

function add_U!(
    c::Gaugefields_4D_nowing_mpi{NC},
    a::T1,
    iseven::Bool,
) where {NC,T1<:Abstractfields}
    @inbounds for it = 1:c.PN[4]
        for iz = 1:c.PN[3]
            for iy = 1:c.PN[2]
                for ix = 1:c.PN[1]
                    evenodd = ifelse((ix + iy + iz + it) % 2 == 0, true, false)
                    if evenodd == iseven
                        for k2 = 1:NC
                            @simd for k1 = 1:NC
                                av = getvalue(a, k1, k2, ix, iy, iz, it)
                                cv = getvalue(c, k1, k2, ix, iy, iz, it)
                                v = cv + av
                                setvalue!(c, v, k1, k2, ix, iy, iz, it)
                                #c[k1,k2,ix,iy,iz,it] += a[k1,k2,ix,iy,iz,it]
                            end
                        end
                    end
                end
            end
        end
    end
    #set_wing_U!(c)
end

function add_U!(
    c::Gaugefields_4D_nowing_mpi{NC},
    α::N,
    a::T1,
) where {NC,T1<:Abstractfields,N<:Number}
    #@inbounds for i=1:length(c.U)
    #    c.U[i] += α*a.U[i]
    #end
    #return 

    NT = c.NT
    NZ = c.NZ
    NY = c.NY
    NX = c.NX
    @inbounds for it = 1:c.PN[4]
        for iz = 1:c.PN[3]
            for iy = 1:c.PN[2]
                for ix = 1:c.PN[1]
                    for k2 = 1:NC
                        @simd for k1 = 1:NC
                            v =
                                getvalue(c, k1, k2, ix, iy, iz, it) +
                                α * getvalue(a, k1, k2, ix, iy, iz, it)
                            setvalue!(c, v, k1, k2, ix, iy, iz, it)
                            #c[k1,k2,ix,iy,iz,it] += α*a[k1,k2,ix,iy,iz,it]
                        end
                    end
                end
            end
        end
    end
    #set_wing_U!(c)
end

function substitute_U!(
    a::Array{T1,1},
    b::Array{T2,1},
) where {T1<:Gaugefields_4D_nowing_mpi,T2<:Gaugefields_4D_nowing_mpi}
    for μ = 1:4
        substitute_U!(a[μ], b[μ])
    end
end

function substitute_U!(
    a::Array{T1,1},
    b::Array{T2,1},
    iseven::Bool,
) where {T1<:Gaugefields_4D_nowing_mpi,T2<:Gaugefields_4D_nowing_mpi}
    for μ = 1:4
        substitute_U!(a[μ], b[μ], iseven)
    end
end


function substitute_U!(
    U::Gaugefields_4D_nowing_mpi{NC},
    b::T2,
) where {NC,T2<:Abstractfields}
    for it = 1:U.PN[4]
        for iz = 1:U.PN[3]
            for iy = 1:U.PN[2]
                for ix = 1:U.PN[1]
                    for k2 = 1:NC
                        for k1 = 1:NC
                            v = getvalue(b, k1, k2, ix, iy, iz, it)
                            #v = b[k1,k2,ix,iy,iz,it]
                            @inbounds setvalue!(U, v, k1, k2, ix, iy, iz, it)
                        end
                    end
                end
            end
        end
    end
    set_wing_U!(U)

end


function substitute_U!(
    U::Gaugefields_4D_nowing_mpi{NC},
    b::T2,
    iseven::Bool,
) where {NC,T2<:Abstractfields}
    for it = 1:U.PN[4]
        for iz = 1:U.PN[3]
            for iy = 1:U.PN[2]
                for ix = 1:U.PN[1]
                    evenodd = ifelse((ix + iy + iz + it) % 2 == 0, true, false)
                    if evenodd == iseven
                        for k2 = 1:NC
                            for k1 = 1:NC
                                v = getvalue(b, k1, k2, ix, iy, iz, it)
                                #v = b[k1,k2,ix,iy,iz,it]
                                @inbounds setvalue!(U, v, k1, k2, ix, iy, iz, it)
                            end
                        end
                    end
                end
            end
        end
    end
    set_wing_U!(U)

end


function map_U!(
    U::Gaugefields_4D_nowing_mpi{NC},
    f!::Function,
    V::Gaugefields_4D_nowing_mpi{NC},
    iseven::Bool,
) where {NC}

    A = zeros(ComplexF64, NC, NC)
    B = zeros(ComplexF64, NC, NC)
    for it = 1:U.PN[4]
        for iz = 1:U.PN[3]
            for iy = 1:U.PN[2]
                for ix = 1:U.PN[1]
                    evenodd = ifelse((ix + iy + iz + it) % 2 == 0, true, false)
                    if evenodd == iseven
                        for k2 = 1:NC
                            for k1 = 1:NC

                                A[k1, k2] = getvalue(V, k1, k2, ix, iy, iz, it)
                                B[k1, k2] = getvalue(U, k1, k2, ix, iy, iz, it)
                            end
                        end
                        f!(B, A)
                        for k2 = 1:NC
                            for k1 = 1:NC
                                v = B[k1, k2]
                                setvalue!(U, v, k1, k2, ix, iy, iz, it)
                                #U[k1,k2,ix,iy,iz,it] = B[k1,k2]
                            end
                        end
                    end
                end
            end
        end
    end
    set_wing_U!(U)
end

function map_U!(
    U::Gaugefields_4D_nowing_mpi{NC},
    f!::Function,
    V::Gaugefields_4D_nowing_mpi{NC},
) where {NC}

    A = zeros(ComplexF64, NC, NC)
    B = zeros(ComplexF64, NC, NC)
    for it = 1:U.PN[4]
        for iz = 1:U.PN[3]
            for iy = 1:U.PN[2]
                for ix = 1:U.PN[1]
                    #evenodd = ifelse((ix + iy + iz + it) % 2 == 0, true, false)
                    #if evenodd == iseven
                        for k2 = 1:NC
                            for k1 = 1:NC

                                A[k1, k2] = getvalue(V, k1, k2, ix, iy, iz, it)
                                B[k1, k2] = getvalue(U, k1, k2, ix, iy, iz, it)
                            end
                        end
                        f!(B, A)
                        for k2 = 1:NC
                            for k1 = 1:NC
                                v = B[k1, k2]
                                setvalue!(U, v, k1, k2, ix, iy, iz, it)
                                #U[k1,k2,ix,iy,iz,it] = B[k1,k2]
                            end
                        end
                    #end
                end
            end
        end
    end
    set_wing_U!(U)
end

function map_U_sequential!(U::Gaugefields_4D_nowing_mpi{NC}, f!::Function, Uin) where {NC}
    error("The function map_U_sequential! can not be used with MPI")
end



struct Shifted_Gaugefields_4D_mpi_nowing{NC} <: Shifted_Gaugefields{NC,4}
    parent::Gaugefields_4D_nowing_mpi{NC}
    #parent::T
    shift::NTuple{4,Int8}
    NX::Int64
    NY::Int64
    NZ::Int64
    NT::Int64
    NDW::Int64

    #function Shifted_Gaugefields(U::T,shift,Dim) where {T <: AbstractGaugefields}
    function Shifted_Gaugefields_4D_mpi_nowing(
        U::Gaugefields_4D_nowing_mpi{NC},
        shift,
    ) where {NC}
        #shifted_U!(U,shift)
        shifted_U_improved!(U, shift)

        return new{NC}(U, shift, U.NX, U.NY, U.NZ, U.NT, U.NDW)
    end
end

function shifted_U_improved_zeroshift!(U::Gaugefields_4D_nowing_mpi{NC}) where {NC}
    for it = 1:U.PN[4]
        for iz = 1:U.PN[3]
            for iy = 1:U.PN[2]
                for ix = 1:U.PN[1]
                    for jc = 1:NC
                        for ic = 1:NC
                            v = getvalue(U, ic, jc, ix, iy, iz, it)
                            U.Ushifted[ic, jc, ix, iy, iz, it] = v
                        end
                    end

                end
            end
        end
    end
end

function update_sent_data!(
    send_ranks,
    N,
    ix,
    iy,
    iz,
    it,
    ix_shifted,
    iy_shifted,
    iz_shifted,
    it_shifted,
    PEs,
    myrank_xyzt,
    xP,
    yP,
    zP,
    tP,
    U::Gaugefields_4D_nowing_mpi{NC},
) where {NC}
    tempmatrix_mini = view(U.tempmatrix, 1:NC, 1:NC, 1)


    px = myrank_xyzt[1] + xP
    while px >= PEs[1]
        px += -PEs[1]
    end
    while px < 0
        px += PEs[1]
    end

    py = myrank_xyzt[2] + yP
    while py >= PEs[2]
        py += -PEs[2]
    end
    while py < 0
        py += PEs[2]
    end

    pz = myrank_xyzt[3] + zP
    while pz >= PEs[3]
        pz += -PEs[3]
    end
    while pz < 0
        pz += PEs[3]
    end

    pt = myrank_xyzt[4] + tP
    while pt >= PEs[4]
        pt += -PEs[4]
    end
    while pt < 0
        pt += PEs[4]
    end

    #=
    px += ifelse(px >= PEs[1],-PEs[1],0) 
    px += ifelse(px < 0,+PEs[1],0) 
    py = myrank_xyzt[2] + yP
    py += ifelse(py >= PEs[2],-PEs[2],0) 
    py += ifelse(py < 0,+PEs[2],0) 
    pz = myrank_xyzt[3] + zP
    pz += ifelse(pz >= PEs[3],-PEs[3],0) 
    pz += ifelse(pz < 0,+PEs[3],0) 
    pt = myrank_xyzt[4] + tP
    pt += ifelse(pt >= PEs[4],-PEs[4],0) 
    pt += ifelse(pt < 0,+PEs[4],0) 
    =#

    myrank_xyzt_send = (px, py, pz, pt)

    myrank_send = get_myrank(myrank_xyzt_send, PEs)
    #println("send ",myrank_send)

    #=
    for rank=0:get_nprocs(U)
        if rank == get_myrank(U)
            if myrank_send == rank
                println("myrank = $rank, ",myrank_xyzt_send)
                println("myrank_xyzt $myrank_xyzt")
                println("(xP,yP,zP,tP) ",(xP,yP,zP,tP))
            println("send ",myrank_send)
            println("(ix,iy,iz,it) ",(ix,iy,iz,it))
            println("(ix_shifted,iy_shifted,iz_shifted,it_shifted) ",(ix_shifted,iy_shifted,iz_shifted,it_shifted))
            end


        end
        barrier(U)
    end
    =#


    for jc = 1:NC
        @simd for ic = 1:NC
            #v = getvalue(U,ic,jc,ix_shifted_back,iy_shifted_back,iz_shifted_back,it_shifted_back)
            #v = getvalue(U,ic,jc,ix_shifted,iy_shifted,iz_shifted,it_shifted)
            v = getvalue(U, ic, jc, ix, iy, iz, it)
            tempmatrix_mini[ic, jc] = v
        end
    end
    #disp = ((((it-1)*U.PN[3] + iz-1)*U.PN[2] + iy-1)*U.PN[1] + ix-1)*NC*NC
    #disp = ((((it_shifted-1)*U.PN[3] + iz_shifted-1)*U.PN[2] + iy_shifted-1)*U.PN[1] + ix_shifted-1)*NC*NC
    #println(myrank_send)
    disp =
        (((it_shifted - 1) * U.PN[3] + iz_shifted - 1) * U.PN[2] + iy_shifted - 1) *
        U.PN[1] + ix_shifted


    if haskey(send_ranks, myrank_send)
    else
        send_ranks[myrank_send] = Data_sent(N, NC)
    end
    send_ranks[myrank_send].count += 1
    send_ranks[myrank_send].data[:, :, send_ranks[myrank_send].count] .= tempmatrix_mini
    send_ranks[myrank_send].positions[send_ranks[myrank_send].count] = disp

end



function shifted_U_improved_xshift!(U::Gaugefields_4D_nowing_mpi{NC}, shift) where {NC}
    yP = 0
    zP = 0
    tP = 0

    PEs = U.PEs
    PN = U.PN
    myrank = U.myrank
    myrank_xyzt = U.myrank_xyzt
    myrank_xyzt_send = U.myrank_xyzt
    #tempmatrix = zeros(ComplexF64,NC,NC)#view(U.tempmatrix,1:NC,1:NC,1) #zeros(ComplexF64,NC,NC)
    #tempmatrix_mini = view(U.tempmatrix,1:NC,1:NC,1) 

    lat_size = size(U.Ushifted)
    send_ranks = U.send_ranks
    empty!(send_ranks)
    # Dict{Int64,Data_sent}()
    N = prod(U.PN)

    for it = 1:U.PN[4]
        it_shifted = it
        for iz = 1:U.PN[3]
            iz_shifted = iz
            for iy = 1:U.PN[2]
                iy_shifted = iy
                for ix = 1:U.PN[1]
                    ix_shifted = ix - shift[1]
                    ix_global = myrank_xyzt[1] * U.PN[1] + ix
                    ix_shifted_global = ix_global - shift[1]
                    #if myrank_xyzt[1] == 0
                    while ix_shifted_global < 1
                        ix_shifted += U.NX
                        ix_shifted_global += U.NX
                    end
                    #ix_shifted += ifelse(ix_shifted < 1,U.NX,0)
                    #end
                    #if myrank_xyzt[1] == PEs[1]-1
                    while ix_shifted_global > U.NX
                        ix_shifted += -U.NX
                        ix_shifted_global += -U.NX
                    end

                    if ix_shifted <= 0
                        xP = div(ix_shifted, U.PN[1]) - 1
                    else
                        xP = div(ix_shifted - 1, U.PN[1])
                    end


                    while ix_shifted < 1
                        ix_shifted += U.PN[1]
                    end
                    while ix_shifted > U.PN[1]
                        ix_shifted += -U.PN[1]
                    end


                    if xP == 0
                        for jc = 1:NC
                            @simd for ic = 1:NC
                                #v = getvalue(U,ic,jc,ix_shifted,iy_shifted,iz_shifted,it_shifted)
                                #U.Ushifted[ic,jc,ix,iy,iz,it] = v
                                v = getvalue(U, ic, jc, ix, iy, iz, it)
                                U.Ushifted[
                                    ic,
                                    jc,
                                    ix_shifted,
                                    iy_shifted,
                                    iz_shifted,
                                    it_shifted,
                                ] = v

                            end
                        end
                    else
                        update_sent_data!(
                            send_ranks,
                            N,
                            ix,
                            iy,
                            iz,
                            it,
                            ix_shifted,
                            iy_shifted,
                            iz_shifted,
                            it_shifted,
                            PEs,
                            myrank_xyzt,
                            xP,
                            yP,
                            zP,
                            tP,
                            U,
                        )

                    end
                end
            end
        end
    end

    mpi_updates_U!(U, send_ranks)

end

function shifted_U_improved_yshift!(U::Gaugefields_4D_nowing_mpi{NC}, shift) where {NC}
    xP = 0
    zP = 0
    tP = 0

    PEs = U.PEs
    PN = U.PN
    myrank = U.myrank
    myrank_xyzt = U.myrank_xyzt
    myrank_xyzt_send = U.myrank_xyzt
    #tempmatrix = zeros(ComplexF64,NC,NC)#view(U.tempmatrix,1:NC,1:NC,1) #zeros(ComplexF64,NC,NC)
    #tempmatrix_mini = view(U.tempmatrix,1:NC,1:NC,1) 

    lat_size = size(U.Ushifted)
    send_ranks = U.send_ranks
    empty!(send_ranks)
    # Dict{Int64,Data_sent}()
    N = prod(U.PN)

    for it = 1:U.PN[4]
        it_shifted = it
        for iz = 1:U.PN[3]
            iz_shifted = iz
            for iy = 1:U.PN[2]
                iy_shifted = iy - shift[2]
                iy_global = myrank_xyzt[2] * U.PN[2] + iy
                iy_shifted_global = iy_global - shift[2]
                #if myrank_xyzt[2] == 0
                while iy_shifted_global < 1
                    iy_shifted += U.NY
                    iy_shifted_global += U.NY
                end

                #iy_shifted += ifelse(iy_shifted < 1,U.NY,0)
                #end
                #if myrank_xyzt[2] == PEs[2]-1
                while iy_shifted_global > U.NY
                    iy_shifted += -U.NY
                    iy_shifted_global += -U.NY
                end

                if iy_shifted <= 0
                    yP = div(iy_shifted, U.PN[2]) - 1
                else
                    yP = div(iy_shifted - 1, U.PN[2])
                end


                while iy_shifted < 1
                    iy_shifted += U.PN[2]
                end
                while iy_shifted > U.PN[2]
                    iy_shifted += -U.PN[2]
                end

                for ix = 1:U.PN[1]
                    ix_shifted = ix

                    if yP == 0
                        for jc = 1:NC
                            @simd for ic = 1:NC
                                #v = getvalue(U,ic,jc,ix_shifted,iy_shifted,iz_shifted,it_shifted)
                                #U.Ushifted[ic,jc,ix,iy,iz,it] = v
                                v = getvalue(U, ic, jc, ix, iy, iz, it)
                                U.Ushifted[
                                    ic,
                                    jc,
                                    ix_shifted,
                                    iy_shifted,
                                    iz_shifted,
                                    it_shifted,
                                ] = v

                            end
                        end
                    else
                        update_sent_data!(
                            send_ranks,
                            N,
                            ix,
                            iy,
                            iz,
                            it,
                            ix_shifted,
                            iy_shifted,
                            iz_shifted,
                            it_shifted,
                            PEs,
                            myrank_xyzt,
                            xP,
                            yP,
                            zP,
                            tP,
                            U,
                        )

                    end
                end
            end
        end
    end

    mpi_updates_U!(U, send_ranks)

end


function shifted_U_improved_zshift!(U::Gaugefields_4D_nowing_mpi{NC}, shift) where {NC}
    xP = 0
    yP = 0
    tP = 0

    PEs = U.PEs
    PN = U.PN
    myrank = U.myrank
    myrank_xyzt = U.myrank_xyzt
    myrank_xyzt_send = U.myrank_xyzt
    #tempmatrix = zeros(ComplexF64,NC,NC)#view(U.tempmatrix,1:NC,1:NC,1) #zeros(ComplexF64,NC,NC)
    #tempmatrix_mini = view(U.tempmatrix,1:NC,1:NC,1) 

    lat_size = size(U.Ushifted)
    send_ranks = U.send_ranks
    empty!(send_ranks)
    # Dict{Int64,Data_sent}()
    N = prod(U.PN)

    for it = 1:U.PN[4]
        it_shifted = it
        for iz = 1:U.PN[3]
            iz_shifted = iz - shift[3]
            iz_global = myrank_xyzt[3] * U.PN[3] + iz
            iz_shifted_global = iz_global - shift[3]
            #if myrank_xyzt[3] == 0
            while iz_shifted_global < 1
                iz_shifted += U.NZ
                iz_shifted_global += U.NZ
            end
            #iz_shifted += ifelse(iz_shifted < 1,U.NZ,0)
            #end
            #if myrank_xyzt[3] == PEs[3]-1
            while iz_shifted_global > U.NZ
                iz_shifted += -U.NZ
                iz_shifted_global += -U.NZ
            end

            if iz_shifted <= 0
                zP = div(iz_shifted, U.PN[3]) - 1
            else
                zP = div(iz_shifted - 1, U.PN[3])
            end



            while iz_shifted < 1
                iz_shifted += U.PN[3]
            end
            while iz_shifted > U.PN[3]
                iz_shifted += -U.PN[3]
            end
            for iy = 1:U.PN[2]
                iy_shifted = iy

                for ix = 1:U.PN[1]
                    ix_shifted = ix

                    if zP == 0
                        for jc = 1:NC
                            @simd for ic = 1:NC
                                #v = getvalue(U,ic,jc,ix_shifted,iy_shifted,iz_shifted,it_shifted)
                                #U.Ushifted[ic,jc,ix,iy,iz,it] = v
                                v = getvalue(U, ic, jc, ix, iy, iz, it)
                                U.Ushifted[
                                    ic,
                                    jc,
                                    ix_shifted,
                                    iy_shifted,
                                    iz_shifted,
                                    it_shifted,
                                ] = v

                            end
                        end
                    else
                        update_sent_data!(
                            send_ranks,
                            N,
                            ix,
                            iy,
                            iz,
                            it,
                            ix_shifted,
                            iy_shifted,
                            iz_shifted,
                            it_shifted,
                            PEs,
                            myrank_xyzt,
                            xP,
                            yP,
                            zP,
                            tP,
                            U,
                        )

                    end
                end
            end
        end
    end

    mpi_updates_U!(U, send_ranks)


end

function shifted_U_improved_tshift!(U::Gaugefields_4D_nowing_mpi{NC}, shift) where {NC}
    xP = 0
    yP = 0
    zP = 0

    PEs = U.PEs
    PN = U.PN
    myrank = U.myrank
    myrank_xyzt = U.myrank_xyzt
    myrank_xyzt_send = U.myrank_xyzt
    #tempmatrix = zeros(ComplexF64,NC,NC)#view(U.tempmatrix,1:NC,1:NC,1) #zeros(ComplexF64,NC,NC)
    #tempmatrix_mini = view(U.tempmatrix,1:NC,1:NC,1) 

    lat_size = size(U.Ushifted)
    send_ranks = U.send_ranks
    empty!(send_ranks)
    # Dict{Int64,Data_sent}()
    N = prod(U.PN)

    for it = 1:U.PN[4]
        it_shifted = it - shift[4]
        it_global = myrank_xyzt[4] * U.PN[4] + it
        it_shifted_global = it_global - shift[4]
        #if myrank_xyzt[4] == 0
        while it_shifted_global < 1
            it_shifted += U.NT
            it_shifted_global += U.NT
        end
        #it_shifted += ifelse(it_shifted < 1,U.NT,0)
        #end  
        #if myrank_xyzt[4] == PEs[4]-1
        while it_shifted_global > U.NT
            it_shifted += -U.NT
            it_shifted_global += -U.NT
        end

        if it_shifted <= 0
            tP = div(it_shifted, U.PN[4]) - 1
        else
            tP = div(it_shifted - 1, U.PN[4])
        end
        #if tP < 0 
        #    println("it_shifted $it_shifted tP = $tP")
        #end


        #it_shifted += ifelse(it_shifted < 1,U.PN[4],0)
        while it_shifted < 1
            it_shifted += U.PN[4]
        end
        while it_shifted > U.PN[4]
            it_shifted += -U.PN[4]
        end

        for iz = 1:U.PN[3]
            iz_shifted = iz

            for iy = 1:U.PN[2]
                iy_shifted = iy

                for ix = 1:U.PN[1]
                    ix_shifted = ix

                    if tP == 0
                        @inbounds for jc = 1:NC
                            @simd for ic = 1:NC
                                #v = getvalue(U,ic,jc,ix_shifted,iy_shifted,iz_shifted,it_shifted)
                                #U.Ushifted[ic,jc,ix,iy,iz,it] = v
                                v = getvalue(U, ic, jc, ix, iy, iz, it)
                                U.Ushifted[
                                    ic,
                                    jc,
                                    ix_shifted,
                                    iy_shifted,
                                    iz_shifted,
                                    it_shifted,
                                ] = v

                            end
                        end
                    else
                        update_sent_data!(
                            send_ranks,
                            N,
                            ix,
                            iy,
                            iz,
                            it,
                            ix_shifted,
                            iy_shifted,
                            iz_shifted,
                            it_shifted,
                            PEs,
                            myrank_xyzt,
                            xP,
                            yP,
                            zP,
                            tP,
                            U,
                        )

                    end
                end
            end
        end
    end

    mpi_updates_U!(U, send_ranks)


end


function mpi_updates_U_1data!(U::Gaugefields_4D_nowing_mpi{NC}, send_ranks) where {NC}
    if length(send_ranks) != 0
        #=
        for rank=0:get_nprocs(U)
            if rank == get_myrank(U)
                println("myrank = ",myrank)
                for (key,value) in send_ranks
                    println(key,"\t",value.count)
                end
            end
            barrier(U)
        end
        =#
        tempmatrix = U.tempmatrix #zeros(ComplexF64,NC,NC,N)
        #tempmatrix = zeros(ComplexF64,NC,NC,N)
        positions = U.positions

        win = U.win
        #@time win = MPI.Win_create(tempmatrix,comm)
        #println(typeof(win))
        #Isend Irecv
        MPI.Win_fence(0, win)

        for (myrank_send, value) in send_ranks
            count = value.count
            MPI.Put(value.data[:, :, 1:count], myrank_send, win)
        end

        MPI.Win_fence(0, win)
        #MPI.free(win)

        win_i = U.win_i#MPI.Win_create(positions,comm)
        MPI.Win_fence(0, win_i)

        for (myrank_send, value) in send_ranks
            count = value.count
            MPI.Put(value.positions[1:count], myrank_send, win_i)
        end

        MPI.Win_fence(0, win_i)
        #MPI.free(win_i)

        countvec = U.countvec#zeros(Int64,1)
        win_c = U.win_1i
        #win_c = MPI.Win_create(countvec,comm)
        MPI.Win_fence(0, win_c)

        for (myrank_send, value) in send_ranks
            count = value.count
            MPI.Put(Int64[count], myrank_send, win_c)
        end

        MPI.Win_fence(0, win_c)
        #MPI.free(win_c)

        count = countvec[1]



        #=
        for rank=0:get_nprocs(U)
            if rank == get_myrank(U)
                println("myrank = ",myrank)
                for position in positions[1:count]
                    println(position)
                end
            end
            barrier(U)
        end
        =#

        for i = 1:count
            position = positions[i]
            for jc = 1:NC
                for ic = 1:NC
                    ii = ((position - 1) * NC + jc - 1) * NC + ic
                    U.Ushifted[ii] = tempmatrix[ic, jc, i]
                end
            end
            #println(position)
        end

        #error("in shiftdU")
    end
end


const printdata = false

function mpi_updates_U_moredata!(U::Gaugefields_4D_nowing_mpi{NC}, send_ranks) where {NC}




    otherranks = U.otherranks
    win_other = U.win_other

    MPI.Win_fence(0, win_other)
    myrank = get_myrank(U)
    nprocs = get_nprocs(U)
    for (myrank_send, value) in send_ranks
        count = value.count
        MPI.Put(Int64[count], myrank_send, myrank, win_other)
    end
    MPI.Win_fence(0, win_other)


    tempmatrix = U.tempmatrix #zeros(ComplexF64,NC,NC,N)
    #tempmatrix = zeros(ComplexF64,NC,NC,N)
    positions = U.positions

    win = U.win
    #@time win = MPI.Win_create(tempmatrix,comm)
    #println(typeof(win))
    #Isend Irecv

    win_i = U.win_i#MPI.Win_create(positions,comm)

    win_c = U.win_1i
    #win_c = MPI.Win_create(countvec,comm)


    countvec = U.countvec#zeros(Int64,1)

    your_ranks = U.your_ranks #zeros(Int64,nprocs,nprocs)
    your_ranks .= -1

    MPI.Win_fence(0, win_other)
    icount = 0
    for (myrank_send, value) in send_ranks
        icount += 1
        MPI.Get(view(your_ranks, 1:nprocs, icount), myrank_send, win_other)
    end
    MPI.Win_fence(0, win_other)




    MPI.Win_fence(0, win)
    MPI.Win_fence(0, win_i)
    MPI.Win_fence(0, win_c)

    icount = 0
    for (myrank_send, value) in send_ranks
        count = value.count
        icount += 1
        disp = 0
        for irank = 1:myrank
            if your_ranks[irank, icount] != -1
                disp += your_ranks[irank, icount]
            end
        end


        MPI.Put(value.positions[1:count], myrank_send, disp, win_i)
        MPI.Put(value.data[:, :, 1:count], myrank_send, disp * NC * NC, win)
    end


    MPI.Win_fence(0, win)
    MPI.Win_fence(0, win_i)
    MPI.Win_fence(0, win_c)

    your_ranks .= -1

    totaldatanum = sum(otherranks)


    for i = 1:totaldatanum
        position = positions[i]
        for jc = 1:NC
            for ic = 1:NC
                ii = ((position - 1) * NC + jc - 1) * NC + ic
                U.Ushifted[ii] = tempmatrix[ic, jc, i]
            end
        end
        #println(position)
    end

    otherranks .= 0

end

function mpi_updates_U!(U::Gaugefields_4D_nowing_mpi{NC}, send_ranks) where {NC}
    if length(send_ranks) != 0

        val = MPI.Allreduce(length(send_ranks), +, U.comm) ÷ get_nprocs(U)

        #=
        for rank=0:get_nprocs(U)
            if rank == get_myrank(U)
                println("length = ",val,"\t")
                println("myrank = ",rank," length = $(length(send_ranks))")
            end
            barrier(U)
        end
        =#

        mpi_updates_U_moredata!(U, send_ranks)
        return

        if val == 1
            mpi_updates_U_1data!(U, send_ranks)
        else
            mpi_updates_U_moredata!(U, send_ranks)
        end
        return

        if length(send_ranks) == 1
            mpi_updates_U_1data!(U, send_ranks)
            barrier(U)
            return
        else
            mpi_updates_U_moredata!(U, send_ranks)
            barrier(U)
            return
        end

        return


        for rank = 0:get_nprocs(U)
            if rank == get_myrank(U)
                println("myrank = ", rank, " length = $(length(send_ranks))")
                for (key, value) in send_ranks
                    println(key, "\t", value.count)
                end
                for i = 1:get_nprocs(U)
                    println("other ", otherranks[i])
                end
                for i = 1:get_nprocs(U)
                    println("my data ", your_ranks[i])
                end
                #println("I have ",)
            end
            barrier(U)
        end
        otherranks .= 0

        for (myrank_send, value) in send_ranks
            count = value.count
            #count = value.count
            MPI.Put(Int64[count], myrank_send, win_c)

            # count = value.count
            MPI.Put(value.positions[1:count], myrank_send, win_i)
            MPI.Put(value.data[:, :, 1:count], myrank_send, win)

        end

        MPI.Win_fence(0, win)
        MPI.Win_fence(0, win_i)
        MPI.Win_fence(0, win_c)

        count = countvec[1]

        for i = 1:count
            position = positions[i]
            for jc = 1:NC
                for ic = 1:NC
                    ii = ((position - 1) * NC + jc - 1) * NC + ic
                    U.Ushifted[ii] = tempmatrix[ic, jc, i]
                end
            end
            #println(position)
        end

        #MPI.free(win)

        #=



        #for (myrank_send,value) in send_ranks
        #    count = value.count
        #    MPI.Put(value.positions[1:count], myrank_send,win_i)
        #end


        #MPI.free(win_i)

        countvec = U.countvec#zeros(Int64,1)


        for (myrank_send,value) in send_ranks
            count = value.count
            MPI.Put(Int64[count], myrank_send,win_c)
        end


        #MPI.free(win_c)

        count = countvec[1]



        #=
        for rank=0:get_nprocs(U)
            if rank == get_myrank(U)
                println("myrank = ",myrank)
                for position in positions[1:count]
                    println(position)
                end
            end
            barrier(U)
        end
        =#

        for i = 1:count
            position = positions[i]
            for jc = 1:NC
                for ic= 1:NC
                    ii = ((position-1)*NC + jc-1)*NC + ic
                    U.Ushifted[ii] = tempmatrix[ic,jc,i]
                end
            end
            #println(position)
        end

        =#

        #error("in shiftdU")
    end
end




function shifted_U_improved!(U::Gaugefields_4D_nowing_mpi{NC}, shift) where {NC}
    if shift == (0, 0, 0, 0)
        shifted_U_improved_zeroshift!(U)
        return




    elseif shift[1] != 0 && shift[2] == 0 && shift[3] == 0 && shift[4] == 0
        shifted_U_improved_xshift!(U, shift)
        return
    elseif shift[1] == 0 && shift[2] != 0 && shift[3] == 0 && shift[4] == 0
        shifted_U_improved_yshift!(U, shift)
        return
    elseif shift[1] == 0 && shift[2] == 0 && shift[3] != 0 && shift[4] == 0
        shifted_U_improved_zshift!(U, shift)
        return
    elseif shift[1] == 0 && shift[2] == 0 && shift[3] == 0 && shift[4] != 0
        shifted_U_improved_tshift!(U, shift)
        return


    end



    PEs = U.PEs
    PN = U.PN
    myrank = U.myrank
    myrank_xyzt = U.myrank_xyzt
    myrank_xyzt_send = U.myrank_xyzt
    #tempmatrix = zeros(ComplexF64,NC,NC)#view(U.tempmatrix,1:NC,1:NC,1) #zeros(ComplexF64,NC,NC)
    tempmatrix_mini = view(U.tempmatrix, 1:NC, 1:NC, 1)

    lat_size = size(U.Ushifted)
    send_ranks = U.send_ranks
    empty!(send_ranks)
    # Dict{Int64,Data_sent}()
    N = prod(U.PN)


    #win = MPI.Win_create(U.Ushifted,comm)
    #Isend Irecv

    #MPI.Win_fence(0, win)


    for it = 1:U.PN[4]
        it_shifted = it - shift[4]
        it_global = myrank_xyzt[4] * U.PN[4] + it
        it_shifted_global = it_global - shift[4]
        #if myrank_xyzt[4] == 0
        while it_shifted_global < 1
            it_shifted += U.NT
            it_shifted_global += U.NT
        end
        #it_shifted += ifelse(it_shifted < 1,U.NT,0)
        #end  
        #if myrank_xyzt[4] == PEs[4]-1
        while it_shifted_global > U.NT
            it_shifted += -U.NT
            it_shifted_global += -U.NT
        end
        #it_shifted += ifelse(it_shifted > U.PN[4],-U.NT,0)
        #end
        if it_shifted <= 0
            tP = div(it_shifted, U.PN[4]) - 1
        else
            tP = div(it_shifted - 1, U.PN[4])
        end
        #if tP < 0 
        #    println("it_shifted $it_shifted tP = $tP myrank_xyzt $myrank_xyzt it = $it shift = $shift it_shifted_global $it_shifted_global")
        #end


        #it_shifted += ifelse(it_shifted < 1,U.PN[4],0)
        while it_shifted < 1
            it_shifted += U.PN[4]
        end
        while it_shifted > U.PN[4]
            it_shifted += -U.PN[4]
        end
        #it_shifted += ifelse(it_shifted > U.PN[4],-U.PN[4],0)


        for iz = 1:U.PN[3]
            iz_shifted = iz - shift[3]
            iz_global = myrank_xyzt[3] * U.PN[3] + iz
            iz_shifted_global = iz_global - shift[3]
            #if myrank_xyzt[3] == 0
            while iz_shifted_global < 1
                iz_shifted += U.NZ
                iz_shifted_global += U.NZ
            end
            #iz_shifted += ifelse(iz_shifted < 1,U.NZ,0)
            #end
            #if myrank_xyzt[3] == PEs[3]-1
            while iz_shifted_global > U.NZ
                iz_shifted += -U.NZ
                iz_shifted_global += -U.NZ
            end

            #iz_shifted += ifelse(iz_shifted > U.PN[3],-U.NZ,0)
            #end

            if iz_shifted <= 0
                zP = div(iz_shifted, U.PN[3]) - 1
            else
                zP = div(iz_shifted - 1, U.PN[3])
            end



            while iz_shifted < 1
                iz_shifted += U.PN[3]
            end
            while iz_shifted > U.PN[3]
                iz_shifted += -U.PN[3]
            end
            #iz_shifted += ifelse(iz_shifted < 1,U.PN[3],0)
            #iz_shifted += ifelse(iz_shifted > U.PN[3],-U.PN[3],0)

            for iy = 1:U.PN[2]

                iy_shifted = iy - shift[2]
                iy_global = myrank_xyzt[2] * U.PN[2] + iy
                iy_shifted_global = iy_global - shift[2]
                #if myrank_xyzt[2] == 0
                while iy_shifted_global < 1
                    iy_shifted += U.NY
                    iy_shifted_global += U.NY
                end

                #iy_shifted += ifelse(iy_shifted < 1,U.NY,0)
                #end
                #if myrank_xyzt[2] == PEs[2]-1
                while iy_shifted_global > U.NY
                    iy_shifted += -U.NY
                    iy_shifted_global += -U.NY
                end
                #iy_shifted += ifelse(iy_shifted > U.PN[2],-U.NY,0)
                #end

                if iy_shifted <= 0
                    yP = div(iy_shifted, U.PN[2]) - 1
                else
                    yP = div(iy_shifted - 1, U.PN[2])
                end


                while iy_shifted < 1
                    iy_shifted += U.PN[2]
                end
                while iy_shifted > U.PN[2]
                    iy_shifted += -U.PN[2]
                end
                #iy_shifted += ifelse(iy_shifted < 1,U.PN[2],0)
                #iy_shifted += ifelse(iy_shifted > U.PN[2],-U.PN[2],0)

                for ix = 1:U.PN[1]
                    ix_shifted = ix - shift[1]
                    ix_global = myrank_xyzt[1] * U.PN[1] + ix
                    ix_shifted_global = ix_global - shift[1]
                    #if myrank_xyzt[1] == 0
                    while ix_shifted_global < 1
                        ix_shifted += U.NX
                        ix_shifted_global += U.NX
                    end
                    #ix_shifted += ifelse(ix_shifted < 1,U.NX,0)
                    #end
                    #if myrank_xyzt[1] == PEs[1]-1
                    while ix_shifted_global > U.NX
                        ix_shifted += -U.NX
                        ix_shifted_global += -U.NX
                    end
                    #ix_shifted += ifelse(ix_shifted > U.PN[1],-U.NX,0)
                    #end


                    if ix_shifted <= 0
                        xP = div(ix_shifted, U.PN[1]) - 1
                    else
                        xP = div(ix_shifted - 1, U.PN[1])
                    end


                    while ix_shifted < 1
                        ix_shifted += U.PN[1]
                    end
                    while ix_shifted > U.PN[1]
                        ix_shifted += -U.PN[1]
                    end
                    #ix_shifted += ifelse(ix_shifted < 1,U.PN[1],0)
                    #ix_shifted += ifelse(ix_shifted > U.PN[1],-U.PN[1],0)
                    #xP = div(ix_shifted-1,U.PN[1])
                    #println((tP,zP,yP,xP),"\t $shift")
                    if tP == 0 && zP == 0 && yP == 0 && xP == 0
                        for jc = 1:NC
                            @simd for ic = 1:NC
                                #v = getvalue(U,ic,jc,ix_shifted,iy_shifted,iz_shifted,it_shifted)
                                #U.Ushifted[ic,jc,ix,iy,iz,it] = v
                                v = getvalue(U, ic, jc, ix, iy, iz, it)
                                U.Ushifted[
                                    ic,
                                    jc,
                                    ix_shifted,
                                    iy_shifted,
                                    iz_shifted,
                                    it_shifted,
                                ] = v

                            end
                        end
                    else
                        update_sent_data!(
                            send_ranks,
                            N,
                            ix,
                            iy,
                            iz,
                            it,
                            ix_shifted,
                            iy_shifted,
                            iz_shifted,
                            it_shifted,
                            PEs,
                            myrank_xyzt,
                            xP,
                            yP,
                            zP,
                            tP,
                            U,
                        )
                    end
                end
            end
        end
    end



    #println("length = ",length(send_ranks))


    #barrier(U)
    if length(send_ranks) != 0
        mpi_updates_U!(U, send_ranks)
        #=
        if length(send_ranks) == 1
            mpi_updates_U_1data!(U,send_ranks)
        else
            mpi_updates_U_moredata!(U,send_ranks)
        end
        =#
    end
    #=
    if length(send_ranks) != 0
        #=
        for rank=0:get_nprocs(U)
            if rank == get_myrank(U)
                println("myrank = ",myrank)
                for (key,value) in send_ranks
                    println(key,"\t",value.count)
                end
            end
            barrier(U)
        end

        =#
        tempmatrix = U.tempmatrix #zeros(ComplexF64,NC,NC,N)
        #tempmatrix = zeros(ComplexF64,NC,NC,N)
        positions = U.positions

        win = MPI.Win_create(tempmatrix,comm)
        #Isend Irecv
        MPI.Win_fence(0, win)

        for (myrank_send,value) in send_ranks
            count = value.count
            MPI.Put(value.data[:,:,1:count], myrank_send,win)
        end

        MPI.Win_fence(0, win)
        MPI.free(win)

        win_i = MPI.Win_create(positions,comm)
        MPI.Win_fence(0, win_i)

        for (myrank_send,value) in send_ranks
            count = value.count
            MPI.Put(value.positions[1:count], myrank_send,win_i)
        end

        MPI.Win_fence(0, win_i)
        MPI.free(win_i)

        countvec = zeros(Int64,1)

        win_c = MPI.Win_create(countvec,comm)
        MPI.Win_fence(0, win_c)

        for (myrank_send,value) in send_ranks
            count = value.count
            MPI.Put(Int64[count], myrank_send,win_c)
        end

        MPI.Win_fence(0, win_c)
        MPI.free(win_c)

        count = countvec[1]



        #=
        for rank=0:get_nprocs(U)
            if rank == get_myrank(U)
                println("myrank = ",myrank)
                for position in positions[1:count]
                    println(position)
                end
            end
            barrier(U)
        end
        =#

        for i = 1:count
            position = positions[i]
            for jc = 1:NC
                for ic= 1:NC
                    ii = ((position-1)*NC + jc-1)*NC + ic
                    U.Ushifted[ii] = tempmatrix[ic,jc,i]
                end
            end
            #println(position)
        end

        #error("in shiftdU")
    end
    =#




    #MPI.Win_fence(0, win)

    #MPI.free(win)



end



function shifted_U!(U::Gaugefields_4D_nowing_mpi{NC}, shift) where {NC}
    PEs = U.PEs
    PN = U.PN
    myrank = U.myrank
    myrank_xyzt = U.myrank_xyzt
    myrank_xyzt_send = U.myrank_xyzt
    tempmatrix = zeros(ComplexF64, NC, NC)

    win = MPI.Win_create(U.Ushifted, U[1].comm)
    #Isend Irecv

    MPI.Win_fence(0, win)


    for it = 1:U.PN[4]
        it_shifted = it - shift[4]
        if myrank_xyzt[4] == 0
            while it_shifted < 1
                it_shifted += U.NT
            end
            #it_shifted += ifelse(it_shifted < 1,U.NT,0)
        end
        if myrank_xyzt[4] == PEs[4] - 1
            while it_shifted > U.PN[4]
                it_shifted += -U.NT
            end
            #it_shifted += ifelse(it_shifted > U.PN[4],-U.NT,0)
        end
        if it_shifted <= 0
            tP = div(it_shifted, U.PN[4]) - 1
        else
            tP = div(it_shifted - 1, U.PN[4])
        end


        #it_shifted += ifelse(it_shifted < 1,U.PN[4],0)
        while it_shifted < 1
            it_shifted += U.PN[4]
        end
        while it_shifted > U.PN[4]
            it_shifted += -U.PN[4]
        end
        #it_shifted += ifelse(it_shifted > U.PN[4],-U.PN[4],0)


        for iz = 1:U.PN[3]
            iz_shifted = iz - shift[3]
            if myrank_xyzt[3] == 0
                while iz_shifted < 1
                    iz_shifted += U.NZ
                end
                #iz_shifted += ifelse(iz_shifted < 1,U.NZ,0)
            end
            if myrank_xyzt[3] == PEs[3] - 1
                while iz_shifted > U.PN[3]
                    iz_shifted += -U.NZ
                end

                #iz_shifted += ifelse(iz_shifted > U.PN[3],-U.NZ,0)
            end

            if iz_shifted <= 0
                zP = div(iz_shifted, U.PN[3]) - 1
            else
                zP = div(iz_shifted - 1, U.PN[3])
            end



            while iz_shifted < 1
                iz_shifted += U.PN[3]
            end
            while iz_shifted > U.PN[3]
                iz_shifted += -U.PN[3]
            end
            #iz_shifted += ifelse(iz_shifted < 1,U.PN[3],0)
            #iz_shifted += ifelse(iz_shifted > U.PN[3],-U.PN[3],0)

            for iy = 1:U.PN[2]
                iy_shifted = iy - shift[2]
                if myrank_xyzt[2] == 0
                    while iy_shifted < 1
                        iy_shifted += U.NY
                    end

                    #iy_shifted += ifelse(iy_shifted < 1,U.NY,0)
                end
                if myrank_xyzt[2] == PEs[2] - 1
                    while iy_shifted > U.PN[2]
                        iy_shifted += -U.NY
                    end
                    #iy_shifted += ifelse(iy_shifted > U.PN[2],-U.NY,0)
                end

                if iy_shifted <= 0
                    yP = div(iy_shifted, U.PN[2]) - 1
                else
                    yP = div(iy_shifted - 1, U.PN[2])
                end


                while iy_shifted < 1
                    iy_shifted += U.PN[2]
                end
                while iy_shifted > U.PN[2]
                    iy_shifted += -U.PN[2]
                end
                #iy_shifted += ifelse(iy_shifted < 1,U.PN[2],0)
                #iy_shifted += ifelse(iy_shifted > U.PN[2],-U.PN[2],0)

                for ix = 1:U.PN[1]
                    ix_shifted = ix - shift[1]
                    if myrank_xyzt[1] == 0
                        while ix_shifted < 1
                            ix_shifted += U.NX
                        end
                        #ix_shifted += ifelse(ix_shifted < 1,U.NX,0)
                    end
                    if myrank_xyzt[1] == PEs[1] - 1
                        while ix_shifted > U.PN[1]
                            ix_shifted += -U.NX
                        end
                        #ix_shifted += ifelse(ix_shifted > U.PN[1],-U.NX,0)
                    end


                    if ix_shifted <= 0
                        xP = div(ix_shifted, U.PN[1]) - 1
                    else
                        xP = div(ix_shifted - 1, U.PN[1])
                    end


                    while ix_shifted < 1
                        ix_shifted += U.PN[1]
                    end
                    while ix_shifted > U.PN[1]
                        ix_shifted += -U.PN[1]
                    end
                    #ix_shifted += ifelse(ix_shifted < 1,U.PN[1],0)
                    #ix_shifted += ifelse(ix_shifted > U.PN[1],-U.PN[1],0)
                    #xP = div(ix_shifted-1,U.PN[1])
                    #println((tP,zP,yP,xP),"\t $shift")
                    if tP == 0 && zP == 0 && yP == 0 && xP == 0
                        for jc = 1:NC
                            @simd for ic = 1:NC
                                #v = getvalue(U,ic,jc,ix_shifted,iy_shifted,iz_shifted,it_shifted)
                                #U.Ushifted[ic,jc,ix,iy,iz,it] = v
                                v = getvalue(U, ic, jc, ix, iy, iz, it)
                                U.Ushifted[
                                    ic,
                                    jc,
                                    ix_shifted,
                                    iy_shifted,
                                    iz_shifted,
                                    it_shifted,
                                ] = v

                            end
                        end
                    else

                        px = myrank_xyzt[1] + xP
                        px += ifelse(px >= PEs[1], -PEs[1], 0)
                        px += ifelse(px < 0, +PEs[1], 0)
                        py = myrank_xyzt[2] + yP
                        py += ifelse(py >= PEs[2], -PEs[2], 0)
                        py += ifelse(py < 0, +PEs[2], 0)
                        pz = myrank_xyzt[3] + zP
                        pz += ifelse(pz >= PEs[3], -PEs[3], 0)
                        pz += ifelse(pz < 0, +PEs[3], 0)
                        pt = myrank_xyzt[4] + tP
                        pt += ifelse(pt >= PEs[4], -PEs[4], 0)
                        pt += ifelse(pt < 0, +PEs[4], 0)

                        myrank_xyzt_send = (px, py, pz, pt)
                        #println(myrank_xyzt_send)
                        myrank_send = get_myrank(myrank_xyzt_send, PEs)
                        #println(myrank_send,"\t",myrank)



                        #it_shifted_back = (it_shifted-1) % U.PN[4] + 1
                        #iz_shifted_back = (iz_shifted-1) % U.PN[3] +1
                        #iy_shifted_back = (iy_shifted-1) % U.PN[2] + 1
                        #ix_shifted_back = (ix_shifted-1) % U.PN[1] + 1

                        for jc = 1:NC
                            @simd for ic = 1:NC
                                #v = getvalue(U,ic,jc,ix_shifted_back,iy_shifted_back,iz_shifted_back,it_shifted_back)
                                #v = getvalue(U,ic,jc,ix_shifted,iy_shifted,iz_shifted,it_shifted)
                                v = getvalue(U, ic, jc, ix, iy, iz, it)
                                tempmatrix[ic, jc] = v
                            end
                        end
                        #disp = ((((it-1)*U.PN[3] + iz-1)*U.PN[2] + iy-1)*U.PN[1] + ix-1)*NC*NC
                        disp =
                            (
                                (
                                    ((it_shifted - 1) * U.PN[3] + iz_shifted - 1) *
                                    U.PN[2] + iy_shifted - 1
                                ) * U.PN[1] + ix_shifted - 1
                            ) *
                            NC *
                            NC
                        #println(myrank_send)
                        MPI.Put(tempmatrix, myrank_send, disp, win)
                        #println("t ",tempmatrix)
                        #if myrank ==  myrank_send
                        #    println(U.Ushifted[:,:,ix,iy,iz,it] )
                        #end

                        #=
                        for rank=0:(get_nprocs(U)-1)
                            #println(get_nprocs(U))
                            if get_myrank(U) == rank
                                println("site $((ix,iy,iz,it))")
                                println("shift $shift")
                                println("shifted site $((ix_shifted_back,iy_shifted_back,iz_shifted_back,it_shifted_back))")
                                println("xPs,$((xP,yP,zP,tP))")
                                println("myrank = $myrank send $myrank_send")
                                println("pxs ",(px,py,pz,pt))
                                println((1,1,ix_shifted_back,iy_shifted_back,iz_shifted_back,it_shifted_back))
                            end
                            barrier(U)
                        end
                        =#

                    end
                end
            end
        end
    end

    MPI.Win_fence(0, win)

    MPI.free(win)



end



@inline function getvalue(
    U::Shifted_Gaugefields_4D_mpi_nowing{NC},
    i1,
    i2,
    i3,
    i4,
    i5,
    i6,
) where {NC}
    @inbounds return U.parent.Ushifted[i1, i2, i3, i4, i5, i6]
end

@inline function setvalue!(
    U::Shifted_Gaugefields_4D_mpi_nowing{NC},
    v,
    i1,
    i2,
    i3,
    i4,
    i5,
    i6,
) where {NC}
    error("type $(typeof(U)) has no setindex method. This type is read only.")
end


function shift_U(U::Gaugefields_4D_nowing_mpi{NC}, ν::T) where {T<:Integer,NC}
    if ν == 1
        shift = (1, 0, 0, 0)
    elseif ν == 2
        shift = (0, 1, 0, 0)
    elseif ν == 3
        shift = (0, 0, 1, 0)
    elseif ν == 4
        shift = (0, 0, 0, 1)
    elseif ν == -1
        shift = (-1, 0, 0, 0)
    elseif ν == -2
        shift = (0, -1, 0, 0)
    elseif ν == -3
        shift = (0, 0, -1, 0)
    elseif ν == -4
        shift = (0, 0, 0, -1)
    end

    return Shifted_Gaugefields_4D_mpi_nowing(U, shift)
end

function shift_U(
    U::TU,
    shift::NTuple{Dim,T},
) where {Dim,T<:Integer,TU<:Gaugefields_4D_nowing_mpi}
    return Shifted_Gaugefields_4D_mpi_nowing(U, shift)
end



function normalize_U!(U::Gaugefields_4D_nowing_mpi{NC}) where {NC}

    A = zeros(ComplexF64, NC, NC)

    for it = 1:U.PN[4]
        for iz = 1:U.PN[3]
            for iy = 1:U.PN[2]
                for ix = 1:U.PN[1]
                    for jc = 1:NC
                        @simd for ic = 1:NC
                            A[ic, jc] = getvalue(U, ic, jc, ix, iy, iz, it)
                        end
                    end
                    gramschmidt!(A)

                    for jc = 1:NC
                        @simd for ic = 1:NC
                            v = A[ic, jc]
                            setvalue!(U, v, ic, jc, ix, iy, iz, it)
                        end
                    end
                end
            end
        end
    end
    set_wing_U!(U)

end


function Base.similar(U::T) where {T<:Gaugefields_4D_nowing_mpi}
    Uout = Gaugefields_4D_nowing_mpi(
        U.NC,
        U.NX,
        U.NY,
        U.NZ,
        U.NT,
        U.PEs,
        mpiinit = U.mpiinit,
        verbose_level = U.verbose_print.level,
        comm = U.comm,
    )
    #identityGaugefields_4D_nowing(U.NC,U.NX,U.NY,U.NZ,U.NT,U.NDW)
    return Uout
end


function Base.similar(U::Array{T,1}) where {T<:Gaugefields_4D_nowing_mpi}
    Uout = Array{T,1}(undef, 4)
    for μ = 1:4
        Uout[μ] = similar(U[μ])
    end
    return Uout
end

function LinearAlgebra.tr(a::Gaugefields_4D_nowing_mpi{NC}) where {NC}
    NX = a.NX
    NY = a.NY
    NZ = a.NZ
    NT = a.NT
    PN = a.PN

    s = 0
    for it = 1:PN[4]
        for iz = 1:PN[3]
            for iy = 1:PN[2]
                for ix = 1:PN[1]
                    @simd for k = 1:NC
                        s += getvalue(a, k, k, ix, iy, iz, it)
                        #println(a[k,k,ix,iy,iz,it])
                    end
                end
            end
        end
    end

    s = MPI.Allreduce(s, MPI.SUM, a.comm)

    #println(3*NT*NZ*NY*NX*NC)
    return s
end

function calculate_Polyakov_loop(
    U::Array{T,1},
    temp1::AbstractGaugefields{NC,Dim},
    temp2::AbstractGaugefields{NC,Dim},
) where {NC,Dim,T<:Gaugefields_4D_nowing_mpi}
    Uold = temp1
    Unew = temp2
    shift = zeros(Int64, Dim)

    μ = Dim
    _, _, NN... = size(U[1]) #NC,NC,NX,NY,NZ,NT 4D case
    lastaxis = NN[end]
    #println(lastaxis)

    substitute_U!(Uold, U[μ])
    for i = 2:lastaxis
        shift[μ] = i - 1
        U1 = shift_U(U[μ], Tuple(shift))
        mul_skiplastindex!(Unew, Uold, U1)
        #println(getvalue(U1,1,1,1,1,1,1))
        Uold, Unew = Unew, Uold
        #println(getvalue(Uold,1,1,1,1,1,1))
    end

    set_wing_U!(Uold)
    #println(prod(NN[1:Dim-1]))
    #println(Uold)
    poly = 0
    #if get_myrank(U) == 0
    poly = partial_tr(Uold, μ) / prod(NN[1:Dim-1])
    #end
    poly /= U[1].PEs[μ]
    #poly = MPI.bcast(poly,0,comm)

    return poly

end


function partial_tr(a::Gaugefields_4D_nowing_mpi{NC}, μ) where {NC}
    #error("Polyakov loop is not supported with MPI yet.")
    PN = a.PN

    if μ == 1
        s = 0
        ix = 1
        for it = 1:PN[4]
            for iz = 1:PN[3]
                for iy = 1:PN[2]
                    #for ix=1:NX
                    @simd for k = 1:NC
                        s += getvalue(a, k, k, ix, iy, iz, it)
                        #println(a[k,k,ix,iy,iz,it])
                    end

                    #end
                end
            end
        end
    elseif μ == 2
        s = 0
        iy = 1
        for it = 1:PN[4]
            for iz = 1:PN[3]
                #for iy=1:NY
                for ix = 1:PN[1]
                    @simd for k = 1:NC
                        s += getvalue(a, k, k, ix, iy, iz, it)
                        #println(a[k,k,ix,iy,iz,it])
                    end
                end
                #end
            end
        end
    elseif μ == 3
        s = 0
        iz = 1
        for it = 1:PN[4]
            #for iz=1:NZ
            for iy = 1:PN[2]
                for ix = 1:PN[1]
                    @simd for k = 1:NC
                        s += getvalue(a, k, k, ix, iy, iz, it)
                        #println(a[k,k,ix,iy,iz,it])
                    end
                end
            end
            #end
        end
    else
        s = 0
        it = 1
        for iz = 1:PN[3]
            for iy = 1:PN[2]
                for ix = 1:PN[1]
                    @simd for k = 1:NC
                        s += getvalue(a, k, k, ix, iy, iz, it)
                        # println(s)
                    end
                end
            end
        end

    end

    s = MPI.Allreduce(s, MPI.SUM, a.comm)



    #println(3*NT*NZ*NY*NX*NC)
    return s
end



function LinearAlgebra.mul!(
    c::Gaugefields_4D_nowing_mpi{NC},
    a::T1,
    b::T2,
) where {NC,T1<:Abstractfields,T2<:Abstractfields}
    @assert NC != 2 && NC != 3 "This function is for NC != 2,3"
    NT = c.NT
    NZ = c.NZ
    NY = c.NY
    NX = c.NX
    PN = c.PN
    for it = 1:PN[4]
        for iz = 1:PN[3]
            for iy = 1:PN[2]
                for ix = 1:PN[1]
                    for k2 = 1:NC
                        for k1 = 1:NC
                            v = 0
                            setvalue!(c, v, k1, k2, ix, iy, iz, it)
                            #c[k1,k2,ix,iy,iz,it] = 0

                            @simd for k3 = 1:NC
                                vc =
                                    getvalue(c, k1, k2, ix, iy, iz, it) +
                                    getvalue(a, k1, k3, ix, iy, iz, it) *
                                    getvalue(b, k3, k2, ix, iy, iz, it)
                                setvalue!(c, vc, k1, k2, ix, iy, iz, it)
                                #c[k1,k2,ix,iy,iz,it] += a[k1,k3,ix,iy,iz,it]*b[k3,k2,ix,iy,iz,it]
                            end
                        end
                    end
                end
            end
        end
    end
    #set_wing_U!(c)
end

function LinearAlgebra.mul!(
    c::Gaugefields_4D_nowing_mpi{NC},
    a::T1,
    b::T2,
    iseven::Bool,
) where {NC,T1<:Abstractfields,T2<:Abstractfields}
    @assert NC != 2 && NC != 3 "This function is for NC != 2,3"
    NT = c.NT
    NZ = c.NZ
    NY = c.NY
    NX = c.NX
    PN = c.PN
    for it = 1:PN[4]
        for iz = 1:PN[3]
            for iy = 1:PN[2]
                for ix = 1:PN[1]
                    evenodd = ifelse((ix + iy + iz + it) % 2 == 0, true, false)
                    if evenodd == iseven

                        for k2 = 1:NC
                            for k1 = 1:NC
                                v = 0
                                setvalue!(c, v, k1, k2, ix, iy, iz, it)
                                #c[k1,k2,ix,iy,iz,it] = 0

                                @simd for k3 = 1:NC
                                    vc =
                                        getvalue(c, k1, k2, ix, iy, iz, it) +
                                        getvalue(a, k1, k3, ix, iy, iz, it) *
                                        getvalue(b, k3, k2, ix, iy, iz, it)
                                    setvalue!(c, vc, k1, k2, ix, iy, iz, it)
                                    #c[k1,k2,ix,iy,iz,it] += a[k1,k3,ix,iy,iz,it]*b[k3,k2,ix,iy,iz,it]
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    #set_wing_U!(c)
end

function mul_skiplastindex!(
    c::Gaugefields_4D_nowing_mpi{NC},
    a::T1,
    b::T2,
) where {NC,T1<:Abstractfields,T2<:Abstractfields}
    #@assert NC != 2 && NC != 3 "This function is for NC != 2,3"
    NT = c.NT
    NZ = c.NZ
    NY = c.NY
    NX = c.NX
    #for it=1:NT
    it = 1
    PN = c.PN
    for iz = 1:PN[3]
        for iy = 1:PN[2]
            for ix = 1:PN[1]
                for k2 = 1:NC
                    for k1 = 1:NC
                        v = 0
                        #setvalue!(c,v,k1,k2,ix,iy,iz,it)
                        #c[k1,k2,ix,iy,iz,it] = 0

                        @simd for k3 = 1:NC
                            av = getvalue(a, k1, k3, ix, iy, iz, it)
                            bv = getvalue(b, k3, k2, ix, iy, iz, it)
                            #cv = getvalue(c,k1,k2,ix,iy,iz,it)

                            v += av * bv

                            #c[k1,k2,ix,iy,iz,it] += a[k1,k3,ix,iy,iz,it]*b[k3,k2,ix,iy,iz,it]
                        end
                        setvalue!(c, v, k1, k2, ix, iy, iz, it)
                    end
                end
            end
        end
    end
    #end
    set_wing_U!(c)
end


function LinearAlgebra.mul!(
    c::Gaugefields_4D_nowing_mpi{3},
    a::T1,
    b::T2,
) where {NC,T1<:Abstractfields,T2<:Abstractfields}
    #@assert NC != 2 && NC != 3 "This function is for NC != 2,3"

    NT = c.NT
    NZ = c.NZ
    NY = c.NY
    NX = c.NX
    PN = c.PN
    @inbounds for it = 1:PN[4]
        for iz = 1:PN[3]
            for iy = 1:PN[2]
                for ix = 1:PN[1]
                    a11 = getvalue(a, 1, 1, ix, iy, iz, it)
                    a21 = getvalue(a, 2, 1, ix, iy, iz, it)
                    a31 = getvalue(a, 3, 1, ix, iy, iz, it)
                    a12 = getvalue(a, 1, 2, ix, iy, iz, it)
                    a22 = getvalue(a, 2, 2, ix, iy, iz, it)
                    a32 = getvalue(a, 3, 2, ix, iy, iz, it)
                    a13 = getvalue(a, 1, 3, ix, iy, iz, it)
                    a23 = getvalue(a, 2, 3, ix, iy, iz, it)
                    a33 = getvalue(a, 3, 3, ix, iy, iz, it)
                    b11 = getvalue(b, 1, 1, ix, iy, iz, it)
                    b21 = getvalue(b, 2, 1, ix, iy, iz, it)
                    b31 = getvalue(b, 3, 1, ix, iy, iz, it)
                    b12 = getvalue(b, 1, 2, ix, iy, iz, it)
                    b22 = getvalue(b, 2, 2, ix, iy, iz, it)
                    b32 = getvalue(b, 3, 2, ix, iy, iz, it)
                    b13 = getvalue(b, 1, 3, ix, iy, iz, it)
                    b23 = getvalue(b, 2, 3, ix, iy, iz, it)
                    b33 = getvalue(b, 3, 3, ix, iy, iz, it)


                    v = (a11 * b11 + a12 * b21 + a13 * b31)
                    setvalue!(c, v, 1, 1, ix, iy, iz, it)
                    v = (a21 * b11 + a22 * b21 + a23 * b31)
                    setvalue!(c, v, 2, 1, ix, iy, iz, it)
                    v = (a31 * b11 + a32 * b21 + a33 * b31)
                    setvalue!(c, v, 3, 1, ix, iy, iz, it)
                    v = (a11 * b12 + a12 * b22 + a13 * b32)
                    setvalue!(c, v, 1, 2, ix, iy, iz, it)
                    v = (a21 * b12 + a22 * b22 + a23 * b32)
                    setvalue!(c, v, 2, 2, ix, iy, iz, it)
                    v = (a31 * b12 + a32 * b22 + a33 * b32)
                    setvalue!(c, v, 3, 2, ix, iy, iz, it)
                    v = (a11 * b13 + a12 * b23 + a13 * b33)
                    setvalue!(c, v, 1, 3, ix, iy, iz, it)
                    v = (a21 * b13 + a22 * b23 + a23 * b33)
                    setvalue!(c, v, 2, 3, ix, iy, iz, it)
                    v = (a31 * b13 + a32 * b23 + a33 * b33)
                    setvalue!(c, v, 3, 3, ix, iy, iz, it)
                end
            end
        end
    end

    #set_wing_U!(c)
end

function LinearAlgebra.mul!(
    c::Gaugefields_4D_nowing_mpi{3},
    a::T1,
    b::T2,
    iseven::Bool,
) where {NC,T1<:Abstractfields,T2<:Abstractfields}
    #@assert NC != 2 && NC != 3 "This function is for NC != 2,3"
    NT = c.NT
    NZ = c.NZ
    NY = c.NY
    NX = c.NX
    PN = c.PN
    for it = 1:PN[4]
        for iz = 1:PN[3]
            for iy = 1:PN[2]
                for ix = 1:PN[1]
                    evenodd = ifelse((ix + iy + iz + it) % 2 == 0, true, false)
                    if evenodd == iseven

                        a11 = getvalue(a, 1, 1, ix, iy, iz, it)
                        a21 = getvalue(a, 2, 1, ix, iy, iz, it)
                        a31 = getvalue(a, 3, 1, ix, iy, iz, it)
                        a12 = getvalue(a, 1, 2, ix, iy, iz, it)
                        a22 = getvalue(a, 2, 2, ix, iy, iz, it)
                        a32 = getvalue(a, 3, 2, ix, iy, iz, it)
                        a13 = getvalue(a, 1, 3, ix, iy, iz, it)
                        a23 = getvalue(a, 2, 3, ix, iy, iz, it)
                        a33 = getvalue(a, 3, 3, ix, iy, iz, it)
                        b11 = getvalue(b, 1, 1, ix, iy, iz, it)
                        b21 = getvalue(b, 2, 1, ix, iy, iz, it)
                        b31 = getvalue(b, 3, 1, ix, iy, iz, it)
                        b12 = getvalue(b, 1, 2, ix, iy, iz, it)
                        b22 = getvalue(b, 2, 2, ix, iy, iz, it)
                        b32 = getvalue(b, 3, 2, ix, iy, iz, it)
                        b13 = getvalue(b, 1, 3, ix, iy, iz, it)
                        b23 = getvalue(b, 2, 3, ix, iy, iz, it)
                        b33 = getvalue(b, 3, 3, ix, iy, iz, it)


                        v = (a11 * b11 + a12 * b21 + a13 * b31)
                        setvalue!(c, v, 1, 1, ix, iy, iz, it)
                        v = (a21 * b11 + a22 * b21 + a23 * b31)
                        setvalue!(c, v, 2, 1, ix, iy, iz, it)
                        v = (a31 * b11 + a32 * b21 + a33 * b31)
                        setvalue!(c, v, 3, 1, ix, iy, iz, it)
                        v = (a11 * b12 + a12 * b22 + a13 * b32)
                        setvalue!(c, v, 1, 2, ix, iy, iz, it)
                        v = (a21 * b12 + a22 * b22 + a23 * b32)
                        setvalue!(c, v, 2, 2, ix, iy, iz, it)
                        v = (a31 * b12 + a32 * b22 + a33 * b32)
                        setvalue!(c, v, 3, 2, ix, iy, iz, it)
                        v = (a11 * b13 + a12 * b23 + a13 * b33)
                        setvalue!(c, v, 1, 3, ix, iy, iz, it)
                        v = (a21 * b13 + a22 * b23 + a23 * b33)
                        setvalue!(c, v, 2, 3, ix, iy, iz, it)
                        v = (a31 * b13 + a32 * b23 + a33 * b33)
                        setvalue!(c, v, 3, 3, ix, iy, iz, it)
                    end
                end
            end
        end
    end
    #set_wing_U!(c)
end

function LinearAlgebra.mul!(
    c::Gaugefields_4D_nowing_mpi{2},
    a::T1,
    b::T2,
) where {NC,T1<:Abstractfields,T2<:Abstractfields}
    #@assert NC != 2 && NC != 3 "This function is for NC != 2,3"
    NT = c.NT
    NZ = c.NZ
    NY = c.NY
    NX = c.NX
    PN = c.PN
    for it = 1:PN[4]
        for iz = 1:PN[3]
            for iy = 1:PN[2]
                for ix = 1:PN[1]
                    a11 = getvalue(a, 1, 1, ix, iy, iz, it)
                    a21 = getvalue(a, 2, 1, ix, iy, iz, it)

                    a12 = getvalue(a, 1, 2, ix, iy, iz, it)
                    a22 = getvalue(a, 2, 2, ix, iy, iz, it)


                    b11 = getvalue(b, 1, 1, ix, iy, iz, it)
                    b21 = getvalue(b, 2, 1, ix, iy, iz, it)

                    b12 = getvalue(b, 1, 2, ix, iy, iz, it)
                    b22 = getvalue(b, 2, 2, ix, iy, iz, it)



                    v = a11 * b11 + a12 * b21
                    setvalue!(c, v, 1, 1, ix, iy, iz, it)
                    v = a21 * b11 + a22 * b21
                    setvalue!(c, v, 2, 1, ix, iy, iz, it)

                    v = a11 * b12 + a12 * b22
                    setvalue!(c, v, 1, 2, ix, iy, iz, it)
                    v = a21 * b12 + a22 * b22
                    setvalue!(c, v, 2, 2, ix, iy, iz, it)
                    #v = a31*b12+a32*b22

                end
            end
        end
    end
    #set_wing_U!(c)
end

function LinearAlgebra.mul!(
    c::Gaugefields_4D_nowing_mpi{2},
    a::T1,
    b::T2,
    iseven::Bool,
) where {NC,T1<:Abstractfields,T2<:Abstractfields}
    #@assert NC != 2 && NC != 3 "This function is for NC != 2,3"
    NT = c.NT
    NZ = c.NZ
    NY = c.NY
    NX = c.NX
    PN = c.PN
    for it = 1:PN[4]
        for iz = 1:PN[3]
            for iy = 1:PN[2]
                for ix = 1:PN[1]
                    evenodd = ifelse((ix + iy + iz + it) % 2 == 0, true, false)
                    if evenodd == iseven


                        a11 = getvalue(a, 1, 1, ix, iy, iz, it)
                        a21 = getvalue(a, 2, 1, ix, iy, iz, it)

                        a12 = getvalue(a, 1, 2, ix, iy, iz, it)
                        a22 = getvalue(a, 2, 2, ix, iy, iz, it)


                        b11 = getvalue(b, 1, 1, ix, iy, iz, it)
                        b21 = getvalue(b, 2, 1, ix, iy, iz, it)

                        b12 = getvalue(b, 1, 2, ix, iy, iz, it)
                        b22 = getvalue(b, 2, 2, ix, iy, iz, it)



                        v = a11 * b11 + a12 * b21
                        setvalue!(c, v, 1, 1, ix, iy, iz, it)
                        v = a21 * b11 + a22 * b21
                        setvalue!(c, v, 2, 1, ix, iy, iz, it)

                        v = a11 * b12 + a12 * b22
                        setvalue!(c, v, 1, 2, ix, iy, iz, it)
                        v = a21 * b12 + a22 * b22
                        setvalue!(c, v, 2, 2, ix, iy, iz, it)
                        v = a31 * b12 + a32 * b22
                    end

                end
            end
        end
    end
    #set_wing_U!(c)
end

function LinearAlgebra.mul!(
    c::Gaugefields_4D_nowing_mpi{NC},
    a::T1,
    b::T2,
    α::Ta,
    β::Tb,
) where {NC,T1<:Abstractfields,T2<:Abstractfields,Ta<:Number,Tb<:Number}
    @assert NC != 2 && NC != 3 "This function is for NC != 2,3"
    NT = c.NT
    NZ = c.NZ
    NY = c.NY
    NX = c.NX
    PN = c.PN
    for it = 1:PN[4]
        for iz = 1:PN[3]
            for iy = 1:PN[2]
                for ix = 1:PN[1]
                    for k2 = 1:NC
                        for k1 = 1:NC
                            v = β * getvalue(c, k1, k2, ix, iy, iz, it)
                            setvalue!(c, v, k1, k2, ix, iy, iz, it)
                            #c[k1,k2,ix,iy,iz,it] = β*c[k1,k2,ix,iy,iz,it] 
                            @simd for k3 = 1:NC
                                vc =
                                    getvalue(c, k1, k2, ix, iy, iz, it) +
                                    α *
                                    getvalue(a, k1, k3, ix, iy, iz, it) *
                                    getvalue(b, k3, k2, ix, iy, iz, it)
                                setvalue!(c, vc, k1, k2, ix, iy, iz, it)
                                #c[k1,k2,ix,iy,iz,it] += α*a[k1,k3,ix,iy,iz,it]*b[k3,k2,ix,iy,iz,it] 
                            end
                        end
                    end
                end
            end
        end
    end
    #set_wing_U!(c)
end

function LinearAlgebra.mul!(
    c::Gaugefields_4D_nowing_mpi{2},
    a::T1,
    b::T2,
    α::Ta,
    β::Tb,
) where {NC,T1<:Abstractfields,T2<:Abstractfields,Ta<:Number,Tb<:Number}
    #@assert NC != 2 && NC != 3 "This function is for NC != 2,3"
    NT = c.NT
    NZ = c.NZ
    NY = c.NY
    NX = c.NX
    PN = c.PN
    if β == zero(β)
        if α == one(α)
            mul!(c, a, b)
            return
        end
    end


    @inbounds for it = 1:PN[4]
        for iz = 1:PN[3]
            for iy = 1:PN[2]
                @simd for ix = 1:PN[1]
                    a11 = getvalue(a, 1, 1, ix, iy, iz, it)
                    a21 = getvalue(a, 2, 1, ix, iy, iz, it)
                    a12 = getvalue(a, 1, 2, ix, iy, iz, it)
                    a22 = getvalue(a, 2, 2, ix, iy, iz, it)

                    b11 = getvalue(b, 1, 1, ix, iy, iz, it)
                    b21 = getvalue(b, 2, 1, ix, iy, iz, it)
                    b12 = getvalue(b, 1, 2, ix, iy, iz, it)
                    b22 = getvalue(b, 2, 2, ix, iy, iz, it)


                    v = (a11 * b11 + a12 * b21) * α + β * getvalue(c, 1, 1, ix, iy, iz, it)
                    setvalue!(c, v, 1, 1, ix, iy, iz, it)
                    v = (a21 * b11 + a22 * b21) * α + β * getvalue(c, 2, 1, ix, iy, iz, it)
                    setvalue!(c, v, 2, 1, ix, iy, iz, it)
                    v = (a11 * b12 + a12 * b22) * α + β * getvalue(c, 1, 2, ix, iy, iz, it)
                    setvalue!(c, v, 1, 2, ix, iy, iz, it)
                    v = (a21 * b12 + a22 * b22) * α + β * getvalue(c, 2, 2, ix, iy, iz, it)
                    setvalue!(c, v, 2, 2, ix, iy, iz, it)


                end
            end
        end
    end
    #set_wing_U!(c)
end

function LinearAlgebra.mul!(
    c::Gaugefields_4D_nowing_mpi{3},
    a::T1,
    b::T2,
    α::Ta,
    β::Tb,
) where {NC,T1<:Abstractfields,T2<:Abstractfields,Ta<:Number,Tb<:Number}
    #@assert NC != 2 && NC != 3 "This function is for NC != 2,3"
    NT = c.NT
    NZ = c.NZ
    NY = c.NY
    NX = c.NX
    PN = c.PN
    if β == zero(β)
        if α == one(α)
            mul!(c, a, b)
            return
        end
    end


    @inbounds for it = 1:PN[4]
        for iz = 1:PN[3]
            for iy = 1:PN[2]
                @simd for ix = 1:PN[1]
                    a11 = getvalue(a, 1, 1, ix, iy, iz, it)
                    a21 = getvalue(a, 2, 1, ix, iy, iz, it)
                    a31 = getvalue(a, 3, 1, ix, iy, iz, it)
                    a12 = getvalue(a, 1, 2, ix, iy, iz, it)
                    a22 = getvalue(a, 2, 2, ix, iy, iz, it)
                    a32 = getvalue(a, 3, 2, ix, iy, iz, it)
                    a13 = getvalue(a, 1, 3, ix, iy, iz, it)
                    a23 = getvalue(a, 2, 3, ix, iy, iz, it)
                    a33 = getvalue(a, 3, 3, ix, iy, iz, it)
                    b11 = getvalue(b, 1, 1, ix, iy, iz, it)
                    b21 = getvalue(b, 2, 1, ix, iy, iz, it)
                    b31 = getvalue(b, 3, 1, ix, iy, iz, it)
                    b12 = getvalue(b, 1, 2, ix, iy, iz, it)
                    b22 = getvalue(b, 2, 2, ix, iy, iz, it)
                    b32 = getvalue(b, 3, 2, ix, iy, iz, it)
                    b13 = getvalue(b, 1, 3, ix, iy, iz, it)
                    b23 = getvalue(b, 2, 3, ix, iy, iz, it)
                    b33 = getvalue(b, 3, 3, ix, iy, iz, it)

                    v =
                        (a11 * b11 + a12 * b21 + a13 * b31) * α +
                        β * getvalue(c, 1, 1, ix, iy, iz, it)
                    setvalue!(c, v, 1, 1, ix, iy, iz, it)
                    v =
                        (a21 * b11 + a22 * b21 + a23 * b31) * α +
                        β * getvalue(c, 2, 1, ix, iy, iz, it)
                    setvalue!(c, v, 2, 1, ix, iy, iz, it)
                    v =
                        (a31 * b11 + a32 * b21 + a33 * b31) * α +
                        β * getvalue(c, 3, 1, ix, iy, iz, it)
                    setvalue!(c, v, 3, 1, ix, iy, iz, it)
                    v =
                        (a11 * b12 + a12 * b22 + a13 * b32) * α +
                        β * getvalue(c, 1, 2, ix, iy, iz, it)
                    setvalue!(c, v, 1, 2, ix, iy, iz, it)
                    v =
                        (a21 * b12 + a22 * b22 + a23 * b32) * α +
                        β * getvalue(c, 2, 2, ix, iy, iz, it)
                    setvalue!(c, v, 2, 2, ix, iy, iz, it)
                    v =
                        (a31 * b12 + a32 * b22 + a33 * b32) * α +
                        β * getvalue(c, 3, 2, ix, iy, iz, it)
                    setvalue!(c, v, 3, 2, ix, iy, iz, it)
                    v =
                        (a11 * b13 + a12 * b23 + a13 * b33) * α +
                        β * getvalue(c, 1, 3, ix, iy, iz, it)
                    setvalue!(c, v, 1, 3, ix, iy, iz, it)
                    v =
                        (a21 * b13 + a22 * b23 + a23 * b33) * α +
                        β * getvalue(c, 2, 3, ix, iy, iz, it)
                    setvalue!(c, v, 2, 3, ix, iy, iz, it)
                    v =
                        (a31 * b13 + a32 * b23 + a33 * b33) * α +
                        β * getvalue(c, 3, 3, ix, iy, iz, it)
                    setvalue!(c, v, 3, 3, ix, iy, iz, it)


                end
            end
        end
    end
end

function Antihermitian!(
    vin::Gaugefields_4D_nowing_mpi{NC},
    vout::Gaugefields_4D_nowing_mpi{NC};
    factor = 1
) where {NC}

    PN = vin.PN
    for it = 1:PN[4]
        for iz = 1:PN[3]
            for iy = 1:PN[2]
                for ix = 1:PN[1]

                    for k1 = 1:NC
                        #@simd for k2 = k1+1:NC
                        @simd for k2 = k1:NC
                            vv =
                                factor*(
                                    getvalue(vin,k1, k2, ix, iy, iz, it) -
                                    conj(getvalue(vin,k2, k1, ix, iy, iz, it))
                                )
                            setvalue!(vout,vv,k1, k2, ix, iy, iz, it)
                            if k1 != k2
                                setvalue!(vout,-conj(vv),k2, k1, ix, iy, iz, it)
                            end
                        end
                    end

                end
            end
        end
    end
    #set_wing_U!(c)
end

function set_wing_U!(u::Array{Gaugefields_4D_nowing_mpi{NC},1}) where {NC}
    return
end

function set_wing_U!(u::Gaugefields_4D_nowing_mpi{NC}) where {NC}
    return
end


const sr3 = sqrt(3)
const sr3i = 1/sr3
const sr3ih = 0.5*sr3i
const sqr3inv = sr3i

"""
    b = (lambda_k/2)*a
    lambda_k : GellMann matrices. k=1, 8 
"""
function lambda_k_mul!(b::Gaugefields_4D_nowing_mpi{3}, a::Gaugefields_4D_nowing_mpi{3},k,generator)
    PN = a.PN

    if k==1
        for it = 1:PN[1]
            for iz = 1:PN[2]
                for iy = 1:PN[3]
                    @inbounds @simd for ix = 1:PN[4]
                        b[1,1,ix,iy,iz,it] = 0.5 * a[2,1,ix,iy,iz,it] 
                        b[1,2,ix,iy,iz,it] = 0.5 * a[2,2,ix,iy,iz,it]
                        b[1,3,ix,iy,iz,it] = 0.5 * a[2,3,ix,iy,iz,it]
                        b[2,1,ix,iy,iz,it] = 0.5 * a[1,1,ix,iy,iz,it]
                        b[2,2,ix,iy,iz,it] = 0.5 * a[1,2,ix,iy,iz,it]
                        b[2,3,ix,iy,iz,it] = 0.5 * a[1,3,ix,iy,iz,it]
                        b[3,1,ix,iy,iz,it] = 0
                        b[3,2,ix,iy,iz,it] = 0
                        b[3,3,ix,iy,iz,it] = 0
                    end
                end
            end
        end
    elseif k==2
        for it = 1:PN[1]
            for iz = 1:PN[2]
                for iy = 1:PN[3]
                    @inbounds @simd for ix = 1:PN[4]
                        b[1,1,ix,iy,iz,it] = -0.5*im * a[2,1,ix,iy,iz,it] 
                        b[1,2,ix,iy,iz,it] = -0.5*im * a[2,2,ix,iy,iz,it]
                        b[1,3,ix,iy,iz,it] = -0.5*im * a[2,3,ix,iy,iz,it]
                        b[2,1,ix,iy,iz,it] =  0.5*im * a[1,1,ix,iy,iz,it]
                        b[2,2,ix,iy,iz,it] =  0.5*im * a[1,2,ix,iy,iz,it]
                        b[2,3,ix,iy,iz,it] =  0.5*im * a[1,3,ix,iy,iz,it]
                        b[3,1,ix,iy,iz,it] = 0
                        b[3,2,ix,iy,iz,it] = 0
                        b[3,3,ix,iy,iz,it] = 0
                    end
                end
            end
        end
    elseif k==3
        for it = 1:PN[1]
            for iz = 1:PN[2]
                for iy = 1:PN[3]
                    @inbounds @simd for ix = 1:PN[4]
                        b[1,1,ix,iy,iz,it] =  0.5 * a[1,1,ix,iy,iz,it] 
                        b[1,2,ix,iy,iz,it] =  0.5 * a[1,2,ix,iy,iz,it]
                        b[1,3,ix,iy,iz,it] =  0.5 * a[1,3,ix,iy,iz,it]
                        b[2,1,ix,iy,iz,it] = -0.5 * a[2,1,ix,iy,iz,it]
                        b[2,2,ix,iy,iz,it] = -0.5 * a[2,2,ix,iy,iz,it]
                        b[2,3,ix,iy,iz,it] = -0.5 * a[2,3,ix,iy,iz,it]
                        b[3,1,ix,iy,iz,it] = 0
                        b[3,2,ix,iy,iz,it] = 0
                        b[3,3,ix,iy,iz,it] = 0
                    end
                end
            end
        end
    elseif k==4
        for it = 1:PN[1]
            for iz = 1:PN[2]
                for iy = 1:PN[3]
                    @inbounds @simd for ix = 1:PN[4]
                        b[1,1,ix,iy,iz,it] = 0.5 * a[3,1,ix,iy,iz,it] 
                        b[1,2,ix,iy,iz,it] = 0.5 * a[3,2,ix,iy,iz,it]
                        b[1,3,ix,iy,iz,it] = 0.5 * a[3,3,ix,iy,iz,it]
                        b[2,1,ix,iy,iz,it] = 0
                        b[2,2,ix,iy,iz,it] = 0
                        b[2,3,ix,iy,iz,it] = 0
                        b[3,1,ix,iy,iz,it] = 0.5 * a[1,1,ix,iy,iz,it]
                        b[3,2,ix,iy,iz,it] = 0.5 * a[1,2,ix,iy,iz,it]
                        b[3,3,ix,iy,iz,it] = 0.5 * a[1,3,ix,iy,iz,it]
                    end
                end
            end
        end
    elseif k==5
        for it = 1:PN[1]
            for iz = 1:PN[2]
                for iy = 1:PN[3]
                    @inbounds @simd for ix = 1:PN[4]
                        b[1,1,ix,iy,iz,it] = -0.5*im * a[3,1,ix,iy,iz,it] 
                        b[1,2,ix,iy,iz,it] = -0.5*im * a[3,2,ix,iy,iz,it]
                        b[1,3,ix,iy,iz,it] = -0.5*im * a[3,3,ix,iy,iz,it]
                        b[2,1,ix,iy,iz,it] = 0
                        b[2,2,ix,iy,iz,it] = 0
                        b[2,3,ix,iy,iz,it] = 0
                        b[3,1,ix,iy,iz,it] =  0.5*im * a[1,1,ix,iy,iz,it]
                        b[3,2,ix,iy,iz,it] =  0.5*im * a[1,2,ix,iy,iz,it]
                        b[3,3,ix,iy,iz,it] =  0.5*im * a[1,3,ix,iy,iz,it]
                    end
                end
            end
        end
    elseif k==6
        for it = 1:PN[1]
            for iz = 1:PN[2]
                for iy = 1:PN[3]
                    @inbounds @simd for ix = 1:PN[4]
                        b[1,1,ix,iy,iz,it] = 0
                        b[1,2,ix,iy,iz,it] = 0
                        b[1,3,ix,iy,iz,it] = 0
                        b[2,1,ix,iy,iz,it] = 0.5 * a[3,1,ix,iy,iz,it] 
                        b[2,2,ix,iy,iz,it] = 0.5 * a[3,2,ix,iy,iz,it]
                        b[2,3,ix,iy,iz,it] = 0.5 * a[3,3,ix,iy,iz,it]
                        b[3,1,ix,iy,iz,it] = 0.5 * a[2,1,ix,iy,iz,it]
                        b[3,2,ix,iy,iz,it] = 0.5 * a[2,2,ix,iy,iz,it]
                        b[3,3,ix,iy,iz,it] = 0.5 * a[2,3,ix,iy,iz,it]
                    end
                end
            end
        end
    elseif k==7
        for it = 1:PN[1]
            for iz = 1:PN[2]
                for iy = 1:PN[3]
                    @inbounds @simd for ix = 1:PN[4]
                        b[1,1,ix,iy,iz,it] = 0
                        b[1,2,ix,iy,iz,it] = 0
                        b[1,3,ix,iy,iz,it] = 0
                        b[2,1,ix,iy,iz,it] = -0.5*im * a[3,1,ix,iy,iz,it] 
                        b[2,2,ix,iy,iz,it] = -0.5*im * a[3,2,ix,iy,iz,it]
                        b[2,3,ix,iy,iz,it] = -0.5*im * a[3,3,ix,iy,iz,it]
                        b[3,1,ix,iy,iz,it] =  0.5*im * a[2,1,ix,iy,iz,it]
                        b[3,2,ix,iy,iz,it] =  0.5*im * a[2,2,ix,iy,iz,it]
                        b[3,3,ix,iy,iz,it] =  0.5*im * a[2,3,ix,iy,iz,it]
                    end
                end
            end
        end
    elseif k==8
        for it = 1:PN[1]
            for iz = 1:PN[2]
                for iy = 1:PN[3]
                    @inbounds @simd for ix = 1:PN[4]
                        b[1,1,ix,iy,iz,it] =  sr3ih * a[1,1,ix,iy,iz,it] 
                        b[1,2,ix,iy,iz,it] =  sr3ih * a[1,2,ix,iy,iz,it]
                        b[1,3,ix,iy,iz,it] =  sr3ih * a[1,3,ix,iy,iz,it]
                        b[2,1,ix,iy,iz,it] =  sr3ih * a[2,1,ix,iy,iz,it] 
                        b[2,2,ix,iy,iz,it] =  sr3ih * a[2,2,ix,iy,iz,it]
                        b[2,3,ix,iy,iz,it] =  sr3ih * a[2,3,ix,iy,iz,it]
                        b[3,1,ix,iy,iz,it] = -sqr3inv * a[3,1,ix,iy,iz,it]
                        b[3,2,ix,iy,iz,it] = -sqr3inv * a[3,2,ix,iy,iz,it]
                        b[3,3,ix,iy,iz,it] = -sqr3inv * a[3,3,ix,iy,iz,it]
                    end
                end
            end
        end
    else
        error("k should be k <= 8 but k = $k")
    end
    #error("lambda_k_mul! is not implemented in type $(typeof(a)) and $(typeof(b))")
end

"""
    b = (lambda_k/2)*a
    lambda_k : SU2 matrices. k=1, 3
"""
function lambda_k_mul!(b::Gaugefields_4D_nowing_mpi{2}, a::Gaugefields_4D_nowing_mpi{2},k,generator)
    PN = a.PN


    if k==1
        for it = 1:PN[1]
            for iz = 1:PN[2]
                for iy = 1:PN[3]
                    @inbounds @simd for ix = 1:PN[4]
                        b[1,1,ix,iy,iz,it] = -0.5*im* a[2,1,ix,iy,iz,it]*im
                        b[1,2,ix,iy,iz,it] = -0.5*im * a[2,2,ix,iy,iz,it]*im

                        b[2,1,ix,iy,iz,it] = -0.5*im * a[1,1,ix,iy,iz,it]*im
                        b[2,2,ix,iy,iz,it] = -0.5*im * a[1,2,ix,iy,iz,it]*im
                    end
                end
            end
        end
    elseif k==2
        for it = 1:PN[1]
            for iz = 1:PN[2]
                for iy = 1:PN[3]
                    @inbounds @simd for ix = 1:PN[4]
                        b[1,1,ix,iy,iz,it] = -0.5 * a[2,1,ix,iy,iz,it] *im
                        b[1,2,ix,iy,iz,it] = -0.5 * a[2,2,ix,iy,iz,it]*im

                        b[2,1,ix,iy,iz,it] =  0.5 * a[1,1,ix,iy,iz,it]*im
                        b[2,2,ix,iy,iz,it] =  0.5 * a[1,2,ix,iy,iz,it]*im
                    end
                end
            end
        end
    elseif k==3
        for it = 1:PN[1]
            for iz = 1:PN[2]
                for iy = 1:PN[3]
                    @inbounds @simd for ix = 1:PN[4]
                        b[1,1,ix,iy,iz,it] =  -0.5*im * a[1,1,ix,iy,iz,it] *im
                        b[1,2,ix,iy,iz,it] =  -0.5*im * a[1,2,ix,iy,iz,it]*im

                        b[2,1,ix,iy,iz,it] = 0.5*im * a[2,1,ix,iy,iz,it]*im
                        b[2,2,ix,iy,iz,it] = 0.5*im * a[2,2,ix,iy,iz,it]*im
                    end
                end
            end
        end
    else
        error("k should be k <= 3 but k = $k")
    end

    return
end

"""
    b = (lambda_k/2)*a
    lambda_k : SUN matrices. k=1, ...
"""
function lambda_k_mul!(b::Gaugefields_4D_nowing_mpi{NC},a::Gaugefields_4D_nowing_mpi{NC},k,generator) where NC
    PN = a.PN
    #NV = a.NV
    #NC = generator.NC
    matrix = generator.generator[k]
    for it = 1:PN[1]
        for iz = 1:PN[2]
            for iy = 1:PN[3]
                @inbounds @simd for ix = 1:PN[4]
                    for k2=1:NC
                        for k1=1:NC
                            b[k1,k2,ix,iy,iz,it] = 0
                            @simd for l=1:NC
                                b[k1,k2,ix,iy,iz,it] += matrix[k1,l]*a[l,k2,ix,iy,iz,it]/2
                            end
                        end
                    end
                end
            end
        end
    end


    return
end


#end
