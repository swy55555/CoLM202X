#include <define.h>

MODULE MOD_SPMD_Task

   !-----------------------------------------------------------------------------------------
   ! DESCRIPTION:
   !
   !    SPMD refers to "Single Program/Multiple Data" parallelization.
   ! 
   !    In CoLM, processes do three types of tasks,
   !    1. master : There is only one master process, usually rank 0 in global communicator. 
   !                It reads or writes global data, prints informations.
   !    2. io     : IO processes read data from files and scatter to workers, gather data from 
   !                workers and write to files.
   !    3. worker : Worker processes do model calculations.
   !   
   !    Notice that,
   !    1. There are mainly two types of data in CoLM: gridded data and vector data. 
   !       Gridded data takes longitude and latitude   as its last two dimensions. 
   !       Vector  data takes ELEMENT/PATCH/HRU/PFT/PC as its last dimension.
   !       Usually gridded data is allocated on IO processes and vector data is allocated on
   !       worker processes.
   !    2. One IO process and multiple worker processes form a group. The Input/Output 
   !       in CoLM is mainly between IO and workers in the same group. However, all processes
   !       can communicate with each other.
   !    3. Number of IO is less or equal than the number of blocks with non-zero elements.
   !
   ! Created by Shupeng Zhang, May 2023
   !-----------------------------------------------------------------------------------------

   USE MOD_Precision
   IMPLICIT NONE

   include 'mpif.h'

#ifndef USEMPI
   
   INTEGER, parameter :: p_root       = 0

   LOGICAL, parameter :: p_is_master = .true.
   LOGICAL, parameter :: p_is_io     = .true.
   LOGICAL, parameter :: p_is_worker = .true.

   INTEGER, parameter :: p_np_glb    = 1    
   INTEGER, parameter :: p_np_worker = 1
   INTEGER, parameter :: p_np_io     = 1

   INTEGER, parameter :: p_iam_glb    = 0
   INTEGER, parameter :: p_iam_io     = 0
   INTEGER, parameter :: p_iam_worker = 0
   
   INTEGER, parameter :: p_np_group   = 1

#else
   INTEGER, parameter :: p_root = 0

   LOGICAL :: p_is_master    
   LOGICAL :: p_is_io
   LOGICAL :: p_is_worker

   ! Global communicator
   INTEGER :: p_comm_glb
   INTEGER :: p_iam_glb    
   INTEGER :: p_np_glb     

   ! Processes in the same working group
   INTEGER :: p_comm_group
   INTEGER :: p_iam_group
   INTEGER :: p_np_group

   INTEGER :: p_my_group

   ! Input/output processes 
   INTEGER :: p_comm_io
   INTEGER :: p_iam_io
   INTEGER :: p_np_io     

   INTEGER, allocatable :: p_itis_io (:)
   INTEGER, allocatable :: p_address_io (:)
   
   ! Processes carrying out computing work
   INTEGER :: p_comm_worker
   INTEGER :: p_iam_worker
   INTEGER :: p_np_worker     
   
   INTEGER, allocatable :: p_itis_worker (:)
   INTEGER, allocatable :: p_address_worker (:)

   INTEGER :: p_stat (MPI_STATUS_SIZE)
   INTEGER :: p_err

   ! tags
   INTEGER, PUBLIC, parameter :: mpi_tag_size = 1
   INTEGER, PUBLIC, parameter :: mpi_tag_mesg = 2
   INTEGER, PUBLIC, parameter :: mpi_tag_data = 3 

   INTEGER  :: MPI_INULL_P(1)
   REAL(r8) :: MPI_RNULL_P(1)

   ! subroutines
   PUBLIC :: spmd_init
   PUBLIC :: spmd_exit
   PUBLIC :: divide_processes_into_groups

#endif

CONTAINS

