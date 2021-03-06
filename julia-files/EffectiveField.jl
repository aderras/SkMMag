#=
    The effective field at point i in a spin system is

                        (H_eff)_i = - dE/ds_i

    where E is the total energy of the system. Here we consider the effective
    field generated by exchange, Zeeman, Dzyaloshinskii-Moriya (only
    Bloch-type), dipolar, and perpendicular magnetic anisotropy (in z)
    interactions.

    This module contains two types of effective field functions:
        1. Ones that find the effective field at a particular point
        2. Ones that find the effective field of the entire lattice

    The functions are presented in this order in the code.

    Additionally, a few of the functions calculate the effective exchange energy
    for a lattice that contains an exchange-modifying defect.

    Useful functions:
       effectivefieldelem! computes effective field at a point
       effectivefield computes effective field of the whole lattice

    Note: effectivefieldelem! does not compute DDI field. This is because the
    DDI field must be computed for the entire lattice at once. (It's possible to
    compute element-wise DDI by executing FFT, but it would be prohibitively
    slow.) This function is only used in the field alignment algorithm, and
    there we calculate the full dipolar field every few iterations.

    IMPROVEMENTS:
        + Rewrite exchangefield_defect! in a faster julian way
=#
module EffectiveField

    import DipoleDipole
    export effectivefieldelem!, effectivefield, ddifield, defectarray,
    exchangefield!, zeemanfield!, pmafield!, dmifield!

    # effectivefieldelem! modifies a (3, 1) array to equal the effective field
    # at some point nx,ny. Prealocating this way improves speed.
    #
    # in: mat = (3, m, n) spin matrix, effField = (3, 1) arbitrary array
    # used to store answer, nx,ny = position of the spin component of interest,
    # params =  [J, H, DMI, PMA, ED, PBC, PIN, POS] material parameters,
    # defectParams = defect parameters (optional argument)
    #
    # out: nothing
    function effectivefieldelem!(effField::Array{Float64,1},
        mat::Array{Float64,3}, nx::Int, ny::Int, params)

        matParams = params.mp

        j,h,a,dz,ed,n,m,nz,pbc,v =
            [getfield(matParams, x) for x in fieldnames(typeof(matParams))]

        # Compute zeeman field
        effField[1] = 0.
        effField[2] = 0.
        effField[3] = h

        # Compute exchange field
        if params.defect.t==0
            exchangefieldelem!(effField, mat, nx, ny, j, pbc==1.0)
        elseif params.defect.t==2
            exchangefieldelem!(effField, mat, nx, ny, params )
        end

        # Compute DMI and PMA if they're not set to zero
        if a != 0.0
            dmifieldelem!(effField, mat, nx, ny, a, pbc==1.0)
        end
        if dz != 0.0
            pmafieldelem!(effField, mat, nx, ny, dz)
        end

    end

    # This function modifies effField to store the exchange field of the array,
    # mat. Nearest neighbor spins are considered.
    #
    # in: mat = (3, m, n), effField = (3, 1) array used to store answer,
    # nx, ny = positions in mat to calculate exchange field, J = exchange
    # constant, pbc = periodic boundary conditions
    #
    # out: nothing
    function exchangefieldelem!(effField::Array{Float64,1},
        mat::Array{Float64,3}, nx::Int, ny::Int, J::Float64, pbc)

        p, m, n = size(mat)

        if nx > 1 && nx < m
            for k in 1:3
                effField[k] = effField[k] + J*(mat[k,nx-1,ny] + mat[k,nx+1,ny])
            end
        elseif nx==1
            if pbc==1.0
                for k in 1:3 effField[k] = effField[k] + J * mat[k,m,ny] end
            end
            for k in 1:3 effField[k] = effField[k] + J * mat[k,nx+1,ny] end
        elseif nx == m
            if pbc==1.0
                for k in 1:3 effField[k] = effField[k] + J * mat[k,1,ny] end
            end
            for k in 1:3 effField[k] = effField[k] + J * mat[k,nx-1,ny] end
        end

        if ny > 1 && ny < n
            for k in 1:3
                effField[k] = effField[k] + J*(mat[k,nx,ny-1] + mat[k,nx,ny+1])
            end
        elseif ny==1
            if pbc==1.0
                for k in 1:3 effField[k] = effField[k] + J * mat[k,nx,n] end
            end
            for k in 1:3 effField[k] = effField[k] + J * mat[k,nx,ny+1] end
        elseif ny==n
            if pbc==1.0
                for k in 1:3 effField[k] = effField[k] + J * mat[k,nx,1] end
            end
            for k in 1:3 effField[k] = effField[k] + J * mat[k,nx,ny-1] end
        end
    end

    # This function modifies effField to store the exchange field of the array,
    # mat, which contains a Gaussian-type defect. Nearest neighbor spins are
    # considered.
    #
    # in: mat = (3, m, n), effField = (3, 1) array used to store answer,
    # nx, ny = positions in mat to calculate exchange field, params = struct
    # of all computation parameters
    #
    # out: nothing
    function exchangefieldelem!(effField::Array{Float64,1},
        mat::Array{Float64,3}, nx::Int, ny::Int, params)

        defType,aJ,dJ,jx,jy = [getfield(params.defect, x)
            for x in fieldnames(typeof(params.defect))]
        J = params.mp.j
        pbc = params.mp.pbc==1.0

        # This is the Gaussian-type of defect we consider. The exchange
        # constant is modified by a maximum of aJ at the location of the
        # defect, (jx,jy).
        @inline Jmod(i,j) = J*(1 + aJ*exp(-((i - jx)^2 + (j -jy)^2)/dJ^2))

        p, m, n = size(mat)

        if nx > 1 && nx < m
            for k in 1:3
                effField[k] = effField[k] +
                    Jmod(nx-1/2, ny) * (mat[k,nx-1,ny] + mat[k,nx+1,ny])
            end
        elseif nx == 1
            if pbc==1.0
                for k in 1:3
                    effField[k] = effField[k] + Jmod(nx-1/2, ny) * mat[k,m,ny]
                end
            end

            for k in 1:3
                effField[k] = effField[k] + Jmod(nx+1/2, ny) * mat[k,nx+1,ny]
            end
        elseif nx == m
            if pbc==1.0
                for k in 1:3
                    effField[k] = effField[k] + Jmod(nx+1/2, ny) * mat[k,1,ny]
                end
            end

            for k in 1:3
                effField[k] = effField[k] + Jmod(nx+1/2, ny) * mat[k,nx-1,ny]
            end
        end


        if ny > 1 && ny < n
            for k in 1:3
                effField[k] = effField[k] +
                    Jmod(nx, ny-1/2) * (mat[k,nx,ny-1] + mat[k,nx,ny+1])
            end
        elseif ny == 1
            if pbc==1.0
                for k in 1:3
                    effField[k] = effField[k] + Jmod(nx, ny-1/2) * mat[k,nx,n]
                end
            end
            for k in 1:3
                effField[k] = effField[k] + Jmod(nx, ny+1/2) * mat[k,nx,ny+1]
            end

        elseif ny == n
            if pbc==1.0
                for k in 1:3
                    effField[k] = effField[k] + Jmod(nx, ny+1/2) * mat[k,nx,1]
                end
            end
            for k in 1:3
                effField[k] = effField[k] + Jmod(nx, ny+1/2) * mat[k,nx,ny-1]
            end
        end
    end

    # This function modifies effField to add the dmi contribution to the
    # effective field at some point nx, ny.
    #
    # in: mat = (3, m, n), effField = (3, 1) array used to store answer,
    # nx, ny = positions in mat to calculate exchange field, J = exchange
    # constant, pbc = periodic boundary conditions
    #
    # out: nothing
    function dmifieldelem!(effField::Array{Float64,1},
        mat::Array{Float64,3}, nx::Int, ny::Int, dmi::Float64, pbc)

        p,m,n = size(mat)

        if ny==1

            if pbc==1.0
                effField[1]-=dmi*mat[3,nx,n];
                effField[3]+=dmi*mat[1,nx,n];
            end

            effField[1]+=dmi*mat[3,nx,ny+1];
            effField[3]-=dmi*mat[1,nx,ny+1];

        elseif ny==n

            if pbc==1.0
                effField[1]+=dmi*mat[3,nx,1];
                effField[3]-=dmi*mat[1,nx,1];
            end

            effField[1]-=dmi*mat[3,nx,ny-1];
            effField[3]+=dmi*mat[1,nx,ny-1];

        else

            effField[1]+=dmi*(mat[3,nx,ny+1]-mat[3,nx,ny-1]);
            effField[3]+=dmi*(mat[1,nx,ny-1]-mat[1,nx,ny+1]);

        end

        if nx==1

            if pbc==1.0

                effField[2]+=dmi*mat[3,m,ny];
                effField[3]-=dmi*mat[2,m,ny];

            end

            effField[2]-=dmi*mat[3,nx+1,ny];
            effField[3]+=dmi*mat[2,nx+1,ny];

        elseif nx==m

            if pbc==1.0

                effField[2]-=dmi*mat[3,1,ny];
                effField[3]+=dmi*mat[2,1,ny];

            end

            effField[2]+=dmi*mat[3,nx-1,ny];
            effField[3]-=dmi*mat[2,nx-1,ny];

        else

            effField[2]+=dmi*(mat[3,nx-1,ny]-mat[3,nx+1,ny]);
            effField[3]+=dmi*(mat[2,nx+1,ny]-mat[2,nx-1,ny]);

        end

    end

    # pmafieldelem! modifies effField to include the PMA contribution at
    # point (nx, ny)
    #
    # in: mat = spin matrix, effField = effective field at some nx, ny,
    # nx & ny are coordinates of in the spin matrix, pma = anisotropy constant
    #
    # out: nothing
    function pmafieldelem!(effField::Array{Float64,1},
        mat::Array{Float64,3}, nx::Int, ny::Int, pma::Float64)

        effField[3] += pma*mat[3,nx,ny]

    end

    # Computes the effective field for the entire spin array. Returns (3, m, n)
    # array of the matrix
    #
    # in: mat = (3, m, n) spin array, params = struct of all computation
    # parameters
    #
    # out: (3, m, n) array defining effective field at every point in the
    # input array, mat
    function effectivefield(mat::Array{Float64,3}, params)

        matParams = params.mp
        j,h,a,dz,ed,n,m,nz,pbc,v =
            [getfield(matParams, x) for x in fieldnames(typeof(matParams))]

        Heff = zeros(3, m, n)

        # Exchange effective field
        exchangefield!(Heff, mat, params)
        zeemanfield!(Heff, mat, params)

        if a != 0.0
            dmifield!(Heff, mat, params)
        end
        if dz != 0.0
            pmafield!(Heff, mat, params)
        end

        if ed != 0.0
            dipField = Array{Float64}(undef, 3, m, n)
            dipField = ddifield(mat, ed, pbc==1.0, v)

            Heff = Heff + dipField
        end

        # If there is a pinning field, add the field at the point where the
        # skyrmion was initially created.
        hPin = params.pin.hPin
        px = params.ic.px
        py = params.ic.py

        if hPin != 0.0
            # Was testing whether pinning several sites affected results
            # for nx = px-1:px+1, ny = py-1:py+1
            #      Heff[3,nx,ny] = Heff[3,nx,ny] + hPin
            # end
            Heff[3,px,py] = Heff[3,px,py] + hPin
        end

        return Heff
    end

    # Compute the exchange field of the entire spin array, mat. Nearest neighbor
    # interactions are considered.
    #
    # in: mat = (3,m,n) spin array, params = struct of all material params,
    # Heff = (3,m,n) array of the effective field which is modified to store
    # the result
    #
    # out: nothing
    function exchangefield!(Heff::Array{Float64,3},
        mat::Array{Float64,3}, params)

        p, m, n = size(mat)

        if params.defect.t == 2
            exchangefield_defect!(Heff, mat, params)
            return
        end

        J = params.mp.j

        pbc = params.mp.pbc == 1.0

        for j in 1:n, i in 1:m-1, k in 1:p
            Heff[k,i,j] += mat[k,i+1,j]
	    end
        for j in 1:n, i in 2:m, k in 1:p
	        Heff[k,i,j] += mat[k,i-1,j]
	    end
        for j in 1:n-1, i in 1:m, k in 1:p
		    Heff[k,i,j] += mat[k,i,j+1]
	    end
        for j in 2:n, i in 1:m, k in 1:p
		    Heff[k,i,j] += mat[k,i,j-1]
	    end

    	if pbc==1.0
    		for j in 1:n, k in 1:p
    		    Heff[k,m,j] += mat[k,1,j]
    		    Heff[k,1,j] += mat[k,m,j]
    		end
    		for i in 1:m, k in 1:p
    		    Heff[k,i,1] += mat[k,i,n]
    		    Heff[k,i,n] += mat[k,i,1]
    		end
    	end


    end

    # Compute the exchange field of the entire spin array, mat, that contains
    # an exchange-modifying defect. Nearest neighbors considered. We precompute
    # the exchange-modification array and store it in params.defect.jMat[k],
    # where k distinguishes between left neighbor, right neighbor, etc. We
    # distinguis all four because the exchange reduction occurs at the bond
    # between lattice points, so to compute the effective field at lattice site
    # (nx,ny), we need the locations of all the bonds connected to it. This is
    # time-intensive, so precomputing improves speed.
    #
    # in: mat = (3,m,n) spin array, params = struct of all material params,
    # Heff = (3,m,n) array of the effective field which is modified to store
    # the result
    #
    # out: nothing
    function exchangefield_defect!(Heff::Array{Float64,3},
        mat::Array{Float64,3}, params)

        p, m, n = size(mat)
        pbc = params.mp.pbc == 1.0

        # There's a tiny improvement in benchmark speed by writing the for
        # loop this way. Not sure if it's real improvement, but I'll take what
        # I can get.
        for k in 1:3
            for ny in 1:m
                for nx in 1:n

                    if pbc==1.0
                        nxNext = nx%m + 1
                        nyNext = ny%n + 1

                        if nx == 1
                            nxPrev = m
                        else
                            nxPrev = nx-1
                        end
                        if ny == 1
                            nyPrev = n
                        else
                            nyPrev = ny-1
                        end

                        Heff[k,nx,ny] = Heff[k,nx,ny] +
                            params.defect.jMat[1][nx,ny] * mat[k,nxPrev,ny] +
                            params.defect.jMat[2][nx,ny] * mat[k,nxNext,ny] +
                            params.defect.jMat[3][nx,ny] * mat[k,nx,nyPrev] +
                            params.defect.jMat[4][nx,ny] * mat[k,nx,nyNext]

                    else

                        if nx > 1
                            Heff[k,nx,ny] = Heff[k,nx,ny] +
                                params.defect.jMat[1][nx,ny]*mat[k,nx-1,ny]
                        end
                        if ny > 1
                            Heff[k,nx,ny] = Heff[k,nx,ny] +
                                params.defect.jMat[3][nx,ny]*mat[k,nx,ny-1]
                        end
                        if nx < m
                            Heff[k,nx,ny] = Heff[k,nx,ny] +
                                params.defect.jMat[2][nx,ny]*mat[k,nx+1,ny]
                        end
                        if ny < n
                            Heff[k,nx,ny] = Heff[k,nx,ny] +
                                params.defect.jMat[4][nx,ny]*mat[k,nx,ny+1]
                        end
                    end
                end
            end
        end
    end

    # Calculates the gaussian-like modification for each type of bond (left,
    # right, top, bottom) at every point in the lattice.
    #
    # in: aJ = strength of modification, dJ = widfh of modification, jx =
    # position of the defect in x, jy = position of the defect in y.
    #   NOTE: This only works with the rest of the program if the defect is at
    #   the center of the lattice. Need to generalize this.
    #
    # out: [A1,A2,A3,A4] where each A is an (m,n) matrix
    function defectarray(aJ, dJ, jx, jy)

        nx = round(Int, jx*2)
        ny = round(Int, jy*2)

        left = zeros(nx,ny)
        right = zeros(nx,ny)
        top = zeros(nx,ny)
        bott = zeros(nx,ny)

        for i in 1:nx, j in 1:ny
            left[i,j] = (1+aJ*exp(-((i-jx-1/2)^2 + (j-jy)^2)/dJ^2))
            right[i,j] = (1+aJ*exp(-((i-jx+1/2)^2 + (j-jy)^2)/dJ^2))
            top[i,j] = (1+aJ*exp(-((i-jx)^2 + (j-jy-1/2)^2)/dJ^2))
            bott[i,j] = (1+aJ*exp(-((i-jx)^2 + (j-jy+1/2)^2)/dJ^2))
        end

        return [left, right, top, bott]
    end

    # Calculates the dmi field of the entire spin array.
    #
    # in: mat = (3,m,n) spin array, params = struct of all material params,
    # Heff = (3,m,n) array of the effective field which is modified to store
    # the result
    #
    # out: nothing
    function dmifield!(Heff::Array{Float64,3},
        mat::Array{Float64,3}, params)

        p,m,n = size(mat)

        dmi = params.mp.a
        pbc = params.mp.pbc == 1.0

        for nx in 1:m, ny in 1:n

            if ny==1
                if pbc==1.0
                    Heff[1,nx,ny] = Heff[1,nx,ny] - dmi*mat[3,nx,n]
                    Heff[3,nx,ny] = Heff[3,nx,ny] + dmi*mat[1,nx,n]
                end
                Heff[1,nx,ny] = Heff[1,nx,ny] + dmi*mat[3,nx,ny+1]
                Heff[3,nx,ny] = Heff[3,nx,ny] - dmi*mat[1,nx,ny+1]

            elseif ny==n
                if pbc==1.0
                    Heff[1,nx,ny] = Heff[1,nx,ny] + dmi*mat[3,nx,1]
                    Heff[3,nx,ny] = Heff[3,nx,ny] - dmi*mat[1,nx,1]
                end
                Heff[1,nx,ny] = Heff[1,nx,ny] - dmi*mat[3,nx,ny-1]
                Heff[3,nx,ny] = Heff[3,nx,ny] + dmi*mat[1,nx,ny-1]

            else
                Heff[1,nx,ny] = Heff[1,nx,ny]+dmi*(mat[3,nx,ny+1]-mat[3,nx,ny-1])
                Heff[3,nx,ny] = Heff[3,nx,ny]+dmi*(mat[1,nx,ny-1]-mat[1,nx,ny+1])
            end

            if nx==1
                if pbc==1.0
                    Heff[2,nx,ny] = Heff[2,nx,ny] + dmi*mat[3,m,ny]
                    Heff[3,nx,ny] = Heff[3,nx,ny] - dmi*mat[2,m,ny]
                end
                Heff[2,nx,ny] = Heff[2,nx,ny] - dmi*mat[3,nx+1,ny]
                Heff[3,nx,ny] = Heff[3,nx,ny] + dmi*mat[2,nx+1,ny]

            elseif nx==m
                if pbc==1.0
                    Heff[2,nx,ny] = Heff[2,nx,ny] - dmi*mat[3,1,ny]
                    Heff[3,nx,ny] = Heff[3,nx,ny] + dmi*mat[2,1,ny]
                end
                Heff[2,nx,ny] = Heff[2,nx,ny] + dmi*mat[3,nx-1,ny]
                Heff[3,nx,ny] = Heff[3,nx,ny] - dmi*mat[2,nx-1,ny]

            else
                Heff[2,nx,ny] = Heff[2,nx,ny]+dmi*(mat[3,nx-1,ny]-mat[3,nx+1,ny])
                Heff[3,nx,ny] = Heff[3,nx,ny]+dmi*(mat[2,nx+1,ny]-mat[2,nx-1,ny])
            end

        end

    end

    # Calculates the entire Zeeman effective field
    #
    # in: mat = (3,m,n) spin array, params = struct of all material params,
    # Heff = (3,m,n) array of the effective field which is modified to store
    # the result
    #
    # out: nothing
    function zeemanfield!(Heff::Array{Float64,3},
        mat::Array{Float64,3}, params)

        p, m, n = size(mat)

        H = params.mp.h

        for i in 1:m, j in 1:n, p in 3
            Heff[p,i,j] +=  H
        end

    end

    # Calculates the entire PMA effective field.
    #
    # in: mat = (3,m,n) spin array, params = struct of all material params,
    # Heff = (3,m,n) array of the effective field which is modified to store
    # the result
    #
    # out: nothing
    function pmafield!(Heff::Array{Float64,3},
        mat::Array{Float64,3}, params)

        p, m, n = size(mat)

        Dz = params.mp.dz

        for i in 1:m, j in 1:n, p in 3
            Heff[p,i,j] = Heff[p,i,j] + Dz * mat[p, i, j]
        end

    end

    # Compute the DDI field of a spin array, mat.
    #
    # in: mat = (3, m, n) array of spins, ed = DDI constant, pbc =
    # boolean defining periodic boundary conditions, phi matrices =
    # array of matrices used to compute DDI
    #
    # out: field = (3, m, n) array containing values of DDI field
    # at every point of mat.
    function ddifield(mat::Array{Float64,3}, ed::Float64, pbc,
        phiMatrices::Array{Array{Float64,2},1})

        p, m, n = size(mat)
        field = Array{Float64}(undef, p, m, n)

        field = ed * DipoleDipole.fhd(mat, phiMatrices, pbc)

        return field
    end

end
