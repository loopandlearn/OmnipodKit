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
Currently if you already have an active pod session using a previous pump manager, you must wait until that pod session is completed and you deactivated the pod. 

After the pod is deactivated:

* Scroll to the bottom of the Omnipod screen and select `Switch to other insulin delivery device`
* From the main OS-AID screen, tap on `Add Pump`
* Select `All Omnipod Types`
   * Follow the onboarding prompts until you get to the pod selection screen
   * Select your pod type and continue

Eventually the OmniKit and OmniBLE pump manager will be replaced by OmnipodKit.
When this happens, OmnipodKit can handle the conversion of
any OmniKit or OmniBLE state (including an active pod).
