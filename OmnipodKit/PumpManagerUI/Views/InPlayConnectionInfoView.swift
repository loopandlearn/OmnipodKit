//
//  InPlayConnectionInfoView.swift
//  OmnipodKit
//
//  Detail screen behind the persistent "slow connections expected" notice shown in pod
//  settings when an InPlay-variant DASH pod is paired with an affected iPhone model
//  (iPhone 16 family or iPhone 17e). See BluetoothManager's eager-connect watchdog.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import UIKit
import LoopKitUI

struct InPlayConnectionInfoView: View {

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .imageScale(.large)
                        Text(LocalizedString("Slower Connections Expected", comment: "Title on InPlay connection info view"))
                            .font(.headline)
                    }
                    Text(String(format: LocalizedString("Your pod uses an “InPlay” Bluetooth radio, and your phone (%1$@) is a model known to trigger a bug in that radio’s firmware. When it happens, the Bluetooth connection silently stalls while being established.", comment: "InPlay connection info: what is happening (1: iPhone model name)"), UIDevice.modelName))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
            }

            Section(header: SectionHeader(label: LocalizedString("What to Expect", comment: "Section header on InPlay connection info view"))) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(LocalizedString("Connecting to the pod may sometimes take noticeably longer than usual — occasionally up to 30 seconds — while stalled attempts are detected and retried automatically. Commands still complete once the connection is made.", comment: "InPlay connection info: what to expect body 1"))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LocalizedString("Pairing a new pod may also need extra time or an additional attempt.", comment: "InPlay connection info: what to expect body 2"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section(header: SectionHeader(label: LocalizedString("Pump Heartbeat", comment: "Section header on InPlay connection info view"))) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(LocalizedString("The usual method for the pod to wake the app on a timer can't be used on this combination. Instead, the app is woken when the pod's connection drops, and reconnects right away.", comment: "InPlay connection info: heartbeat body 1"))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LocalizedString("These wake-ups are less regular than usual — roughly every few minutes. If your CGM delivers readings to the app, it provides the wake-ups instead and looping continues normally.", comment: "InPlay connection info: heartbeat body 2"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section(header: SectionHeader(label: LocalizedString("What You Can Do", comment: "Section header on InPlay connection info view"))) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(LocalizedString("No action is needed — this is not a pod fault, and insulin delivery is not affected. The pod continues its programmed delivery even while disconnected.", comment: "InPlay connection info: guidance body 1"))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LocalizedString("Keeping your phone near the pod helps connections complete faster. Not every pod uses this radio — a future pod may connect normally.", comment: "InPlay connection info: guidance body 2"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
        .insetGroupedListStyle()
        .navigationBarTitle(LocalizedString("Pod Connections", comment: "Navigation bar title for InPlay connection info view"), displayMode: .inline)
    }
}

struct InPlayConnectionInfoView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            InPlayConnectionInfoView()
        }
    }
}
