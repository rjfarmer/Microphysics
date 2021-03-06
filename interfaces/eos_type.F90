module eos_type_module

  use network, only: nspec, naux
  use amrex_fort_module, only: rt => amrex_real

  implicit none

  integer, parameter :: eos_input_rt = 1  ! rho, T are inputs
  integer, parameter :: eos_input_rh = 2  ! rho, h are inputs
  integer, parameter :: eos_input_tp = 3  ! T, p are inputs
  integer, parameter :: eos_input_rp = 4  ! rho, p are inputs
  integer, parameter :: eos_input_re = 5  ! rho, e are inputs
  integer, parameter :: eos_input_ps = 6  ! p, s are inputs
  integer, parameter :: eos_input_ph = 7  ! p, h are inputs
  integer, parameter :: eos_input_th = 8  ! T, h are inputs

  ! these are used to allow for a generic interface to the 
  ! root finding
  integer, parameter :: itemp = 1
  integer, parameter :: idens = 2
  integer, parameter :: iener = 3
  integer, parameter :: ienth = 4
  integer, parameter :: ientr = 5
  integer, parameter :: ipres = 6

  ! error codes
  integer, parameter :: ierr_general         = 1
  integer, parameter :: ierr_input           = 2
  integer, parameter :: ierr_iter_conv       = 3
  integer, parameter :: ierr_neg_e           = 4
  integer, parameter :: ierr_neg_p           = 5
  integer, parameter :: ierr_neg_h           = 6
  integer, parameter :: ierr_neg_s           = 7
  integer, parameter :: ierr_iter_var        = 8
  integer, parameter :: ierr_init            = 9
  integer, parameter :: ierr_init_xn         = 10
  integer, parameter :: ierr_out_of_bounds   = 11
  integer, parameter :: ierr_not_implemented = 12

  ! Minimum and maximum thermodynamic quantities permitted by the EOS.

  real(rt), allocatable, save :: mintemp
  real(rt), allocatable, save :: maxtemp
  real(rt), allocatable, save :: mindens
  real(rt), allocatable, save :: maxdens
  real(rt), allocatable, save :: minx
  real(rt), allocatable, save :: maxx
  real(rt), allocatable, save :: minye
  real(rt), allocatable, save :: maxye
  real(rt), allocatable, save :: mine
  real(rt), allocatable, save :: maxe
  real(rt), allocatable, save :: minp
  real(rt), allocatable, save :: maxp
  real(rt), allocatable, save :: mins
  real(rt), allocatable, save :: maxs
  real(rt), allocatable, save :: minh
  real(rt), allocatable, save :: maxh

#ifdef CUDA
  attributes(managed) :: mintemp, maxtemp, mindens, maxdens
  attributes(managed) :: minx, maxx, minye, maxye, mine, maxe
  attributes(managed) :: minp, maxp, mins, maxs, minh, maxh  
