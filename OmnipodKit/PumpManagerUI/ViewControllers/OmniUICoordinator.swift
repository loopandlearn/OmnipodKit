//
//  OmniUIController.swift
//  OmnipodKit
//
//  Based on OmniBLE/PumpManagerUI/ViewControllers/OmniBLEUIController.swift
//  Created by Pete Schwamb on 2/16/20.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation

import UIKit
import SwiftUI
import Combine
import LoopKit
import LoopKitUI
import RileyLinkKit
import RileyLinkBLEKit
import RileyLinkKitUI

enum OmniUIScreen {
    case firstRunScreen
    case expirationReminderSetup
    case lowReservoirReminderSetup
    case insulinTypeSelection
    case selectPodType
    case podTypeSelected // virtual routing step — never presented; resolves to o5KeySetup / rileyLinkSetup / pairAndPrime
    case o5KeySetup
    case rileyLinkSetup // will be skipped for non-Eros pods
    case pairAndPrime
    case insertCannula
    case confirmAttachment
    case checkInsertedCannula
    case setupComplete
    case pendingCommandRecovery
    case uncertaintyRecovered
    case deactivate
    case settings

    func next() -> OmniUIScreen? {
        switch self {
        case .firstRunScreen:
            return .expirationReminderSetup
        case .expirationReminderSetup:
            return .lowReservoirReminderSetup
        case .lowReservoirReminderSetup:
            return .insulinTypeSelection
        case .insulinTypeSelection:
            return .selectPodType
        case .selectPodType:
            return .podTypeSelected
        case .podTypeSelected:
            // Resolved by `navigateTo` to one of o5KeySetup / rileyLinkSetup / pairAndPrime.
            // The fallback here (rileyLinkSetup) is never reached because this case is
            // never the "currentScreen" — it's intercepted before being pushed.
            return .rileyLinkSetup
        case .o5KeySetup:
            return .pairAndPrime
        case .rileyLinkSetup: // will be skipped for non-Eros pods
            return .pairAndPrime
        case .pairAndPrime:
            return .confirmAttachment
        case .confirmAttachment:
            return .insertCannula
        case .insertCannula:
            return .checkInsertedCannula
        case .checkInsertedCannula:
            return .setupComplete
        case .setupComplete:
            return nil
        case .pendingCommandRecovery:
            return .deactivate
        case .uncertaintyRecovered:
            return nil
        case .deactivate:
            return .podTypeSelected
        case .settings:
            return nil
        }
    }
}

protocol OmniUINavigator: AnyObject {
    func navigateTo(_ screen: OmniUIScreen)
}

class OmniUICoordinator: UINavigationController, PumpManagerOnboarding, CompletionNotifying, UINavigationControllerDelegate {

    weak var pumpManagerOnboardingDelegate: PumpManagerOnboardingDelegate?

    weak var completionDelegate: CompletionDelegate?

    var podType = unknownOmnipodType

    var pumpManager: OmniPumpManager

    private var disposables = Set<AnyCancellable>()

    var currentScreen: OmniUIScreen {
        return screenStack.last!
    }

    var screenStack = [OmniUIScreen]()

    private let colorPalette: LoopUIColorPalette

    private var pumpManagerType: OmniPumpManager.Type?

    private var allowedInsulinTypes: [InsulinType]

    private var allowDebugFeatures: Bool

