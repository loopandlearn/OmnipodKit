//
//  EapSqn.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/Session/EapSqn.swift
//  Created by Randall Knutson on 11/17/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation

enum EapSqnError: Error {
    case InvalidSize
    case OutOfRange
}

class EapSqn {
    private let SIZE = 6
    let data: Data
    
    init(data: Data)  throws {
        guard data.count == SIZE else { throw EapSqnError.InvalidSize }
        self.data = data
    }
    
    init(int: Int) {
        self.data = Data(bigEndian: Int64(int)).subdata(in: 2..<8)
    }

    func toInt() throws -> Int {
        let value = (Data([0x00, 0x00]) + data).withUnsafeBytes {
            $0.loadUnaligned(as: Int64.self).bigEndian
        }
        guard let int = Int(exactly: value) else { throw EapSqnError.OutOfRange }
        return int
    }
    
    func increment() throws -> EapSqn {
        return EapSqn(int: try toInt() + 1)
    }
}
