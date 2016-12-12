! Diffusion map code example
! James W. Barnett

module subs

    implicit none

contains 

    subroutine get_evect(p, evect, evalues)

        ! SLOW
        implicit none
        integer :: n, info, i, lwork, lda, ldvl, ldvr
        real(8), dimension(:), allocatable ::  wr, wi, work
        real(8), dimension(:), allocatable, intent(inout) ::  evalues
        real(8), dimension(:,:), allocatable, intent(inout) :: evect, p
        real(8), dimension(:,:), allocatable :: a, vl, vr
        integer, allocatable, dimension(:) :: order
        logical, allocatable, dimension(:) :: mask
        character :: jobvl = 'N', jobvr = 'V'

        interface 
          subroutine dgeev(jobvl, jobvr, n, a, lda, wr, wi, vl, ldvl, vr, ldvr, work, lwork, info)
            character, intent(in) :: jobvl, jobvr
            integer, intent(in) :: n, lda, ldvl, ldvr, lwork
            integer, intent(out) :: info
            real(8), intent(inout) :: a(lda,*)
            real(8), intent(out) :: wr(*), wi(*), vl(ldvl,*), vr(ldvr,*), work(*)
          end subroutine
        end interface

        a = p
        n = size(a,1)
        lwork = 26*n
        lda = n
        ldvl = n
        ldvr = n
        allocate(work(lwork))
        allocate(vl(ldvl, n))
        allocate(vr(ldvr, n))
        allocate(wr(n))
        allocate(wi(n))

!       Get eigenvectors and eigenvalues (LAPACK)
        call dgeev(jobvl, jobvr, n, a, lda, wr, wi, vl, ldvl, vr, ldvr, work, lwork, info)
        if(info .ne. 0) then
            write(*,*) "ERROR: Eigenvector calculation failed."
        end if

!       Sort the evalues in descending so we can use the top components for
!       later calcs
        allocate(order(n))
        allocate(mask(n))
        mask = .true.
        do i = lbound(wr,1), ubound(wr,1)
            order(i) = maxloc(wr,1,mask)
            mask(order(i)) = .false.
        end do

        allocate(evect(ldvr, n))
        allocate(evalues(n))
        evalues = wr(order)
        evect = vr(:,order)

    end subroutine get_evect

    subroutine check_file(myfile)

        implicit none
        character (len=*), intent(in) :: myfile
        logical ex

        inquire(file=trim(myfile), exist=ex)
        if (ex .eqv. .false.) then
            write(*,"(a)") "ERROR: "//trim(myfile)//" does not exist."
            stop
        end if

    end subroutine

end module subs

