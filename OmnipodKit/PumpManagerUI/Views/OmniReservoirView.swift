//
//  OmniReservoirView.swift
//  OmnipodKit
//
//  From OmniBLE/PumpManageUI/Views/OmniBLEReservoirView.swift
//  Created by Pete Schwamb on 10/22/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//

import UIKit
import LoopKitUI


final class OmniReservoirView: LevelHUDView, NibLoadable {

    override var orderPriority: HUDViewOrderPriority {
        return 11
    }

    @IBOutlet private weak var volumeLabel: UILabel!
    
    @IBOutlet private weak var alertLabel: UILabel! {
        didSet {
            alertLabel.alpha = 0
            alertLabel.textColor = UIColor.white
            alertLabel.layer.cornerRadius = 9
            alertLabel.clipsToBounds = true
        }
    }

    class func instantiate() -> OmniReservoirView {
        return nib().instantiate(withOwner: nil, options: nil)[0] as! OmniReservoirView
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        volumeLabel.isHidden = true
    }

    private var reservoirLevel: ReservoirLevel?
    private var approximateReservoirLevel: Double?
    private var lastUpdateDate: Date?
    private var reservoirLevelHighlightState = ReservoirLevelHighlightState.normal

    override func tintColorDidChange() {
        super.tintColorDidChange()
        
        alertLabel?.backgroundColor = tintColor
        volumeLabel.textColor = tintColor
        levelMaskView.tintColor = tintColor
    }

    override func updateColor() {
        switch reservoirLevelHighlightState {
        case .normal:
            tintColor = stateColors?.normal
        case .warning:
            tintColor = stateColors?.warning
        case .critical:
            tintColor = stateColors?.error
        }
    }

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short

        return formatter
    }()

    private lazy var numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0

        return formatter
    }()

    private func updateViews() {
        if let reservoirLevel = reservoirLevel, let date = lastUpdateDate {

            let time = timeFormatter.string(from: date)
            caption?.text = time

            switch reservoirLevel {
            case .aboveThreshold:
                level = nil
                if let approximateReservoirLevel = approximateReservoirLevel, let units = numberFormatter.string(from: approximateReservoirLevel) {
                    // "~" marks the volume as approximated from the fill amount
                    volumeLabel.isHidden = false
                    volumeLabel.text = String(format: LocalizedString("~%@U", comment: "Format string for approximate reservoir volume while the pod reads above its maximum reading. (1: The localized volume)"), units)
                    accessibilityValue = String(format: LocalizedString("About %1$@ units remaining at %2$@", comment: "Accessibility format string for approximate reservoir volume (1: localized volume)(2: time)"), units, time)
                } else {
                    volumeLabel.isHidden = true
                    if let units = numberFormatter.string(from: Pod.maximumReservoirReading) {
                        volumeLabel.text = String(format: LocalizedString("%@+ U", comment: "Format string for reservoir volume when above maximum reading. (1: The maximum reading)"), units)
                        accessibilityValue = String(format: LocalizedString("Greater than %1$@ units remaining at %2$@", comment: "Accessibility format string for (1: localized volume)(2: time)"), units, time)
                    }
                }
            case .valid(let value):
                level = reservoirLevel.percentage
                volumeLabel.isHidden = false

                if let units = numberFormatter.string(from: value) {
                    volumeLabel.text = String(format: LocalizedString("%@U", comment: "Format string for reservoir volume. (1: The localized volume)"), units)

                    accessibilityValue = String(format: LocalizedString("%1$@ units remaining at %2$@", comment: "Accessibility format string for (1: localized volume)(2: time)"), units, time)
                }
            }
        } else {
            level = 0
            volumeLabel.isHidden = true
        }

        var alertLabelAlpha: CGFloat = 1
        switch reservoirLevelHighlightState {
        case .normal:
            alertLabelAlpha = 0
        case .warning, .critical:
            alertLabel?.text = "!"
        }

        UIView.animate(withDuration: 0.25, animations: {
            self.alertLabel?.alpha = alertLabelAlpha
        })
    }
    
    func update(level: ReservoirLevel?, approximateLevel: Double? = nil, at date: Date, reservoirLevelHighlightState: ReservoirLevelHighlightState) {
        self.reservoirLevel = level
        self.approximateReservoirLevel = approximateLevel
        self.lastUpdateDate = date
        self.reservoirLevelHighlightState = reservoirLevelHighlightState
        updateViews()
    }
}
