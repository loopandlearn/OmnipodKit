# OmnipodKit

## Overview

OmnipodKit is a new universal Omnipod pump manager that

* Handles all supported Omnipod types
* Simplifies future DIY Omnipod code maintenance
* Has a number of improvements and updates for Omnipod support
* Will be replacing both OmniKit (Eros) and OmniBLE (Dash)

To select the new OmnipodKit pump manager,
select `All Omnipod Types` when doing an `Add Pump`.
The actual Omnipod pod type will be selected during
the pump manager initialization setup sequence.
After deactivating a pod when using the OmnipodKit pump manager,
you can switch to either a different pod type OR
to another completely different pump manager
by scrolling to the bottom of the pod settings view and tapping on
`Switch to another pod or pump type`.

The `Omnipod` (OmniKit) and `Omnipod DASH` (OmniBLE) pump managers
currently displayed with `Add Pump` are the original unmodified
pump managers which maintain their own separate pump manager state.
Currently if you already have an active pod session using a previous pump manager,
you must select `Switch to other insulin delivery device`
after deactivating any active pod before you can do an `Add Pump`
to select `All Omnipod Types` for the OmnipodKit pump manager.

Eventually the OmniKit and OmniBLE pump manager will be replaced by OmnipodKit.
When this happens, OmnipodKit will handle any conversion of
any OmniKit or OmniBLE state (including for a currently active pod)
with minor app changes and the OmniKit and OmniBLE pump managers
will no longer be available and eventually unsupported.

### Status as of May 07, 2026

Modify the status of OmnipodKit to be public.

* Update the README file to be appropriate for a public version of this repository.

    * Now that repository is public, get more people using the repository to evaluate this as a replacement for OmniBLE and OmniKit
    * In parallel, continue work on a few features needed before O5 support is publicly available
    * The O5 work will continue to be done privately, then made available to the public repository after thorough testing

### Status as of April 14, 2026

Support for Omnipod 5 pod type was added to `main` with certain caveats

* the required information to work with O5 (*O5 data*) is not included in the repository
* future work will add the ability to get *O5 data* with a method that is under development
* developers who have access to the private *O5 data* file will be able to test the O5 pod type
* when the *O5 data* is not available, the repository provides full support for Classic (Eros) and DASH pod types
    * for this case, the `Omnipod Type` view display
only the `Omnipod Classic` and `Omnipod DASH` pod types

Known Issues with O5 support:

* No nudge or heartbeat services as of yet
    * time between loop operations can vary a lot without a CGM
providing a "heartbeat" service

### New feature available (as of March 6, 2026)
Pod Details now displays the printed lot information
along with the decimal lot value for all pod types.

* The interpretation of the electronic lot number provided by the pod for DASH or O5 is converted to the Px1xMMDDYYLb number that appears on the packaging and back of pod and is thus available to the users in the current and previous Pod Details.