#endif

  !$acc declare &
  !$acc create(mintemp, maxtemp, mindens, maxdens, minx, maxx, minye, maxye) &
  !$acc create(mine, maxe, minp, maxp, mins, maxs, minh, maxh)

  ! A generic structure holding thermodynamic quantities and their derivatives,
  ! plus some other quantities of interest.

  ! rho      -- mass density (g/cm**3)
  ! T        -- temperature (K)
  ! xn       -- the mass fractions of the individual isotopes
  ! p        -- the pressure (dyn/cm**2)
  ! h        -- the enthalpy (erg/g)
  ! e        -- the internal energy (erg/g)
  ! s        -- the entropy (erg/g/K)
  ! c_v      -- specific heat at constant volume
  ! c_p      -- specific heat at constant pressure
  ! ne       -- number density of electrons + positrons
  ! np       -- number density of positrons only
  ! eta      -- degeneracy parameter
  ! pele     -- electron pressure + positron pressure
  ! ppos     -- position pressure only
  ! mu       -- mean molecular weight
  ! mu_e     -- mean number of nucleons per electron
  ! y_e      -- electron fraction == 1 / mu_e
  ! dPdT     -- d pressure/ d temperature
  ! dPdr     -- d pressure/ d density
  ! dedT     -- d energy/ d temperature
  ! dedr     -- d energy/ d density
  ! dsdT     -- d entropy/ d temperature
  ! dsdr     -- d entropy/ d density
  ! dhdT     -- d enthalpy/ d temperature
  ! dhdr     -- d enthalpy/ d density
  ! dPdX     -- d pressure / d xmass
  ! dhdX     -- d enthalpy / d xmass at constant pressure
  ! gam1     -- first adiabatic index (d log P/ d log rho) |_s
  ! cs       -- sound speed
  ! abar     -- average atomic number ( sum_k {X_k} ) / ( sum_k {X_k/A_k} )
  ! zbar     -- average proton number ( sum_k {Z_k X_k/ A_k} ) / ( sum_k {X_k/A_k} )
  ! dpdA     -- d pressure/ d abar
  ! dpdZ     -- d pressure/ d zbar
  ! dedA     -- d energy/ d abar
  ! dedZ     -- d energy/ d zbar

  type :: eos_t

    real(rt) :: rho
    real(rt) :: T
    real(rt) :: p
    real(rt) :: e
    real(rt) :: h
    real(rt) :: s
    real(rt) :: xn(nspec)
    real(rt) :: aux(naux)

    real(rt) :: dpdT
    real(rt) :: dpdr
    real(rt) :: dedT
    real(rt) :: dedr
    real(rt) :: dhdT
    real(rt) :: dhdr
    real(rt) :: dsdT
    real(rt) :: dsdr
    real(rt) :: dpde
    real(rt) :: dpdr_e

    real(rt) :: cv
    real(rt) :: cp
    real(rt) :: xne
    real(rt) :: xnp
    real(rt) :: eta
    real(rt) :: pele
    real(rt) :: ppos
    real(rt) :: mu
    real(rt) :: mu_e
    real(rt) :: y_e

#ifdef EXTRA_THERMO
    real(rt) :: dedX(nspec)
    real(rt) :: dpdX(nspec)
    real(rt) :: dhdX(nspec)
#endif

    real(rt) :: gam1
    real(rt) :: cs

    real(rt) :: abar
    real(rt) :: zbar

#ifdef EXTRA_THERMO
    real(rt) :: dpdA
    real(rt) :: dpdZ
    real(rt) :: dedA
    real(rt) :: dedZ
#endif
  end type eos_t