    private func viewControllerForScreen(_ screen: OmniUIScreen) -> UIViewController {
        switch screen {
        case .firstRunScreen:
            let view = PodSetupView(nextAction: { [weak self] in self?.stepFinished() },
                                    allowDebugFeatures: allowDebugFeatures,
                                    skipOnboarding: { [weak self] in    // NOTE: DEBUG FEATURES - DEBUG AND TEST ONLY
                                        guard let self = self else { return }
                                        self.pumpManager.completeOnboard()
                                        self.completionDelegate?.completionNotifyingDidComplete(self)
                                    })
            let controller = hostingController(rootView: view)
            controller.navigationItem.title = pumpManager.localizedTitle
            return controller

        case .expirationReminderSetup:
            var view = ExpirationReminderSetupView(expirationReminderDefault: Int(pumpManager.defaultExpirationReminderOffset.hours))
            view.valueChanged = { [weak self] value in
                self?.pumpManager.defaultExpirationReminderOffset = .hours(Double(value))
            }
            view.continueButtonTapped = { [weak self] in
                guard let self = self else { return }
                if !self.pumpManager.isOnboarded {
                    self.pumpManager.completeOnboard()
                    self.pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didOnboardPumpManager: self.pumpManager)
                }
                self.stepFinished()
            }
            view.cancelButtonTapped = { [weak self] in
                self?.setupCanceled()
            }
            let hostedView = hostingController(rootView: view)
            hostedView.navigationItem.title = LocalizedString("Expiration Reminder", comment: "Title for ExpirationReminderSetupView")
            return hostedView

        case .lowReservoirReminderSetup:
            var view = LowReservoirView(
                reservoirLevel: Pod.reservoirLevelAboveThresholdMagicNumber,
                setDefault: true,
                initialValue: Int(pumpManager.defaultLowReservoirReminderValue),
            )
            view.valueUpdated = { [weak self] value in
                self?.pumpManager.defaultLowReservoirReminderValue = Double(value)
            }
            view.continueButtonTapped = { [weak self] in
                self?.pumpManager.initialConfigurationCompleted = true
                self?.stepFinished()
            }
            view.cancelButtonTapped = { [weak self] in
                self?.setupCanceled()
            }
            let hostedView = hostingController(rootView: view)
            hostedView.navigationItem.title = LocalizedString("Low Reservoir", comment: "Title for LowReservoirView")
            hostedView.navigationItem.backButtonDisplayMode = .generic
            return hostedView

        case .insulinTypeSelection:
            let didConfirm: (InsulinType) -> Void = { [weak self] (confirmedType) in
                self?.pumpManager.insulinType = confirmedType
                self?.stepFinished()
            }
            let didCancel: () -> Void = { [weak self] in
                self?.setupCanceled()
            }
            
            let insulinSelectionView = InsulinTypeConfirmation(initialValue: .novolog, supportedInsulinTypes: allowedInsulinTypes, didConfirm: didConfirm, didCancel: didCancel)
            let hostedView = hostingController(rootView: insulinSelectionView)
            hostedView.navigationItem.title = LocalizedString("Insulin Type", comment: "Title for insulin type selection screen")
            return hostedView

        case .selectPodType:
            let didConfirm: (PodType) -> Void = { [weak self] (selectedPodType) in
                self?.podType = selectedPodType
                self?.pumpManager.podType = selectedPodType
                self?.stepFinished()
            }
            let didCancel: () -> Void = { [weak self] in
                self?.setupCanceled()
            }
 
            let o5NotAvailable = !isOmnipod5Enabled()
            let podTypeSelectionView = PodTypeSelection(initialValue: self.podType, o5NotAvailable: o5NotAvailable, didConfirm: didConfirm, didCancel: didCancel)
            let hostedView = hostingController(rootView: podTypeSelectionView)
            hostedView.navigationItem.title = LocalizedString("Pod Type", comment: "Title for Pod Type selection screen")
            return hostedView

        case .podTypeSelected:
            // Virtual step: navigateTo resolves it before push. Reaching here would mean
            // someone instantiated a view controller for the routing step itself.
            fatalError("podTypeSelected is a virtual routing step and must be resolved before presentation")

        case .o5KeySetup:
            let view = O5KeySetupView(
                o5KeypairsNotAvailable: O5CertificateStore.isEmpty,
                didContinue: { [weak self] in self?.stepFinished() },
                didCancel: { [weak self] in self?.setupCanceled() }
            )
            let hostedView = hostingController(rootView: view)
            hostedView.navigationItem.title = LocalizedString("Omnipod 5 Setup", comment: "Title for the Omnipod 5 key setup screen")
            return hostedView

        case .rileyLinkSetup:
            // This step will be skipped for non-Eros pods
            let dataSource = RileyLinkListDataSource(rileyLinkPumpManager: pumpManager)
            var view = RileyLinkSetupView(
                dataSource: dataSource,
                nextAction: { [weak self] in self?.stepFinished() })
            view.cancelButtonTapped = { [weak self] in
                 self?.setupCanceled()
            }
            let controller = hostingController(rootView: view)
            controller.navigationItem.title = pumpManager.localizedTitle
            return controller

        case .deactivate:
            let viewModel = DeactivatePodViewModel(podDeactivator: pumpManager, podAttachedToBody: pumpManager.podAttachmentConfirmed, fault: pumpManager.state.podState?.fault)

            viewModel.didFinish = { [weak self] in
                self?.stepFinished()
            }
            viewModel.didCancel = { [weak self] in
                self?.setupCanceled()
            }
            let view = DeactivatePodView(viewModel: viewModel)
            let hostedView = hostingController(rootView: view)
            hostedView.navigationItem.title = LocalizedString("Deactivate Pod", comment: "Title for deactivate pod screen")
            return hostedView

        case .settings:
            let viewModel = OmniSettingsViewModel(pumpManager: pumpManager)
            viewModel.didFinish = { [weak self] in
                if self?.pumpManager.podType == unknownOmnipodType {
                    print("Resetting OmniUICoordinator podType to unknownOmnipodType")
                    self?.podType = unknownOmnipodType
                }
                self?.stepFinished()
            }
            viewModel.navigateTo = { [weak self] (screen) in
                self?.navigateTo(screen)
            }
            let rileyLinkListDataSource = RileyLinkListDataSource(rileyLinkPumpManager: pumpManager)

            let handleRileyLinkSelection = { [weak self] (device: RileyLinkDevice) in
                if let self = self {
                    let vc = RileyLinkDeviceTableViewController(
                        device: device,
                        batteryAlertLevel: self.pumpManager.rileyLinkBatteryAlertLevel,
                        batteryAlertLevelChanged: { [weak self] value in
                            self?.pumpManager.rileyLinkBatteryAlertLevel = value
                        }
                    )
                    self.show(vc, sender: self)
                }
            }

            let view = OmniSettingsView(viewModel: viewModel, rileyLinkListDataSource: rileyLinkListDataSource, handleRileyLinkSelection: handleRileyLinkSelection, supportedInsulinTypes: allowedInsulinTypes)
            let controller = hostingController(rootView: view)
            controller.navigationItem.title = pumpManager.localizedTitle
            return controller

        case .pairAndPrime:
            pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didCreatePumpManager: pumpManager)

