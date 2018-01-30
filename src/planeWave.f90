module planeWave
	!generates bloch and lattice periodidc functions given a basCoeff matrix
	use omp_lib
	use mathematics,	only:	dp, PI_dp,i_dp, acc, machineP,& 
									myExp, myLeviCivita
	use sysPara

	implicit none

	private
	public	::	calcBasis, calcVeloGrad, calcConnOnCoarse, calcMmat


	contains







!public
	subroutine calcBasis(qi, ri, basVec)
		!calculates the basis vectors e^i(k+G).r
		!	if |k+G| is larger then the cutoff the basis vector is set to zero
		!	the cutoff enforces a symmetric base at each k point
		integer,	 intent(in)		:: qi, ri
		complex(dp), intent(out)	:: basVec(:)
		integer 				 	:: i 
		!
		basVec	= 0.0_dp
		do i =1, nGq(qi)
			basVec(i) 		= myExp( dot_product( Gvec(1:2,i,qi), rpts(1:2,ri) )		)  !/ dsqrt(vol)
		end do
		!
		!
		return
	end subroutine


	subroutine calcVeloGrad(ck, v_mat )
		!calculates the velocity operator matrix
		!	Psi_n v Psi_m	= i/hbar Psi_n grad_r Psi_m
		!					= - 1 / hbar sum_G ckn^dag ckm G
		complex(dp),	intent(in)		:: 	ck(:,:,:)
		complex(dp),	intent(out)		::	v_mat(:,:,:,:)
		integer							::	qi, m, n, gi
		!
		v_mat = dcmplx(0.0_dp)
		!
		if(	size(ck,3)/=size(v_mat,4)	) then
			write(*,*)	"[calcVeloGrad]: coeff and velo defined on different k meshes, stop now"
			!call exit(status)
		else
			!$OMP PARALLEL DO SCHEDULE(STATIC) DEFAULT(SHARED) PRIVATE(qi, m, n, gi)
			do qi = 1, nQ
				do m = 1, nSolve
					do n = 1, nSolve
						!
						!SUM OVER BASIS FUNCTIONS
						do gi = 1 , nGq(qi)
							v_mat(1:2,n,m,qi) = v_mat(1:2,n,m,qi) -  dconjg(ck(gi,n,qi)) *  ck(gi,m,qi) *  Gvec(1:2,gi,qi)
						end do
					end do
				end do
			end do
			!$OMP END PARALLEL DO
		end if
		!
		return
	end subroutine


	subroutine calcMmat(qi,knb,gShift, nGq, Gvec, ck, Mmat)
		integer,		intent(in)		:: qi, knb, nGq(:)
		real(dp),		intent(in)		:: gShift(2),  Gvec(:,:,:)
		complex(dp),	intent(in)		:: ck(:,:,:)
		complex(dp),	intent(out)		:: Mmat(:,:)
		integer							:: gi, gj, n, m, cnt
		real(dp)						:: delta(2)
		logical							:: notFound
		!
		Mmat	= dcmplx(0.0_dp)
		cnt		= 0
		do gi = 1, nGq(qi)
			notFound 	= .true.
			gj			= 1
			do while( gj<= nGq(knb) .and. notFound ) 
				delta(1:2)	=  ( Gvec(1:2,gi,qi)-qpts(1:2,qi) ) 	-  		( Gvec(1:2,gj,knb)-qpts(1:2,knb)-gShift(1:2) )
				if( norm2(delta) < machineP )	then
					do n = 1, size(Mmat,2)
						do m = 1, size(Mmat,1)
							Mmat(m,n)	= Mmat(m,n)	+ dconjg(	ck(gi,m,qi)	) * ck(gj,n,knb)
						end do
					end do
					!UNKoverlap	= UNKoverlap +  dconjg( ck(gi,n,qi) ) * ck(gj,m,knb) 
					cnt = cnt + 1
					notFound = .false.
				end if
				gj = gj + 1
			end do
			!if( gj>= nGq(knb) .and. notFound	) write(*,'(a,i3,a,i3)')	"[UNKoverlap]: no neighbour for gi=",gi," at qi=",qi
		end do
		!
		if( cnt > nGq(qi)	)		write(*,'(a,i8,a,i8)')	"[calcMmat]: warning, used ",cnt," where nGmax(qi)=",nGq(qi)
		if( cnt < nGq(qi) / 2.0_dp)	write(*,'(a,i8,a,i8)')	"[calcMmat]: warning, used  only",cnt," where nGmax(qi)=",nGq(qi)
		!
		!
		return
	end subroutine


	subroutine calcConnOnCoarse(ck, A)
		!finite difference on lattice periodic unk to calculate the Berry connection A
		!	A_n(k) 	= <u_n(k)|i \nabla_k|u_n(k)>
		!		 	= i  <u_n(k)| \sum_b{ w_b * b * [u_n(k+b)-u_n(k)]}
		!			= i \sum_b{		w_b	 * [  <u_n(k)|u_n(k+b)> -  <u_n(k)|u_n(k)>]		}
		!
		! see Mazari, Vanderbilt PRB.56.12847 (1997), Appendix B
		!
		complex(dp),	intent(in)		:: ck(:,:,:) 	! ckW(nG, nWfs, nQ)		
		complex(dp),	intent(out)		:: A(:,:,:,:)			
		complex(dp),	allocatable		:: Mtmp(:,:)
		integer							:: n, m, Z, qi, qx, qy, qxl, qxr, qyl, qyr, al, be
		real(dp)						:: wbx,wby, bxl(2), bxr(2), byl(2), byr(2), delta, &
											Gxl(2), Gyl(2), Gxr(2), Gyr(2)
		!
		if( size(nGq) 		/= nQ ) write(*,*)"[#",myID,";calcConnOnCoarse]: critical WARNING: basis array nGq has wrong size"
		if(	size(Gvec,3)	/= nQ ) write(*,*)"[#",myID,";calcConnOnCoarse]: critical WARNING: basis array Gvec has wrong size"

		A 		= dcmplx(0.0_dp)
		Z 		= 4	!amount of nearest neighbours( 2 for 2D cubic unit cell)
		wbx 	= 2.0_dp / 		( real(Z,dp) * dqx**2 )
		wby		= wbx
		write(*,*)	"[calcConnOnCoarse]	weight wb=", wbx
		!wby 	= 1.0_dp /		( real(Z,dp) * dqy**2 )
		!b vector two nearest X neighbours:
		bxl(1) 	= -dqx				
		bxl(2)	= 0.0_dp
		bxr(1) 	= +dqx
		bxr(2)	= 0.0_dp
		!b vector two nearest Y neighbours:
		byl(1) 	= 0.0_dp
		byl(2)	= -dqy
		byr(1) 	= 0.0_dp
		byr(2)	= +dqy
		!
		!DEBUG WEIGHTS
		do al = 1, 2
			do be = 1, 2
				delta 	= 0.0_dp
				delta = delta + wbx * bxl(al) * bxl(be)
				delta = delta + wbx * bxr(al) * bxr(be)
				delta = delta + wby * byl(al) * byl(be)
				delta = delta + wby * byr(al) * byr(be)
				if( al==be .and. abs(delta-1.0_dp) > acc ) then
					write(*,'(a,i1,a,i1,a,f6.3)') &
							"[calcConnCoarse]: weights dont fullfill condition for a=",al," b=",be," delta=",delta
				else if ( al/=be .and. abs(delta) > acc ) then
					write(*,'(a,i1,a,i1,a,f6.3)') & 
							"[calcConnCoarse]: weights dont fullfill condition for a=",al," b=",be,"delta=",delta
				end if
			end do
		end do
		!
		write(*,'(a,f6.3,a,f6.3)')	"[calcConnOnCoarse]: dqx=",dqx," dqy=",dqy
		!
		!$OMP PARALLEL DEFAULT(SHARED) PRIVATE(m,n,qx,qy, qxl, qxr, qyl, qyr, qi, Gxl, Gxr, Gyl, Gyr, Mtmp)
		allocate(	Mtmp( size(A,2), size(A,3) )		)
		!$OMP DO COLLAPSE(2)  SCHEDULE(STATIC)
		do qx = 1, nQx
			do qy = 1, nQy
				!GET NEIGHBOURS
				qxl	= getLeft( qx,nQx)
				qxr	= getRight(qx,nQx)
				qyl	= getLeft(  qy,nQy)
				qyr = getRight( qy,nQy)
				!
				!GET GRID POSITION OF NEIGHBOURS
				qi	= getKindex(qx,qy)
				qxl	= getKindex(qxl,qy)
				qxr	= getKindex(qxr,qy)
				qyl	= getKindex(qx,qyl)
				qyr	= getKindex(qx,qyr)
				!call testNeighB(qi, qxl, qxr, qyl, qyr)
				!
				!SHIFT NEIGHBOURS BACK TO FIRST BZ
				Gxl(:)	= 0.0_dp
				Gxr(:)	= 0.0_dp
				Gyl(:)	= 0.0_dp
				Gyr(:)	= 0.0_dp
				if( qx == 1 ) 	Gxl(1)	= - 2.0_dp * PI_dp / aX
				if( qx == nQx)	Gxr(1)	= + 2.0_dp * PI_dp / aX
				if( qy == 1 ) 	Gyl(2)	= - 2.0_dp * PI_dp / aY
				if( qy == nQy)	Gyr(2)	= + 2.0_dp * PI_dp / aY
				!
				!UNCOMMENT FOR DEBUGGING
				!write(*,*)"*"
				!write(*,*)"*"
				!write(*,*)"*"
				!write(*,'(a,f6.3,a,f6.3,a)')	"[calcConnOnCoarse]: q_i=(",qpts(1,qi) ,", ",qpts(2,qi) ,")"
				!write(*,'(a,f6.3,a,f6.3,a)')	"[calcConnOnCoarse]: qxl=(",qpts(1,qxl),", ",qpts(2,qxl),")"
				!write(*,'(a,f6.3,a,f6.3,a)')	"[calcConnOnCoarse]: qxr=(",qpts(1,qxr),", ",qpts(2,qxr),")"
				!write(*,'(a,f6.3,a,f6.3,a)')	"[calcConnOnCoarse]: qyl=(",qpts(1,qyl),", ",qpts(2,qyl),")"
				!write(*,'(a,f6.3,a,f6.3,a)')	"[calcConnOnCoarse]: qyr=(",qpts(1,qyr),", ",qpts(2,qyr),")"
				!write(*,*)"*"
				!write(*,'(a,f6.3,a,f6.3,a)')"[calcConnOnCoarse]:  Gxl=",Gxl(1),", ",Gxl(2),")."
				!write(*,'(a,f6.3,a,f6.3,a)')"[calcConnOnCoarse]:  Gxr=",Gxr(1),", ",Gxr(2),")."
				!write(*,'(a,f6.3,a,f6.3,a)')"[calcConnOnCoarse]:  Gyl=",Gyl(1),", ",Gyl(2),")."
				!write(*,'(a,f6.3,a,f6.3,a)')"[calcConnOnCoarse]:  Gyr=",Gyr(1),", ",Gyr(2),")."
				!
				!OVLERAPS:
				!XL
				!call calcMmat(qi, nnlist(qi,nn), gShift, nGq_glob, Gvec_glob, ck_glob, M_loc(:,:,nn,qi))
				call calcMmat(qi, qxl, Gxl, nGq, Gvec, ck, Mtmp)
				do n = 1, size(A,3)
					do m = 1, size(A,2)
						A(1:2,m,n,qi)	= A(1:2,m,n,qi) - wbx * bxl(1:2) * dimag( 	log(	Mtmp(m,n) )	 )
					end do
				end do
				!XR
				call calcMmat(qi, qxr, Gxr, nGq, Gvec, ck, Mtmp)
				do n = 1, size(A,3)
					do m = 1, size(A,2)
						A(1:2,m,n,qi)	= A(1:2,m,n,qi) - wbx * bxr(1:2) * dimag( 	log(	Mtmp(m,n) )	 )
					end do
				end do
				!YL
				call calcMmat(qi, qyl, Gyl, nGq, Gvec, ck, Mtmp)
				do n = 1, size(A,3)
					do m = 1, size(A,2)
						A(1:2,m,n,qi)	= A(1:2,m,n,qi) - wby * byl(1:2) * dimag( 	log(	Mtmp(m,n) )	 )
					end do
				end do
				!YR
				call calcMmat(qi, qyr, Gyr, nGq, Gvec, ck, Mtmp)
				do n = 1, size(A,3)
					do m = 1, size(A,2)
						A(1:2,m,n,qi)	= A(1:2,m,n,qi) - wby * byr(1:2) * dimag( 	log(	Mtmp(m,n) )	 )
					end do
				end do
				!
			end do
		end do
		!$OMP END DO
		!$OMP END PARALLEL
		!
		!
		return
	end subroutine



