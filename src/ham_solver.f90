module ham_Solver
	!this modules sets up the Hamiltonian matrix and solves it for each k point
	!	in the process the wannier functions are generated aswell with routines from wannGen module
	use mpi
	use omp_lib
	use util_math,		only:	dp, PI_dp,i_dp, machineP, myExp, &
								eigSolverPART, isUnit, isHermitian, aUtoEv
	use util_sysPara				
	
	use	ham_PotWell,	only:	add_potWell
	use	ham_Zeeman,		only:	add_Zeeman
	use ham_Magnetic,	only:	add_magHam
	use ham_Rashba,		only:	add_rashba
	use ham_PWbasis,	only:	writeUNKs



	use ham_PWbasis,	only:	calcVeloGrad, calcAmatANA, calcMmat
	use util_basisIO,	only:	writeABiN_basVect, writeABiN_energy, writeABiN_basCoeff, writeABiN_Mmn, &
								read_coeff, read_gVec, read_energies
	use util_w90Interf,	only:	setup_w90, write_w90_matrices, printNNinfo
	use util_output,	only:	writeEnTXT
	implicit none	
	!#include "mpif.h"

	private
	public ::			solveHam			



		

	


	contains
!public:
	subroutine solveHam()   !call solveHam(wnF, unk, EnW, VeloBwf)
		!solves Hamiltonian at each k point
		!	and prepares the wannier90 input files (.mmn, .amn, .eig, .win, ...)
		!																
		integer							::	nntotMax, nntot
		integer,		allocatable		::	nnlist(:,:), nncell(:,:,:)

		!	
		!
		nntotMax = 12
		allocate(	nnlist(		nQ, nntotMax)		)
		allocate(	nncell(3, 	nQ, nntotMax)		)
		!
		

		!SOLVE HAM at each k-point
		call worker()
		!
		!get FD scheme from w90
		if( myID == root )  then
			call setup_w90(nntot, nnlist, nncell)
			call printNNinfo(nntot, nnlist)
		end if
		!
		!Bcast FD scheme
		call MPI_Bcast(nntot,			1		, MPI_INTEGER, root, MPI_COMM_WORLD, ierr)
		call MPI_Bcast(nnlist,		nntotMax*nQ	, MPI_INTEGER, root, MPI_COMM_WORLD, ierr)
		call MPI_Bcast(nncell,	3*	nntotMax*nQ	, MPI_INTEGER, root, MPI_COMM_WORLD, ierr)
		if( myID == root) write(*,'(a,i3,a)')	"[#",myID,";potWellMethod]: broadcasted fd scheme"
		!
		!calc Mmat
		call calc_Mmat(nntot, nnlist, nncell)
		call MPI_BARRIER(MPI_COMM_WORLD, ierr)	!without root may try to read Mmat files which are not written
		!
		!
		!call w90 interface to write input files & .mmn etc. files
		if( myID == root ) then
			call prepare_w90_run()
		end if
		!
		!
		return
	end subroutine




