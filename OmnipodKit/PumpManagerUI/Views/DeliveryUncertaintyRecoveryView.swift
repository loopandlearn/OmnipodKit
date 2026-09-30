//
//  DeliveryUncertaintyRecoveryView.swift
//  OmnipodKit
//
//  From Omni{BLE,Kit}/PumpManageUI/Views/DeliveryUncertaintyRecoveryView.swift
//  Created by Pete Schwamb on 8/17/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKitUI
import RileyLinkBLEKit


struct DeliveryUncertaintyRecoveryView: View {

    let model: DeliveryUncertaintyRecoveryViewModel

    init(model: DeliveryUncertaintyRecoveryViewModel) {
        self.model = model
    }

    var body: some View {
        GuidePage(content: {
            Text(String(format: LocalizedString("%1$@ has been unable to communicate with the pod on your body since %2$@.\n\nDo not Discard Pod without scrolling to read this entire screen.\n\nCommunication was interrupted at a critical time. Information about active insulin / pod temp basal rate is uncertain.\n\nYou can tap on Access Omnipod Screen to attempt pod Diagnostic commands to reconnect to the pod%3$@; or use iPhone settings to toggle phone Bluetooth off and on, and/or quit and restart the app. (Wait up to 30 seconds for recovery.)\n\nIf you decide to give up because communication cannot be restored, tap the Discard Pod button, follow the steps and start a new pod. Monitor your glucose closely for the next 6 hours, as there may or may not be insulin actively working in your body that %4$@ cannot display.", comment: "Format string for main text of delivery uncertainty recovery page. (1: app name)(2: date of command)(3: localized pod type dependent recovery actions)(4: app name)"), self.model.appName, self.uncertaintyDateLocalizedString, self.model.podTypeDependentRecoveryActions, self.model.appName))
                .padding([.top, .bottom])
        }) {
            VStack {
                Text(LocalizedString("Attemping to re-establish communication", comment: "Description string above progress indicator while attempting to re-establish communication from an unacknowledged command")).padding(.top)
                ProgressIndicatorView(state: .indeterminantProgress)
                Button(action: {
                    self.model.onDismiss?()
                }) {
                    Text(LocalizedString("Access Omnipod Screen", comment: "Button title to access Omnipod screen if waiting for recovery from uncertain comms"))
                    .actionButtonStyle(.primary)
                    .padding([.horizontal])
                }
                Button(action: {
                    self.model.podDeactivationChosen()
                }) {
                    Text(LocalizedString("Discard Pod", comment: "Button title to discard pod on uncertain program"))
                    .actionButtonStyle(.destructive)
                    .padding()
                }
            }
        }
        .navigationBarTitleDisplayMode(.large)
        .navigationBarItems(leading: backButton)
    }

    private var uncertaintyDateLocalizedString: String {
        DateFormatter.localizedString(from: model.uncertaintyStartedAt, dateStyle: .none, timeStyle: .short)
    }

    private var backButton: some View {
        Button(LocalizedString("Back", comment: "Back button text on DeliveryUncertaintyRecoveryView"), action: {
            self.model.onDismiss?()
        })
    }
}

struct DeliveryUncertaintyRecoveryView_Previews: PreviewProvider {
    static var previews: some View {
        let model = DeliveryUncertaintyRecoveryViewModel(appName: "Test App", uncertaintyStartedAt: Date(), usesRileyLink: true)
        return DeliveryUncertaintyRecoveryView(model: model)
    }
}
