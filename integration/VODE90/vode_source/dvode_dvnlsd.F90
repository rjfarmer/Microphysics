module dvode_dvnlsd_module

  use vode_rhs_module, only: f_rhs, jac
  use vode_type_module, only: rwork_t
  use vode_parameters_module, only: VODE_LMAX, VODE_NEQS, VODE_LIW,   &
                                    VODE_LENWM, VODE_MAXORD, VODE_ITOL
  use dvode_type_module, only: dvode_t
  use amrex_fort_module, only: rt => amrex_real
  use blas_module
  use linpack_module

  use dvode_dvjac_module
  use dvode_dvnorm_module
  use dvode_dvsol_module

  use dvode_constants_module

  implicit none

contains

  AMREX_DEVICE subroutine dvnlsd(IWM, NFLAG, rwork, vstate)

    !$acc routine seq
    
    ! -----------------------------------------------------------------------
    !  Call sequence input -- Y, YH, LDYH, SAVF, EWT, ACOR, IWM, WM,
    !                         F, JAC, NFLAG, RPAR, IPAR
    !  Call sequence output -- YH, ACOR, WM, IWM, NFLAG
    !  COMMON block variables accessed:
    !      /DVOD01/ ACNRM, CRATE, DRC, H, RC, RL1, TQ(5), TN, ICF,
    !                 JCUR, METH, MITER, N, NSLP
    !      /DVOD02/ HU, NCFN, NETF, NFE, NJE, NLU, NNI, NQU, NST
    ! 
    !  Subroutines called by DVNLSD: F, DAXPY, DCOPY, DSCAL, DVJAC, DVSOL
    !  Function routines called by DVNLSD: DVNORM
    ! -----------------------------------------------------------------------
    !  Subroutine DVNLSD is a nonlinear system solver, which uses functional
    !  iteration or a chord (modified Newton) method.  For the chord method
    !  direct linear algebraic system solvers are used.  Subroutine DVNLSD
    !  then handles the corrector phase of this integration package.
    ! 
    !  Communication with DVNLSD is done with the following variables. (For
    !  more details, please see the comments in the driver subroutine.)
    ! 
    !  Y          = The dependent variable, a array of length N, input.
    !  YH         = The Nordsieck (Taylor) array, LDYH by LMAX, input
    !               and output.  On input, it contains predicted values.
    !  LDYH       = A constant .ge. N, the first dimension of YH, input.
    !  VSAV       = Unused work array.
    !  SAVF       = A work array of length N.
    !  EWT        = An error weight array of length N, input.
    !  ACOR       = A work array of length N, used for the accumulated
    !               corrections to the predicted y array.
    !  WM,IWM     = Real and integer work arrays associated with matrix
    !               operations in chord iteration (MITER .ne. 0).
    !  F          = Dummy name for user supplied routine for f.
    !  JAC        = Dummy name for user supplied Jacobian routine.
    !  PDUM       = Unused dummy subroutine name.  Included for uniformity
    !               over collection of integrators.
    !  NFLAG      = Input/output flag, with values and meanings as follows:
    !               INPUT
    !                   0 first call for this time step.
    !                  -1 convergence failure in previous call to DVNLSD.
    !                  -2 error test failure in DVSTEP.
    !               OUTPUT
    !                   0 successful completion of nonlinear solver.
    !                  -1 convergence failure or singular matrix.
    !                  -2 unrecoverable error in matrix preprocessing
    !                     (cannot occur here).
    !                  -3 unrecoverable error in solution (cannot occur
    !                     here).
    !  RPAR, IPAR = Dummy names for user's real and integer work arrays.
    ! 
    !  IPUP       = Own variable flag with values and meanings as follows:
    !               0,            do not update the Newton matrix.
    !               MITER .ne. 0, update Newton matrix, because it is the
    !                             initial step, order was changed, the error
    !                             test failed, or an update is indicated by
    !                             the scalar RC or step counter NST.
    ! 
    !  For more details, see comments in driver subroutine.
    ! -----------------------------------------------------------------------
    !

    implicit none

    ! Declare arguments
    type(dvode_t), intent(inout) :: vstate
    type(rwork_t), intent(inout) :: rwork
    integer,       intent(inout) :: IWM(VODE_LIW), NFLAG

    ! Declare local variables
    real(rt) :: CSCALE, DCON, DEL, DELP
    integer    :: I, IERPJ, IERSL, M

    ! Parameter declarations
    real(rt), parameter :: CCMAX = 0.3D0
    real(rt), parameter :: CRDOWN = 0.3D0
    real(rt), parameter :: RDIV  = 2.0D0
    integer, parameter :: MAXCOR = 3
    integer, parameter :: MSBP = 20

    ! -----------------------------------------------------------------------
    !  On the first step, on a change of method order, or after a
    !  nonlinear convergence failure with NFLAG = -2, set IPUP = MITER
    !  to force a Jacobian update when MITER .ne. 0.
    ! -----------------------------------------------------------------------
    IF (vstate % JSTART .EQ. 0) vstate % NSLP = 0
    IF (NFLAG .EQ. 0) vstate % ICF = 0
    IF (NFLAG .EQ. -2) vstate % IPUP = vstate % MITER
    IF ( (vstate % JSTART .EQ. 0) .OR. (vstate % JSTART .EQ. -1) ) vstate % IPUP = vstate % MITER
    ! If this is functional iteration, set CRATE .eq. 1 and drop to 220
    IF (vstate % MITER .EQ. 0) THEN
       vstate % CRATE = ONE
       GO TO 220
    ENDIF
    ! -----------------------------------------------------------------------
    !  RC is the ratio of new to old values of the coefficient H/EL(2)=h/l1.
    !  When RC differs from 1 by more than CCMAX, IPUP is set to MITER
    !  to force DVJAC to be called, if a Jacobian is involved.
    !  In any case, DVJAC is called at least every MSBP steps.
    ! -----------------------------------------------------------------------
    vstate % DRC = ABS(vstate % RC-ONE)
    IF (vstate % DRC .GT. CCMAX .OR. vstate % NST .GE. vstate % NSLP+MSBP) vstate % IPUP = vstate % MITER
    ! -----------------------------------------------------------------------
    !  Up to MAXCOR corrector iterations are taken.  A convergence test is
    !  made on the r.m.s. norm of each correction, weighted by the error
    !  weight array EWT.  The sum of the corrections is accumulated in the
    !  array ACOR(i).  The YH array is not altered in the corrector loop.
    ! -----------------------------------------------------------------------
