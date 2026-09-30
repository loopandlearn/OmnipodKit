//
//  ExpirationReminderSetupView.swift
//  OmnipodKit
//
//  From OmniBLE/PumpManageUI/Views/ExpirationReminderSetupView.swift
//  Created by Pete Schwamb on 5/17/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKitUI


struct ExpirationReminderSetupView: View {
    @State var expirationReminderDefault: Int = 2
    
    var valueChanged: ((_ value: Int) -> Void)?
    var continueButtonTapped: (() -> Void)?
    var cancelButtonTapped: (() -> Void)?

    var body: some View {
        GuidePage(content: {
            VStack(alignment: .leading, spacing: 15) {
                Text(LocalizedString("You will be notified in advance of Pod expiration.\n\nScroll to set the number of hours advance notice you would like to have.", comment: "Description text on ExpirationReminderSetupView")).fixedSize(horizontal: false, vertical: true)
                Divider()
                ExpirationReminderPickerView(expirationReminderDefault: $expirationReminderDefault, collapsible: false, showingHourPicker: true)
                    .onChange(of: expirationReminderDefault) { value in
                        valueChanged?(value)
                    }
            }
            .padding(.vertical, 8)
        }) {
            VStack {
                Button(action: {
                    continueButtonTapped?()
                }) {
                    Text(LocalizedString("Next", comment: "Text of continue button on ExpirationReminderSetupView"))
                        .actionButtonStyle(.primary)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.automatic)
        .navigationBarHidden(false)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(LocalizedString("Cancel", comment: "Cancel button title"), action: {
                    cancelButtonTapped?()
                })
            }
        }
    }
}

struct ExpirationReminderSetupView_Previews: PreviewProvider {
    static var previews: some View {
        ExpirationReminderSetupView()
    }
}
