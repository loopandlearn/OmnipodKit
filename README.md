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

### Status as of May 14, 2026

Modify the status of OmnipodKit to be public.

* Update the README file to be appropriate for a public version of this repository.

    * Now that repository is public, get more people using the repository to evaluate this as a replacement for OmniBLE and OmniKit
    * In parallel, continue work on a few features needed before O5 support is publicly available
    * The O5 work will continue to be done privately, then made available to the public repository after thorough testing