            let viewModel = PairPodViewModel(podPairer: pumpManager)

            viewModel.didFinish = { [weak self] in
                self?.stepFinished()
            }
            viewModel.didCancelSetup = { [weak self] in
                // navigate directly to pod setting on a pair cancel to facilitate easier pod type switching
                self?.navigateTo(.settings)
            }
            viewModel.didRequestDeactivation = { [weak self] in
                self?.navigateTo(.deactivate)
            }

            let view = hostingController(rootView: PairPodView(viewModel: viewModel).onAppear(perform: {UIApplication.shared.isIdleTimerDisabled = true}), onDisappear: {UIApplication.shared.isIdleTimerDisabled = false})
            view.navigationItem.title = String(format: LocalizedString("Pair %1$@ Pod", comment: "Title for pod pairing screen (1: pod type brief name)"), self.podType.briefName)
            view.navigationItem.backButtonDisplayMode = .generic
            return view

        case .confirmAttachment:
            let view = AttachPodView(
                didConfirmAttachment: { [weak self] in
                    self?.pumpManager.podAttachmentConfirmed = true
                    self?.stepFinished()
                },
                didRequestDeactivation: { [weak self] in
                    self?.navigateTo(.deactivate)
                },
                podTabColor: pumpManager.podType.tabColor
            )

            let vc = hostingController(rootView: view.onAppear(perform: {UIApplication.shared.isIdleTimerDisabled = true}), onDisappear: {UIApplication.shared.isIdleTimerDisabled = false})
            vc.navigationItem.title = LocalizedString("Attach Pod", comment: "Title for Attach Pod screen")
            vc.navigationItem.hidesBackButton = true
            return vc

        case .insertCannula:
            let viewModel = InsertCannulaViewModel(cannulaInserter: pumpManager)

            viewModel.didFinish = { [weak self] in
                self?.stepFinished()
            }
            viewModel.didRequestDeactivation = { [weak self] in
                self?.navigateTo(.deactivate)
            }

            let view = hostingController(rootView: InsertCannulaView(viewModel: viewModel).onAppear(perform: {UIApplication.shared.isIdleTimerDisabled = true}), onDisappear: {UIApplication.shared.isIdleTimerDisabled = false})
            view.navigationItem.title = LocalizedString("Insert Cannula", comment: "Title for insert cannula screen")
            view.navigationItem.hidesBackButton = true
            return view

        case .checkInsertedCannula:
            let view = CheckInsertedCannulaView(
                didRequestDeactivation: { [weak self] in
                    self?.navigateTo(.deactivate)
                },
                wasInsertedProperly: { [weak self] in
                    self?.stepFinished()
                }
            )

