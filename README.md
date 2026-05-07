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

## Developer Notes

The OmnipodKit submodule must be added to the workspace for the OS-AID that will use it. To assist in adding the submodule, several patch files are available.  The one for Trio requires update when other managers are incorporated into Trio.

### To Add to LoopWorkspace

Included in the OmnipodKit repository is the patch to add the OmnipodKit (private repo) pump manager to a fresh clone of [LoopWorkspace](https://github.com/LoopKit/LoopWorkspace/).

* This patch is valid for either `main` or `dev` branches for LoopWorkspace.

The commands below should be pasted into Terminal with the path at the top-of-a-buildable LoopWorkspace directory.

If LoopWorkspace is open in Xcode, then before executing these commands:

* select Product, Clean Build Folder
* select File, Close Workspace

```
git switch -c add_omnipodkit_loop
git submodule add https://github.com/loopandlearn/OmnipodKit
git apply OmnipodKit/patches/add_omnipodkit_to_LoopWorkspace.patch
git add .
git commit -am "add submodule OmnipodKit"
xed .
```

When Xcode opens, if questioned, select use the version on disk.

After building Loop, be sure to select the new `All Omnipod Types`
when doing an `Add Pump` to use the new OmnipodKit pump manager.

### To Add to Trio

Included in the OmnipodKit repository is the patch to add OmnipodKit to a fresh clone of [Trio](https://github.com/nightscout/Trio/).

> The Trio patch requires an update when new submodules are incorporated into Trio.

* This patch works with Trio 0.6.0.72 or newer (30 March 2026), including main branch Trio 0.7.0.

The commands below should be pasted into Terminal with the path at the top-of-a-buildable Trio directory.
This patch handles all the Trio pump manager integration requirements to add the
OmnipodKit (private repo) pump manager to Trio, with caveats listed above.

If Trio is open in Xcode, then before executing these commands:

* select Product, Clean Build Folder
* select File, Close Workspace

```
git switch -c add_omnipodkit_trio
git submodule add https://github.com/loopandlearn/OmnipodKit
git apply OmnipodKit/patches/add_omnipodkit_to_Trio.patch
git add .
git commit -am "add submodule OmnipodKit"
xed .
```

When Xcode opens, if questioned, select use the version on disk.

After building with Xcode, this file will be modified as well: `Trio/Sources/Localizations/Main/Localizable.xcstrings`

After building Loop, be sure to select the new `All Omnipod Types`
when doing an `Add Pump` to use the new OmnipodKit pump manager.

### Manually Add a Plugin to LoopWorkspace

This section is here for convenience. It provides instructions on how to add a new plugin to Loop using OmnipodKit as an example. 

**When you use the patch method, above, this section is not required.**


```quote
$ cd <the-top-of-LoopWorkspace-directory>
$ git submodule add https://github.com/loopandlearn/OmnipodKit
$ xed .
```

In Xcode, select File->'Add Files to "LoopWorkspace"...'

* Scroll down to select and double click to open the "OmnipodKit" directory
* Select the "OmnipodKit.xcodeproj" file and tap the blue (Add) button
* Tap the blue (Finish) button

In Xcode with the LoopWorkspace selected, select Product->Scheme->Edit Scheme...

* Make sure that the Build tab on the top of the left panel is selected
* Click on the "+" in the bottom left corner above the blue (Duplicate Scheme) button
* Scroll down to select "OmnipodKitPlugin" icon (under OmnipodKit) and tap the blue (Add) button
* Drag "OmnipodKitPlugin OmnipodKit" from the bottom of the list up until immediately before "OmniKitPlugin OmniKit"
* Tap (Close)

#### Optional: Add Tests

To add the OmniTests to the LoopWorkspace tests in Xcode:

* verify that the LoopWorkspace scheme is selected
* click on the diamond with the check near the top of the lefthand panel to display the Test Navigator panel
* right click on OmniTests under the "Other Tests" section near the end of the panel
* select "Add to LoopWorkspace".