program main

    use json_module
    use subs

    implicit none
    integer :: i, j, n, u, logbandwidth_l, logbandwidth_u, max_output
    real(8), dimension(:,:), allocatable :: distance, similarity, markov_transition, point, evect
    real(8), dimension(:), allocatable ::  evalue, val
    real(8) :: bandwidth
    logical :: get_bandwidth, found
    character (len=256), allocatable :: config_file
    character (len=32) :: arg, n_char
    character (len=:), allocatable :: infile, bandwidth_file, evects_file, evalues_file, diffusionmap_file
    character (len=1024) :: format_string
    type(json_file) :: config
    real(8) :: time ! diffusion "time", not simulation time

    if (command_argument_count() .ne. 1) then
        write(0,*) "ERROR: First argument should be config file."
        stop
    end if

    call get_command_argument(1, arg)

    config_file = trim(arg)
    call check_file(config_file)
    call config%initialize()
    call config%load_file(filename=config_file)
    call config%print_file()
    call config%get('bandwidth_calc.get',get_bandwidth,found)
    if (.not. found) then 
        get_bandwidth=.false.
    end if
    call config%get("bandwidth_calc.log_l",logbandwidth_l,found)
    if (.not. found) then 
        logbandwidth_l = -10
    end if
    call config%get("bandwidth_calc.log_u",logbandwidth_u,found)
    if (.not. found) then 
        logbandwidth_l = 10
    end if
    call config%get("bandwidth_calc.file",bandwidth_file,found)
    if (.not. found) then 
        bandwidth_file = "eps.dat"
    end if
    call config%get("output.dmap",diffusionmap_file,found)
    if (.not. found) then 
        diffusionmap_file = "dmap.dat"
    end if
    call config%get("output.max_cols",max_output,found)
    ! Default is 4 because we are using 3d data for this example (and first eigenvector is all 1's and is ignored)
    if (.not. found) then 
        max_output = 4
    end if
    call config%get("bandwidth",bandwidth,found)
    if (.not. found) then 
        bandwidth = 1.0
    end if
    call config%get("infile",infile,found)
    if (.not. found) then 
        infile = "infile.dat"
    end if
    call config%get("time",time,found)
    if (.not. found) then 
        time = 0.0
    end if
    call check_file(infile)
    call config%get("output.evects",evects_file,found)
    if (.not. found) then 
        evects_file = "evects.dat"
    end if
    call config%get("output.evalues",evalues_file,found)
    if (.not. found) then 
        evalues_file = "evalues.dat"
    end if
    call config%destroy()

    ! Get or calculate distances, saved in a distance matrix
    ! TODO: assumes data is 3D

    ! val is the original data's position on the swiss roll
    open(newunit=u, file=trim(infile), status="old")
    read(u,*) n
    allocate(point(n,3))
    allocate(val(n))
    do i = 1, n
        read(u,*) point(i,:), val(i)
    end do
    close(u) 

    ! only appropriate for cartesian data. Real world use we would use a different metric here
    allocate(distance(n,n))

    ! TODO: is symmetric, can speed up
    do i = 1, n
        do j = 1, n
            distance(i,j) = dsqrt( (point(i,1)-point(j,1))**2 + (point(i,2)-point(j,2))**2 + (point(i,3)-point(j,3))**2)
        end do
    end do

    if (get_bandwidth) then

        ! Cycle through different values of the bandwidth. See Fig. S1 in https://www.pnas.org/cgi/doi/10.1073/pnas.1003293107
        open(newunit=u, file=trim(bandwidth_file))
        do i = logbandwidth_l, logbandwidth_u
            bandwidth = exp(dble(i))
            similarity = exp( - ( (distance**2) / (2*bandwidth) ) )
            write(u,"(i0,f12.6)") i, log(sum(similarity))
        end do
        close(u)

    else

        allocate(similarity(n,n))

        ! Using a Gaussian kernel
        similarity = exp( - ( (distance**2) / (2*bandwidth) ) )

        ! Normalize the diffusion / similarity matrix
        allocate(markov_transition(n,n))
        do i = 1, n
            markov_transition(i,:) = similarity(i,:) / sum(similarity(i,:))
        end do

        call get_evect(markov_transition, evect, evalue)

        open(newunit=u, file=trim(evalues_file))
        write(u,"(f12.6)") evalue(1:max_output)
        close(u)

        open(newunit=u, file=trim(evects_file))
        write(n_char,'(i0)') max_output
        format_string = "("//trim(n_char)//"f12.6)"
        write(u,format_string) transpose(evect(:,1:max_output))
        close(u)

        open(newunit=u, file=trim(diffusionmap_file))
        write(u,"(a)") "# First column is original location on swiss roll"
        write(u,"(a)") "# Next columns are points in diffusion space"
        write(u,"(a)") "# In gnuplot to plot the first dimensions try:"
        write(u,"(a)") "#   plot 'evects.dat' u 2:3:1 w points palette"
        write(u,"(a,f12.6)") "# time = ", time
        write(u,"(a,f12.6)") "# bandwidth = ", bandwidth
        format_string = "("//trim(n_char)//"f12.6)"
        do i = 1, n
            write(u,"(f12.6)", advance="no") val(i)
            ! Note that we do not output the first eigenvector since it is trivial (all 1's)
            do j = 2, max_output
                write(u,"(f12.6)", advance="no") evect(i,j)*evalue(j)**time
            end do
            write(u,*)
        end do
        close(u)
        
    end if

end program main