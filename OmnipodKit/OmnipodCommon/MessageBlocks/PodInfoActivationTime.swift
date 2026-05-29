//
//  PodInfoActivationTime.swift
//  OmnipodKit
//
//  From OmniBLE/OmnipodCommon/MessageBlocks/PodInfoResponseSubType.swift
//  Created by Eelke Jager on 25/09/2018.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//

import Foundation

// Type 5 PodInfo returns the pod activation time and possible fault code & fault time
struct PodInfoActivationTime : PodInfo {
    // OFF 1  2  3  4 5  6 7 8 9 10111213 1415161718
    // DATA   0  1  2 3  4 5 6 7 8 9 1011 1213141516
    // 02 11 05 PP QQQQ 00000000 00000000 MMDDYYHHMM

    let podInfoType: PodInfoResponseSubType = .activationTime
    let faultEventCode: FaultEventCode
    let faultTime: TimeInterval
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let data: Data

    init(encodedData: Data) throws {
        guard encodedData.count >= 16 else {
            throw MessageBlockError.notEnoughData
        }
        self.faultEventCode = FaultEventCode(rawValue: encodedData[1])
        self.faultTime = TimeInterval(minutes: Double((Int(encodedData[2]) << 8) + Int(encodedData[3])))
        self.year   = Int(encodedData[14])
        self.month  = Int(encodedData[12])
        self.day    = Int(encodedData[13])
        self.hour   = Int(encodedData[15])
        self.minute = Int(encodedData[16])
        self.data   = Data(encodedData)
    }
}

func activationTimeString(podInfoActivationTime: PodInfoActivationTime) -> String {
    var result: [String] = []

    // activation time info
    result.append(String(format: "Year:   %lld", podInfoActivationTime.year))
    result.append(String(format: "Month:  %lld", podInfoActivationTime.month))
    result.append(String(format: "Day:    %lld", podInfoActivationTime.day))
    result.append(String(format: "Hour:   %lld", podInfoActivationTime.hour))
    result.append(String(format: "Minute: %lld", podInfoActivationTime.minute))

    // pod fault info
    result.append(String(format: "\nFault Time: %@", podInfoActivationTime.faultTime.timeIntervalStr))
    result.append(String(describing: podInfoActivationTime.faultEventCode))

    return result.joined(separator: "\n")
}
