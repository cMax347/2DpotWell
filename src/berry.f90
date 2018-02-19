module berry
	!module contains methods related to the Berry phase theory of modern polarization
	!	i.e. calculation of connection, velocities, curvatures and polarization
	use omp_lib
	use sysPara,		only:	Bext, prefactF3, &
								nWfs, nQ, nSolve, vol, &
								qpts, &
								atPos, atPot, &
								doGaugBack, doNiu, fastConnConv, doVeloNum 
	
	use w90Interface,	only:	read_U_matrix, read_M_initial, read_FD_b_vectors, read_wann_centers, &
								readBandVelo
	use basisIO,		only:	read_energies, read_velo
	use semiClassics,	only:	calcFirstOrdP
	use output,			only:	writePolFile, writeVeloHtxt, writeConnTxt

	implicit none

	private
	public	::					berryMethod

	!cloned from mathematics.f90:
	integer, 		parameter 	:: 	dp 				= kind(0.d0)
	real(dp), 		parameter	:: 	machineP 		= 1e-15_dp
	complex(dp),	parameter 	::	i_dp 			= dcmplx(0.0_dp, 1.0_dp)
		real(dp),	parameter 	::	aUtoEv	 		= 27.211385_dp

	!read in parameters:
	integer						::	num_wann, num_bands, num_kpts, num_stat, &
									nntot
	integer,		allocatable	::	nnlist(:,:), nncell(:,:,:)
	real(dp),		allocatable	::	b_k(:,:), w_b(:)








	contains




!public
	subroutine berryMethod()
		complex(dp),	allocatable		:: 	U_mat(:,:,:), M_ham(:,:,:,:), M_wann(:,:,:,:), &
											FcurvQ(:,:,:,:),veloQ(:,:,:,:) 		
		real(dp),		allocatable		::	Aconn_H(:,:,:,:), Aconn_W(:,:,:,:), &
											EnQ(:,:), b_k(:,:), w_b(:), &
											w_centers(:,:), berry_W_gauge(:,:),berry_H_gauge(:,:), niu_polF2(:,:), niu_polF3(:,:)
		integer							::	n
		!
		num_wann = nWfs		
		num_kpts = nQ
		num_stat = nSolve

		
		!READ W90 Files
		call read_M_initial(num_bands, num_kpts, nntot, nnlist, nncell, M_ham)
		call read_U_matrix(num_wann, U_mat)
		
		!WARNINGS & INFO
		write(*,*)	"[berryMethod]: detected parameter info:"
		write(*,*)	"	num_kpts  =",num_kpts
		write(*,*)	"	num_bands =",num_bands
		write(*,*)	"	num_wann  =",num_wann
		write(*,*)	"	nntot  	  =",nntot
		if(	num_wann /= num_bands ) 	stop		"[berryMethod]: detected different num_wann(from _u.mat) and num_bands( .mmn file)"
		if(	nntot /= 4 )				write(*,*)	"[berryMethod]: WARNING nntot is not equal 4"
		write(*,*)	"*"

		!fd-scheme allo
		allocate(			w_b(		nntot	)	)
		allocate(			b_k(	3,	nntot	)	)
		!k-space allo
		allocate(			M_wann(		num_wann	,	num_wann	,	nntot		,	num_kpts		)			)		
		allocate(			Aconn_H(		3		, 	num_wann	,	num_wann	,	num_kpts		)			)
		allocate(			Aconn_W(		3		, 	num_wann	,	num_wann	,	num_kpts		)			)
		!real-space
		allocate(			w_centers(		3,					num_wann					)			)
		allocate(			berry_W_gauge(	3,					num_wann					)			)
		allocate(			berry_H_gauge(	3,					num_wann					)			)
		allocate(			niu_polF2(		3,					num_wann					)			)
		allocate(			niu_polF3(		3,					num_wann					)			)
		!
		!
		!print atoms
		write(*,*)		"[berryMethod]: atom positions:"
		do n = 1, size(atPos,2)
				write(*,'(a,i3,a,f6.2,a,f6.2,a ,f6.2,a)')	"at=",n,"	atPos(at)=(",atPos(1,n),", ",atPos(2,n),"); Vpot(at)=",atPot(n)*aUtoEv,"[eV]"
		end do
	
		!print w90 centers
		write(*,*)		"[berryMethod]: w90 centers:"
		call read_wann_centers(w_centers)
		do n = 1, size(w_centers,2)
			write(*,'(a,i3,a,f6.2,a,f6.2,a,f6.2,a)')	"n=",n,"	p_w90(n)=(",w_centers(1,n),", ",w_centers(2,n),", ",w_centers(3,n),")."
		end do




		!0th HAM GAUGE
		write(*,*)		"[berryMethod]: start (H) gauge calculation"
		call read_FD_b_vectors(b_k, w_b)
		call calcConnOnCoarse(M_ham, w_b, b_k, Aconn_H)
		call calcPolViaA(Aconn_H, berry_H_gauge)
		!
		!0th WANN GAUGE
		write(*,*)		"[berryMethod]: start (W) gauge calculation"
		call rot_M_matrix(M_ham, U_mat, M_wann)
		call calcConnOnCoarse(M_wann, w_b, b_k, Aconn_W)
		call calcPolViaA(Aconn_W, berry_W_gauge)
		!
		!
		!1st ORDER SEMICLASSICS
		if(doNiu) then
			!
			write(*,*)	"*"
			write(*,*)	"*"
			write(*,*)	"[berryMethod]: **************SEMICLASSICS*************************"
			allocate(	EnQ(		num_stat,				num_kpts)		)
			allocate(	FcurvQ(	3,	num_wann, num_wann,		num_kpts)		)
			allocate(	veloQ(	3, 	num_stat, num_stat,		num_kpts)		)
			
			!get energies
			call read_energies(EnQ)
			!get velocities
			if(	doVeloNum) then
				if( .not. 	doGaugBack )	call calcVeloBLOUNT(Aconn_W, EnQ, veloQ)	
				if(			doGaugBack )	call calcVeloBLOUNT(Aconn_H, EnQ, veloQ)	
			else
				call read_velo(veloQ)
			end if
			!get curvature (toDo) 
			call calcCurv(FcurvQ)
			!
			!semiclassics
			call calcFirstOrdP(Bext, prefactF3, FcurvQ, Aconn_W, veloQ, EnQ, niu_polF2, niu_polF3)
			!
			write(*,*)	"[berryMethod]: done with semiclassics"
		else
			niu_polF2 = 0.0_dp
			niu_polF3 = 0.0_dp
			write(*,*)	"[berryMethod]: semiclassics disabled, first order pol. set to zero"
		end if
		write(*,*)		"*"
		write(*,*)		"*"
		!
		!OUTPUT
		call writePolFile(w_centers, berry_H_gauge, berry_W_gauge, niu_polF2, niu_polF3)
		write(*,*)		"[berryMethod]: wrote pol file"
		call writeConnTxt( Aconn_W )
		!call writeVeloHtxt( veloQ )		
		!write(*,*)	"[berryMethod]: wrote k-space info files (connection & velocities)"			
		!
		!
		return
	end subroutine










