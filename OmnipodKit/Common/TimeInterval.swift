//
//  TimeInterval.swift
//  OmnipodKit
//
//  From OmniBLE/Common/TimeInterval.swift
//  Created by Nathan Racklyeft on 1/9/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation

extension TimeInterval {

    static func days(_ days: Double) -> TimeInterval {
        return self.init(days: days)
    }

    static func hours(_ hours: Double) -> TimeInterval {
        return self.init(hours: hours)
    }

    static func minutes(_ minutes: Int) -> TimeInterval {
        return self.init(minutes: Double(minutes))
    }

    static func minutes(_ minutes: Double) -> TimeInterval {
        return self.init(minutes: minutes)
    }

    static func seconds(_ seconds: Double) -> TimeInterval {
        return self.init(seconds)
    }

    static func milliseconds(_ milliseconds: Double) -> TimeInterval {
        return self.init(milliseconds / 1000)
    }

    init(days: Double) {
        self.init(hours: days * 24)
    }

    init(hours: Double) {
        self.init(minutes: hours * 60)
    }

    init(minutes: Double) {
        self.init(minutes * 60)
    }

    init(seconds: Double) {
        self.init(seconds)
    }

    init(milliseconds: Double) {
        self.init(milliseconds / 1000)
    }

    var milliseconds: Double {
        return self * 1000
    }

    init(hundredthsOfMilliseconds: Double) {
        self.init(hundredthsOfMilliseconds / 100000)
    }

    var hundredthsOfMilliseconds: Double {
        return self * 100000
    }

    var minutes: Double {
        return self / 60.0
    }

    var hours: Double {
        return minutes / 60.0
    }

    var days: Double {
        return hours / 24.0
    }

    var timeIntervalStr: String {
        var str: String = ""
        let ihours = UInt(self / 3600)
        let iminutes = UInt(self / 60) % 60
        let iseconds = UInt(self) % 60
        if ihours != 0 {
            str += String(format: "%lluh", ihours)
        }
        if iminutes != 0 {
            str += String(format: "%llum", iminutes)
        }
        if iseconds != 0 || str.isEmpty {
            str += String(format: "%llus", iseconds)
        }
        return str
    }
}