220 continue
    M = 0
    DELP = ZERO

    CALL DCOPYN(VODE_NEQS, rwork % yh(:,1), 1, vstate % Y, 1)
    CALL f_rhs (vstate % TN, vstate % Y, rwork % savf, vstate % RPAR)
    vstate % NFE = vstate % NFE + 1
    IF (vstate % IPUP .LE. 0) GO TO 250
    ! -----------------------------------------------------------------------
    !  If indicated, the matrix P = I - h*rl1*J is reevaluated and
    !  preprocessed before starting the corrector iteration.  IPUP is set
    !  to 0 as an indicator that this has been done.
    ! -----------------------------------------------------------------------
    CALL DVJAC (IWM, IERPJ, rwork, vstate)
    vstate % IPUP = 0
    vstate % RC = ONE
    vstate % DRC = ZERO
    vstate % CRATE = ONE
    vstate % NSLP = vstate % NST
    ! If matrix is singular, take error return to force cut in step size. --
    IF (IERPJ .NE. 0) GO TO 430
250 continue
    do I = 1,VODE_NEQS
       rwork % acor(I) = ZERO
    end do
    ! This is a looping point for the corrector iteration. -----------------
270 IF (vstate % MITER .NE. 0) GO TO 350
    ! -----------------------------------------------------------------------
    !  In the case of functional iteration, update Y directly from
    !  the result of the last function evaluation.
    ! -----------------------------------------------------------------------
    do I = 1,VODE_NEQS
       rwork % SAVF(I) = vstate % RL1*(vstate % H * rwork % SAVF(I) - rwork % YH(I,2))
    end do
    do I = 1,VODE_NEQS
       vstate % Y(I) = rwork % SAVF(I) - rwork % ACOR(I)
    end do
    DEL = DVNORM (vstate % Y, rwork % EWT)
    do I = 1,VODE_NEQS
       vstate % Y(I) = rwork % YH(I,1) + rwork % SAVF(I)
    end do
    CALL DCOPYN(VODE_NEQS, rwork % SAVF, 1, rwork % ACOR, 1)

    GO TO 400
    ! -----------------------------------------------------------------------
    !  In the case of the chord method, compute the corrector error,
    !  and solve the linear system with that as right-hand side and
    !  P as coefficient matrix.  The correction is scaled by the factor
    !  2/(1+RC) to account for changes in h*rl1 since the last DVJAC call.
    ! -----------------------------------------------------------------------
