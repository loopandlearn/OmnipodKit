//
//  EnDecrypt.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/EnDecrypt/EnDecrypt.swift
//  Created by Randall Knutson on 11/4/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation
import CryptoSwift
import os.log

class EnDecrypt {
    private let MAC_SIZE = 8
    private let log = OSLog(category: "EnDecrypt")
    private let nonce: Nonce
    private let ck: Data

    init(nonce: Nonce, ck: Data) {
        self.nonce = nonce
        self.ck = ck
    }

    func decrypt(_ msg: MessagePacket, _ nonceSeq: Int) throws -> MessagePacket {
        let payload = msg.payload
        let header = msg.asData(forEncryption: false).subdata(in: 0..<16)

        let n = nonce.toData(sqn: nonceSeq, podReceiving: false)
        let ccm = CCM(iv: Array(n), tagLength: MAC_SIZE, messageLength: payload.count - MAC_SIZE, additionalAuthenticatedData: Array(header))
        let aes = try AES(key: Array(ck), blockMode: ccm, padding: .noPadding)
        let decryptedPayload = try aes.decrypt(Array(payload))
        
        var msgCopy = msg
        msgCopy.payload = Data(decryptedPayload)
        return msgCopy
    }

    func encrypt(_ headerMessage: MessagePacket, _ nonceSeq: Int) throws -> MessagePacket {
        let payload = headerMessage.payload
        let header = headerMessage.asData(forEncryption: true).subdata(in: 0..<16)

        let n = nonce.toData(sqn: nonceSeq, podReceiving: true)
        let ccm = CCM(iv: Array(n), tagLength: MAC_SIZE, messageLength: payload.count, additionalAuthenticatedData: Array(header))
        let aes = try AES(key: Array(ck), blockMode: ccm, padding: .noPadding)
        let encryptedPayload = try aes.encrypt(Array(payload))

        var msgCopy = headerMessage
        msgCopy.payload = Data(encryptedPayload)
        return msgCopy
    }
}
