module actual_network
  use physical_constants, only: ERG_PER_MeV
  use amrex_fort_module, only: rt => amrex_real
  
  implicit none

  public

  double precision, parameter :: avo = 6.0221417930d23
  double precision, parameter :: c_light = 2.99792458d10
  double precision, parameter :: enuc_conv2 = -avo*c_light*c_light

  double precision, parameter :: ev2erg  = 1.60217648740d-12
  double precision, parameter :: mev2erg = ev2erg*1.0d6
  double precision, parameter :: mev2gr  = mev2erg/c_light**2

  double precision, parameter :: mass_neutron  = 1.67492721184d-24
  double precision, parameter :: mass_proton   = 1.67262163783d-24
  double precision, parameter :: mass_electron = 9.10938215450d-28

  integer, parameter :: nrates = 7
  integer, parameter :: num_rate_groups = 4

  ! Evolution and auxiliary
  integer, parameter :: nspec_evolve = 9
  integer, parameter :: naux  = 0

  ! Number of nuclear species in the network
  integer, parameter :: nspec = 9

  ! Number of reaclib rates
  integer, parameter :: nrat_reaclib = 5
  
  ! Number of tabular rates
  integer, parameter :: nrat_tabular = 2

  ! Binding Energies Per Nucleon (MeV)
  double precision :: ebind_per_nucleon(nspec)

  ! aion: Nucleon mass number A
  ! zion: Nucleon atomic number Z
  ! nion: Nucleon neutron number N
  ! bion: Binding Energies (ergs)

  ! Nuclides
  integer, parameter :: jn   = 1
  integer, parameter :: jp   = 2
  integer, parameter :: jhe4   = 3
  integer, parameter :: jc12   = 4
  integer, parameter :: jo16   = 5
  integer, parameter :: jne20   = 6
  integer, parameter :: jne23   = 7
  integer, parameter :: jna23   = 8
  integer, parameter :: jmg23   = 9

  ! Reactions
  integer, parameter :: k_c12_c12__he4_ne20   = 1
  integer, parameter :: k_c12_c12__n_mg23   = 2
  integer, parameter :: k_c12_c12__p_na23   = 3
  integer, parameter :: k_he4_c12__o16   = 4
  integer, parameter :: k_n__p   = 5
  integer, parameter :: k_na23__ne23   = 6
  integer, parameter :: k_ne23__na23   = 7

  ! reactvec indices
  integer, parameter :: i_rate        = 1
  integer, parameter :: i_drate_dt    = 2
  integer, parameter :: i_scor        = 3
  integer, parameter :: i_dscor_dt    = 4
  integer, parameter :: i_dqweak      = 5
  integer, parameter :: i_epart       = 6

  character (len=16), save :: spec_names(nspec) 
  character (len= 5), save :: short_spec_names(nspec)
  character (len= 5), save :: short_aux_names(naux)

  real(rt), allocatable, save :: aion(:), zion(:), bion(:)
  real(rt), allocatable, save :: nion(:), mion(:), wion(:)

#ifdef CUDA
  attributes(managed) :: aion, zion, bion, nion, mion, wion
#endif

  !$acc declare create(aion, zion, bion, nion, mion, wion)

