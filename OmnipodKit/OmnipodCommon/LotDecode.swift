//  OmnipodKit
//
//  Created by Joe Moran on 2/24/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.

import Foundation

// Constants
let ProductCode: [UInt32: String] = [
    0x04: "D1", // 'D'ash (gen 4) U100
    0x18: "D2", // 'D'ash (gen 4) U200
    0x36: "D5", // 'D'ash (gen 4) U500

    0x07: "H1", // 'H'orizon (Omnipod 5) U100
    0x1B: "H2", // 'H'orizon (Omnipod 5) U200
    0x39: "H5", // 'H'orizon (Omnipod 5) U500

    0x02: "E1", // 'E' pod (Omnipod 6?) U100
    0x16: "E2", // 'E' pod (Omnipod 6?) U200
    0x34: "E5", // 'E' pod (Omnipod 6?) U500

    0x05: "P1", // 'P're-production? U100
    0x19: "P2", // 'P're-production? U200
    0x37: "P5", // 'P're-production? U500

    0x03: "A0",
    0x09: "R1",
]

let MfgLoc: [Int: String] = [
    0: "C", // China
    1: "U", // USA
    2: "K", // Kunshan (China)
    6: "M", // Malaysia
]

struct LotDecode {
    let lot: UInt32
    let lotHex: String
    let prefix: String
    let productNum: Int
    let productCode: String
    let locationNum: Int
    let locationCode: String
    let dateMMDD: String
    let dateYY: Int
    let line: Int
    let batch: String
    let readableText: String
}

/// Returns the decoded lot information for a modern Insulet 32-bit lot #.
/// This function does not work for the older (Eros and before) lot #s.
func lotDecode(lot: UInt32) -> LotDecode {
    let prefix = (lot & 0x80000000) == 0 ? "P" : "E"

    let productNum = Int((lot >> 25) & mask(6))
    let productCode = ProductCode[UInt32(productNum)] ?? "XX"

    let locationNum = Int((lot >> 22) & mask(3))
    let locationCode = MfgLoc[locationNum] ?? "X"

    let dayNumber = Int((lot >> 7) & mask(15))
    let dateYY = dayNumber >> 9
    let dayOfYear = dayNumber - (dateYY << 9)

    let dateMMDD: String
    if dayOfYear > 0 {
        let date = Calendar.current.date(from: DateComponents(year: Int(dateYY + 2000), month: 1, day: 1))!.addingTimeInterval(TimeInterval((dayOfYear - 1) * (60*60*24)))
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd"
        dateMMDD = formatter.string(from: date)
    } else {
        dateMMDD = "0000"    }

    let line = Int((lot >> 4) & mask(3))
    let batch = String(format: "%llX", lot & mask(4))

    let readableText = "\(prefix)\(productCode)\(locationCode)\(dateMMDD)\(dateYY)\(line)\(batch)"

    return LotDecode(
        lot: lot,
        lotHex: String(format: "0x%08llX", lot),
        prefix: prefix,
        productNum: productNum,
        productCode: productCode,
        locationNum: locationNum,
        locationCode: locationCode,
        dateMMDD: dateMMDD,
        dateYY: dateYY,
        line: line,
        batch: batch,
        readableText: readableText
    )
}

private func mask(_ n: Int) -> UInt32 {
    return (1 << n) - 1
}