            let hostedView = hostingController(rootView: view.onAppear(perform: {UIApplication.shared.isIdleTimerDisabled = true}), onDisappear: {UIApplication.shared.isIdleTimerDisabled = false})
            hostedView.navigationItem.title = LocalizedString("Check Cannula", comment: "Title for check cannula screen")
            hostedView.navigationItem.hidesBackButton = true
            return hostedView

        case .setupComplete:
            guard let podExpiresAt = pumpManager.expiresAt,
                  let allowedExpirationReminderDates = pumpManager.allowedExpirationReminderDates
            else {
                fatalError("Cannot show setup complete UI without expiration and allowed reminder dates.")
            }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short

            let view = SetupCompleteView(
                scheduledReminderDate: pumpManager.scheduledExpirationReminder,
                dateFormatter: formatter,
                allowedDates: allowedExpirationReminderDates,
                onSaveScheduledExpirationReminder: { [weak self] (newExpirationReminderDate, completion) in
                    var intervalBeforeExpiration : TimeInterval?
                    if let newExpirationReminderDate = newExpirationReminderDate {
                        intervalBeforeExpiration = podExpiresAt.timeIntervalSince(newExpirationReminderDate)
                    }
                    self?.pumpManager.updateExpirationReminder(intervalBeforeExpiration, completion: completion)
                },
                didFinish: { [weak self] in
                    self?.stepFinished()
                },
                didRequestDeactivation: { [weak self] in
                    self?.navigateTo(.deactivate)
                }
            )

            let hostedView = hostingController(rootView: view.onAppear(perform: {UIApplication.shared.isIdleTimerDisabled = true}), onDisappear: {UIApplication.shared.isIdleTimerDisabled = false})
            hostedView.navigationItem.title = LocalizedString("Setup Complete", comment: "Title for setup complete screen")
            return hostedView

        case .pendingCommandRecovery:
            guard let podState = pumpManager.state.podState, let pendingCommand = podState.unacknowledgedCommand, podState.needsCommsRecovery == true else {
                fatalError("Pending command recovery UI attempted without pending command")
            }

            let model = DeliveryUncertaintyRecoveryViewModel(appName: appName, uncertaintyStartedAt: pendingCommand.commandDate, usesRileyLink: self.pumpManager.podType.usesRileyLink)
            model.didRecover = { [weak self] in
                self?.navigateTo(.uncertaintyRecovered)
            }
            model.onDeactivate = { [weak self] in
                self?.navigateTo(.deactivate)
            }
            model.onDismiss = { [weak self] in
                // Navigate to the settings view on dismissal to allow the
                // user can work on reestablishing pod communications there.
                self?.navigateTo(.settings)
            }
            pumpManager.addStatusObserver(model, queue: DispatchQueue.main)
            pumpManager.getPodStatus() { _ in }

            let view = DeliveryUncertaintyRecoveryView(model: model)
            let hostedView = hostingController(rootView: view)
            hostedView.navigationItem.title = LocalizedString("Unable To Reach Pod", comment: "Title for pending command recovery screen")
            return hostedView

