# Instructions to Add OmnipodKit Submodule

## Developer Notes

The OmnipodKit submodule must be added to the workspace for the OS-AID that will use it. To assist in adding the submodule, several patch files are available.  The one for Trio requires update when other managers are incorporated into Trio.

### To Add to LoopWorkspace

Included in the OmnipodKit repository is the patch to add the OmnipodKit pump manager to a fresh clone of [LoopWorkspace](https://github.com/LoopKit/LoopWorkspace/).

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

When Xcode opens, if questioned, select "use the version on disk".

After building Loop, be sure to select the new `All Omnipod Types`
when doing an `Add Pump` to use the new OmnipodKit pump manager.

### To Add to Trio

Included in the OmnipodKit repository is the patch to add OmnipodKit to a fresh clone of [Trio](https://github.com/nightscout/Trio/).

> The Trio patch requires an update when new submodules are incorporated into Trio.

* This patch works with Trio 0.6.0.72 or newer (30 March 2026), including main branch Trio 0.7.0.

The commands below should be pasted into Terminal with the path at the top-of-a-buildable Trio directory.

This patch handles all the Trio pump manager integration requirements to add the
OmnipodKit pump manager to Trio, with for versions listed above.

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

When Xcode opens, if questioned, select "use the version on disk".

After building with Xcode, this file will be modified as well: `Trio/Sources/Localizations/Main/Localizable.xcstrings`

After building Trio, be sure to select the new `All Omnipod Types`
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