!private:
	subroutine worker()
		!			solve Ham, write results and derived quantites														
		complex(dp),	allocatable		::	Hmat(:,:) , ck_temp(:,:)
		real(dp),		allocatable		::	En_temp(:)
		integer							:: 	qi_glob, qi_loc, found, Gsize, boundStates, loc_minBound, loc_maxBound
		!	
		!
		allocate(	Hmat(				Gmax,	Gmax				)	)
		allocate(	ck_temp(		GmaxGLOBAL, nSolve				)	)
		allocate(	En_temp(				Gmax					)	)
		!
		qi_loc 	= 1
		loc_minBound = nSolve
		loc_maxBound = -1
		call MPI_BARRIER( MPI_COMM_WORLD, ierr)
		!LOOP KPTS
		do qi_glob = myID*qChunk +1, myID*qChunk + qChunk
			!
			!SETUP HAM
			call populateH(qi_loc, Hmat) 
			!
			!SOLVE HAM
			ck_temp	= dcmplx(0.0_dp)
			En_temp	= 0.0_dp
			Gsize 	= nGq(qi_loc)
			call eigSolverPART(Hmat(1:Gsize,1:Gsize),En_temp(1:Gsize), ck_temp(1:Gsize,:), found)
			!
			!WRITE FILEs
			call writeABiN_basVect(qi_glob, Gvec(:,:,qi_loc))
			call writeABiN_basCoeff(qi_glob, ck_temp)
			call writeABiN_energy(qi_glob, En_temp(1:nSolve))
			!get derived quantities & write to file
			call calcAmatANA(	qi_loc, qi_glob, ck_temp)
			call calcVeloGrad(	qi_loc, qi_glob, ck_temp)
			!w90 plot preparation
			call writeUNKs(qi_glob, nGq(qi_loc), ck_temp(:,1:nBands), Gvec(:,:,qi_loc))
			!
			!
			!count insulating states
			boundStates = count_negative_eigenvalues(loc_minBound, loc_maxBound, En_temp)
			!FINALIZE
			call debug_message_printer(qi_loc, qi_glob, found, Gsize, boundStates, En_temp)
			!goto next qpt
			qi_loc = qi_loc + 1		
		end do
		!
		!ANALYZE BANDS
		call band_analyzer(loc_minBound, loc_maxBound)
		!
		!
		return
	end subroutine



	subroutine calc_Mmat(nntot, nnlist, nncell)
		integer,		intent(in)		::	nntot, nnlist(:,:), nncell(:,:,:)
		integer,		allocatable		::	nGq_glob(:)
		complex(dp),	allocatable		::	ck_qi(:,:), cK_nn(:,:), Mmn(:,:,:)
		real(dp),		allocatable		::	Gvec_qi(:,:), Gvec_nn(:,:)
		real(dp)						::	gShift(2)
		integer							::	qi, nn, q_nn, nG_qi, nG_nn, qi_loc
		!
		allocate(	nGq_glob(nQ)					)
		allocate(	Gvec_qi(dim, nG)				)
		allocate(	Gvec_nn(dim, nG)				)
		allocate(	ck_nn(GmaxGLOBAL, nSolve)		)
		allocate(	ck_qi(GmaxGLOBAL, nSolve)		)
		allocate(	Mmn(nBands, nBands, nntot)		)
		!
		call MPI_ALLGATHER( nGq	, qChunk, MPI_INTEGER, nGq_glob		, qChunk, MPI_INTEGER, MPI_COMM_WORLD, ierr)
		!
		!
		qi_loc = 1
		do qi = myID*qChunk +1, myID*qChunk + qChunk
			!
			do nn = 1, nntot
				!calc overlap of unks
				if( nncell(3,qi,nn)/= 0 ) stop '[w90prepMmat]: out of plane nearest neighbour found. '
				!
				q_nn		=	nnlist(qi,nn)
				nG_qi		= 	nGq_glob(qi)
				nG_nn		= 	nGq_glob(q_nn)
				gShift(1)	= 	real(nncell(1,qi,nn),dp) * 2.0_dp * PI_dp / aX
				gShift(2)	= 	real(nncell(2,qi,nn),dp) * 2.0_dp * PI_dp / aY
				!
				!read basis coefficients
				call read_coeff(qi,	ck_qi)
				call read_coeff(q_nn, ck_nn)
				!
				!read Gvec
				call read_gVec(qi, 		Gvec_qi)
				call read_gVec(q_nn,	Gvec_nn)
				!
				!
				call calcMmat(qi, q_nn, gShift, nG_qi, nG_nn, Gvec_qi, Gvec_nn, ck_qi, ck_nn, Mmn(:,:,nn)	)
			end do
			!
			!write result to file, alternative: gather on root and write .mmn directly
			call writeABiN_Mmn(qi, Mmn)
			!write(*,'(a,i3,a,i5,a,i5,a,i5,a)')		"[#",myID,",calc_Mmat]: wrote M_matrix for qi=",qi,"; task (",qi_loc,"/",qChunk,") done"
			qi_loc = qi_loc + 1
		end do
		!		
		!
		return
	end subroutine


	subroutine prepare_w90_run()
		real(dp),		allocatable		::	EnQ(:,:)
		!
		allocate(	EnQ(nSolve,nQ)	)
		!
		write(*,*)	"*"
		write(*,*)	"*"
		write(*,*)	"*"
		write(*,'(a,i3,a)')		"[#",myID,";prepare_w90_run]: wrote Mmn files, now collect files to write wannier90 input files"
		call write_w90_matrices()
		write(*,'(a,i3,a)')		"[#",myID,";prepare_w90_run]: wrote w90 matrix input files (.amn, .mmn, .eig)"
		call read_energies(EnQ)
		call writeEnTXT(EnQ)
		write(*,'(a,i3,a)')		"[#",myID,";prepare_w90_run]: wrote energies to txt file"
		!
		!
		return
	end subroutine













!POPULATION OF H MATRIX
	subroutine populateH(qi_loc, Hmat)
		!populates the Hamiltonian matrix by adding 
		!	1. kinetic energy terms (onSite)
		!	2. potential terms V(qi,i,j)
		!and checks if the resulting matrix is hermitian( for debugging)
		integer,		intent(in)	:: 	qi_loc
		complex(dp), intent(inout) 	:: 	Hmat(:,:)
		integer						::	gi
		!init to zero
		Hmat = dcmplx(0.0_dp) 
		!
		!
		!KINETIC ENERGY
		do gi = 1, size(Hmat,1)
			Hmat(gi,gi) = 0.5_dp * dot_product(	Gvec(:,gi,qi_loc),	Gvec(:,gi,qi_loc)	)
		end do
		!
		!POTENTIAL WELLS
		call add_potWell(qi_loc, Hmat)
		!
		!ZEEMAN
		if(	doZeeman )		call add_Zeeman(qi_loc, Hmat)
		!
		!PEIERLS
		if( doMagHam )	 	call add_magHam(qi_loc, Hmat)
		!
		!RASHBA	
		if( doRashba )		call add_rashba(qi_loc, Hmat)

		!
		!DEBUG
		if(debugHam) then
			if ( .not.	isHermitian(Hmat)	) 	write(*,'(a,i3,a,i3)')	"[#",myID,";populateH]: WARNING Hamiltonian matrix is not Hermitian at qi_loc=",qi_loc
		end if
		!
		!		
		return
	end subroutine



