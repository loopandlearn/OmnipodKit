# OmnipodKit
Universal Omnipod Pump Manager for iOS Open-Source Automated Insulin Delivery (OS-AID) systems.

## Description
OmnipodKit is a new universal Omnipod pump manager that

* Handles all supported Omnipod types (Omnipod 5, DASH, and Eros)
* Includes a number of improvements and updates for Omnipod support
* Supersedes both the OmniBLE and OmniKit pump managers
* Simplifies future Open-Source Omnipod code maintenance

To use the OmnipodKit pump manager,
select `All Omnipod Types` when adding a pump type in your
favorite iOS Open-Source Automated Insulin Delivery app.
The actual Omnipod pod type will be selected during
the pump manager initialization setup sequence.
When there is no active pod,
you can switch to either a different pod type OR
to different pump manager by scrolling to the bottom
of the pod settings view and tapping on
`Switch to another pod or pump type`.

The OmniBLE and OmniKit pump managers are no longer
included in current versions of iOS OS-AID apps,
When an older version of an iOS OS-AID app using
the OmniBLE and OmniKit pump managers is replaced by a more
modern version of the app using the OmnipodKit pump manager,
OmnipodKit will automatically handle the conversion of
any saved OmniBLE or OmniKit state upon start up
(including for a currently active pod).

## Status
This repository contains code being used by current versions
of several iOS OS-AID systems including Loop and Trio.
This repository is derived from and supersedes both the
OmniBLE (DASH) and OmniKit (Eros) repositories and
includes support for the Omnipod 5 pod type.

## For more information on Loop
Please join loop zulipchat at https://loop.zulipchat.com

## For more information on Trio
Please join loop Discord at https://discord.triodocs.org
