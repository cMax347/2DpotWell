module potWellModel
	!this modules sets up the Hamiltonian matrix and solves it for each k point
	!	in the process the wannier functions are generated aswell with routines from wannGen module
	use mathematics,	only:	dp, PI_dp,i_dp, machineP, myExp, myLeviCivita, eigSolver, nIntegrate, isHermitian
	use sysPara
	use blochWf,		only:	genBlochWf, calcVeloBwf, genUnk									
	use wannGen,		only:	projectBwf, genWannF
	use output,			only:	printMat
	implicit none	
	
	private
	public ::					solveHam



		

	


	contains
!public:
	subroutine solveHam(wnF, unkW)
		!solves Hamiltonian at each k point
		!also generates the Wannier functions on the fly (sum over all k)
		complex(dp),	intent(out)		::	wnF(:,:,:), unkW(:,:,:)!, veloBwf(:,:,:)		!Uh(  nWfs	, nWfs,		nK		)	
																				!wnF( nR	, nSupC,	nWfs	)	
																				!unkW(nR	, nKpts,	nWfs	)
																				!veloBwf(nR,nK,2*nG)
		!real(dp),		intent(out)		::	En(:,:)																	
		complex(dp),	allocatable		::	Hmat(:,:), bWf(:,:), lobWf(:,:), gnr(:,:), U(:,:)
		real(dp),		allocatable		::	EnT(:), bwfR(:,:), bwfI(:,:)	 
		integer							:: 	qi, xi , n, failCount
		real(dp)						::	kVal(dim), smin, smax
		!
		allocate(	Hmat(	nG,	nG	)			)
		allocate(	U(		nG, nG	)			)
		allocate(	EnT(		nG	)			)	
		allocate(	bWf(	nR, nG	)			)
		allocate(	bWfR(	nR, nG	)			)
		allocate(	bWfI(	nR, nG	)			)
		allocate(	lobWf(	nR, nWfs)			)
		allocate(	gnr(	nR,	nWfs)			)
		
		wnF			=	dcmplx(0.0_dp)
		bWf			=	dcmplx(0.0_dp)
		unkW		=	dcmplx(0.0_dp)
		!veloBwf		=	dcmplx(0.0_dp)
		failCount	=	0
		smin		=	1.0_dp
		smax		= 	0.0_dp
		!
		
		!call genTrialOrb(gnr) !ToDo
		!
		open(unit=200, file='rawData/bandStruct.dat', form='unformatted', access='stream', action='write')
		open(unit=210, file='rawData/bwfR.dat'		, form='unformatted', access='stream', action='write')
		open(unit=211, file='rawData/bwfI.dat'		, form='unformatted', access='stream', action='write')
		do qi = 1, nQ
			!write(*,*)"[solveHam]: qi=",qi
			kVal	=	qpts(:,qi)
			!
			call populateH(kVal, Hmat)	
			call eigSolver(Hmat, EnT)
			write(200)	EnT
			!En(qi,:) = EnT(1:nWfs) 
			!
			call gaugeCoeff(kVal, Hmat)
			call genBlochWf(qi, Hmat, bWf)		
			!call calcVeloBwf(qi,Hmat, veloBwf)
			bWfR 	= dreal(bWf)                 !Todo fix that
			bWfI	= dimag(bWf)
			write(210)bWfR
			write(211)bwfI
			!
			call projectBwf(qi, bWf, loBwf, U(:,:), failCount, smin, smax)
			
			call genWannF(qi, lobWf, wnF)

			call genUnk(qi, lobWf, unkW(:, qi, :))
			!
		end do
		write(*,'(a,f16.15,a,f16.12)') "[solveHam]: projection matrix  smin=", smin, " smax=", smax
		write(*,'(a,i7,a)')"[solveHam]: ",failCount," of the projected bloch like functions are not orthonormal"
		close(200)
		close(210)
		close(211)
		!
		return
	end