!BAND STRUCTURE TESTS
	integer function count_negative_eigenvalues(loc_minBound, loc_maxBound, energies)
		integer,		intent(inout)		::	loc_minBound, loc_maxBound
		real(dp),		intent(in)			::	energies(:)
		integer								::	boundStates
		!
		!count boundStates
		boundStates = 0
		do while (	energies(boundStates+1) < 0.0_dp .and. boundStates < size(energies)	)
			boundStates = boundStates + 1
		end do
		loc_minBound = min(loc_minBound,boundStates)
		loc_maxBound = max(loc_maxBound,boundStates)
		!
		!return
		count_negative_eigenvalues = boundStates
		return
	end function


	subroutine band_analyzer(loc_minBound, loc_maxBound)
		!
		!	test if all kpts have same amount of negative energy eigenvalues (i.e. no states become metallic in parts of BZ)
		!
		integer,		intent(in)		::	loc_minBound	, 	loc_maxBound
		integer							::	glob_minBound	,	glob_maxBound 
		!
		call MPI_REDUCE(loc_minBound, 	glob_minBound, 	1, MPI_INTEGER, 	MPI_MIN,	root, MPI_COMM_WORLD, ierr)
		call MPI_REDUCE(loc_maxBound, 	glob_maxBound, 	1, MPI_INTEGER, 	MPI_MAX,	root, MPI_COMM_WORLD, ierr)
		!
		if( myID == root ) then
			write(*,*)	"*"
			write(*,*)	"*"
			write(*,*)	"*"
			write(*,'(a,i3,a)')	"[#",myID,", solveHam]:********band structure analysis:****************************************"
			!
			!TEST FOR METALLIC BANDS
			if( glob_minBound == glob_maxBound	) then
				write(*,'(a,i3,a,i3,a)')	"[#",myID,", solveHam]: found system with #",glob_minBound," insulating states"
			else
				write(*,'(a,i3,a,i3,a)')	"[#",myID,", solveHam]: WARNING: ",glob_maxBound-glob_minBound," insulating states get metallic at points of BZ"
			end if
			!
			!TEST IF ENOUGH BANDS FOR W90
			if( glob_minBound < nWfs	) then
				write(*,'(a,i3,a)')	"[#",myID,", solveHam]: WARNING: not enough localized states for w90"
			end if
			write(*,*)	"*"
		end if
		!
		!
		return
	end subroutine



	subroutine debug_message_printer(qi_loc, qi_glob , found, Gsize, boundStates, En_temp)
		integer,		intent(in)		::	qi_loc, qi_glob, found, Gsize, boundStates
		real(dp),		intent(in)		::	En_temp(:)
		real(dp)						::	bandGap
		!
		if( found /= nSolve )	write(*,'(a,i3,a,i5,a,i5)'	)	"[#",myID,";solveHam]:WARNING only found ",found," bands of required ",nSolve
		if( nBands > found	)	stop	"[solveHam]: ERROR did not find required amount of bands"
		if( Gsize < nSolve	) 	stop	"[solveHam]: cutoff to small to get bands! only get basis functions"
		if( Gsize > Gmax	)	stop	"[solveHam]: critical error in solveHam please contact developer. (nobody but dev will ever read this^^)"
		!
		bandGap =	( En_temp(boundStates+1)-En_temp(boundStates)  ) * aUtoEv
		!
		write(*,'(a,i3,a,i5,a,f6.2,a,f6.2,a,f6.2,a,a,i3,a,i5,a,i5,a)')"[#",myID,", solveHam]: qi=",qi_glob," wann energies= [",En_temp(1)*aUtoEv," : ",&
														En_temp(nWfs)*aUtoEv,"](eV); band gap=",bandGap," (eV).",&
														" insulating states: #",boundStates,". done tasks=(",qi_loc,"/",qChunk,")"
		!if( boundStates < nWfs) write(*,'(a,i3,a,f8.3,a,f8.3,a)') "[#",myID,", solveHam]: WARNING not enough bound states at qpt=(",qpts(1,qi),",",qpts(2,qi),")."
		!
		return
	end subroutine







end module ham_Solver