350 continue
    do I = 1,VODE_NEQS
       vstate % Y(I) = (vstate % RL1*vstate % H) * rwork % SAVF(I) - &
            (vstate % RL1 * rwork % YH(I,2) + rwork % ACOR(I))
    end do
    CALL DVSOL (rwork % wm, IWM, IERSL, vstate)
    vstate % NNI = vstate % NNI + 1
    IF (IERSL .GT. 0) GO TO 410
    IF (vstate % METH .EQ. 2 .AND. vstate % RC .NE. ONE) THEN
       CSCALE = TWO/(ONE + vstate % RC)
       CALL DSCALN (VODE_NEQS, CSCALE, vstate % Y, 1)
    ENDIF
    DEL = DVNORM (vstate % Y, rwork % EWT)
    call daxpyn(VODE_NEQS, ONE, vstate % Y, 1, rwork % acor, 1)

    do I = 1,VODE_NEQS
       vstate % Y(I) = rwork % YH(I,1) + rwork % ACOR(I)
    end do
    ! -----------------------------------------------------------------------
    !  Test for convergence.  If M .gt. 0, an estimate of the convergence
    !  rate constant is stored in CRATE, and this is used in the test.
    ! -----------------------------------------------------------------------
400 continue
    IF (M .NE. 0) vstate % CRATE = MAX(CRDOWN*vstate % CRATE,DEL/DELP)
    DCON = DEL*MIN(ONE,vstate % CRATE)/vstate % TQ(4)
    IF (DCON .LE. ONE) GO TO 450
    M = M + 1
    IF (M .EQ. MAXCOR) GO TO 410
    IF (M .GE. 2 .AND. DEL .GT. RDIV*DELP) GO TO 410
    DELP = DEL
    CALL f_rhs (vstate % TN, vstate % Y, rwork % SAVF, vstate % RPAR)
    vstate % NFE = vstate % NFE + 1
    GO TO 270
    
410 IF (vstate % MITER .EQ. 0 .OR. vstate % JCUR .EQ. 1) GO TO 430
    vstate % ICF = 1
    vstate % IPUP = vstate % MITER
    GO TO 220
    
430 CONTINUE
    NFLAG = -1
    vstate % ICF = 2
    vstate % IPUP = vstate % MITER
    RETURN

    ! Return for successful step. ------------------------------------------
450 continue
    NFLAG = 0
    vstate % JCUR = 0
    vstate % ICF = 0
    IF (M .EQ. 0) vstate % ACNRM = DEL
    IF (M .GT. 0) vstate % ACNRM = DVNORM (rwork % ACOR, rwork % EWT)
    RETURN
  end subroutine dvnlsd

end module dvode_dvnlsd_module
