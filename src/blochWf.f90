module blochWf
	!generates bloch and lattice periodidc functions given a basCoeff matrix
	use mathematics,	only:	dp, PI_dp,i_dp, acc, myExp, myLeviCivita, eigSolver, nIntegrate
	use sysPara

	implicit none

	private
	public	::	genBwfVelo, genUnk, testNormal


	contains







!public
	subroutine genBwfVelo(qi,basCoeff, bWf, velobWf)
		!generates the bloch wavefunctions, with  the basCoeff from eigSolver
		integer		, intent(in)	:: qi
		complex(dp)	, intent(in)	:: basCoeff(:,:)
		complex(dp)	, intent(out)	:: bWf(:,:,:), velobWf(:,:,:)	!bWf(nRpts,nG)			
		complex(dp)	, allocatable	:: basVec(:)
		integer 				 	:: xi
		allocate(	basVec(nG)	)
		!$OMP PARALLEL DO SCHEDULE(STATIC) DEFAULT(SHARED) PRIVATE(xi, basVec)
		do xi = 1, nR
				!WAVEFUNCTIONS
				call calcBasVec(qi,xi, basVec)
				bWf(xi,:,qi) = matmul(	 basVec , basCoeff	)  /  dsqrt(vol)
				!VELOCITIES
				call calcVeloBasVec(qi,xi, basVec)
				velobWf(xi,qi,:) = matmul(	 basVec , basCoeff	)  /  dsqrt(vol)
		end do
		!
		return 
	end subroutine




	!logical function BwFisLattSym(bWf)
	!	!ToDo
	!	!checks if bwf(k) = bwf(k+G)
	!	complex(dp),	intent(in)		:: bWf(:,:,:) !nR, nK , nG or nWfs
	!	integer							:: k00, k10, k01, k11, n ! edge point indices
!
!	!	BwFisLattSym = .true.
!	!	k00 = getKindex(	1	, 1		)
!	!	k10	= getKindex(	nKx	, 1		)
!	!	k01 = getKindex(	1	, nKy	)
!	!	k11 = getKindex(	nKx , nKy	)
!	!	write(*,'(a,i3,a,i3,a,i3,a,i3)')"[isLattSym]: k00 =",k00,", k10=",k10,", k01=",k01,", k11=",k11 
!
!
!	!	do n = 1, size(bwf,3) ! loop states
!
!	!	end do
!
!	!	return
	!end


	subroutine genUnk(qi, bWf, unk)
		! generates the lattice periodic part from given bloch wave functions
		integer,		intent(in)		:: qi
		complex(dp),	intent(in)		:: bWf(:,:) !lobWf(	nR, nWfs)
		complex(dp),	intent(out)		:: unk(:,:,:)   !unk(	nR, nWfs)
		integer							:: xi, n
		complex(dp)						:: phase
		!
		!$OMP PARALLEL DO SCHEDULE(STATIC) COLLAPSE(2) DEFAULT(SHARED) PRIVATE(n, xi, phase) 
		do n = 1, nWfs
			do xi = 1, nR
				phase		 = myExp( -1.0_dp 	*	 dot_product( qpts(:,qi) , rpts(:,xi)	) 			)
				unk(xi,qi,n) = phase * bWf(xi,n)
			end do
		end do
		!$OMP END PARALLEL DO
		!
		return
	end subroutine


	subroutine testNormal(bwf)
		! <Y_nk1|Y_mk2> = N * \delta_n,m * \delta_k1,k2
		complex(dp),	intent(in)		:: bwf(:,:,:)
		complex(dp),	allocatable		:: f(:)
		integer							:: ri, q1,q2, n,m, count, tot
		complex(dp)						:: oLap
		real(dp)						:: avg
		!
		allocate(	f(nR)	)
		!
		count	= 0
		avg		= 0.0_dp
		tot		= 0
		!
		do m = 1, nWfs
			do n = 1, nWfs
				do q1 = 1, nQ
					!do q2 = 1, nQ
						!FILL INTEGRATION ARRAY
						do ri = 1, nR
							f(ri)	= dconjg(bwf(ri,q1,n)) * bwf(ri,q1,m)
						end do
						oLap	= nIntegrate(nR, nRx,nRy, dx,dy, f)
						!CHECK CONDITION
						if( dimag(oLap) > acc ) then
							count	= count + 1
							avg		= avg	+ abs(dreal(oLap)-nSC)
						else
							if(n==m .and. q1==q2) then
								if(abs(dreal(oLap)-nSC) > acc )then
									count	= count + 1
									avg		= avg	+ abs(dreal(oLap)-nSC)
								end if
							else
								if(abs(dreal(oLap)) > acc )then
									count	= count + 1
									avg		= avg	+ abs(dreal(oLap)-nSC)
								end if
							end if
						end if
						!
						!
						tot	= tot + 1
					!end do
				end do
			end do
		end do

		avg	= avg / real(tot,dp)
		write(*,*)"[testNormal]: found ",count," points of ",tot," not normalized bwfs, avg diff=",avg

		return
	end subroutine












!privat
	subroutine calcBasVec(qi, ri, basVec)
		!calculates the basis vectors e^i(k+G).r
		!	if |k+G| is larger then the cutoff the basis vector is set to zero
		!	the cutoff enforces a symmetric base at each k point
		integer,	 intent(in)  :: qi, ri
		complex(dp), intent(out) :: basVec(:)
		real(dp)				 :: tmp(2)
		integer 				 ::	i 
		!

		do i =1, nG
			tmp(:) = qpts(:,qi) + Gvec(:,i)
			!
			if( norm2(tmp) < Gcut ) then
				basVec(i) = myExp( 		dot_product( tmp, rpts(:,ri) )			)
			else
				basVec(i) = dcmplx( 0.0_dp )
			end if
		end do
		!
		return
	end subroutine



	!VELOCITY HELPERS
	subroutine calcVeloBasVec(qi,ri,basVec)
		!the velocity basis
		integer,		intent(in)		:: qi, ri
		complex(dp),	intent(out)		:: basVec(:)
		real(dp)				 :: tmp(2)
		integer 				 ::	i 
		!
		do i =1, nG
			tmp(:) = qpts(:,qi) + Gvec(:,i)
			!
			if( norm2(tmp) < Gcut ) then
				!X COMPONENT
				basVec(i) 		= i_dp * (	qpts(1,qi) + Gvec(1,i)	) * myExp( 		dot_product( tmp, rpts(:,ri) )			)
				!Y COMPONENT
				basVec(i+nG)	= i_dp * (	qpts(2,qi) + Gvec(2,i)	) * myExp(		dot_product( tmp, rpts(:,ri) )			)
			else
				basVec(i) = dcmplx( 0.0_dp )
			end if
		end do
		!		
		!
		return
	end subroutine



end module blochWf













