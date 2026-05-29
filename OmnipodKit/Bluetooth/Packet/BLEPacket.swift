//
//  BLEPacket.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/Packet/BLEPacket.swift
//  Created by Randall Knutson on 8/11/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation

protocol BlePacket {
    var payload: Data { get }

    func toData(layout: BlePacketLayout) -> Data
}


struct FirstBlePacket: BlePacket {
    let fullFragments: Int
    let payload: Data
    var size: UInt8?
    var crc32: Data?
    var oneExtraPacket: Bool = false

    func toData(layout: BlePacketLayout) -> Data {
        var bb = Data(capacity: layout.maxPayloadSize)
        bb.append(UInt8(0)) // index
        bb.append(UInt8(fullFragments)) // # of fragments except FirstBlePacket and LastOptionalPlusOneBlePacket

        if let crc32 = crc32 {
            bb.append(crc32)
        }
        if let size = size {
            bb.append(UInt8(size))
        }
        bb.append(payload)

        return bb;
    }
    
    static func parse(payload: Data, layout: BlePacketLayout) throws -> FirstBlePacket {
        guard payload.count >= layout.firstPacketHeaderSizeWithMiddlePackets else {
            throw PodProtocolError.messageIOException("Wrong packet size")
        }

        if (Int(payload[0]) != 0) {
            // most likely we lost the first packet.
            throw PodProtocolError.incorrectPacketException(payload, 0)
        }

        let fullFragments = Int(payload[1])
        guard (fullFragments <= layout.maxFragments) else {
            throw PodProtocolError.messageIOException(String(format: "Received more than %lld fragments", layout.maxFragments))
        }

        guard payload.count >= layout.firstPacketHeaderSizeWithoutMiddlePackets else {
            throw PodProtocolError.messageIOException("Wrong packet size")
        }

        if (fullFragments == 0) {
            let rest = payload[6]
            let end = min(Int(rest) + layout.firstPacketHeaderSizeWithoutMiddlePackets, payload.count)
            guard payload.count >= end else {
                throw PodProtocolError.messageIOException("Wrong packet size")
            }

            return FirstBlePacket(
                fullFragments: fullFragments,
                payload: payload.subdata(in: layout.firstPacketHeaderSizeWithoutMiddlePackets..<end),
                size:  rest,
                crc32: payload.subdata(in: 2..<6),
                oneExtraPacket:  Int(rest) + layout.firstPacketHeaderSizeWithoutMiddlePackets > end
            )
        } else if (payload.count < layout.maxPayloadSize) {
            throw PodProtocolError.incorrectPacketException(payload, 0)
        }
        return FirstBlePacket(
            fullFragments: fullFragments,
            payload: payload.subdata(in: layout.firstPacketHeaderSizeWithMiddlePackets..<layout.maxPayloadSize)
        )
    }
}

struct MiddleBlePacket: BlePacket {
    let index: UInt8
    let payload: Data
        
    func toData(layout: BlePacketLayout) -> Data {
        return Data([index]) + payload
    }
    
    static func parse(payload: Data, layout: BlePacketLayout) throws -> MiddleBlePacket {
        guard payload.count >= layout.maxPayloadSize else { throw PodProtocolError.messageIOException("Wrong packet size") }
        return MiddleBlePacket(
            index: payload[0],
            payload: payload.subdata(in: 1..<layout.maxPayloadSize)
        )
    }
}

struct LastBlePacket: BlePacket {
    let index: UInt8
    let size: UInt8
    let payload: Data
    let crc32: Data
    var oneExtraPacket: Bool = false

    func toData(layout: BlePacketLayout) -> Data {
        var bb = Data(capacity: layout.maxPayloadSize)
        bb.append(index)
        bb.append(size)
        bb.append(crc32)
        bb.append(payload)
        bb.append(Data(count: layout.maxPayloadSize - payload.count - layout.lastPacketHeaderSize))
        return bb
    }
    
    static func parse(payload: Data, layout: BlePacketLayout) throws -> LastBlePacket {
        guard payload.count >= layout.lastPacketHeaderSize else { throw PodProtocolError.messageIOException("Wrong packet size") }

        let rest = payload[1]
        let end = min(Int(rest) + layout.lastPacketHeaderSize, payload.count)

        guard payload.count >= end else { throw PodProtocolError.messageIOException("Wrong packet size") }

        return LastBlePacket(
            index: payload[0],
            size: rest,
            payload: payload.subdata(in: layout.lastPacketHeaderSize..<end),
            crc32: payload.subdata(in: 2..<6),
            oneExtraPacket: Int(rest) + layout.lastPacketHeaderSize > end
        )
    }
}

struct LastOptionalPlusOneBlePacket: BlePacket {
    static let HEADER_SIZE = 2
    let index: UInt8
    let payload: Data
    let size: UInt8

    func toData(layout: BlePacketLayout) -> Data {
        return Data([index, size]) + payload + Data(count: layout.maxPayloadSize - payload.count - 2)
    }

    static func parse(payload: Data, layout: BlePacketLayout) throws -> LastOptionalPlusOneBlePacket {
        guard payload.count >= 2 else { throw PodProtocolError.messageIOException("Wrong packet size") }
        let size = payload[1]
        guard payload.count >= HEADER_SIZE + Int(size) else { throw PodProtocolError.messageIOException("Wrong packet size") }

        return LastOptionalPlusOneBlePacket(
            index: payload[0],
            payload: payload.subdata(in: HEADER_SIZE..<HEADER_SIZE + Int(size)),
            size: size
        )
    }
}