!private

	!w90 subroutine :::   (rave are the centers)
!	csheet = dcmplx(1.0_dp)
!	sheet = 0.0_dp
 !   do nkp = 1, num_kpts
 !      do nn = 1, nntot
 !         do n = 1, num_wann
 !            ! Note that this ln_tmp is defined differently wrt the one in wann_omega
 !            ln_tmp(n,nn,nkp)=wb(nn)*( aimag(log(csheet(n,nn,nkp) * m_matrix(n,n,nn,nkp))) - sheet(n,nn,nkp) )
 !         end do
 !     end do
 !   end do
!
! !   ! recalculate rave
! !   rave = 0.0_dp
! !   do iw = 1, num_wann  
! !      do ind = 1, 3  
! !         do nkp = 1, num_kpts  
! !            do nn = 1, nntot  
! !               rave(ind,iw) = rave(ind,iw) +  bk(ind,nn,nkp) &
! !                    * ln_tmp(iw,nn,nkp)
! !            enddo
! !         enddo
! !      enddo
! !   enddo
 !   rave = -rave/real(num_kpts,dp)




	subroutine calcConnOnCoarse(M_mat, w_b, b_k, A_conn)
		!calculates the Berry connection, from the overlap matrix
		! see Vanderbilt 1997, eq.(22) & eq.(31)
		!b_k:	 non zero if qi at boundary of bz and nn accross bz
		!w_b:	 weight of nn 
		!
		!fastConnvergence:
		!			\vec{r_n} = 	1/N_k 	\sum_{k,b}	 w_b \vec{b} IMAG[ log M(n,n,nn,qi) ]
		!
		!finiteDifference:
		!			\vec{r_n} = 	1/N_k 	\sum_{k,b}	 w_b \vec{b} i_dp [ M(n,n,nn,qi) - 1.0_dp ]

		complex(dp),	intent(in)			:: 	M_mat(:,:,:,:)
		real(dp),		intent(in)			::	w_b(:), b_k(:,:)
		real(dp),		intent(out)			::	A_conn(:,:,:,:)
		real(dp),		allocatable			::	ln_tmp(:,:)
		complex(dp)							::	delta
		integer								::	qi, nn, n, m
		!
		if( 		fastConnConv ) write(*,*)	"[calcConnOnCoarse]: use logarithmic formula for connection"
		if( .not.	fastConnConv ) write(*,*)	"[calcConnOnCoarse]: use finite difference formula for connection" 
		if(num_bands /= num_wann ) stop			"[calcConnONCoarse]: WARNING disentanglement not supported"
		!
		A_conn = 0.0_dp
		!$OMP PARALLEL DEFAULT(SHARED) PRIVATE(qi, nn, n,m, delta, ln_tmp)
		allocate(		ln_tmp( size(M_mat,1), size(M_mat,2) )			)
		!$OMP DO SCHEDULE(STATIC)	
		do qi = 1, num_kpts
			!SUM OVER NN
			do nn = 1, nntot
				!
				!(Fast Convergence)
				if( fastConnConv ) then
					ln_tmp(:,:)			= aimag(	log(	M_mat(:,:,nn,qi)	)		)
					A_conn(1,:,:,qi)	= A_conn(1,:,:,qi)	+	w_b(nn) * b_k(1,nn) * ln_tmp(:,:)
					A_conn(2,:,:,qi)	= A_conn(2,:,:,qi)	+	w_b(nn) * b_k(2,nn) * ln_tmp(:,:)
					A_conn(3,:,:,qi)	= A_conn(3,:,:,qi)	+	w_b(nn) * b_k(3,nn) * ln_tmp(:,:)
				!(Finite Difference)
				else
					do n = 1, size(M_mat,2)
						do m = 1, size(M_mat,1)
							delta = dcmplx(0.0_dp)
							if( n==m ) 	delta = dcmplx(1.0_dp)
							A_conn(1,m,n,qi)		= 	A_conn(1,m,n,qi)	-	w_b(nn) * b_k(1,nn) * dreal( i_dp * (M_mat(m,n,nn,qi) - delta)  )					
							A_conn(2,m,n,qi)		= 	A_conn(2,m,n,qi)	-	w_b(nn) * b_k(2,nn) * dreal( i_dp * (M_mat(m,n,nn,qi) - delta)  )
							A_conn(3,m,n,qi)		= 	A_conn(3,m,n,qi)	-	w_b(nn) * b_k(3,nn) * dreal( i_dp * (M_mat(m,n,nn,qi) - delta)  )	
						end do
					end do				
				end if
			end do
			!
			!
		end do
		!$OMP END DO
		!$OMP END PARALLEL
		write(*,*)	"[calcConnOnCoarse]: established connection"
		!
		return
	end subroutine


	subroutine calcPolViaA(A_mat, centers)
		!calculates the polarization by integrating connection over the brillouin zone
		! r_n 	= <0n|r|0n> 
		!		=V/(2pi)**2 \integrate_BZ <unk|i \nabla_k|unk>
		!		=V/(2pi)**2 \integrate_BZ A(k)
		real(dp),			intent(in)		:: 	A_mat(:,:,:,:)			!A(2,	 nWfs, nWfs, nQ	)	
		real(dp),			intent(out)		:: 	centers(:,:)
		integer								::	n
		real(dp)							::	polQuantum
		!
		polQuantum = 1.0_dp / vol
		!
		centers = 0.0_dp
		!$OMP PARALLEL DO SCHEDULE(STATIC) DEFAULT(SHARED) PRIVATE(n)
		do n 	= 1, size(A_mat,2)
			!
			!INTEGRATE
			centers(1,n) = -1.0_dp * sum(A_mat(1,n,n,:)) / real(size(A_mat,4),dp)
			centers(2,n) = -1.0_dp * sum(A_mat(2,n,n,:)) / real(size(A_mat,4),dp)
			if(size(A_mat,1)==3)	centers(3,n) =  -1.0_dp * sum(A_mat(3,n,n,:)) / real(size(A_mat,4),dp)
			!
		end do
		!$OMP END PARALLEL DO
		!
		do n = 1, size(A_mat,2)
			write(*,'(a,i3,a,f6.2,a,f6.2,a,f6.2,a,a,f9.4,a,f9.4,a,f9.4,a)')	"[calcPolViaA]: n=",n,"  r(n)=(",centers(1,n),", ", centers(2,n),",",centers(3,n), ")=",&
																"(",mod(centers(1,n),polQuantum),", ", mod(centers(2,n),polQuantum),",",mod(centers(3,n),polQuantum), ")."
		end do
		!		
		return
	end subroutine





	subroutine rot_M_matrix(M_H, U_mat, M_W)
		!	M^(W)(nn,qi)	= U^*(qi)	M^(H)(nn,qi) U(qnb(nn)) 
		complex(dp),		intent(in)		::	M_H(:,:,:,:), U_mat(:,:,:)
		complex(dp),		intent(out)		::	M_W(:,:,:,:)
		complex(dp),		allocatable		::	U_left(:,:), tmp(:,:)
		integer								:: 	qi, nn, qnn
		!
		!$OMP PARALLEL DEFAULT(SHARED) PRIVATE(tmp, U_left, nn, qi)
		allocate(		tmp(	size(U_mat,1), size(U_mat,2)	)			)
		allocate(		U_left(	size(U_mat,1), size(U_mat,2)	)			)
		!$OMP DO SCHEDULE(STATIC)
		do qi = 1, size(M_H,4)
			U_left(:,:)			=	dconjg(		 transpose( U_mat(:,:,qi) )			)
			!
			do nn = 1, nntot
				qnn				=	nnlist(qi,nn)
				tmp(:,:)		=	matmul(		U_left(:,:)	,	M_H(:,:,nn,qi)		)
				M_W(:,:,nn,qi)	= 	matmul(		tmp(:,:)	, 	U_mat(:,:,qnn) 		)
			end do
			!
		end do
		!$OMP END DO
		!$OMP END PARALLEL
		return
	end subroutine



	subroutine calcCurv(Fcurv_mat)
		!todo: implement this in case of 3d system
		complex(dp),		intent(out)		:: Fcurv_mat(:,:,:,:)
		!
		write(*,*)	"[calcCurv]: WARNING - calcCurv is not implemented (irrelevant for 2D system)"
		!
		Fcurv_mat = dcmplx(0.0_dp)
		!
		!
		return
	end subroutine



	subroutine calcVeloBLOUNT(A_conn, En_vec ,  v_mat)
		!use Blount 1962 formu.la
		! 
		real(dp),		intent(in)		::	A_conn(:,:,:,:)
		real(dp),		intent(in)		::	En_vec(:,:)
		complex(dp),	intent(out)		::	v_mat(:,:,:,:)
		real(dp),		allocatable		::	v_Band(:,:,:)
		integer							::	n, m, qi
		!
		allocate(	v_Band(	3,	num_wann,	num_kpts)		)
		!
		v_mat	= dcmplx(0.0_dp)
		!
		!DEBUG
		if( size(A_conn,1) /= size(v_mat,1)	)	write(*,*)	"[calcVeloBLOUNT]: A_conn and v_mat have different real space dimensionality"
		if( size(A_conn,2) /= size(v_mat,2) )	stop		"[calcVeloBLOUNT]: A_conn and v_mat have different amount of states covered"
		if( size(A_conn,3) /= size(v_mat,3) )	stop		"[calcVeloBLOUNT]: A_conn and v_mat have different amount of states covered"
		if( size(A_conn,4) /= size(v_mat,4) )	stop		"[calcVeloBLOUNT]: A_conn and v_mat live on different k meshes"
		!
		!GET DIAGONAL ELEMENTS
		call readBandVelo( v_Band ) !=band derivative
		!FILL MATRIX
		do qi = 1, size(A_conn,4)
			do m = 1, size(v_mat,3)
				do n = 1, size(v_mat,2)
					if(n==m)	v_mat(1:3,n,n,qi)	= dcmplx(v_Band(1:3,n,qi) )
					if(n/=m) 	v_mat(1:3,n,m,qi)	= dcmplx(		0.0_dp,		-1.0_dp * (En_vec(m,qi)-En_vec(n,qi)) * A_conn(1:3,n,m,qi)		 )
				end do
			end do
		end do	
		!
		!
		return
	end subroutine




end module berry