contains

  ! Provides a copy subroutine for the eos_t type to
  ! avoid derived type assignment (OpenACC and CUDA can't handle that)
  AMREX_DEVICE subroutine copy_eos_t(to_eos, from_eos)

    implicit none

    type(eos_t) :: to_eos, from_eos

    to_eos % rho = from_eos % rho
    to_eos % T = from_eos % T
    to_eos % p = from_eos % p
    to_eos % e = from_eos % e
    to_eos % h = from_eos % h
    to_eos % s = from_eos % s
    to_eos % xn(:) = from_eos % xn(:)
    to_eos % aux(:) = from_eos % aux(:)

    to_eos % dpdT = from_eos % dpdT
    to_eos % dpdr = from_eos % dpdr
    to_eos % dedT = from_eos % dedT
    to_eos % dedr = from_eos % dedr
    to_eos % dhdT = from_eos % dhdT
    to_eos % dhdr = from_eos % dhdr
    to_eos % dsdT = from_eos % dsdT
    to_eos % dsdr = from_eos % dsdr
    to_eos % dpde = from_eos % dpde
    to_eos % dpdr_e = from_eos % dpdr_e

    to_eos % cv = from_eos % cv
    to_eos % cp = from_eos % cp
    to_eos % xne = from_eos % xne
    to_eos % xnp = from_eos % xnp
    to_eos % eta = from_eos % eta
    to_eos % pele = from_eos % pele
    to_eos % ppos = from_eos % ppos
    to_eos % mu = from_eos % mu
    to_eos % mu_e = from_eos % mu_e
    to_eos % y_e = from_eos % y_e

    to_eos % gam1 = from_eos % gam1
    to_eos % cs = from_eos % cs

    to_eos % abar = from_eos % abar
    to_eos % zbar = from_eos % zbar

#ifdef EXTRA_THERMO
    to_eos % dedX(:) = from_eos % dedX(:)
    to_eos % dpdX(:) = from_eos % dpdX(:)
    to_eos % dhdX(:) = from_eos % dhdX(:)
    
    to_eos % dpdA = from_eos % dpdA
    to_eos % dpdZ = from_eos % dpdZ
    to_eos % dedA = from_eos % dedA
    to_eos % dedZ = from_eos % dedZ
#endif
  end subroutine copy_eos_t


  ! Given a set of mass fractions, calculate quantities that depend
  ! on the composition like abar and zbar.

  AMREX_DEVICE subroutine composition(state)

    !$acc routine seq

    use amrex_constants_module, only: ONE
    use network, only: aion_inv, zion

    implicit none

    type (eos_t), intent(inout) :: state

    ! Calculate abar, the mean nucleon number,
    ! zbar, the mean proton number,
    ! mu, the mean molecular weight,
    ! mu_e, the mean number of nucleons per electron, and
    ! y_e, the electron fraction.

    state % mu_e = ONE / (sum(state % xn(:) * zion(:) * aion_inv(:)))
    state % y_e = ONE / state % mu_e

    state % abar = ONE / (sum(state % xn(:) * aion_inv(:)))
    state % zbar = state % abar / state % mu_e

  end subroutine composition

  ! Compute thermodynamic derivatives with respect to xn(:)

  AMREX_DEVICE subroutine composition_derivatives(state)

    !$acc routine seq

    use amrex_constants_module, only: ZERO
    use network, only: aion, aion_inv, zion

    implicit none

    type (eos_t), intent(inout) :: state

#ifdef EXTRA_THERMO
    state % dpdX(:) = state % dpdA * (state % abar * aion_inv(:))   &
                                   * (aion(:) - state % abar) &
                    + state % dpdZ * (state % abar * aion_inv(:))   &
                                   * (zion(:) - state % zbar)

    state % dEdX(:) = state % dedA * (state % abar * aion_inv(:))   &
                                   * (aion(:) - state % abar) &
                    + state % dedZ * (state % abar * aion_inv(:))   &
                                   * (zion(:) - state % zbar)

    if (state % dPdr .ne. ZERO) then

       state % dhdX(:) = state % dedX(:) &
                       + (state % p / state % rho**2 - state % dedr) &
                       *  state % dPdX(:) / state % dPdr

    endif
#endif

  end subroutine composition_derivatives



  ! Normalize the mass fractions: they must be individually positive
  ! and less than one, and they must all sum to unity.

  AMREX_DEVICE subroutine normalize_abundances(state)

    !$acc routine seq

    use amrex_constants_module, only: ONE
    use extern_probin_module, only: small_x

    implicit none

    type (eos_t), intent(inout) :: state

    state % xn = max(small_x, min(ONE, state % xn))

    state % xn = state % xn / sum(state % xn)

  end subroutine normalize_abundances



  ! Ensure that inputs are within reasonable limits.

  AMREX_DEVICE subroutine clean_state(state)

    !$acc routine seq

    implicit none

    type (eos_t), intent(inout) :: state

    state % T = min(maxtemp, max(mintemp, state % T))
    state % rho = min(maxdens, max(mindens, state % rho))

  end subroutine clean_state



  ! Print out details of the state.
#ifndef CUDA
  subroutine print_state(state)

    implicit none

    type (eos_t), intent(in) :: state

    print *, 'DENS = ', state % rho
    print *, 'TEMP = ', state % T
    print *, 'X    = ', state % xn
    print *, 'Y_E  = ', state % y_e

  end subroutine print_state
#endif


  AMREX_DEVICE subroutine eos_get_small_temp(small_temp_out)

    !$acc routine seq

    implicit none

    real(rt), intent(out) :: small_temp_out

    small_temp_out = mintemp

  end subroutine eos_get_small_temp



  AMREX_DEVICE subroutine eos_get_small_dens(small_dens_out)

    !$acc routine seq

    implicit none

    real(rt), intent(out) :: small_dens_out

    small_dens_out = mindens

  end subroutine eos_get_small_dens



  AMREX_DEVICE subroutine eos_get_max_temp(max_temp_out)

    !$acc routine seq

    implicit none

    real(rt), intent(out) :: max_temp_out

    max_temp_out = maxtemp

  end subroutine eos_get_max_temp



  AMREX_DEVICE subroutine eos_get_max_dens(max_dens_out)

    !$acc routine seq

    implicit none

    real(rt), intent(out) :: max_dens_out

    max_dens_out = maxdens

  end subroutine eos_get_max_dens

end module eos_type_module
