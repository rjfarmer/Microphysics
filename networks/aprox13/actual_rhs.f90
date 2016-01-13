module actual_rhs_module

  use network
  use network_indices
  use eos_type_module
  use vode_indices, only: net_itemp, net_ienuc
  use rpar_indices

  implicit none

contains

  subroutine actual_rhs(neq,time,state,y,dydt,rpar)

    use extern_probin_module, only: do_constant_volume_burn, jacobian

    implicit none
    
    ! This routine sets up the system of ode's for the aprox13
    ! nuclear reactions.  This is an alpha chain + heavy ion network
    ! with (a,p)(p,g) links.
    !     
    ! Isotopes: he4,  c12,  o16,  ne20, mg24, si28, s32,
    !           ar36, ca40, ti44, cr48, fe52, ni56

    integer          :: neq
    double precision :: time
    double precision :: y(1:neq), dydt(1:neq)
    type (eos_t)     :: state
    double precision :: rpar(n_rpar_comps)
    
    ! Local variables
    integer :: i
    logical :: deriva
    
    double precision :: ratraw(nrates), dratrawdt(nrates), dratrawdd(nrates)
    double precision :: ratdum(nrates), dratdumdt(nrates), dratdumdd(nrates)
    double precision :: scfac(nrates),  dscfacdt(nrates),  dscfacdd(nrates)    

    double precision :: sneut,dsneutdt,dsneutdd,snuda,snudz    
    double precision :: enuc

    ! Get the raw reaction rates
    call aprox13rat(state % T, state % rho, ratraw, dratrawdt, dratrawdd)
    

    ! Do the screening here because the corrections depend on the composition
    call screen_aprox13(state % T, state % rho, state % xn / aion, &
                        ratraw, dratrawdt, dratrawdd, &
                        ratdum, dratdumdt, dratdumdd, &
                        scfac, dscfacdt, dscfacdd)
    

    ! Get the right hand side of the ODEs. First, we'll do it
    ! using d(rates)/dT to get the data for the Jacobian and store it.
    ! Then we'll do it using the normal rates.

    if (jacobian == 1) then
       deriva = .true.
       call rhs(state % xn / aion,dratdumdt,ratdum,dydt,deriva)
       rpar(irp_dydt:irp_dydt+nspec-1) = dydt(1:nspec) * aion
       rpar(irp_rates:irp_rates+nrates-1) = ratdum
    endif
       
    deriva = .false.
    
    call rhs(state % xn / aion,ratdum,ratdum,dydt,deriva)

    ! Instantaneous energy generation rate -- this needs molar fractions
    call ener_gener_rate(dydt,enuc)

    ! Go from molar fractions back to mass fractions
    dydt(1:nspec) = dydt(1:nspec) * aion    

    ! Get the neutrino losses
    call sneut5(state % T,state % rho,state % abar,state % zbar, &
                sneut,dsneutdt,dsneutdd,snuda,snudz)
    
    ! Append the energy equation (this is erg/g/s)
    dydt(net_ienuc) = enuc - sneut    
    
    if (rpar(irp_self_heat) > ZERO) then
       
       ! Set up the temperature ODE.  For constant pressure, Dp/Dt = 0, we
       ! evolve :
       !    dT/dt = (1/c_p) [ -sum_i (xi_i omega_i) + Hnuc]
       ! 
       ! For constant volume, div{U} = 0, and we evolve:
       !    dT/dt = (1/c_v) [ -sum_i ( {e_x}_i omega_i) + Hnuc]
       !
       ! See paper III, including Eq. A3 for details.
       
       if (do_constant_volume_burn) then
          dydt(net_itemp) = (dydt(net_ienuc) - sum(state % dEdX(:) * dydt(1:nspec))) / state % cv
       else
          dydt(net_itemp) = (dydt(net_ienuc) - sum(state % dhdX(:) * dydt(1:nspec))) / state % cp
       endif

    endif    

  end subroutine actual_rhs



  ! Analytical Jacobian

  subroutine actual_jac(neq, t, y, pd, rpar)

    use bl_types
    use bl_constants_module, only: ZERO
    use eos_module
    use extern_probin_module, only: do_constant_volume_burn

    implicit none

    integer         , intent(IN   ) :: neq
    double precision, intent(IN   ) :: y(neq), rpar(n_rpar_comps), t
    double precision, intent(  OUT) :: pd(neq,neq)

    double precision :: rates(nrates), ydot(nspec)

    double precision :: b1, sneut, dsneutdt, dsneutdd, snuda, snudz  

    integer          :: i, j

    double precision :: rho, temp, cv, cp, abar, zbar, dEdX(nspec), dhdX(nspec)

    pd(:,:) = ZERO

    rho  = rpar(irp_dens)
    temp = y(net_itemp)
    cv   = rpar(irp_cv)
    cp   = rpar(irp_cp)

    ! Get the data from rpar

    dhdX = rpar(irp_dhdX:irp_dhdX+nspec-1)
    dEdX = rpar(irp_dEdX:irp_dEdX+nspec-1)
    abar = rpar(irp_abar)
    zbar = rpar(irp_zbar)

    ! Note that this RHS has been evaluated using rates = d(ratdum) / dT

    ydot = rpar(irp_dydt:irp_dydt+nspec-1)
    rates = rpar(irp_rates:irp_rates+nrates-1)

    ! Species Jacobian elements with respect to other species

    call dfdy_isotopes_aprox13(y, pd, neq, rates)

    ! Energy generation rate Jacobian elements with respect to species

    do j = 1, nspec
       call ener_gener_rate(pd(1:nspec,j) / aion,pd(net_ienuc,j))
    enddo

    ! Account for the thermal neutrino losses

    call sneut5(T,rho,abar,zbar,sneut,dsneutdt,dsneutdd,snuda,snudz)

    do j = 1, nspec
       b1 = ((aion(j) - abar) * abar * snuda + (zion(j) - zbar) * abar * snudz)
       pd(net_ienuc,j) = pd(net_ienuc,j) - b1
    enddo

    if (rpar(irp_self_heat) > ZERO) then

       ! Jacobian elements with respect to temperature

       pd(1:nspec,net_itemp) = ydot

       call ener_gener_rate(pd(1:nspec,net_itemp) / aion, pd(net_ienuc,net_itemp))
       pd(net_ienuc,net_itemp) = pd(net_ienuc,net_itemp) - dsneutdt

       ! Temperature Jacobian elements

       if (do_constant_volume_burn) then

          ! d(itemp)/d(yi)
          do j = 1, nspec
             pd(net_itemp,j) = ( pd(net_ienuc,j) - sum( dEdX(:) * pd(1:nspec,j) ) ) / cv
          enddo

          ! d(itemp)/d(temp)
          pd(net_itemp,net_itemp) = ( pd(net_ienuc,net_itemp) - sum( dEdX(:) * pd(1:nspec,net_itemp) ) ) / cv

       else

          ! d(itemp)/d(yi)
          do j = 1, nspec
             pd(net_itemp,j) = ( pd(net_ienuc,j) - sum( dhdX(:) * pd(1:nspec,j) ) ) / cp
          enddo

          ! d(itemp)/d(temp)
          pd(net_itemp,net_itemp) = ( pd(net_ienuc,net_itemp) - sum( dhdX(:) * pd(1:nspec,net_itemp) ) ) / cp

       endif

    endif

  end subroutine actual_jac
  


  ! Evaluates the right hand side of the aprox13 ODEs

  subroutine rhs(y,rate,ratdum,dydt,deriva)

    use bl_constants_module, only: ZERO, SIXTH
    use bl_types, only: qp_t

    implicit none
    
    ! deriva is used in forming the analytic Jacobian to get
    ! the derivative wrt A

    logical          :: deriva
    double precision :: y(nspec),rate(nrates),ratdum(nrates),dydt(nspec)

    ! local variables
    integer          :: i

    ! Quad precision dydt sums
    ! Note that the qp_t type defined in the bl_types module
    ! automatically detects whether quad precision is actually
    ! implemented on the system in question, and if not it
    ! automatically returns a double precision type.

    real(kind=qp_t) :: qray(nspec)
    real(kind=qp_t) :: a1,  a2,  a3,  a4,  a5,  a6, &
                       a7,  a8,  a9,  a10, a11, a12, &
                       a13, a14, a15, a16, a17

    dydt(1:nspec) = ZERO
    qray(1:nspec) = 0.0_qp_t


    ! he4 reactions
    ! heavy ion reactions
    a1  = 0.5d0 * y(ic12) * y(ic12) * rate(ir1212)
    a2  = 0.5d0 * y(ic12) * y(io16) * rate(ir1216)
    a3  = 0.56d0 * 0.5d0 * y(io16) * y(io16) * rate(ir1616)

    qray(ihe4) = qray(ihe4) + a1 + a2 + a3

    ! (a,g) and (g,a) reactions
    a1  = -0.5d0 * y(ihe4) * y(ihe4) * y(ihe4) * rate(ir3a)
    a2  =  3.0d0 * y(ic12) * rate(irg3a)
    a3  = -y(ihe4)  * y(ic12) * rate(ircag)
    a4  =  y(io16)  * rate(iroga)
    a5  = -y(ihe4)  * y(io16) * rate(iroag)
    a6  =  y(ine20) * rate(irnega)
    a7  = -y(ihe4)  * y(ine20) * rate(irneag)
    a8  =  y(img24) * rate(irmgga)
    a9  = -y(ihe4)  * y(img24)* rate(irmgag)
    a10 =  y(isi28) * rate(irsiga)
    a11 = -y(ihe4)  * y(isi28)*rate(irsiag)
    a12 =  y(is32)  * rate(irsga)

    qray(ihe4) = qray(ihe4) + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12

    a1  = -y(ihe4)  * y(is32) * rate(irsag)
    a2  =  y(iar36) * rate(irarga)
    a3  = -y(ihe4)  * y(iar36)*rate(irarag)
    a4  =  y(ica40) * rate(ircaga)
    a5  = -y(ihe4)  * y(ica40)*rate(ircaag)
    a6  =  y(iti44) * rate(irtiga)
    a7  = -y(ihe4)  * y(iti44)*rate(irtiag)
    a8  =  y(icr48) * rate(ircrga)
    a9  = -y(ihe4)  * y(icr48)*rate(ircrag)
    a10 =  y(ife52) * rate(irfega)
    a11 = -y(ihe4)  * y(ife52) * rate(irfeag)
    a12 =  y(ini56) * rate(irniga)

    qray(ihe4) = qray(ihe4) + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12

    ! (a,p)(p,g) and (g,p)(p,a) reactions

    if (.not.deriva) then

       a1  =  0.34d0*0.5d0*y(io16)*y(io16)*rate(irs1)*rate(ir1616)
       a2  = -y(ihe4)  * y(img24) * rate(irmgap)*(1.0d0-rate(irr1))
       a3  =  y(isi28) * rate(irsigp) * rate(irr1)
       a4  = -y(ihe4)  * y(isi28) * rate(irsiap)*(1.0d0-rate(irs1))
       a5  =  y(is32)  * rate(irsgp) * rate(irs1)
       a6  = -y(ihe4)  * y(is32) * rate(irsap)*(1.0d0-rate(irt1))
       a7  =  y(iar36) * rate(irargp) * rate(irt1)
       a8  = -y(ihe4)  * y(iar36) * rate(irarap)*(1.0d0-rate(iru1))
       a9  =  y(ica40) * rate(ircagp) * rate(iru1)
       a10 = -y(ihe4)  * y(ica40) * rate(ircaap)*(1.0d0-rate(irv1))
       a11 =  y(iti44) * rate(irtigp) * rate(irv1)
       a12 = -y(ihe4)  * y(iti44) * rate(irtiap)*(1.0d0-rate(irw1))
       a13 =  y(icr48) * rate(ircrgp) * rate(irw1)
       a14 = -y(ihe4)  * y(icr48) * rate(ircrap)*(1.0d0-rate(irx1))
       a15 =  y(ife52) * rate(irfegp) * rate(irx1)
       a16 = -y(ihe4)  * y(ife52) * rate(irfeap)*(1.0d0-rate(iry1))
       a17 =  y(ini56) * rate(irnigp) * rate(iry1)

       qray(ihe4) = qray(ihe4) + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 &
                               + a11 + a12 + a13 + a14 + a15 + a16 + a17

    else
       a1  =  0.34d0*0.5d0*y(io16)*y(io16) * ratdum(irs1) * rate(ir1616)
       a2  =  0.34d0*0.5d0*y(io16)*y(io16) * rate(irs1) * ratdum(ir1616)
       a3  = -y(ihe4)*y(img24) * rate(irmgap)*(1.0d0 - ratdum(irr1))
       a4  =  y(ihe4)*y(img24) * ratdum(irmgap)*rate(irr1)
       a5  =  y(isi28) * ratdum(irsigp) * rate(irr1)
       a6  =  y(isi28) * rate(irsigp) * ratdum(irr1)
       a7  = -y(ihe4)*y(isi28) * rate(irsiap)*(1.0d0 - ratdum(irs1))
       a8  =  y(ihe4)*y(isi28) * ratdum(irsiap) * rate(irs1)
       a9  =  y(is32)  * ratdum(irsgp) * rate(irs1)
       a10 =  y(is32)  * rate(irsgp) * ratdum(irs1)

       qray(ihe4) = qray(ihe4) + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10

       a1  = -y(ihe4)*y(is32) * rate(irsap)*(1.0d0 - ratdum(irt1))
       a2  =  y(ihe4)*y(is32) * ratdum(irsap)*rate(irt1)
       a3  =  y(iar36) * ratdum(irargp) * rate(irt1)
       a4  =  y(iar36) * rate(irargp) * ratdum(irt1)
       a5  = -y(ihe4)*y(iar36) * rate(irarap)*(1.0d0 - ratdum(iru1))
       a6  =  y(ihe4)*y(iar36) * ratdum(irarap)*rate(iru1)
       a7  =  y(ica40) * ratdum(ircagp) * rate(iru1)
       a8  =  y(ica40) * rate(ircagp) * ratdum(iru1)
       a9  = -y(ihe4)*y(ica40) * rate(ircaap)*(1.0d0-ratdum (irv1))
       a10 =  y(ihe4)*y(ica40) * ratdum(ircaap)*rate(irv1)
       a11 =  y(iti44) * ratdum(irtigp) * rate(irv1)
       a12 =  y(iti44) * rate(irtigp) * ratdum(irv1)

       qray(ihe4) = qray(ihe4) + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12

       a1  = -y(ihe4)*y(iti44) * rate(irtiap)*(1.0d0 - ratdum(irw1))
       a2  =  y(ihe4)*y(iti44) * ratdum(irtiap)*rate(irw1)
       a3  =  y(icr48) * ratdum(ircrgp) * rate(irw1)
       a4  =  y(icr48) * rate(ircrgp) * ratdum(irw1)
       a5  = -y(ihe4)*y(icr48) * rate(ircrap)*(1.0d0 - ratdum(irx1))
       a6  =  y(ihe4)*y(icr48) * ratdum(ircrap)*rate(irx1)
       a7  =  y(ife52) * ratdum(irfegp) * rate(irx1)
       a8  =  y(ife52) * rate(irfegp) * ratdum(irx1)
       a9  = -y(ihe4)*y(ife52) * rate(irfeap)*(1.0d0 - ratdum(iry1))
       a10 =  y(ihe4)*y(ife52) * ratdum(irfeap)*rate(iry1)
       a11 =  y(ini56) * ratdum(irnigp) * rate(iry1)
       a12 =  y(ini56) * rate(irnigp) * ratdum(iry1)

       qray(ihe4) = qray(ihe4) + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12
    end if


    ! c12 reactions
    a1 = -y(ic12) * y(ic12) * rate(ir1212)
    a2 = -y(ic12) * y(io16) * rate(ir1216)
    a3 =  SIXTH * y(ihe4) * y(ihe4) * y(ihe4) * rate(ir3a)
    a4 = -y(ic12) * rate(irg3a)
    a5 = -y(ic12) * y(ihe4) * rate(ircag)
    a6 =  y(io16) * rate(iroga)

    qray(ic12) = qray(ic12) + a1 + a2 + a3 + a4 + a5 + a6


    ! o16 reactions
    a1 = -y(ic12) * y(io16) * rate(ir1216)
    a2 = -y(io16) * y(io16) * rate(ir1616)
    a3 =  y(ic12) * y(ihe4) * rate(ircag)
    a4 = -y(io16) * y(ihe4) * rate(iroag)
    a5 = -y(io16) * rate(iroga)
    a6 =  y(ine20) * rate(irnega)

    qray(io16) = qray(io16) + a1 + a2 + a3 + a4 + a5 + a6


    ! ne20 reactions
    a1 =  0.5d0 * y(ic12) * y(ic12) * rate(ir1212)
    a2 =  y(io16) * y(ihe4) * rate(iroag)
    a3 = -y(ine20) * y(ihe4) * rate(irneag)
    a4 = -y(ine20) * rate(irnega)
    a5 =  y(img24) * rate(irmgga)

    qray(ine20) = qray(ine20) + a1 + a2 + a3 + a4 + a5


    ! mg24 reactions
    a1 =  0.5d0 * y(ic12) * y(io16) * rate(ir1216)
    a2 =  y(ine20) * y(ihe4) * rate(irneag)
    a3 = -y(img24) * y(ihe4) * rate(irmgag)
    a4 = -y(img24) * rate(irmgga)
    a5 =  y(isi28) * rate(irsiga)

    qray(img24) = qray(img24) + a1 + a2 + a3 + a4 + a5

    if (.not.deriva) then
       a1 = -y(img24) * y(ihe4) * rate(irmgap)*(1.0d0-rate(irr1))
       a2 =  y(isi28) * rate(irr1) * rate(irsigp)

       qray(img24) = qray(img24) + a1 + a2

    else
       a1 = -y(img24)*y(ihe4) * rate(irmgap)*(1.0d0 - ratdum(irr1))
       a2 =  y(img24)*y(ihe4) * ratdum(irmgap)*rate(irr1)
       a3 =  y(isi28) * ratdum(irr1) * rate(irsigp)
       a4 =  y(isi28) * rate(irr1) * ratdum(irsigp)

       qray(img24) = qray(img24) + a1 + a2 + a3 + a4
    end if



    ! si28 reactions
    a1 =  0.5d0 * y(ic12) * y(io16) * rate(ir1216)
    a2 =  0.56d0 * 0.5d0*y(io16) * y(io16) * rate(ir1616)
    a3 =  y(img24) * y(ihe4) * rate(irmgag)
    a4 = -y(isi28) * y(ihe4) * rate(irsiag)
    a5 = -y(isi28) * rate(irsiga)
    a6 =  y(is32)  * rate(irsga)

    qray(isi28) = qray(isi28) + a1 + a2 + a3 + a4 + a5 + a6

    if (.not.deriva) then

       a1 =  0.34d0*0.5d0*y(io16)*y(io16)*rate(irs1)*rate(ir1616)
       a2 =  y(img24) * y(ihe4) * rate(irmgap)*(1.0d0-rate(irr1))
       a3 = -y(isi28) * rate(irr1) * rate(irsigp)
       a4 = -y(isi28) * y(ihe4) * rate(irsiap)*(1.0d0-rate(irs1))
       a5 =  y(is32)  * rate(irs1) * rate(irsgp)

       qray(isi28) = qray(isi28) + a1 + a2 + a3 + a4 + a5

    else
       a1  =  0.34d0*0.5d0*y(io16)*y(io16) * ratdum(irs1)*rate(ir1616)
       a2  =  0.34d0*0.5d0*y(io16)*y(io16) * rate(irs1)*ratdum(ir1616)
       a3  =  y(img24)*y(ihe4) * rate(irmgap)*(1.0d0 - ratdum(irr1))
       a4  = -y(img24)*y(ihe4) * ratdum(irmgap)*rate(irr1)
       a5  = -y(isi28) * ratdum(irr1) * rate(irsigp)
       a6  = -y(isi28) * rate(irr1) * ratdum(irsigp)
       a7  = -y(isi28)*y(ihe4) * rate(irsiap)*(1.0d0 - ratdum(irs1))
       a8  =  y(isi28)*y(ihe4) * ratdum(irsiap)*rate(irs1)
       a9  = y(is32) * ratdum(irs1) * rate(irsgp)
       a10 = y(is32) * rate(irs1) * ratdum(irsgp)

       qray(isi28) = qray(isi28) + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10
    end if



    ! s32 reactions
    a1 =  0.1d0 * 0.5d0*y(io16) * y(io16) * rate(ir1616)
    a2 =  y(isi28) * y(ihe4) * rate(irsiag)
    a3 = -y(is32) * y(ihe4) * rate(irsag)
    a4 = -y(is32) * rate(irsga)
    a5 =  y(iar36) * rate(irarga)

    qray(is32) = qray(is32) + a1 + a2 + a3 + a4 + a5


    if (.not.deriva) then
       a1 =  0.34d0*0.5d0*y(io16)*y(io16)* rate(ir1616)*(1.0d0-rate(irs1))
       a2 =  y(isi28) * y(ihe4) * rate(irsiap)*(1.0d0-rate(irs1))
       a3 = -y(is32) * rate(irs1) * rate(irsgp)
       a4 = -y(is32) * y(ihe4) * rate(irsap)*(1.0d0-rate(irt1))
       a5 =  y(iar36) * rate(irt1) * rate(irargp)

       qray(is32) = qray(is32) + a1 + a2 + a3 + a4 + a5

    else
       a1  =  0.34d0*0.5d0*y(io16)*y(io16) * rate(ir1616)*(1.0d0-ratdum(irs1))
       a2  = -0.34d0*0.5d0*y(io16)*y(io16) * ratdum(ir1616)*rate(irs1)
       a3  =  y(isi28)*y(ihe4) * rate(irsiap)*(1.0d0-ratdum(irs1))
       a4  = -y(isi28)*y(ihe4) * ratdum(irsiap)*rate(irs1)
       a5  = -y(is32) * ratdum(irs1) * rate(irsgp)
       a6  = -y(is32) * rate(irs1) * ratdum(irsgp)
       a7  = -y(is32)*y(ihe4) * rate(irsap)*(1.0d0-ratdum(irt1))
       a8  =  y(is32)*y(ihe4) * ratdum(irsap)*rate(irt1)
       a9  =  y(iar36) * ratdum(irt1) * rate(irargp)
       a10 =  y(iar36) * rate(irt1) * ratdum(irargp)

       qray(is32) = qray(is32) + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10
    end if


    ! ar36 reactions
    a1 =  y(is32)  * y(ihe4) * rate(irsag)
    a2 = -y(iar36) * y(ihe4) * rate(irarag)
    a3 = -y(iar36) * rate(irarga)
    a4 =  y(ica40) * rate(ircaga)

    qray(iar36) = qray(iar36) + a1 + a2 + a3 + a4

    if (.not.deriva) then
       a1 = y(is32)  * y(ihe4) * rate(irsap)*(1.0d0-rate(irt1))
       a2 = -y(iar36) * rate(irt1) * rate(irargp)
       a3 = -y(iar36) * y(ihe4) * rate(irarap)*(1.0d0-rate(iru1))
       a4 =  y(ica40) * rate(ircagp) * rate(iru1)

       qray(iar36) = qray(iar36) + a1 + a2 + a3 + a4

    else
       a1 =  y(is32)*y(ihe4) * rate(irsap)*(1.0d0 - ratdum(irt1))
       a2 = -y(is32)*y(ihe4) * ratdum(irsap)*rate(irt1)
       a3 = -y(iar36) * ratdum(irt1) * rate(irargp)
       a4 = -y(iar36) * rate(irt1) * ratdum(irargp)
       a5 = -y(iar36)*y(ihe4) * rate(irarap)*(1.0d0-ratdum(iru1))
       a6 =  y(iar36)*y(ihe4) * ratdum(irarap)*rate(iru1)
       a7 =  y(ica40) * ratdum(ircagp) * rate(iru1)
       a8 =  y(ica40) * rate(ircagp) * ratdum(iru1)

       qray(iar36) = qray(iar36) + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8
    end if


    ! ca40 reactions
    a1 =  y(iar36) * y(ihe4) * rate(irarag)
    a2 = -y(ica40) * y(ihe4) * rate(ircaag)
    a3 = -y(ica40) * rate(ircaga)
    a4 =  y(iti44) * rate(irtiga)

    qray(ica40) = qray(ica40) + a1 + a2 + a3 + a4

    if (.not.deriva) then
       a1 =  y(iar36) * y(ihe4) * rate(irarap)*(1.0d0-rate(iru1))
       a2 = -y(ica40) * rate(ircagp) * rate(iru1)
       a3 = -y(ica40) * y(ihe4) * rate(ircaap)*(1.0d0-rate(irv1))
       a4 =  y(iti44) * rate(irtigp) * rate(irv1)

       qray(ica40) = qray(ica40) + a1 + a2 + a3 + a4

    else
       a1 =  y(iar36)*y(ihe4) * rate(irarap)*(1.0d0-ratdum(iru1))
       a2 = -y(iar36)*y(ihe4) * ratdum(irarap)*rate(iru1)
       a3 = -y(ica40) * ratdum(ircagp) * rate(iru1)
       a4 = -y(ica40) * rate(ircagp) * ratdum(iru1)
       a5 = -y(ica40)*y(ihe4) * rate(ircaap)*(1.0d0-ratdum(irv1))
       a6 =  y(ica40)*y(ihe4) * ratdum(ircaap)*rate(irv1)
       a7 =  y(iti44) * ratdum(irtigp) * rate(irv1)
       a8 =  y(iti44) * rate(irtigp) * ratdum(irv1)

       qray(ica40) = qray(ica40) + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8
    end if


    ! ti44 reactions
    a1 =  y(ica40) * y(ihe4) * rate(ircaag)
    a2 = -y(iti44) * y(ihe4) * rate(irtiag)
    a3 = -y(iti44) * rate(irtiga)
    a4 =  y(icr48) * rate(ircrga)

    qray(iti44) = qray(iti44) + a1 + a2 + a3 + a4

    if (.not.deriva) then
       a1 =  y(ica40) * y(ihe4) * rate(ircaap)*(1.0d0-rate(irv1))
       a2 = -y(iti44) * rate(irv1) * rate(irtigp)
       a3 = -y(iti44) * y(ihe4) * rate(irtiap)*(1.0d0-rate(irw1))
       a4 =  y(icr48) * rate(irw1) * rate(ircrgp)

       qray(iti44) = qray(iti44) + a1 + a2 + a3 + a4

    else
       a1 =  y(ica40)*y(ihe4) * rate(ircaap)*(1.0d0-ratdum(irv1))
       a2 = -y(ica40)*y(ihe4) * ratdum(ircaap)*rate(irv1)
       a3 = -y(iti44) * ratdum(irv1) * rate(irtigp)
       a4 = -y(iti44) * rate(irv1) * ratdum(irtigp)
       a5 = -y(iti44)*y(ihe4) * rate(irtiap)*(1.0d0-ratdum(irw1))
       a6 =  y(iti44)*y(ihe4) * ratdum(irtiap)*rate(irw1)
       a7 =  y(icr48) * ratdum(irw1) * rate(ircrgp)
       a8 =  y(icr48) * rate(irw1) * ratdum(ircrgp)

       qray(iti44) = qray(iti44) + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8
    end if


    ! cr48 reactions
    a1 =  y(iti44) * y(ihe4) * rate(irtiag)
    a2 = -y(icr48) * y(ihe4) * rate(ircrag)
    a3 = -y(icr48) * rate(ircrga)
    a4 =  y(ife52) * rate(irfega)

    qray(icr48) = qray(icr48) + a1 + a2 + a3 + a4

    if (.not.deriva) then
       a1 =  y(iti44) * y(ihe4) * rate(irtiap)*(1.0d0-rate(irw1))
       a2 = -y(icr48) * rate(irw1) * rate(ircrgp)
       a3 = -y(icr48) * y(ihe4) * rate(ircrap)*(1.0d0-rate(irx1))
       a4 =  y(ife52) * rate(irx1) * rate(irfegp)

       qray(icr48) = qray(icr48) + a1 + a2 + a3 + a4

    else
       a1 =  y(iti44)*y(ihe4) * rate(irtiap)*(1.0d0-ratdum(irw1))
       a2 = -y(iti44)*y(ihe4) * ratdum(irtiap)*rate(irw1)
       a3 = -y(icr48) * ratdum(irw1) * rate(ircrgp)
       a4 = -y(icr48) * rate(irw1) * ratdum(ircrgp)
       a5 = -y(icr48)*y(ihe4) * rate(ircrap)*(1.0d0-ratdum(irx1))
       a6 =  y(icr48)*y(ihe4) * ratdum(ircrap)*rate(irx1)
       a7 =  y(ife52) * ratdum(irx1) * rate(irfegp)
       a8 =  y(ife52) * rate(irx1) * ratdum(irfegp)

       qray(icr48) = qray(icr48) + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8
    end if


    ! fe52 reactions
    a1 =  y(icr48) * y(ihe4) * rate(ircrag)
    a2 = -y(ife52) * y(ihe4) * rate(irfeag)
    a3 = -y(ife52) * rate(irfega)
    a4 =  y(ini56) * rate(irniga)

    qray(ife52) = qray(ife52) + a1 + a2 + a3 + a4

    if (.not.deriva) then
       a1 =  y(icr48) * y(ihe4) * rate(ircrap)*(1.0d0-rate(irx1))
       a2 = -y(ife52) * rate(irx1) * rate(irfegp)
       a3 = -y(ife52) * y(ihe4) * rate(irfeap)*(1.0d0-rate(iry1))
       a4 =  y(ini56) * rate(iry1) * rate(irnigp)

       qray(ife52) = qray(ife52) + a1 + a2 + a3 + a4

    else
       a1 =  y(icr48)*y(ihe4) * rate(ircrap)*(1.0d0-ratdum(irx1))
       a2 = -y(icr48)*y(ihe4) * ratdum(ircrap)*rate(irx1)
       a3 = -y(ife52) * ratdum(irx1) * rate(irfegp)
       a4 = -y(ife52) * rate(irx1) * ratdum(irfegp)
       a5 = -y(ife52)*y(ihe4) * rate(irfeap)*(1.0d0-ratdum(iry1))
       a6 =  y(ife52)*y(ihe4) * ratdum(irfeap)*rate(iry1)
       a7 =  y(ini56) * ratdum(iry1) * rate(irnigp)
       a8 =  y(ini56) * rate(iry1) * ratdum(irnigp)

       qray(ife52) = qray(ife52) + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8
    end if


    ! ni56 reactions
    a1 =  y(ife52) * y(ihe4) * rate(irfeag)
    a2 = -y(ini56) * rate(irniga)

    qray(ini56) = qray(ini56) + a1 + a2

    if (.not.deriva) then
       a1 =  y(ife52) * y(ihe4) * rate(irfeap)*(1.0d0-rate(iry1))
       a2 = -y(ini56) * rate(iry1) * rate(irnigp)

       qray(ini56) = qray(ini56) + a1 + a2

    else
       a1 =  y(ife52)*y(ihe4) * rate(irfeap)*(1.0d0-ratdum(iry1))
       a2 = -y(ife52)*y(ihe4) * ratdum(irfeap)*rate(iry1)
       a3 = -y(ini56) * ratdum(iry1) * rate(irnigp)
       a4 = -y(ini56) * rate(iry1) * ratdum(irnigp)

       qray(ini56) = qray(ini56) + a1 + a2 + a3 + a4
    end if



    ! Now set the double precision return argument dydt

    dydt(1:nspec) = qray(1:nspec)

  end subroutine rhs


  subroutine aprox13rat(btemp, bden, ratraw, dratrawdt, dratrawdd)

    ! this routine generates unscreened
    ! nuclear reaction rates for the aprox13 network.

    use tfactors_module
    use rates_module

    implicit none
    
    double precision :: btemp, bden
    double precision :: ratraw(nrates), dratrawdt(nrates), dratrawdd(nrates)

    integer          :: i
    double precision :: rrate,drratedt,drratedd
    type (tf_t)      :: tf

    do i=1,nrates
       ratraw(i)    = ZERO
       dratrawdt(i) = ZERO
       dratrawdd(i) = ZERO
    enddo
  
    if (btemp .lt. 1.0d6) return


    ! get the temperature factors
    tf = get_tfactors(btemp)


    ! c12(a,g)o16
    call rate_c12ag(tf,bden, &
                    ratraw(ircag),dratrawdt(ircag),dratrawdd(ircag), &
                    ratraw(iroga),dratrawdt(iroga),dratrawdd(iroga))
    
    ! triple alpha to c12
    call rate_tripalf(tf,bden, &
                      ratraw(ir3a),dratrawdt(ir3a),dratrawdd(ir3a), &
                      ratraw(irg3a),dratrawdt(irg3a),dratrawdd(irg3a))
    
    ! c12 + c12
    call rate_c12c12(tf,bden, &
                     ratraw(ir1212),dratrawdt(ir1212),dratrawdd(ir1212), &
                     rrate,drratedt,drratedd)
    
    ! c12 + o16
    call rate_c12o16(tf,bden, &
                     ratraw(ir1216),dratrawdt(ir1216),dratrawdd(ir1216), &
                     rrate,drratedt,drratedd)
    
    ! o16 + o16
    call rate_o16o16(tf,bden, &
                     ratraw(ir1616),dratrawdt(ir1616),dratrawdd(ir1616), &
                     rrate,drratedt,drratedd)
    
    ! o16(a,g)ne20
    call rate_o16ag(tf,bden, &
                    ratraw(iroag),dratrawdt(iroag),dratrawdd(iroag), &
                    ratraw(irnega),dratrawdt(irnega),dratrawdd(irnega))
    
    ! ne20(a,g)mg24
    call rate_ne20ag(tf,bden, &
                     ratraw(irneag),dratrawdt(irneag),dratrawdd(irneag), &
                     ratraw(irmgga),dratrawdt(irmgga),dratrawdd(irmgga))
    
    ! mg24(a,g)si28
    call rate_mg24ag(tf,bden, &
                     ratraw(irmgag),dratrawdt(irmgag),dratrawdd(irmgag), &
                     ratraw(irsiga),dratrawdt(irsiga),dratrawdd(irsiga))
    
    ! mg24(a,p)al27
    call rate_mg24ap(tf,bden, &
                     ratraw(irmgap),dratrawdt(irmgap),dratrawdd(irmgap), &
                     ratraw(iralpa),dratrawdt(iralpa),dratrawdd(iralpa))
    
    ! al27(p,g)si28
    call rate_al27pg(tf,bden, &
                     ratraw(iralpg),dratrawdt(iralpg),dratrawdd(iralpg), &
                     ratraw(irsigp),dratrawdt(irsigp),dratrawdd(irsigp))
    
    ! si28(a,g)s32
    call rate_si28ag(tf,bden, &
                     ratraw(irsiag),dratrawdt(irsiag),dratrawdd(irsiag), &
                     ratraw(irsga),dratrawdt(irsga),dratrawdd(irsga))
    
    ! si28(a,p)p31
    call rate_si28ap(tf,bden, &
                     ratraw(irsiap),dratrawdt(irsiap),dratrawdd(irsiap), &
                     ratraw(irppa),dratrawdt(irppa),dratrawdd(irppa))
    
    ! p31(p,g)s32
    call rate_p31pg(tf,bden, &
                    ratraw(irppg),dratrawdt(irppg),dratrawdd(irppg), &
                    ratraw(irsgp),dratrawdt(irsgp),dratrawdd(irsgp))
    
    ! s32(a,g)ar36
    call rate_s32ag(tf,bden, &
                    ratraw(irsag),dratrawdt(irsag),dratrawdd(irsag), &
                    ratraw(irarga),dratrawdt(irarga),dratrawdd(irarga))
    
    ! s32(a,p)cl35
    call rate_s32ap(tf,bden, &
                    ratraw(irsap),dratrawdt(irsap),dratrawdd(irsap), &
                    ratraw(irclpa),dratrawdt(irclpa),dratrawdd(irclpa))
    
    ! cl35(p,g)ar36
    call rate_cl35pg(tf,bden, &
                     ratraw(irclpg),dratrawdt(irclpg),dratrawdd(irclpg), &
                     ratraw(irargp),dratrawdt(irargp),dratrawdd(irargp))
    
    ! ar36(a,g)ca40
    call rate_ar36ag(tf,bden, &
                     ratraw(irarag),dratrawdt(irarag),dratrawdd(irarag), &
                     ratraw(ircaga),dratrawdt(ircaga),dratrawdd(ircaga))
    
    ! ar36(a,p)k39
    call rate_ar36ap(tf,bden, &
                     ratraw(irarap),dratrawdt(irarap),dratrawdd(irarap), &
                     ratraw(irkpa),dratrawdt(irkpa),dratrawdd(irkpa))
    
    ! k39(p,g)ca40
    call rate_k39pg(tf,bden, &
                    ratraw(irkpg),dratrawdt(irkpg),dratrawdd(irkpg), &
                    ratraw(ircagp),dratrawdt(ircagp),dratrawdd(ircagp))
    
    ! ca40(a,g)ti44
    call rate_ca40ag(tf,bden, &
                     ratraw(ircaag),dratrawdt(ircaag),dratrawdd(ircaag), &
                     ratraw(irtiga),dratrawdt(irtiga),dratrawdd(irtiga))
    
    ! ca40(a,p)sc43
    call rate_ca40ap(tf,bden, &
                     ratraw(ircaap),dratrawdt(ircaap),dratrawdd(ircaap), &
                     ratraw(irscpa),dratrawdt(irscpa),dratrawdd(irscpa))
    
    ! sc43(p,g)ti44
    call rate_sc43pg(tf,bden, &
                     ratraw(irscpg),dratrawdt(irscpg),dratrawdd(irscpg), &
                     ratraw(irtigp),dratrawdt(irtigp),dratrawdd(irtigp))
    
    ! ti44(a,g)cr48
    call rate_ti44ag(tf,bden, &
                     ratraw(irtiag),dratrawdt(irtiag),dratrawdd(irtiag), &
                     ratraw(ircrga),dratrawdt(ircrga),dratrawdd(ircrga))

    ! ti44(a,p)v47
    call rate_ti44ap(tf,bden, &
                     ratraw(irtiap),dratrawdt(irtiap),dratrawdd(irtiap), &
                     ratraw(irvpa),dratrawdt(irvpa),dratrawdd(irvpa))
    
    ! v47(p,g)cr48
    call rate_v47pg(tf,bden, &
                    ratraw(irvpg),dratrawdt(irvpg),dratrawdd(irvpg), &
                    ratraw(ircrgp),dratrawdt(ircrgp),dratrawdd(ircrgp))
    
    ! cr48(a,g)fe52
    call rate_cr48ag(tf,bden, &
                     ratraw(ircrag),dratrawdt(ircrag),dratrawdd(ircrag), &
                     ratraw(irfega),dratrawdt(irfega),dratrawdd(irfega))
    
    ! cr48(a,p)mn51
    call rate_cr48ap(tf,bden, &
                     ratraw(ircrap),dratrawdt(ircrap),dratrawdd(ircrap), &
                     ratraw(irmnpa),dratrawdt(irmnpa),dratrawdd(irmnpa))
    
    ! mn51(p,g)fe52
    call rate_mn51pg(tf,bden, &
                     ratraw(irmnpg),dratrawdt(irmnpg),dratrawdd(irmnpg), &
                     ratraw(irfegp),dratrawdt(irfegp),dratrawdd(irfegp))
    
    ! fe52(a,g)ni56
    call rate_fe52ag(tf,bden, &
                     ratraw(irfeag),dratrawdt(irfeag),dratrawdd(irfeag), &
                     ratraw(irniga),dratrawdt(irniga),dratrawdd(irniga))
    
    ! fe52(a,p)co55
    call rate_fe52ap(tf,bden, &
                     ratraw(irfeap),dratrawdt(irfeap),dratrawdd(irfeap), &
                     ratraw(ircopa),dratrawdt(ircopa),dratrawdd(ircopa))
    
    ! co55(p,g)ni56
    call rate_co55pg(tf,bden, &
                     ratraw(ircopg),dratrawdt(ircopg),dratrawdd(ircopg), &
                     ratraw(irnigp),dratrawdt(irnigp),dratrawdd(irnigp))
    
  end subroutine aprox13rat



  subroutine screen_aprox13(btemp, bden, y, &
                            ratraw, dratrawdt, dratrawdd, &
                            ratdum, dratdumdt, dratdumdd, &
                            scfac, dscfacdt, dscfacdd)

    use bl_constants_module, only: ZERO, ONE
    use screening_module, only: screen5, plasma_state, fill_plasma_state
    
    implicit none
    
    ! this routine computes the screening factors
    ! and applies them to the raw reaction rates,
    ! producing the final reaction rates used by the
    ! right hand sides and jacobian matrix elements

    double precision :: btemp, bden
    double precision :: y(nspec)
    double precision :: ratraw(nrates), dratrawdt(nrates), dratrawdd(nrates)
    double precision :: ratdum(nrates), dratdumdt(nrates), dratdumdd(nrates)
    double precision :: scfac(nrates),  dscfacdt(nrates),  dscfacdd(nrates)

    integer          :: i, jscr
    double precision :: sc1a,sc1adt,sc1add,sc2a,sc2adt,sc2add, &
                        sc3a,sc3adt,sc3add
    
    double precision :: abar,zbar,z2bar,ytot1,zbarxx,z2barxx, &
                        denom,denomdt,denomdd, &
                        r1,r1dt,r1dd,s1,s1dt,s1dd,t1,t1dt,t1dd, &
                        u1,u1dt,u1dd,v1,v1dt,v1dd,w1,w1dt,w1dd, &
                        x1,x1dt,x1dd,y1,y1dt,y1dd,zz

    type (plasma_state) :: state

    ! initialize
    do i=1,nrates
       ratdum(i)    = ratraw(i)
       dratdumdt(i) = dratrawdt(i)
       dratdumdd(i) = dratrawdd(i)
       scfac(i)     = ONE
       dscfacdt(i)  = ZERO
       dscfacdd(i)  = ZERO
    end do



    ! Set up the state data, which is the same for all screening factors.
    
    call fill_plasma_state(state, btemp, bden, y(1:nspec))



    ! first the always fun triple alpha and its inverse
    jscr = 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)

    jscr = jscr + 1
    call screen5(state,jscr,sc2a,sc2adt,sc2add)

    sc3a   = sc1a * sc2a
    sc3adt = sc1adt*sc2a + sc1a*sc2adt
    !sc3add = sc1add*sc2a + sc1a*sc2add

    ratdum(ir3a)    = ratraw(ir3a) * sc3a
    dratdumdt(ir3a) = dratrawdt(ir3a)*sc3a + ratraw(ir3a)*sc3adt
    !dratdumdd(ir3a) = dratrawdd(ir3a)*sc3a + ratraw(ir3a)*sc3add

    scfac(ir3a) = sc3a
    dscfacdt(ir3a)  = sc3adt
    !dscfacdd(ir3a)  = sc3add

    ratdum(irg3a)    = ratraw(irg3a) * sc3a
    dratdumdt(irg3a) = dratrawdt(irg3a)*sc3a + ratraw(irg3a)*sc3adt
    !dratdumdd(irg3a) = dratrawdd(irg3a)*sc3a + ratraw(irg3a)*sc3add

    scfac(irg3a)  = sc3a
    dscfacdt(irg3a)  = sc3adt
    !dscfacdd(irg3a)  = sc3add


    ! c12 to o16
    ! c12(a,g)o16
    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)

    ratdum(ircag)     = ratraw(ircag) * sc1a
    dratdumdt(ircag)  = dratrawdt(ircag)*sc1a + ratraw(ircag)*sc1adt
    !dratdumdd(ircag)  = dratrawdd(ircag)*sc1a + ratraw(ircag)*sc1add

    scfac(ircag)  = sc1a
    dscfacdt(ircag)   = sc1adt
    !dscfacdd(ircag)   = sc1add

    ratdum(iroga)     = ratraw(iroga) * sc1a
    dratdumdt(iroga)  = dratrawdt(iroga)*sc1a + ratraw(iroga)*sc1adt
    !dratdumdd(iroga)  = dratrawdd(iroga)*sc1a + ratraw(iroga)*sc1add

    scfac(iroga)  = sc1a
    dscfacdt(iroga)   = sc1adt
    !dscfacdd(iroga)   = sc1add


    ! c12 + c12
    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)


    ratdum(ir1212)    = ratraw(ir1212) * sc1a
    dratdumdt(ir1212) = dratrawdt(ir1212)*sc1a + ratraw(ir1212)*sc1adt
    !dratdumdd(ir1212) = dratrawdd(ir1212)*sc1a + ratraw(ir1212)*sc1add

    scfac(ir1212)     = sc1a
    dscfacdt(ir1212)  = sc1adt
    !dscfacdd(ir1212)  = sc1add



    ! c12 + o16
    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)

    ratdum(ir1216)    = ratraw(ir1216) * sc1a
    dratdumdt(ir1216) = dratrawdt(ir1216)*sc1a + ratraw(ir1216)*sc1adt
    !dratdumdd(ir1216) = dratrawdd(ir1216)*sc1a + ratraw(ir1216)*sc1add

    scfac(ir1216)     = sc1a
    dscfacdt(ir1216)  = sc1adt
    !dscfacdd(ir1216)  = sc1add


    ! o16 + o16
    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)


    ratdum(ir1616)    = ratraw(ir1616) * sc1a
    dratdumdt(ir1616) = dratrawdt(ir1616)*sc1a + ratraw(ir1616)*sc1adt
    !dratdumdd(ir1616) = dratrawdd(ir1616)*sc1a + ratraw(ir1616)*sc1add

    scfac(ir1616)     = sc1a
    dscfacdt(ir1616)  = sc1adt
    !dscfacdd(ir1616)  = sc1add



    ! o16 to ne20
    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)


    ! o16(a,g)ne20
    ratdum(iroag)    = ratraw(iroag) * sc1a
    dratdumdt(iroag) = dratrawdt(iroag)*sc1a + ratraw(iroag)*sc1adt
    !dratdumdd(iroag) = dratrawdd(iroag)*sc1a + ratraw(iroag)*sc1add

    scfac(iroag)  = sc1a
    dscfacdt(iroag)  = sc1adt
    !dscfacdd(iroag)  = sc1add

    ratdum(irnega)    = ratraw(irnega) * sc1a
    dratdumdt(irnega) = dratrawdt(irnega)*sc1a + ratraw(irnega)*sc1adt
    !dratdumdd(irnega) = dratrawdd(irnega)*sc1a + ratraw(irnega)*sc1add

    scfac(irnega)  = sc1a
    dscfacdt(irnega)  = sc1adt
    !dscfacdd(irnega)  = sc1add


    ! ne20 to mg24
    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)


    ! ne20(a,g)mg24
    ratdum(irneag)    = ratraw(irneag) * sc1a
    dratdumdt(irneag) = dratrawdt(irneag)*sc1a + ratraw(irneag)*sc1adt
    !dratdumdd(irneag) = dratrawdd(irneag)*sc1a + ratraw(irneag)*sc1add

    scfac(irneag) = sc1a
    dscfacdt(irneag)  = sc1adt
    !dscfacdd(irneag)  = sc1add

    ratdum(irmgga)    = ratraw(irmgga) * sc1a
    dratdumdt(irmgga) = dratrawdt(irmgga)*sc1a + ratraw(irmgga)*sc1adt
    !dratdumdd(irmgga) = dratrawdd(irmgga)*sc1a + ratraw(irmgga)*sc1add

    scfac(irmgga) = sc1a
    dscfacdt(irmgga)  = sc1adt
    !dscfacdd(irmgga)  = sc1add



    ! mg24 to si28
    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)


    ! mg24(a,g)si28
    ratdum(irmgag)    = ratraw(irmgag) * sc1a
    dratdumdt(irmgag) = dratrawdt(irmgag)*sc1a + ratraw(irmgag)*sc1adt
    !dratdumdd(irmgag) = dratrawdd(irmgag)*sc1a + ratraw(irmgag)*sc1add

    scfac(irmgag) = sc1a
    dscfacdt(irmgag)  = sc1adt
    !dscfacdd(irmgag)  = sc1add

    ratdum(irsiga)    = ratraw(irsiga) * sc1a
    dratdumdt(irsiga) = dratrawdt(irsiga)*sc1a + ratraw(irsiga)*sc1adt
    !dratdumdd(irsiga) = dratrawdd(irsiga)*sc1a + ratraw(irsiga)*sc1add

    scfac(irsiga) = sc1a
    dscfacdt(irsiga)  = sc1adt
    !dscfacdd(irsiga)  = sc1add


    ! mg24(a,p)al27
    ratdum(irmgap)    = ratraw(irmgap) * sc1a
    dratdumdt(irmgap) = dratrawdt(irmgap)*sc1a + ratraw(irmgap)*sc1adt
    !dratdumdd(irmgap) = dratrawdd(irmgap)*sc1a + ratraw(irmgap)*sc1add

    scfac(irmgap)     = sc1a
    dscfacdt(irmgap)  = sc1adt
    !dscfacdd(irmgap)  = sc1add

    ratdum(iralpa)    = ratraw(iralpa) * sc1a
    dratdumdt(iralpa) = dratrawdt(iralpa)*sc1a + ratraw(iralpa)*sc1adt
    !dratdumdd(iralpa) = dratrawdd(iralpa)*sc1a + ratraw(iralpa)*sc1add

    scfac(iralpa)     = sc1a
    dscfacdt(iralpa)  = sc1adt
    !dscfacdd(iralpa)  = sc1add


    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)

    ! al27(p,g)si28
    ratdum(iralpg)    = ratraw(iralpg) * sc1a
    dratdumdt(iralpg) = dratrawdt(iralpg)*sc1a + ratraw(iralpg)*sc1adt
    !dratdumdd(iralpg) = dratrawdd(iralpg)*sc1a + ratraw(iralpg)*sc1add

    scfac(iralpg)     = sc1a
    dscfacdt(iralpg)  = sc1adt
    !dscfacdd(iralpg)  = sc1add

    ratdum(irsigp)    = ratraw(irsigp) * sc1a
    dratdumdt(irsigp) = dratrawdt(irsigp)*sc1a + ratraw(irsigp)*sc1adt
    !dratdumdd(irsigp) = dratrawdd(irsigp)*sc1a + ratraw(irsigp)*sc1add

    scfac(irsigp)     = sc1a
    dscfacdt(irsigp)  = sc1adt
    !dscfacdd(irsigp)  = sc1add


    ! si28 to s32
    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)


    ! si28(a,g)s32
    ratdum(irsiag)    = ratraw(irsiag) * sc1a
    dratdumdt(irsiag) = dratrawdt(irsiag)*sc1a + ratraw(irsiag)*sc1adt
    !dratdumdd(irsiag) = dratrawdd(irsiag)*sc1a + ratraw(irsiag)*sc1add

    scfac(irsiag)     = sc1a
    dscfacdt(irsiag)  = sc1adt
    !dscfacdd(irsiag)  = sc1add

    ratdum(irsga)    = ratraw(irsga) * sc1a
    dratdumdt(irsga) = dratrawdt(irsga)*sc1a + ratraw(irsga)*sc1adt
    !dratdumdd(irsga) = dratrawdd(irsga)*sc1a + ratraw(irsga)*sc1add

    scfac(irsga)     = sc1a
    dscfacdt(irsga)  = sc1adt
    !dscfacdd(irsga)  = sc1add


    ! si28(a,p)p31
    ratdum(irsiap)    = ratraw(irsiap) * sc1a
    dratdumdt(irsiap) = dratrawdt(irsiap)*sc1a + ratraw(irsiap)*sc1adt
    !dratdumdd(irsiap) = dratrawdd(irsiap)*sc1a + ratraw(irsiap)*sc1add

    scfac(irsiap)     = sc1a
    dscfacdt(irsiap)  = sc1adt
    !dscfacdd(irsiap)  = sc1add

    ratdum(irppa)     = ratraw(irppa) * sc1a
    dratdumdt(irppa)  = dratrawdt(irppa)*sc1a  + ratraw(irppa)*sc1adt
    !dratdumdd(irppa)  = dratrawdd(irppa)*sc1a  + ratraw(irppa)*sc1add

    scfac(irppa)      = sc1a
    dscfacdt(irppa)   = sc1adt
    !dscfacdd(irppa)   = sc1add


    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)

    ! p31(p,g)s32
    ratdum(irppg)     = ratraw(irppg) * sc1a
    dratdumdt(irppg)  = dratrawdt(irppg)*sc1a + ratraw(irppg)*sc1adt
    !dratdumdd(irppg)  = dratrawdd(irppg)*sc1a + ratraw(irppg)*sc1add

    scfac(irppg)      = sc1a
    dscfacdt(irppg)   = sc1adt
    !dscfacdd(irppg)   = sc1add

    ratdum(irsgp)     = ratraw(irsgp) * sc1a
    dratdumdt(irsgp)  = dratrawdt(irsgp)*sc1a + ratraw(irsgp)*sc1adt
    !dratdumdd(irsgp)  = dratrawdd(irsgp)*sc1a + ratraw(irsgp)*sc1add

    scfac(irsgp)      = sc1a
    dscfacdt(irsgp)   = sc1adt
    !dscfacdd(irsgp)   = sc1add



    ! s32 to ar36
    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)


    ! s32(a,g)ar36
    ratdum(irsag)     = ratraw(irsag) * sc1a
    dratdumdt(irsag)  = dratrawdt(irsag)*sc1a + ratraw(irsag)*sc1adt
    !dratdumdd(irsag)  = dratrawdd(irsag)*sc1a + ratraw(irsag)*sc1add

    scfac(irsag)      = sc1a
    dscfacdt(irsag)   = sc1adt
    !dscfacdd(irsag)   = sc1add

    ratdum(irarga)     = ratraw(irarga) * sc1a
    dratdumdt(irarga)  = dratrawdt(irarga)*sc1a + ratraw(irarga)*sc1adt
    !dratdumdd(irarga)  = dratrawdd(irarga)*sc1a + ratraw(irarga)*sc1add

    scfac(irarga)      = sc1a
    dscfacdt(irarga)   = sc1adt
    !dscfacdd(irarga)   = sc1add

    ! s32(a,p)cl35
    ratdum(irsap)     = ratraw(irsap) * sc1a
    dratdumdt(irsap)  = dratrawdt(irsap)*sc1a + ratraw(irsap)*sc1adt
    !dratdumdd(irsap)  = dratrawdd(irsap)*sc1a + ratraw(irsap)*sc1add

    scfac(irsap)      = sc1a
    dscfacdt(irsap)   = sc1adt
    !dscfacdd(irsap)   = sc1add

    ratdum(irclpa)    = ratraw(irclpa) * sc1a
    dratdumdt(irclpa) = dratrawdt(irclpa)*sc1a + ratraw(irclpa)*sc1adt
    !dratdumdd(irclpa) = dratrawdd(irclpa)*sc1a + ratraw(irclpa)*sc1add

    scfac(irclpa)     = sc1a
    dscfacdt(irclpa)  = sc1adt
    !dscfacdt(irclpa)  = sc1add


    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)

    ! cl35(p,g)ar36
    ratdum(irclpg)    = ratraw(irclpg) * sc1a
    dratdumdt(irclpg) = dratrawdt(irclpg)*sc1a + ratraw(irclpg)*sc1adt
    !dratdumdd(irclpg) = dratrawdd(irclpg)*sc1a + ratraw(irclpg)*sc1add

    scfac(irclpg)     = sc1a
    dscfacdt(irclpg)  = sc1adt
    !dscfacdd(irclpg)  = sc1add

    ratdum(irargp)    = ratraw(irargp) * sc1a
    dratdumdt(irargp) = dratrawdt(irargp)*sc1a + ratraw(irargp)*sc1adt
    !dratdumdd(irargp) = dratrawdd(irargp)*sc1a + ratraw(irargp)*sc1add

    scfac(irargp)     = sc1a
    dscfacdt(irargp)  = sc1adt
    !dscfacdd(irargp)  = sc1add



    ! ar36 to ca40
    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)


    ! ar36(a,g)ca40
    ratdum(irarag)    = ratraw(irarag) * sc1a
    dratdumdt(irarag) = dratrawdt(irarag)*sc1a + ratraw(irarag)*sc1adt
    !dratdumdd(irarag) = dratrawdd(irarag)*sc1a + ratraw(irarag)*sc1add

    scfac(irarag)     = sc1a
    dscfacdt(irarag)  = sc1adt
    !dscfacdd(irarag)  = sc1add

    ratdum(ircaga)    = ratraw(ircaga) * sc1a
    dratdumdt(ircaga) = dratrawdt(ircaga)*sc1a + ratraw(ircaga)*sc1adt
    !dratdumdd(ircaga) = dratrawdd(ircaga)*sc1a + ratraw(ircaga)*sc1add

    scfac(ircaga)     = sc1a
    dscfacdt(ircaga)  = sc1adt
    !dscfacdd(ircaga)  = sc1add


    ! ar36(a,p)k39
    ratdum(irarap)    = ratraw(irarap) * sc1a
    dratdumdt(irarap) = dratrawdt(irarap)*sc1a + ratraw(irarap)*sc1adt
    !dratdumdd(irarap) = dratrawdd(irarap)*sc1a + ratraw(irarap)*sc1add

    scfac(irarap)     = sc1a
    dscfacdt(irarap)  = sc1adt
    !dscfacdd(irarap)  = sc1add

    ratdum(irkpa)     = ratraw(irkpa) * sc1a
    dratdumdt(irkpa)  = dratrawdt(irkpa)*sc1a  + ratraw(irkpa)*sc1adt
    !dratdumdd(irkpa)  = dratrawdd(irkpa)*sc1a  + ratraw(irkpa)*sc1add

    scfac(irkpa)      = sc1a
    dscfacdt(irkpa)   = sc1adt
    !dscfacdd(irkpa)   = sc1add


    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)

    ! k39(p,g)ca40
    ratdum(irkpg)     = ratraw(irkpg) * sc1a
    dratdumdt(irkpg)  = dratrawdt(irkpg)*sc1a  + ratraw(irkpg)*sc1adt
    !dratdumdd(irkpg)  = dratrawdd(irkpg)*sc1a  + ratraw(irkpg)*sc1add

    scfac(irkpg)      = sc1a
    dscfacdt(irkpg)   = sc1adt
    !dscfacdd(irkpg)   = sc1add

    ratdum(ircagp)     = ratraw(ircagp) * sc1a
    dratdumdt(ircagp)  = dratrawdt(ircagp)*sc1a  + ratraw(ircagp)*sc1adt
    !dratdumdd(ircagp)  = dratrawdd(ircagp)*sc1a  + ratraw(ircagp)*sc1add

    scfac(ircagp)      = sc1a
    dscfacdt(ircagp)   = sc1adt
    !dscfacdd(ircagp)   = sc1add



    ! ca40 to ti44
    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)


    ! ca40(a,g)ti44
    ratdum(ircaag)    = ratraw(ircaag) * sc1a
    dratdumdt(ircaag) = dratrawdt(ircaag)*sc1a + ratraw(ircaag)*sc1adt
    !dratdumdd(ircaag) = dratrawdd(ircaag)*sc1a + ratraw(ircaag)*sc1add

    scfac(ircaag)     = sc1a
    dscfacdt(ircaag)  = sc1adt
    !dscfacdd(ircaag)  = sc1add

    ratdum(irtiga)    = ratraw(irtiga) * sc1a
    dratdumdt(irtiga) = dratrawdt(irtiga)*sc1a + ratraw(irtiga)*sc1adt
    !dratdumdd(irtiga) = dratrawdd(irtiga)*sc1a + ratraw(irtiga)*sc1add

    scfac(irtiga)     = sc1a
    dscfacdt(irtiga)  = sc1adt
    !dscfacdd(irtiga)  = sc1add


    ! ca40(a,p)sc43
    ratdum(ircaap)    = ratraw(ircaap) * sc1a
    dratdumdt(ircaap) = dratrawdt(ircaap)*sc1a + ratraw(ircaap)*sc1adt
    !dratdumdd(ircaap) = dratrawdd(ircaap)*sc1a + ratraw(ircaap)*sc1add

    scfac(ircaap)     = sc1a
    dscfacdt(ircaap)  = sc1adt
    !dscfacdd(ircaap)  = sc1add

    ratdum(irscpa)    = ratraw(irscpa) * sc1a
    dratdumdt(irscpa) = dratrawdt(irscpa)*sc1a + ratraw(irscpa)*sc1adt
    !dratdumdd(irscpa) = dratrawdd(irscpa)*sc1a + ratraw(irscpa)*sc1add

    scfac(irscpa)     = sc1a
    dscfacdt(irscpa)  = sc1adt
    !dscfacdd(irscpa)  = sc1add


    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)

    ! sc43(p,g)ti44
    ratdum(irscpg)    = ratraw(irscpg) * sc1a
    dratdumdt(irscpg) = dratrawdt(irscpg)*sc1a + ratraw(irscpg)*sc1adt
    !dratdumdd(irscpg) = dratrawdd(irscpg)*sc1a + ratraw(irscpg)*sc1add

    scfac(irscpg)     = sc1a
    dscfacdt(irscpg)  = sc1adt
    !dscfacdd(irscpg)  = sc1add

    ratdum(irtigp)    = ratraw(irtigp) * sc1a
    dratdumdt(irtigp) = dratrawdt(irtigp)*sc1a + ratraw(irtigp)*sc1adt
    !dratdumdd(irtigp) = dratrawdd(irtigp)*sc1a + ratraw(irtigp)*sc1add

    scfac(irtigp)     = sc1a
    dscfacdt(irtigp)  = sc1adt
    !dscfacdd(irtigp)  = sc1add



    ! ti44 to cr48
    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)


    ! ti44(a,g)cr48
    ratdum(irtiag)    = ratraw(irtiag) * sc1a
    dratdumdt(irtiag) = dratrawdt(irtiag)*sc1a + ratraw(irtiag)*sc1adt
    !dratdumdd(irtiag) = dratrawdd(irtiag)*sc1a + ratraw(irtiag)*sc1add

    scfac(irtiag)     = sc1a
    dscfacdt(irtiag)  = sc1adt
    !dscfacdd(irtiag)  = sc1add

    ratdum(ircrga)    = ratraw(ircrga) * sc1a
    dratdumdt(ircrga) = dratrawdt(ircrga)*sc1a + ratraw(ircrga)*sc1adt
    !dratdumdd(ircrga) = dratrawdd(ircrga)*sc1a + ratraw(ircrga)*sc1add

    scfac(ircrga)     = sc1a
    dscfacdt(ircrga)  = sc1adt
    !dscfacdd(ircrga)  = sc1add

    ! ti44(a,p)v47
    ratdum(irtiap)    = ratraw(irtiap) * sc1a
    dratdumdt(irtiap) = dratrawdt(irtiap)*sc1a + ratraw(irtiap)*sc1adt
    !dratdumdd(irtiap) = dratrawdd(irtiap)*sc1a + ratraw(irtiap)*sc1add

    scfac(irtiap)  = sc1a
    dscfacdt(irtiap)  = sc1adt
    !dscfacdd(irtiap)  = sc1add

    ratdum(irvpa)     = ratraw(irvpa) * sc1a
    dratdumdt(irvpa)  = dratrawdt(irvpa)*sc1a  + ratraw(irvpa)*sc1adt
    !dratdumdd(irvpa)  = dratrawdd(irvpa)*sc1a  + ratraw(irvpa)*sc1add

    scfac(irvpa)      = sc1a
    dscfacdt(irvpa)   = sc1adt
    !dscfacdd(irvpa)   = sc1add


    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)

    ! v47(p,g)cr48
    ratdum(irvpg)     = ratraw(irvpg) * sc1a
    dratdumdt(irvpg)  = dratrawdt(irvpg)*sc1a  + ratraw(irvpg)*sc1adt
    !dratdumdd(irvpg)  = dratrawdd(irvpg)*sc1a  + ratraw(irvpg)*sc1add

    scfac(irvpg)      = sc1a
    dscfacdt(irvpg)   = sc1adt
    !dscfacdd(irvpg)   = sc1add

    ratdum(ircrgp)     = ratraw(ircrgp) * sc1a
    dratdumdt(ircrgp)  = dratrawdt(ircrgp)*sc1a  + ratraw(ircrgp)*sc1adt
    !dratdumdd(ircrgp)  = dratrawdd(ircrgp)*sc1a  + ratraw(ircrgp)*sc1add

    scfac(ircrgp)      = sc1a
    dscfacdt(ircrgp)   = sc1adt
    !dscfacdd(ircrgp)   = sc1add



    ! cr48 to fe52
    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)


    ! cr48(a,g)fe52
    ratdum(ircrag)    = ratraw(ircrag) * sc1a
    dratdumdt(ircrag) = dratrawdt(ircrag)*sc1a + ratraw(ircrag)*sc1adt
    !dratdumdd(ircrag) = dratrawdd(ircrag)*sc1a + ratraw(ircrag)*sc1add

    scfac(ircrag)     = sc1a
    dscfacdt(ircrag)  = sc1adt
    !dscfacdd(ircrag)  = sc1add

    ratdum(irfega)    = ratraw(irfega) * sc1a
    dratdumdt(irfega) = dratrawdt(irfega)*sc1a + ratraw(irfega)*sc1adt
    !dratdumdd(irfega) = dratrawdd(irfega)*sc1a + ratraw(irfega)*sc1add

    scfac(irfega)     = sc1a
    dscfacdt(irfega)  = sc1adt
    !dscfacdd(irfega)  = sc1add


    ! cr48(a,p)mn51
    ratdum(ircrap)    = ratraw(ircrap) * sc1a
    dratdumdt(ircrap) = dratrawdt(ircrap)*sc1a + ratraw(ircrap)*sc1adt
    !dratdumdd(ircrap) = dratrawdd(ircrap)*sc1a + ratraw(ircrap)*sc1add

    scfac(ircrap)     = sc1a
    dscfacdt(ircrap)  = sc1adt
    !dscfacdd(ircrap)  = sc1add

    ratdum(irmnpa)    = ratraw(irmnpa) * sc1a
    dratdumdt(irmnpa) = dratrawdt(irmnpa)*sc1a + ratraw(irmnpa)*sc1adt
    !dratdumdd(irmnpa) = dratrawdd(irmnpa)*sc1a + ratraw(irmnpa)*sc1add

    scfac(irmnpa)     = sc1a
    dscfacdt(irmnpa)  = sc1adt
    !dscfacdd(irmnpa)  = sc1add


    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)

    ! mn51(p,g)fe52
    ratdum(irmnpg)    = ratraw(irmnpg) * sc1a
    dratdumdt(irmnpg) = dratrawdt(irmnpg)*sc1a + ratraw(irmnpg)*sc1adt
    !dratdumdd(irmnpg) = dratrawdd(irmnpg)*sc1a + ratraw(irmnpg)*sc1add

    scfac(irmnpg)     = sc1a
    dscfacdt(irmnpg)  = sc1adt
    !dscfacdd(irmnpg)  = sc1add

    ratdum(irfegp)    = ratraw(irfegp) * sc1a
    dratdumdt(irfegp) = dratrawdt(irfegp)*sc1a + ratraw(irfegp)*sc1adt
    !dratdumdd(irfegp) = dratrawdd(irfegp)*sc1a + ratraw(irfegp)*sc1add

    scfac(irfegp)     = sc1a
    dscfacdt(irfegp)  = sc1adt
    !dscfacdd(irfegp)  = sc1add



    ! fe52 to ni56
    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)


    ! fe52(a,g)ni56
    ratdum(irfeag)    = ratraw(irfeag) * sc1a
    dratdumdt(irfeag) = dratrawdt(irfeag)*sc1a + ratraw(irfeag)*sc1adt
    !dratdumdd(irfeag) = dratrawdd(irfeag)*sc1a + ratraw(irfeag)*sc1add

    scfac(irfeag)     = sc1a
    dscfacdt(irfeag)  = sc1adt
    !dscfacdd(irfeag)  = sc1add

    ratdum(irniga)    = ratraw(irniga) * sc1a
    dratdumdt(irniga) = dratrawdt(irniga)*sc1a + ratraw(irniga)*sc1adt
    !dratdumdd(irniga) = dratrawdd(irniga)*sc1a + ratraw(irniga)*sc1add

    scfac(irniga)     = sc1a
    dscfacdt(irniga)  = sc1adt
    !dscfacdd(irniga)  = sc1add


    ! fe52(a,p)co55
    ratdum(irfeap) = ratraw(irfeap) * sc1a
    dratdumdt(irfeap) = dratrawdt(irfeap)*sc1a + ratraw(irfeap)*sc1adt
    !dratdumdd(irfeap) = dratrawdd(irfeap)*sc1a + ratraw(irfeap)*sc1add

    scfac(irfeap)     = sc1a
    dscfacdt(irfeap)  = sc1adt
    !dscfacdd(irfeap)  = sc1add

    ratdum(ircopa)    = ratraw(ircopa) * sc1a
    dratdumdt(ircopa) = dratrawdt(ircopa)*sc1a + ratraw(ircopa)*sc1adt
    !dratdumdd(ircopa) = dratrawdd(ircopa)*sc1a + ratraw(ircopa)*sc1add

    scfac(ircopa)     = sc1a
    dscfacdt(ircopa)  = sc1adt
    !dscfacdd(ircopa)  = sc1add


    jscr = jscr + 1
    call screen5(state,jscr,sc1a,sc1adt,sc1add)


    ! co55(p,g)ni56
    ratdum(ircopg)    = ratraw(ircopg) * sc1a
    dratdumdt(ircopg) = dratrawdt(ircopg)*sc1a + ratraw(ircopg)*sc1adt
    !dratdumdd(ircopg) = dratrawdd(ircopg)*sc1a + ratraw(ircopg)*sc1add

    scfac(ircopg)     = sc1a
    dscfacdt(ircopg)  = sc1adt
    !dscfacdd(ircopg)  = sc1add

    ratdum(irnigp)    = ratraw(irnigp) * sc1a
    dratdumdt(irnigp) = dratrawdt(irnigp)*sc1a + ratraw(irnigp)*sc1adt
    !dratdumdd(irnigp) = dratrawdd(irnigp)*sc1a + ratraw(irnigp)*sc1add

    scfac(irnigp)     = sc1a
    dscfacdt(irnigp)  = sc1adt
    !dscfacdd(irniga)  = sc1add



    ! now form those lovely dummy proton link rates
    
    ! mg24(a,p)27al(p,g)28si
    ratdum(irr1)     = 0.0d0
    dratdumdt(irr1)  = 0.0d0
    !dratdumdd(irr1)  = 0.0d0
    denom    = ratdum(iralpa) + ratdum(iralpg)
    denomdt  = dratdumdt(iralpa) + dratdumdt(iralpg)
    !denomdd  = dratdumdd(iralpa) + dratdumdd(iralpg)
    if (denom .gt. 1.0d-30) then
       zz = 1.0d0/denom
       ratdum(irr1)    = ratdum(iralpa)*zz
       dratdumdt(irr1) = (dratdumdt(iralpa) - ratdum(irr1)*denomdt)*zz
       !dratdumdd(irr1) = (dratdumdd(iralpa) - ratdum(irr1)*denomdd)*zz
    end if

    ! si28(a,p)p31(p,g)s32
    ratdum(irs1)     = 0.0d0
    dratdumdt(irs1)  = 0.0d0
    !dratdumdd(irs1)  = 0.0d0
    denom    = ratdum(irppa) + ratdum(irppg)
    denomdt  = dratdumdt(irppa) + dratdumdt(irppg)
    !denomdd  = dratdumdd(irppa) + dratdumdd(irppg)
    if (denom .gt. 1.0d-30) then
       zz = 1.0d0/denom
       ratdum(irs1)    = ratdum(irppa)*zz
       dratdumdt(irs1) = (dratdumdt(irppa) - ratdum(irs1)*denomdt)*zz
       !dratdumdd(irs1) = (dratdumdd(irppa) - ratdum(irs1)*denomdd)*zz
    end if

    ! s32(a,p)cl35(p,g)ar36
    ratdum(irt1)     = 0.0d0
    dratdumdt(irt1)  = 0.0d0
    !dratdumdd(irt1)  = 0.0d0
    denom    = ratdum(irclpa) + ratdum(irclpg)
    denomdt  = dratdumdt(irclpa) + dratdumdt(irclpg)
    !denomdd  = dratdumdd(irclpa) + dratdumdd(irclpg)
    if (denom .gt. 1.0d-30) then
       zz = 1.0d0/denom
       ratdum(irt1)    = ratdum(irclpa)*zz
       dratdumdt(irt1) = (dratdumdt(irclpa) - ratdum(irt1)*denomdt)*zz
       !dratdumdd(irt1) = (dratdumdd(irclpa) - ratdum(irt1)*denomdd)*zz
    end if

    ! ar36(a,p)k39(p,g)ca40
    ratdum(iru1)     = 0.0d0
    dratdumdt(iru1)  = 0.0d0
    !dratdumdd(iru1)  = 0.0d0
    denom    = ratdum(irkpa) + ratdum(irkpg)
    denomdt  = dratdumdt(irkpa) + dratdumdt(irkpg)
    !denomdd  = dratdumdd(irkpa) + dratdumdd(irkpg)
    if (denom .gt. 1.0d-30) then
       zz   = 1.0d0/denom
       ratdum(iru1)   = ratdum(irkpa)*zz
       dratdumdt(iru1) = (dratdumdt(irkpa) - ratdum(iru1)*denomdt)*zz
       !dratdumdd(iru1) = (dratdumdd(irkpa) - ratdum(iru1)*denomdd)*zz
    end if

    ! ca40(a,p)sc43(p,g)ti44
    ratdum(irv1)     = 0.0d0
    dratdumdt(irv1)  = 0.0d0
    !dratdumdd(irv1)  = 0.0d0
    denom    = ratdum(irscpa) + ratdum(irscpg)
    denomdt  = dratdumdt(irscpa) + dratdumdt(irscpg)
    !denomdd  = dratdumdd(irscpa) + dratdumdd(irscpg)
    if (denom .gt. 1.0d-30) then
       zz  = 1.0d0/denom
       ratdum(irv1)    = ratdum(irscpa)*zz
       dratdumdt(irv1) = (dratdumdt(irscpa) - ratdum(irv1)*denomdt)*zz
       !dratdumdd(irv1) = (dratdumdd(irscpa) - ratdum(irv1)*denomdd)*zz
    end if

    ! ti44(a,p)v47(p,g)cr48
    ratdum(irw1)    = 0.0d0
    dratdumdt(irw1) = 0.0d0
    !dratdumdd(irw1) = 0.0d0
    denom    = ratdum(irvpa) + ratdum(irvpg)
    denomdt  = dratdumdt(irvpa) + dratdumdt(irvpg)
    !denomdd  = dratdumdd(irvpa) + dratdumdd(irvpg)
    if (denom .gt. 1.0d-30) then
       zz = 1.0d0/denom
       ratdum(irw1)    = ratdum(irvpa)*zz
       dratdumdt(irw1) = (dratdumdt(irvpa) - ratdum(irw1)*denomdt)*zz
       !dratdumdd(irw1) = (dratdumdd(irvpa) - ratdum(irw1)*denomdd)*zz
    end if

    ! cr48(a,p)mn51(p,g)fe52
    ratdum(irx1)    = 0.0d0
    dratdumdt(irx1) = 0.0d0
    !dratdumdd(irx1) = 0.0d0
    denom    = ratdum(irmnpa) + ratdum(irmnpg)
    denomdt  = dratdumdt(irmnpa) + dratdumdt(irmnpg)
    !denomdd  = dratdumdd(irmnpa) + dratdumdd(irmnpg)
    if (denom .gt. 1.0d-30) then
       zz = 1.0d0/denom
       ratdum(irx1)    = ratdum(irmnpa)*zz
       dratdumdt(irx1) = (dratdumdt(irmnpa) - ratdum(irx1)*denomdt)*zz
       !dratdumdd(irx1) = (dratdumdd(irmnpa) - ratdum(irx1)*denomdd)*zz
    endif

    ! fe52(a,p)co55(p,g)ni56
    ratdum(iry1)    = 0.0d0
    dratdumdt(iry1) = 0.0d0
    !dratdumdd(iry1) = 0.0d0
    denom    = ratdum(ircopa) + ratdum(ircopg)
    denomdt  = dratdumdt(ircopa) + dratdumdt(ircopg)
    !denomdd  = dratdumdd(ircopa) + dratdumdd(ircopg)
    if (denom .gt. 1.0d-30) then
       zz = 1.0d0/denom
       ratdum(iry1)    = ratdum(ircopa)*zz
       dratdumdt(iry1) = (dratdumdt(ircopa) - ratdum(iry1)*denomdt)*zz
       !dratdumdd(iry1) = (dratdumdd(ircopa) - ratdum(iry1)*denomdd)*zz
    end if
    
  end subroutine screen_aprox13



  subroutine dfdy_isotopes_aprox13(y,dfdy,neq,rate)

    use network

    implicit none
    
    ! this routine sets up the dense aprox13 jacobian for the isotopes

    integer          :: neq
    double precision :: y(neq),dfdy(neq,neq)
    double precision :: rate(nrates)

    double precision :: b(30)
    
    ! he4 jacobian elements
    ! d(he4)/d(he4)
    b(1)  = -1.5d0 * y(ihe4) * y(ihe4) * rate(ir3a) 
    b(2)  = -y(ic12)  * rate(ircag) 
    b(3)  = -y(io16)  * rate(iroag) 
    b(4)  = -y(ine20) * rate(irneag) 
    b(5)  = -y(img24) * rate(irmgag) 
    b(6)  = -y(isi28) * rate(irsiag) 
    b(7)  = -y(is32)  * rate(irsag) 
    b(8)  = -y(iar36) * rate(irarag) 
    b(9)  = -y(ica40) * rate(ircaag) 
    b(10) = -y(iti44) * rate(irtiag) 
    b(11) = -y(icr48) * rate(ircrag) 
    b(12) = -y(ife52) * rate(irfeag)
    b(13) = -y(img24) * rate(irmgap) * (1.0d0-rate(irr1)) 
    b(14) = -y(isi28) * rate(irsiap) * (1.0d0-rate(irs1)) 
    b(15) = -y(is32)  * rate(irsap)  * (1.0d0-rate(irt1)) 
    b(16) = -y(iar36) * rate(irarap) * (1.0d0-rate(iru1)) 
    b(17) = -y(ica40) * rate(ircaap) * (1.0d0-rate(irv1)) 
    b(18) = -y(iti44) * rate(irtiap) * (1.0d0-rate(irw1)) 
    b(19) = -y(icr48) * rate(ircrap) * (1.0d0-rate(irx1)) 
    b(20) = -y(ife52) * rate(irfeap) * (1.0d0-rate(iry1))
    dfdy(ihe4,ihe4) = sum(b(1:20))


    ! d(he4)/d(c12)
    b(1) =  y(ic12) * rate(ir1212) 
    b(2) =  0.5d0 * y(io16) * rate(ir1216) 
    b(3) =  3.0d0 * rate(irg3a) 
    b(4) = -y(ihe4) * rate(ircag)
    dfdy(ihe4,ic12) = sum(b(1:4))

    ! d(he4)/d(o16)
    b(1) =  0.5d0 * y(ic12) * rate(ir1216) 
    b(2) =  1.12d0 * 0.5d0*y(io16) * rate(ir1616) 
    b(3) =  0.68d0 * rate(irs1) * 0.5d0*y(io16) * rate(ir1616) 
    b(4) =  rate(iroga) 
    b(5) = -y(ihe4) * rate(iroag) 
    dfdy(ihe4,io16) = sum(b(1:5))

    ! d(he4)/d(ne20)
    b(1) =  rate(irnega) 
    b(2) = -y(ihe4) * rate(irneag)
    dfdy(ihe4,ine20) = sum(b(1:2))

    ! d(he4)/d(mg24)
    b(1) =  rate(irmgga) 
    b(2) = -y(ihe4) * rate(irmgag) 
    b(3) = -y(ihe4) * rate(irmgap) * (1.0d0-rate(irr1))
    dfdy(ihe4,img24) = sum(b(1:3))

    ! d(he4)/d(si28)
    b(1) =  rate(irsiga) 
    b(2) = -y(ihe4) * rate(irsiag) 
    b(3) = -y(ihe4) * rate(irsiap) * (1.0d0-rate(irs1)) 
    b(4) =  rate(irr1) * rate(irsigp)
    dfdy(ihe4,isi28) = sum(b(1:4))

    ! d(he4)/d(s32)
    b(1) =  rate(irsga) 
    b(2) = -y(ihe4) * rate(irsag) 
    b(3) = -y(ihe4) * rate(irsap) * (1.0d0-rate(irt1)) 
    b(4) =  rate(irs1) * rate(irsgp)
    dfdy(ihe4,is32) = sum(b(1:4))

    ! d(he4)/d(ar36)
    b(1)  =  rate(irarga) 
    b(2)  = -y(ihe4) * rate(irarag) 
    b(3)  = -y(ihe4) * rate(irarap) * (1.0d0-rate(iru1)) 
    b(4)  =  rate(irt1) * rate(irargp)
    dfdy(ihe4,iar36) = sum(b(1:4))

    ! d(he4)/d(ca40)
    b(1) =  rate(ircaga) 
    b(2) = -y(ihe4) * rate(ircaag) 
    b(3) = -y(ihe4) * rate(ircaap) * (1.0d0-rate(irv1)) 
    b(4) =  rate(iru1) * rate(ircagp)
    dfdy(ihe4,ica40) = sum(b(1:4))

    ! d(he4)/d(ti44)
    b(1) =  rate(irtiga) 
    b(2) = -y(ihe4) * rate(irtiag) 
    b(3) = -y(ihe4) * rate(irtiap) * (1.0d0-rate(irw1)) 
    b(4) =  rate(irv1) * rate(irtigp)
    dfdy(ihe4,iti44) = sum(b(1:4))

    ! d(he4)/d(cr48)
    b(1) =  rate(ircrga) 
    b(2) = -y(ihe4) * rate(ircrag) 
    b(3) = -y(ihe4) * rate(ircrap) * (1.0d0-rate(irx1)) 
    b(4) =  rate(irw1) * rate(ircrgp)
    dfdy(ihe4,icr48) = sum(b(1:4))

    ! d(he4)/d(fe52)
    b(1) =  rate(irfega) 
    b(2) = -y(ihe4) * rate(irfeag) 
    b(3) = -y(ihe4) * rate(irfeap) * (1.0d0-rate(iry1)) 
    b(4) =  rate(irx1) * rate(irfegp)
    dfdy(ihe4,ife52) = sum(b(1:4))

    ! d(he4)/d(ni56)
    b(1) = rate(irniga) 
    b(2) = rate(iry1) * rate(irnigp)
    dfdy(ihe4,ini56) = sum(b(1:2))


    ! c12 jacobian elements
    ! d(c12)/d(he4)
    b(1) =  0.5d0 * y(ihe4) * y(ihe4) * rate(ir3a) 
    b(2) = -y(ic12) * rate(ircag)
    dfdy(ic12,ihe4) = sum(b(1:2))

    ! d(c12)/d(c12)
    b(1) = -2.0d0 * y(ic12) * rate(ir1212) 
    b(2) = -y(io16) * rate(ir1216) 
    b(3) = -rate(irg3a) 
    b(4) = -y(ihe4) * rate(ircag) 
    dfdy(ic12,ic12) = sum(b(1:4))

    ! d(c12)/d(o16)
    b(1) = -y(ic12) * rate(ir1216) 
    b(2) =  rate(iroga)
    dfdy(ic12,io16) = sum(b(1:2))



    ! o16 jacobian elements
    ! d(o16)/d(he4)
    b(1) =  y(ic12)*rate(ircag) 
    b(2) = -y(io16)*rate(iroag)
    dfdy(io16,ihe4) = sum(b(1:2))

    ! d(o16)/d(c12)
    b(1) = -y(io16)*rate(ir1216) 
    b(2) =  y(ihe4)*rate(ircag)
    dfdy(io16,ic12) = sum(b(1:2))

    ! d(o16)/d(o16)
    b(1) = -y(ic12) * rate(ir1216) 
    b(2) = -2.0d0 * y(io16) * rate(ir1616) 
    b(3) = -y(ihe4) * rate(iroag) 
    b(4) = -rate(iroga) 
    dfdy(io16,io16) = sum(b(1:4))

    ! d(o16)/d(ne20)
    dfdy(io16,ine20) = rate(irnega)



    ! ne20 jacobian elements
    ! d(ne20)/d(he4)
    b(1) =  y(io16) * rate(iroag) 
    b(2) = -y(ine20) * rate(irneag) 
    dfdy(ine20,ihe4) = sum(b(1:2))

    ! d(ne20)/d(c12)
    dfdy(ine20,ic12) = y(ic12) * rate(ir1212)

    ! d(ne20)/d(o16)
    dfdy(ine20,io16) = y(ihe4) * rate(iroag)

    ! d(ne20)/d(ne20)
    b(1) = -y(ihe4) * rate(irneag) 
    b(2) = -rate(irnega)
    dfdy(ine20,ine20) = sum(b(1:2))

    ! d(ne20)/d(mg24)
    dfdy(ine20,img24) = rate(irmgga)


    ! mg24 jacobian elements
    ! d(mg24)/d(he4)
    b(1) =  y(ine20) * rate(irneag) 
    b(2) = -y(img24) * rate(irmgag) 
    b(3) = -y(img24) * rate(irmgap) * (1.0d0-rate(irr1))
    dfdy(img24,ihe4) = sum(b(1:3))

    ! d(mg24)/d(c12)
    dfdy(img24,ic12) = 0.5d0 * y(io16) * rate(ir1216)

    ! d(mg24)/d(o16)
    dfdy(img24,io16) = 0.5d0 * y(ic12) * rate(ir1216)

    ! d(mg24)/d(ne20)
    dfdy(img24,ine20) = y(ihe4) * rate(irneag)

    ! d(mg24)/d(mg24)
    b(1) = -y(ihe4) * rate(irmgag) 
    b(2) = -rate(irmgga) 
    b(3) = -y(ihe4) * rate(irmgap) * (1.0d0-rate(irr1))
    dfdy(img24,img24) = sum(b(1:3))

    ! d(mg24)/d(si28)
    b(1) = rate(irsiga) 
    b(2) = rate(irr1) * rate(irsigp)
    dfdy(img24,isi28) = sum(b(1:2))


    ! si28 jacobian elements
    ! d(si28)/d(he4)
    b(1) =  y(img24) * rate(irmgag) 
    b(2) = -y(isi28) * rate(irsiag) 
    b(3) =  y(img24) * rate(irmgap) * (1.0d0-rate(irr1)) 
    b(4) = -y(isi28) * rate(irsiap) * (1.0d0-rate(irs1))
    dfdy(isi28,ihe4) = sum(b(1:4))

    ! d(si28)/d(c12)
    dfdy(isi28,ic12) =  0.5d0 * y(io16) * rate(ir1216)

    ! d(si28)/d(o16)
    b(1) = 0.5d0 * y(ic12) * rate(ir1216) 
    b(2) = 1.12d0 * 0.5d0*y(io16) * rate(ir1616) 
    b(3) = 0.68d0 * 0.5d0*y(io16) * rate(irs1) * rate(ir1616)
    dfdy(isi28,io16) = sum(b(1:3))

    ! d(si28)/d(mg24)
    b(1) =  y(ihe4) * rate(irmgag) 
    b(2) =  y(ihe4) * rate(irmgap) * (1.0d0-rate(irr1))
    dfdy(isi28,img24) = sum(b(1:2))

    ! d(si28)/d(si28)
    b(1) =  -y(ihe4) * rate(irsiag) 
    b(2) = -rate(irsiga) 
    b(3) = -rate(irr1) * rate(irsigp) 
    b(4) = -y(ihe4) * rate(irsiap) * (1.0d0-rate(irs1))
    dfdy(isi28,isi28) = sum(b(1:4))

    ! d(si28)/d(s32)
    b(1) = rate(irsga) 
    b(2) = rate(irs1) * rate(irsgp)
    dfdy(isi28,is32) = sum(b(1:2))


    ! s32 jacobian elements
    ! d(s32)/d(he4)
    b(1) =  y(isi28) * rate(irsiag) 
    b(2) = -y(is32) * rate(irsag) 
    b(3) =  y(isi28) * rate(irsiap) * (1.0d0-rate(irs1)) 
    b(4) = -y(is32) * rate(irsap) * (1.0d0-rate(irt1))
    dfdy(is32,ihe4) = sum(b(1:4))

    ! d(s32)/d(o16)
    b(1) = 0.68d0*0.5d0*y(io16)*rate(ir1616)*(1.0d0-rate(irs1)) 
    b(2) = 0.2d0 * 0.5d0*y(io16) * rate(ir1616)
    dfdy(is32,io16) = sum(b(1:2))

    ! d(s32)/d(si28)
    b(1)  =y(ihe4) * rate(irsiag) 
    b(2) = y(ihe4) * rate(irsiap) * (1.0d0-rate(irs1))
    dfdy(is32,isi28) = sum(b(1:2))

    ! d(s32)/d(s32)
    b(1) = -y(ihe4) * rate(irsag) 
    b(2) = -rate(irsga) 
    b(3) = -rate(irs1) * rate(irsgp) 
    b(4) = -y(ihe4) * rate(irsap) * (1.0d0-rate(irt1))
    dfdy(is32,is32) = sum(b(1:4))

    ! d(s32)/d(ar36)
    b(1) = rate(irarga) 
    b(2) = rate(irt1) * rate(irargp)
    dfdy(is32,iar36) = sum(b(1:2))


    ! ar36 jacobian elements
    ! d(ar36)/d(he4)
    b(1) =  y(is32)  * rate(irsag) 
    b(2) = -y(iar36) * rate(irarag) 
    b(3) =  y(is32)  * rate(irsap) * (1.0d0-rate(irt1)) 
    b(4) = -y(iar36) * rate(irarap) * (1.0d0-rate(iru1))
    dfdy(iar36,ihe4) = sum(b(1:4))

    ! d(ar36)/d(s32)
    b(1) = y(ihe4) * rate(irsag) 
    b(2) = y(ihe4) * rate(irsap) * (1.0d0-rate(irt1))
    dfdy(iar36,is32) = sum(b(1:2))

    ! d(ar36)/d(ar36)
    b(1) = -y(ihe4) * rate(irarag) 
    b(2) = -rate(irarga) 
    b(3) = -rate(irt1) * rate(irargp) 
    b(4) = -y(ihe4) * rate(irarap) * (1.0d0-rate(iru1))
    dfdy(iar36,iar36) = sum(b(1:4))

    ! d(ar36)/d(ca40)
    b(1) = rate(ircaga) 
    b(2) = rate(ircagp) * rate(iru1)
    dfdy(iar36,ica40) = sum(b(1:2))


    ! ca40 jacobian elements
    ! d(ca40)/d(he4)
    b(1)  =  y(iar36) * rate(irarag) 
    b(2)  = -y(ica40) * rate(ircaag) 
    b(3)  =  y(iar36) * rate(irarap)*(1.0d0-rate(iru1)) 
    b(4)  = -y(ica40) * rate(ircaap)*(1.0d0-rate(irv1))
    dfdy(ica40,ihe4) = sum(b(1:4))

    ! d(ca40)/d(ar36)
    b(1) =  y(ihe4) * rate(irarag) 
    b(2) =  y(ihe4) * rate(irarap)*(1.0d0-rate(iru1))
    dfdy(ica40,iar36) = sum(b(1:2))

    ! d(ca40)/d(ca40)
    b(1) = -y(ihe4) * rate(ircaag) 
    b(2) = -rate(ircaga) 
    b(3) = -rate(ircagp) * rate(iru1) 
    b(4) = -y(ihe4) * rate(ircaap)*(1.0d0-rate(irv1))
    dfdy(ica40,ica40) = sum(b(1:4))

    ! d(ca40)/d(ti44)
    b(1) = rate(irtiga) 
    b(2) = rate(irtigp) * rate(irv1)
    dfdy(ica40,iti44) = sum(b(1:2))



    ! ti44 jacobian elements
    ! d(ti44)/d(he4)
    b(1) =  y(ica40) * rate(ircaag) 
    b(2) = -y(iti44) * rate(irtiag) 
    b(3) =  y(ica40) * rate(ircaap)*(1.0d0-rate(irv1)) 
    b(4) = -y(iti44) * rate(irtiap)*(1.0d0-rate(irw1))
    dfdy(iti44,ihe4) = sum(b(1:4))

    ! d(ti44)/d(ca40)
    b(1) =  y(ihe4) * rate(ircaag) 
    b(2) =  y(ihe4) * rate(ircaap)*(1.0d0-rate(irv1))
    dfdy(iti44,ica40) = sum(b(1:2))

    ! d(ti44)/d(ti44)
    b(1) = -y(ihe4) * rate(irtiag) 
    b(2) = -rate(irtiga) 
    b(3) = -rate(irv1) * rate(irtigp) 
    b(4) = -y(ihe4) * rate(irtiap)*(1.0d0-rate(irw1))
    dfdy(iti44,iti44) = sum(b(1:4))

    ! d(ti44)/d(cr48)
    b(1) = rate(ircrga) 
    b(2) = rate(irw1) * rate(ircrgp)
    dfdy(iti44,icr48) = sum(b(1:2))



    ! cr48 jacobian elements
    ! d(cr48)/d(he4)
    b(1) =  y(iti44) * rate(irtiag) 
    b(2) = -y(icr48) * rate(ircrag) 
    b(3) =  y(iti44) * rate(irtiap)*(1.0d0-rate(irw1)) 
    b(4) = -y(icr48) * rate(ircrap)*(1.0d0-rate(irx1))
    dfdy(icr48,ihe4) = sum(b(1:4))

    ! d(cr48)/d(ti44)
    b(1) =  y(ihe4) * rate(irtiag) 
    b(2) =  y(ihe4) * rate(irtiap)*(1.0d0-rate(irw1))
    dfdy(icr48,iti44) = sum(b(1:2))

    ! d(cr48)/d(cr48)
    b(1) = -y(ihe4) * rate(ircrag) 
    b(2) = -rate(ircrga) 
    b(3) = -rate(irw1) * rate(ircrgp) 
    b(4) = -y(ihe4) * rate(ircrap)*(1.0d0-rate(irx1))
    dfdy(icr48,icr48) = sum(b(1:4))

    ! d(cr48)/d(fe52)
    b(1) = rate(irfega) 
    b(2) = rate(irx1) * rate(irfegp)
    dfdy(icr48,ife52) = sum(b(1:2))



    ! fe52 jacobian elements
    ! d(fe52)/d(he4)
    b(1) =  y(icr48) * rate(ircrag) 
    b(2) = -y(ife52) * rate(irfeag) 
    b(3) =  y(icr48) * rate(ircrap) * (1.0d0-rate(irx1)) 
    b(4) = -y(ife52) * rate(irfeap) * (1.0d0-rate(iry1)) 
    dfdy(ife52,ihe4) = sum(b(1:4))

    ! d(fe52)/d(cr48)
    b(1) = y(ihe4) * rate(ircrag) 
    b(2) = y(ihe4) * rate(ircrap) * (1.0d0-rate(irx1))
    dfdy(ife52,icr48) = sum(b(1:2))

    ! d(fe52)/d(fe52)
    b(1) = -y(ihe4) * rate(irfeag) 
    b(2) = -rate(irfega) 
    b(3) = -rate(irx1) * rate(irfegp) 
    b(4) = -y(ihe4) * rate(irfeap) * (1.0d0-rate(iry1))
    dfdy(ife52,ife52) = sum(b(1:4))

    ! d(fe52)/d(ni56)
    b(1) = rate(irniga) 
    b(2) = rate(iry1) * rate(irnigp)
    dfdy(ife52,ini56) = sum(b(1:2))


    ! ni56 jacobian elements
    ! d(ni56)/d(he4)
    b(1) =  y(ife52) * rate(irfeag) 
    b(2) =  y(ife52) * rate(irfeap) * (1.0d0-rate(iry1))
    dfdy(ini56,ihe4) = sum(b(1:2))

    ! d(ni56)/d(fe52)
    b(1) = y(ihe4) * rate(irfeag) 
    b(2) = y(ihe4) * rate(irfeap) * (1.0d0-rate(iry1)) 
    dfdy(ini56,ife52) = sum(b(1:2))

    ! d(ni56)/d(ni56)
    b(1) = -rate(irniga) 
    b(2) = -rate(iry1) * rate(irnigp)
    dfdy(ini56,ini56) = sum(b(1:2))

  end subroutine dfdy_isotopes_aprox13

end module actual_rhs_module