//
//  OSLog.swift
//  OmnipodKit
//
//  From OmniBLE/Common/OSLog.swift
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import os.log

extension OSLog {
    convenience init(category: String) {
        self.init(subsystem: "com.loopkit.OmnipodKit", category: category)
    }

    func debug(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .debug, args)
    }

    func info(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .info, args)
    }

    func `default`(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .default, args)
    }

    func error(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .error, args)
    }

    private func log(_ message: StaticString, type: OSLogType, _ args: [CVarArg]) {
        switch args.count {
        case 0:
            os_log(message, log: self, type: type)
        case 1:
            os_log(message, log: self, type: type, args[0])
        case 2:
            os_log(message, log: self, type: type, args[0], args[1])
        case 3:
            os_log(message, log: self, type: type, args[0], args[1], args[2])
        case 4:
            os_log(message, log: self, type: type, args[0], args[1], args[2], args[3])
        case 5:
            os_log(message, log: self, type: type, args[0], args[1], args[2], args[3], args[4])
        case 6:
            os_log(message, log: self, type: type, args[0], args[1], args[2], args[3], args[4], args[5])
        case 7:
            os_log(message, log: self, type: type, args[0], args[1], args[2], args[3], args[4], args[5], args[6])
        case 8:
            os_log(message, log: self, type: type, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7])
        case 9:
            os_log(message, log: self, type: type, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8])
        case 10:
            os_log(message, log: self, type: type, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9])
        default:
            assertionFailure("OSLog wrapper received unsupported argument count: \(args.count)")
            os_log("Unsupported OSLog argument count %{public}lld for message %{public}@", log: self, type: .fault, args.count, String(describing: message))
        }
    }
}
