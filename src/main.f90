program main
	!TWO dimensional potential well code
	use mpi
	use mathematics, 	only: 		dp, PI_dp

	use sysPara
	use potWellModel, 	only: 		solveHam
	use basisIO,		only:		readAbIn, readBasis
	use w90Interface,	only:		w90Interf
	use postW90,		only:		effTBmodel
	use berry,			only:		berryMethod

	use output,		 	only:		writeMeshInfo, writeMeshBin, writePolFile,& 
									printTiming, printBasisInfo	!printMat, printInp, printWannInfo,writeSysInfo  


							

	implicit none

	


    complex(dp),	allocatable,	dimension(:,:,:)	:: 	ck
    real(dp),		allocatable,	dimension(:,:)		:: 	En    														
    real												:: 	mastT0, mastT1, mastT, T0, T1, &
    															alloT,hamT,wT,pwT, outT, berryT	
    logical												::	mpiSuccess		

    !MPI INIT
	call MPI_INIT( ierr )
    call MPI_COMM_RANK (MPI_COMM_WORLD, myID, ierr)
    call MPI_COMM_SIZE (MPI_COMM_WORLD, nProcs, ierr)
    root = 0
    mpiSuccess = .true.
    call MPI_Barrier( MPI_COMM_WORLD, ierr )
    !
    !
    if( myID == root) then
    	alloT	= 0.0
    	hamT	= 0.0
    	wT		= 0.0
    	pwT		= 0.0
    	berryT	= 0.0
    	outT 	= 0.0
    	mastT	= 0.0
    	!
   		write(*,*)"[main]:**************************setup Grids*************************"
   		call cpu_time(mastT0)
   		call cpu_time(T0)
    end if

    !READ INPUT FILE & DISTRIBUTE
  	call readInp()
	!
	!CHECK IF QPTS CAN BE EQUALLY DISTRIBUTED -> if not break
	if( mod(nQ,nProcs)/=0)  then
		if(myID == root) write(*,*)"[main]: CRITICAL WARNING: mpi threads have to be integer fraction of nQ"
		mpiSuccess = .false.
	end if
	!
	!PRINT SOME INFO
	if( myID == root) then
		write(*,*)"*"
		write(*,*)"*"
		write(*,*)"[main]:**************************Infos about this run*************************"
		write(*,*)"[main]: electronic structure mesh nQ=",nQ
		write(*,*)"[main]: interpolation mesh        nK=",nK
		write(*,*)"[main]: basis cutoff parameter  Gcut=",Gcut
		write(*,*)"[main]: basis function   maximum  nG=",GmaxGLOBAL," of ",nG," trial basis functions"
		write(*,*)"[main]: only solve for        nSolve=",nSolve
    	write(*,*)"[main]: nBands=", nBands
		write(*,*)"[main]: nWfs  =", nWfs
		write(*,*)"[main]: w90 seed_name= ", seedName	
		write(*,*)"*"
		write(*,*)"*"
		write(*,*)"*"
		write(*,*)"*"
		!
		call cpu_time(T1)
		alloT = T1 - T0
	end if
	
		
	
	
	!ELECTRONIC STRUCTURE
	if( mpiSuccess .and. doSolveHam ) then
		!call cpu_time(T0)	
		
		call MPI_BARRIER( MPI_COMM_WORLD, ierr )	
		if( myID == root )	call cpu_time(T0)
		if( myID == root ) 	write(*,*)"[main]:**************************ELECTRONIC STRUCTURE PART*************************"
	
		!
		!
		call solveHam()
		call MPI_BARRIER( MPI_COMM_WORLD, ierr )
		if( myID == root ) then
			write(*,*)"[main]: done solving Schroedinger eq."
			call cpu_time(T1)
			hamT = T1-T0
		end if
	end if
	




	!POST HAM SOLVER
	if( .not. doSolveHam .and. myID == root ) then	
		write(*,*)"[main]:**************************READ E-STRUCTURE*************************"
		allocate(	En(						nSolve	, 	nQ	)	)
		allocate(	ck(			GmaxGLOBAL,	nSolve 	,	nQ	)	)

		!READ IN ELECTRONIC STRUCTURE
		call readAbIn(ck, En)
		!call readBasis() !reads in Gvec, nGq (optiónal)


	

		call cpu_time(T0)
		write(*,*)"[main]:**************************WANNIER90 INTERFACE*************************"
		call w90Interf(ck,En)

		!EFF TB - post w90
		call cpu_time(T0)
		write(*,*)"[main]:**************************POST WANNIER90 *************************"
		if(	doPw90 ) then
			
			write(*,*)	"[main]: start with eff TB model calculations"
			call effTBmodel()
			write(*,*)	"[main]: done with effective tight binding calculations"
		else
			write(*,*)	"[main]: effective TB model disabled"
		end if
		!
		write(*,*)"*"
		write(*,*)"*"
		write(*,*)"*"
		write(*,*)"*"
		call cpu_time(T1)
		pwT	= T1-T0
	
	
		!K SPACE METHOD
		call cpu_time(T0)
		write(*,*)"[main]:**************************BERRY METHOD*************************"
		if ( doBerry ) then
			call berryMethod(ck, En)
			write(*,*)"[main]: done with wavefunction method "
		else
			write(*,*)"[main]: berry method disabled"
		end if
		!
		write(*,*)"*"
		write(*,*)"*"
		write(*,*)"*"
		write(*,*)"*"
		call cpu_time(T1)
		berryT	= T1 - T0

		!OUTPUT
		write(*,*)"[main]:**************************WRITE OUTPUT*************************"
		call cpu_time(T0)
		!
		call writeMeshInfo() 
		write(*,*)"[main]: ...wrote mesh info"
		if( writeBin )	then
			call writeMeshBin()
			write(*,*)"[main]: ...wrote mesh bin"
			write(*,*)"[main]: ...wrote binary files for meshes and unks"
		end if
		!
		write(*,*)"*"
		write(*,*)"*"
		write(*,*)"*"
		write(*,*)"*"
		call cpu_time(T1)
		outT = T1 - T0
		
		
		!WARNINGS IF GCUT IS TO HIGH
		write(*,*)"[main]:**************************BASIS SET DEBUG*************************"
		call printBasisInfo()
		write(*,*)"[main]: ...wrote basis set debug info"
		write(*,*)"*"
		write(*,*)"*"
		write(*,*)"*"
		write(*,*)"*"
	
	
	
		!TIMING INFO SECTION
		call cpu_time(mastT1)
		mastT= mastT1-mastT0
		write(*,*) '**************TIMING INFORMATION************************'
		call printTiming(alloT,hamT,wT,pwT,berryT,outT,mastT)
		write(*,*)"*"
		write(*,*)"*"
		write(*,*)"*"
		write(*,*)"*"
	end if

	call MPI_Barrier( MPI_COMM_WORLD, ierr )
	write(*,'(a,i3,a)')	"[#",myID,";main]: all done, exit"


	call MPI_FINALIZE ( ierr )
	!
	!
	stop
end program