!prviat
	subroutine testNeighB(qi, qxl, qxr, qyl, qyr)
		integer,		intent(in)		:: qi, qxl, qxr, qyl, qyr
		!
		!
		!X LEFT
		if( 	norm2(qpts(:,qi)-qpts(:,qxl)) > dqx+machineP		 ) then
			write(*,'(a,i3,a,f6.3,a,f6.3,a,a,f6.3,a,f6.3,a)')	&
						"[testNeighB]: problem with x left  at qi=",qi,&
						", qi=(",qpts(1,qi),", ",qpts(2,qi),")",&
						", qxl=(",qpts(1,qxl),", ",qpts(2,qxl),")."
		end if
		!
		!X RIGHT
		if( 	norm2(qpts(:,qxr)-qpts(:,qi)) > dqx+machineP 		 ) then
			write(*,'(a,i3,a,f6.3,a,f6.3,a,a,f6.3,a,f6.3,a)')	&
					"[testNeighB]: problem with x right at qi=",qi,&
					", qi=(",qpts(1,qi),", ",qpts(2,qi),")",&
					", qxr=(",qpts(1,qxr),", ",qpts(2,qxr),")."
		end if
		!
		!
		!Y LEFT
		if( norm2(qpts(:,qi)-qpts(:,qyl)) > dqy+machineP  		 ) then
			write(*,'(a,i3,a,f6.3,a,f6.3,a,a,f6.3,a,f6.3,a)')	&
					"[testNeighB]: problem with y left  at qi=",qi,&
					", qi=(",qpts(1,qi),", ",qpts(2,qi),")",&
					", qyl=(",qpts(1,qyl),", ",qpts(2,qyl),")."
		end if
		!
		!Y RIGHT
		if( 	norm2(qpts(:,qyr)-qpts(:,qi)) > dqy+machineP  		 ) then
			write(*,'(a,i3,a,f6.3,a,f6.3,a,a,f6.3,a,f6.3,a)')	& 
					"[testNeighB]: problem with y right at qi=",qi,&
					", qi=(",qpts(1,qi),", ",qpts(2,qi),")",&
					", qyr=(",qpts(1,qyr),", ",qpts(2,qyr),")."
		end if
		write(*,*)"*"
		write(*,*)"*"
		write(*,*)"*"
		!
		!
		return
	end subroutine




	integer function getLeft(i,N)
		!HELPER for calcConn
		!gets left (lower) neighbour, using the periodicity at boundary
		!
		integer,	intent(in)	:: i,N
		if(i.eq.1) then
			getLeft = N
		else
			getLeft = i-1
		end if
		!
		return
	end function


	integer function getRight(i,N)
		!HELPER for calcConn
		!gets right (upper) neighbour, using the periodicity at boundary
		!
		integer,	intent(in)	:: i,N
		if(i.eq.N) then
			getRight = 1
		else
			getRight = i+1
		end if
		!
		return
	end function

end module planeWave 