!private:
	!POPULATION OF H MATRIX
	subroutine populateH(k, Hmat)
		!populates the Hamiltonian matrix by adding 
		!	1. qinetic energy terms
		!	2. potential terms
		!and checks if the resulting matrix is still hermitian( for debugging)
		real(dp)   , intent(in)    :: k(dim)
		complex(dp), intent(inout) :: Hmat(:,:)
		!init to zero
		Hmat = dcmplx(0.0_dp) 
		!
		!FEATURES:
		call Hkin(k,Hmat) 
		call Hpot( Hmat)
		!
		!DEBUGGING:
		if ( .not.	isHermitian(Hmat)	) then
			write(*,*)"[populateH]: Hamiltonian matrix is not Hermitian :"
			call printMat(nG, Hmat)
		else
			!write(*,*)"[populateH]: Hmat is hermitian"
		end if
		return
	end


	subroutine Hkin(q, Hmat)
		!add kinetic energy to Hamiltonian
		real(dp)   , intent(in)	   :: q(2)
		complex(dp), intent(inout) :: Hmat(:,:)
		integer 				   :: i
		real(dp)				   :: fact, kg(2)
		fact = 0.5_dp	!hbar*hbar/(2*me) in a.u.
		do i = 1, nG
			kg(:) = q(:) + Gvec(:,i)
			Hmat(i,i) = Hmat(i,i) +  dcmplx(	fact * dot_product(kg,kg) , 0.0_dp	) 
		end do
		return
	end


	subroutine Hpot( Hmat)
		!Add potential to Hamiltonian
		complex(dp) , intent(inout) :: Hmat(:,:)
		integer 					:: i,j
		complex(dp)					:: tmp
		do i = 1,nG
			do j = 1,nG
				tmp			= V(i,j)
				!write(*,'(a,i2,a,i2,a,f15.10,a,f15.10)')	"[Hpot]: V(",i,",",j,") =",dreal(tmp),"+i*",dimag(tmp)
				Hmat(i,j)	= Hmat(i,j) + tmp
			end do
		end do
		!
		return
	end


	complex(dp) function V(i,j)
		!calc potential matrix elements
		!the integrals were solved analytical and are hard coded in this function
		integer,	intent(in)	::	i, j
		integer					::	at
		complex(dp)				::	Vx, Vy, Vpot
		real(dp)				::  xL, yL, xR, yR, dGx, dGy
		!
		V 		= dcmplx(0.0_dp)
		dGx		= Gvec(1,j) - Gvec(1,i)
		dGy		= Gvec(2,j) - Gvec(2,i)
		!
		do at = 1, nAt
			Vpot	=	dcmplx(atPot(at))
			xL	=	atPos(1,at) - atR(1,at)
			xR	=	atPos(1,at) + atR(1,at) 
			yL	=	atPos(2,at) - atR(2,at)
			yR	=	atPos(2,at) + atR(2,at) 
			!
			if( abs(dGx) < machineP ) then
				!write(*,*)"zero x difference i=",i," j=",j
				Vx	= ( xR - xL )
			else
				Vx	= -i_dp	*	(	myExp(dGx*xR) - myExp(dGx*xL)	)	/ dcmplx( dGx )
			end if
			

			if( abs(dGy) < machineP ) then
				!write(*,*)"zero y difference i=",i," j=",j
				Vy	= ( yR - yL )
			else
				Vy	= -i_dp *	(	myExp(dGy*yR) - myExp(dGy*yL)	)	/ dcmplx( dGy )
			end if
			!
			!
			V	= V +	Vpot*Vx*Vy
			!write(*,'(a,i2,a,i2,a,f15.10)')	"i=",i," j=",j,": atPot=",Vpot
			!write(*,'(a,i2,a,i2,a,f15.10,a,f15.10)')	"i=",i," j=",j,": V=",dreal(V),"+i*",dimag(V)
		end do
		!
		return
	end







	!GAUGING BASIS COEFFICIENTS
	subroutine gaugeCoeff(k, basCoeff)
		!method gauges the basis coefficients directly
		!	controled via the gaugeSwitch from the input file
		!	this should only be used for testing & understanding purposes,
		!	since this gauge trafo is not saved in the U matrix (U matrix rotates between ham & wann gauge)
		real(dp),		intent(in)		:: k(dim)
		complex(dp),	intent(inout) 	:: basCoeff(:,:)
		!
		select case (gaugeSwitch)
			case (1)
				write(*,*) "[gaugeCoeff]: gauging with G=0 phase"
				call gaugeCoeff1(basCoeff)
			!case (2)
			!	write(*,*) "[gaugeCoeff]: gauging with G(nG0-1) for k<=0, and G(nG0+1) for k>0. (G(nG0)=0)"
			!	call gaugeCoeff2(k,basCoeff)
			case (0)
				!write(*,*) "[gaugeCoeff]: use gauge convention from solver"
				! do nothing
			case default
				write(*,*) "[gaugeCoeff]: unknown gaugeSwitch, eigVecs wont be gauged"
		end select
		!
		return
	end


	subroutine gaugeCoeff1(basCoeff)
		!Gauges basCoeff with the G=0 component, effectively removes k-dependence of basCoeff gauge
		complex(dp)	, intent(inout) :: basCoeff(:,:)
		integer						:: i1,i2
		complex(dp)				  	:: phase0
		real(dp)				   	:: delta
		!
		delta=1E-14_dp
		!
		do i2=1,nG !loop eigVecs
			if(	abs( basCoeff(nG0,i2) )	> delta	) then

				phase0 = basCoeff(nG0,i2) / abs(basCoeff(nG0,i2)) 
				do i1=1,nG !gauge each vector
						basCoeff(i1,i2) = basCoeff(i1,i2)/ phase0
				end do
			endif
		end do
		!
		return
	end


	!subroutine gaugeCoeff2(k, basCoeff)
	!	!what does k < 0 mean here ?!, makes only sense in 1D
	!	!for negative k gauge with Gmin, for positive with Gmax
	!	real(dp),		intent(in)		:: k(dim)
	!	complex(dp), 	intent(inout) 	:: basCoeff(:,:)
	!	integer 				   		:: i1,i2
	!	complex(dp)				   		:: phase0
	!	!
	!	do i2=1,nG
	!		if( k <= 0.0_dp) then
	!			phase0 = basCoeff(nG0-1 ,i2) / abs(basCoeff(nG0-1 ,i2))
	!		else
	!			phase0 = basCoeff(nG0+1,i2) / abs(basCoeff(nG0+1,i2))
	!		end if
	!		do i1=1,nG
	!			basCoeff(i1,i2) = basCoeff(i1,i2)/ phase0
	!		end do
	!	end do
	!	!
	!	return
	!end



end module potWellModel