        case .uncertaintyRecovered:
            var view = UncertaintyRecoveredView(appName: appName)
            view.didFinish = { [weak self] in
                self?.stepFinished()
            }
            let hostedView = hostingController(rootView: view)
            hostedView.navigationItem.title = LocalizedString("Comms Recovered", comment: "Title for uncertainty recovered screen")
            return hostedView
        }
    }

    private func hostingController<Content: View>(rootView: Content, onDisappear: @escaping () -> Void = {}) -> DismissibleHostingController<some View> {
        let rootView = rootView
            .environment(\.appName, Bundle.main.bundleDisplayName)
        return DismissibleHostingController(content: rootView, onDisappear: onDisappear, colorPalette: colorPalette)
    }

    /// Resolves the virtual `.podTypeSelected` routing step into the concrete next
    /// screen for the currently selected pod type. Other screens pass through.
    private func resolveRoutingStep(_ screen: OmniUIScreen) -> OmniUIScreen {
        guard screen == .podTypeSelected else { return screen }
        if podType == omnipod5Type && O5CertificateStore.isEmpty {
            return .o5KeySetup
        }
        if podType.usesRileyLink {
            return .rileyLinkSetup
        }
        return .pairAndPrime
    }

    private func stepFinished() {
        if let nextStep = currentScreen.next() {
            navigateTo(nextStep)
        } else if pumpManager.podType == unknownOmnipodType {
            // User selected switch pod type at bottom of pod settings with
            // no active pod, so we need to reselect the new pod type now.
            navigateTo(.selectPodType)
        } else {
            completionDelegate?.completionNotifyingDidComplete(self)
        }
    }

    private func setupCanceled() {
        completionDelegate?.completionNotifyingDidComplete(self)
    }

    init(pumpManager: OmniPumpManager? = nil, colorPalette: LoopUIColorPalette, pumpManagerSettings: PumpManagerSetupSettings? = nil, allowDebugFeatures: Bool, allowedInsulinTypes: [InsulinType] = [])
    {

        if pumpManager == nil, let pumpManagerSettings = pumpManagerSettings {
            let basalSchedule = pumpManagerSettings.basalSchedule

            let deviceProvider = RileyLinkBluetoothDeviceProvider(autoConnectIDs: []) // only used for Eros

            let pumpManagerState = OmniPumpManagerState(
                isOnboarded: false,
                podState: nil,
                timeZone: basalSchedule.timeZone,
                basalSchedule: BasalSchedule(repeatingScheduleValues: basalSchedule.items, podType: self.podType),
                maxBasalRateUnitsPerHour: pumpManagerSettings.maxBasalRateUnitsPerHour,
                maxBolusUnits: pumpManagerSettings.maxBolusUnits,
                insulinType: nil,
                podType: self.podType)

            self.pumpManager = OmniPumpManager(state: pumpManagerState, rileyLinkDeviceProvider: deviceProvider)
        } else {
            guard let pumpManager = pumpManager else {
                fatalError("Unable to create OmnipodKit PumpManager")
            }
            self.pumpManager = pumpManager
        }

        self.colorPalette = colorPalette

        self.allowDebugFeatures = allowDebugFeatures

        self.allowedInsulinTypes = allowedInsulinTypes

        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func determineInitialStep() -> OmniUIScreen {
        self.podType = pumpManager.podType
        if pumpManager.state.podState?.needsCommsRecovery == true {
            return .pendingCommandRecovery
        } else if pumpManager.podCommState == .activating {
            if pumpManager.state.podState?.readyForCannulaInsertion == true && pumpManager.podAttachmentConfirmed {
                return .insertCannula
            } else {
                assert(self.podType != unknownOmnipodType)
                return .pairAndPrime // need to finish the priming
            }
        } else if !pumpManager.isOnboarded {
            if !pumpManager.initialConfigurationCompleted {
                return .firstRunScreen
            }
            if self.podType == unknownOmnipodType {
                return .selectPodType // need to first select a pod type
            }
            return .podTypeSelected // route to o5KeySetup / rileyLinkSetup / pairAndPrime as appropriate
        } else {
            if self.podType == unknownOmnipodType {
                return .selectPodType // need to first select a pod type
            }
            return .settings
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if screenStack.isEmpty {
            screenStack = [determineInitialStep()]
            let viewController = viewControllerForScreen(currentScreen)
            viewController.isModalInPresentation = false
            setViewControllers([viewController], animated: false)
        }
    }

    var customTraitCollection: UITraitCollection {
        // Select height reduced layouts on iPhone SE and iPod Touch,
        // and select regular width layouts on larger screens, for list rendering styles
        if UIScreen.main.bounds.height <= 640 {
            return UITraitCollection(traitsFrom: [super.traitCollection, UITraitCollection(verticalSizeClass: .compact)])
        } else {
            return UITraitCollection(traitsFrom: [super.traitCollection, UITraitCollection(horizontalSizeClass: .regular)])
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.navigationBar.prefersLargeTitles = true
        delegate = self
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        completionDelegate?.completionNotifyingDidComplete(self)
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
                
        setOverrideTraitCollection(customTraitCollection, forChild: viewController)
        
        if viewControllers.count < screenStack.count {
            // Navigation back
            let _ = screenStack.popLast()
        }
        viewController.view.backgroundColor = UIColor.secondarySystemBackground
    }

    let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as! String
}

extension OmniUICoordinator: OmniUINavigator {
    func navigateTo(_ screen: OmniUIScreen) {
        let resolved = resolveRoutingStep(screen)
        screenStack.append(resolved)
        let viewController = viewControllerForScreen(resolved)
        viewController.isModalInPresentation = false
        self.pushViewController(viewController, animated: true)
        viewController.view.layoutSubviews()
    }
}
