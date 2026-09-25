# OmnipodKit

## Overview

OmnipodKit is a new universal Omnipod pump manager that

* Handles all supported Omnipod types: Omnipod 5, DASH and Eros
* Simplifies future DIY Omnipod code maintenance
* Has a number of improvements and updates for Omnipod support
* Replaced both OmniKit (Eros) and OmniBLE (Dash)

To select the new OmnipodKit pump manager,
select `Omnipod` when doing an `Add Pump`. When the OmniKit and OmniBLE were both available, this used to say "All Omnipod Types". Those two submodules are no longer used with iOS OS-AID system, so the simpler "Omnipod" is sufficient.
The actual Omnipod pod type will be selected during
the pump manager initialization setup sequence.
After deactivating a pod when using the OmnipodKit pump manager,
you can switch to either a different pod type OR
to another completely different pump manager
by scrolling to the bottom of the pod settings view and tapping on
`Switch to another pod or pump type`.

When building code with OmnipodKit over code that used OmniBLE and OmniKit, the OmnipodKit takes over for the DASH or Eros Pod Type automatically. This works even with an active DASH or Eros Pod.