#ifdef USEMPI
   !-----------------------------------------
   SUBROUTINE spmd_init (MyComm_r)

      IMPLICIT NONE
	   integer, intent(in), optional :: MyComm_r
      LOGICAL mpi_inited
      CALL MPI_INITIALIZED( mpi_inited, p_err )

      IF ( .NOT. mpi_inited ) THEN
         CALL mpi_init (p_err) 
      ENDIF
	
      if (present(MyComm_r)) then
         p_comm_glb = MyComm_r
      else
         p_comm_glb = MPI_COMM_WORLD
      endif

      ! 1. Constructing global communicator.
      CALL mpi_comm_rank (p_comm_glb, p_iam_glb, p_err)  
      CALL mpi_comm_size (p_comm_glb, p_np_glb,  p_err) 

      p_is_master = (p_iam_glb == p_root)

   END SUBROUTINE spmd_init

   !-----------------------------------------
   SUBROUTINE divide_processes_into_groups (numblocks, groupsize)

      IMPLICIT NONE
      
      INTEGER, intent(in) :: numblocks
      INTEGER, intent(in) :: groupsize

      ! Local variables
      INTEGER :: iproc
      INTEGER, allocatable :: p_igroup_all (:)

      INTEGER :: nave, nres, ngrp, igrp, key
      CHARACTER(len=512) :: info
      CHARACTER(len=5)   :: cnum

      ! 1. Determine number of groups
      ngrp = max((p_np_glb-1) / groupsize, 1)
      ngrp = min(ngrp, numblocks)

      IF (ngrp <= 0) THEN
         CALL mpi_abort (p_comm_glb, p_err)
      ENDIF

      ! 2. What task will I take? Which group I am in?
      nave = (p_np_glb-1) / ngrp
      nres = mod(p_np_glb-1, ngrp)

      IF (.not. p_is_master) THEN
         IF (p_iam_glb <= (nave+1)*nres) THEN
            p_is_io = mod(p_iam_glb, nave+1) == 1
            p_my_group = (p_iam_glb-1) / (nave+1)
         ELSE
            p_is_io = mod(p_iam_glb-(nave+1)*nres, nave) == 1
            p_my_group = (p_iam_glb-(nave+1)*nres-1) / nave + nres
         ENDIF

         p_is_worker = .not. p_is_io      
      ELSE
         p_is_io     = .false.
         p_is_worker = .false.
         p_my_group  = -1
      ENDIF

      ! 3. Construct IO communicator and address book.
      IF (p_is_io) THEN
         key = 1
         CALL mpi_comm_split (p_comm_glb, key, p_iam_glb, p_comm_io, p_err)
         CALL mpi_comm_rank  (p_comm_io, p_iam_io, p_err)  
      ELSE
         CALL mpi_comm_split (p_comm_glb, MPI_UNDEFINED, p_iam_glb, p_comm_io, p_err)
      ENDIF
         
      IF (.not. p_is_io) p_iam_io = -1
      allocate (p_itis_io (0:p_np_glb-1))
      CALL mpi_allgather (p_iam_io, 1, MPI_INTEGER, p_itis_io, 1, MPI_INTEGER, p_comm_glb, p_err)
      
      p_np_io = count(p_itis_io >= 0)
      allocate (p_address_io (0:p_np_io-1))

      DO iproc = 0, p_np_glb-1
         IF (p_itis_io(iproc) >= 0) THEN
            p_address_io(p_itis_io(iproc)) = iproc
         ENDIF
      ENDDO

      ! 4. Construct worker communicator and address book.
      IF (p_is_worker) THEN
         key = 1
         CALL mpi_comm_split (p_comm_glb, key, p_iam_glb, p_comm_worker, p_err)
         CALL mpi_comm_rank  (p_comm_worker, p_iam_worker, p_err)  
      ELSE
         CALL mpi_comm_split (p_comm_glb, MPI_UNDEFINED, p_iam_glb, p_comm_worker, p_err)
      ENDIF

      IF (.not. p_is_worker) p_iam_worker = -1
      allocate (p_itis_worker (0:p_np_glb-1))
      CALL mpi_allgather (p_iam_worker, 1, MPI_INTEGER, p_itis_worker, 1, MPI_INTEGER, p_comm_glb, p_err)
      
      p_np_worker = count(p_itis_worker >= 0)
      allocate (p_address_worker (0:p_np_worker-1))

      DO iproc = 0, p_np_glb-1
         IF (p_itis_worker(iproc) >= 0) THEN
            p_address_worker(p_itis_worker(iproc)) = iproc
         ENDIF
      ENDDO

      ! 5. Construct group communicator.
      CALL mpi_comm_split (p_comm_glb, p_my_group, p_iam_glb, p_comm_group, p_err)
      CALL mpi_comm_rank  (p_comm_group, p_iam_group, p_err)  
      CALL mpi_comm_size  (p_comm_group, p_np_group,  p_err) 

      ! 6. Print global task informations.
      allocate (p_igroup_all (0:p_np_glb-1))
      CALL mpi_allgather (p_my_group, 1, MPI_INTEGER, p_igroup_all, 1, MPI_INTEGER, p_comm_glb, p_err)

      IF (p_is_master) THEN

         write (*,*) 'MPI information:'
         write (*,'(A,I5)') ' Master is ', p_root  

         DO igrp = 0, p_np_io-1
            write (cnum,'(I5)') igrp  
            info = 'Group ' // cnum // ' includes '

            write (cnum,'(I5)') p_address_io(igrp)
            info = trim(info) // ' IO(' // cnum // '), worker('

            DO iproc = 0, p_np_glb-1
               IF ((p_igroup_all(iproc) == igrp) .and. (iproc /= p_address_io(igrp))) THEN
                  write (cnum,'(I5)') iproc
                  info = trim(info) // cnum
               ENDIF
            ENDDO

            info = trim(info) // ')'
            write (*,*) trim(info)
         ENDDO
            
         write (*,*) 
      ENDIF

      deallocate (p_igroup_all  )
      
   END SUBROUTINE divide_processes_into_groups

   !-----------------------------------------
   SUBROUTINE spmd_exit

      IF (allocated(p_itis_io       )) deallocate (p_itis_io       )
      IF (allocated(p_address_io    )) deallocate (p_address_io    )
      IF (allocated(p_itis_worker   )) deallocate (p_itis_worker   )
      IF (allocated(p_address_worker)) deallocate (p_address_worker)

      CALL mpi_barrier (p_comm_glb, p_err)

      CALL mpi_finalize(p_err)

   END SUBROUTINE spmd_exit

#endif

   ! -- STOP all processes --
   SUBROUTINE CoLM_stop (mesg)

      IMPLICIT NONE
      character(len=*), optional :: mesg

      IF (present(mesg)) write(*,*) trim(mesg)

#ifdef USEMPI
      CALL mpi_abort (p_comm_glb, p_err)
#else
      STOP
#endif

   END SUBROUTINE CoLM_stop

END MODULE MOD_SPMD_Task
