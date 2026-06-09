//
//  DashKeyExchange.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/Pair/KeyExchange.swift
//  Created by Randall Knutson on 8/3/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation
import CryptoSwift

class DashKeyExchange {
    static let CMAC_SIZE = 16

    static let PUBLIC_KEY_SIZE = 32
    static let NONCE_SIZE = 16

    private let INTERMEDIARY_KEY_MAGIC_STRING = "TWIt".data(using: .utf8)
    private let PDM_CONF_MAGIC_PREFIX = "KC_2_U".data(using: .utf8)
    private let POD_CONF_MAGIC_PREFIX = "KC_2_V".data(using: .utf8)

    let pdmNonce: Data
    let pdmPrivate: Data
    let pdmPublic: Data
    var podPublic: Data
    var podNonce: Data
    var podConf: Data
    var pdmConf: Data
    var ltk: Data
    
    private let keyGenerator: PrivateKeyGenerator
    let randomByteGenerator: RandomByteGenerator
    
    init(_ keyGenerator: PrivateKeyGenerator, _ randomByteGenerator: RandomByteGenerator) throws {
        self.keyGenerator = keyGenerator
        self.randomByteGenerator = randomByteGenerator
        
        pdmNonce = randomByteGenerator.nextBytes(length: DashKeyExchange.NONCE_SIZE)
        pdmPrivate = keyGenerator.generatePrivateKey()
        pdmPublic = try keyGenerator.publicFromPrivate(pdmPrivate)
    
        podPublic = Data(capacity: DashKeyExchange.PUBLIC_KEY_SIZE)
        podNonce = Data(capacity: DashKeyExchange.NONCE_SIZE)
    
        podConf = Data(capacity: DashKeyExchange.CMAC_SIZE)
        pdmConf = Data(capacity: DashKeyExchange.CMAC_SIZE)
    
        ltk = Data(capacity: DashKeyExchange.CMAC_SIZE)
    }

    func updatePodPublicData(_ payload: Data) throws {
        if (payload.count != DashKeyExchange.PUBLIC_KEY_SIZE + DashKeyExchange.NONCE_SIZE) {
            throw PodProtocolError.messageIOException("Invalid payload size")
        }
        podPublic = payload.subdata(in: 0..<DashKeyExchange.PUBLIC_KEY_SIZE)
        podNonce = payload.subdata(in: DashKeyExchange.PUBLIC_KEY_SIZE..<DashKeyExchange.PUBLIC_KEY_SIZE + DashKeyExchange.NONCE_SIZE)
        try generateKeys()
    }

    func validatePodConf(_ payload: Data) throws {
        if (podConf != payload) {
            throw PodProtocolError.messageIOException("Invalid podConf value received")
        }
    }

    private func generateKeys() throws  {
        let curveLTK = try keyGenerator.computeSharedSecret(pdmPrivate, podPublic)

        let firstKey = podPublic.subdata(in: podPublic.count - 4..<podPublic.count) +
            pdmPublic.subdata(in: pdmPublic.count - 4..<pdmPublic.count) +
            podNonce.subdata(in: podNonce.count - 4..<podNonce.count) +
            pdmNonce.subdata(in: pdmNonce.count - 4..<pdmNonce.count)

        let intermediateKey = try aesCmac(firstKey, curveLTK)

        let ltkData = Data([0x02]) +
            INTERMEDIARY_KEY_MAGIC_STRING! +
            podNonce +
            pdmNonce +
            Data([0x00, 0x01])
        
        ltk = try aesCmac(intermediateKey, ltkData)

        let confData = Data([0x01]) +
            INTERMEDIARY_KEY_MAGIC_STRING! +
            podNonce +
            pdmNonce +
            Data([0x00, 0x01])
        let confKey = try aesCmac(intermediateKey, confData)

        let pdmConfData = PDM_CONF_MAGIC_PREFIX! +
            pdmNonce +
            podNonce
        pdmConf = try aesCmac(confKey, pdmConfData)

        let podConfData = POD_CONF_MAGIC_PREFIX! +
            podNonce +
            pdmNonce
        podConf = try aesCmac(confKey, podConfData)
    }
    
    private func aesCmac(_ key: Data, _ data: Data) throws -> Data {
        let mac = try CMAC(key: key.byteArray)
        return try Data(mac.authenticate(data.byteArray))
    }
}