contains

  subroutine actual_network_init()
    
    implicit none
    
    integer :: i

    ! Allocate ion info arrays
    allocate(aion(nspec))
    allocate(zion(nspec))
    allocate(bion(nspec))
    allocate(nion(nspec))
    allocate(mion(nspec))
    allocate(wion(nspec))

    spec_names(jn)   = "neutron"
    spec_names(jp)   = "hydrogen-1"
    spec_names(jhe4)   = "helium-4"
    spec_names(jc12)   = "carbon-12"
    spec_names(jo16)   = "oxygen-16"
    spec_names(jne20)   = "neon-20"
    spec_names(jne23)   = "neon-23"
    spec_names(jna23)   = "sodium-23"
    spec_names(jmg23)   = "magnesium-23"

    short_spec_names(jn)   = "n"
    short_spec_names(jp)   = "h1"
    short_spec_names(jhe4)   = "he4"
    short_spec_names(jc12)   = "c12"
    short_spec_names(jo16)   = "o16"
    short_spec_names(jne20)   = "ne20"
    short_spec_names(jne23)   = "ne23"
    short_spec_names(jna23)   = "na23"
    short_spec_names(jmg23)   = "mg23"

    ebind_per_nucleon(jn)   = 0.00000000000000d+00
    ebind_per_nucleon(jp)   = 0.00000000000000d+00
    ebind_per_nucleon(jhe4)   = 7.07391500000000d+00
    ebind_per_nucleon(jc12)   = 7.68014400000000d+00
    ebind_per_nucleon(jo16)   = 7.97620600000000d+00
    ebind_per_nucleon(jne20)   = 8.03224000000000d+00
    ebind_per_nucleon(jne23)   = 7.95525600000000d+00
    ebind_per_nucleon(jna23)   = 8.11149300000000d+00
    ebind_per_nucleon(jmg23)   = 7.90111500000000d+00

    aion(jn)   = 1.00000000000000d+00
    aion(jp)   = 1.00000000000000d+00
    aion(jhe4)   = 4.00000000000000d+00
    aion(jc12)   = 1.20000000000000d+01
    aion(jo16)   = 1.60000000000000d+01
    aion(jne20)   = 2.00000000000000d+01
    aion(jne23)   = 2.30000000000000d+01
    aion(jna23)   = 2.30000000000000d+01
    aion(jmg23)   = 2.30000000000000d+01

    zion(jn)   = 0.00000000000000d+00
    zion(jp)   = 1.00000000000000d+00
    zion(jhe4)   = 2.00000000000000d+00
    zion(jc12)   = 6.00000000000000d+00
    zion(jo16)   = 8.00000000000000d+00
    zion(jne20)   = 1.00000000000000d+01
    zion(jne23)   = 1.00000000000000d+01
    zion(jna23)   = 1.10000000000000d+01
    zion(jmg23)   = 1.20000000000000d+01

    nion(jn)   = 1.00000000000000d+00
    nion(jp)   = 0.00000000000000d+00
    nion(jhe4)   = 2.00000000000000d+00
    nion(jc12)   = 6.00000000000000d+00
    nion(jo16)   = 8.00000000000000d+00
    nion(jne20)   = 1.00000000000000d+01
    nion(jne23)   = 1.30000000000000d+01
    nion(jna23)   = 1.20000000000000d+01
    nion(jmg23)   = 1.10000000000000d+01

    do i = 1, nspec
       bion(i) = ebind_per_nucleon(i) * aion(i) * ERG_PER_MeV
    end do

    ! Set the mass
    mion(:) = nion(:) * mass_neutron + zion(:) * (mass_proton + mass_electron) &
         - bion(:)/(c_light**2)

    ! Molar mass
    wion(:) = avo * mion(:)

    ! Common approximation
    !wion(:) = aion(:)

    !$acc update device(aion, zion, bion, nion, mion, wion)
  end subroutine actual_network_init

  subroutine actual_network_finalize()    
    ! Deallocate storage arrays
    deallocate(aion)
    deallocate(zion)
    deallocate(bion)
    deallocate(nion)
    deallocate(mion)
    deallocate(wion)
  end subroutine actual_network_finalize


  AMREX_DEVICE subroutine ener_gener_rate(dydt, enuc)
    ! Computes the instantaneous energy generation rate
    !$acc routine seq
  
    implicit none

    double precision :: dydt(nspec), enuc

    ! This is basically e = m c**2

    enuc = sum(dydt(:) * mion(:)) * enuc_conv2

  end subroutine ener_gener_rate

end module actual_network
