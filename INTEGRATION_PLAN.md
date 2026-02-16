# O5 Activation Ordering Integration Test Plan

## Objective

Create integration tests that verify the O5 (Omnipod 5) activation command sequence is sent in the correct order. Bugs in command ordering have caused real pod failures during activation, so these tests serve as a regression safety net.

## Test File

- Path: `/Users/james/repos/OmnipodKit/OmniTests/O5ActivationOrderingTests.swift`
- Target: `OmniTests`
- Framework: `XCTest` with `@testable import OmnipodKit`

## Prerequisites: Production Code Changes

Before the test file can be written, several small refactors are needed to make the activation flow testable. The core problem is that `BlePodComms` and `PodCommsSession` use concrete `BlePodMessageTransport` references for O5-specific methods (`sendO5AidCommand` and `sendO5SignedMessage`), which cannot be mocked without a protocol extraction.

### Change 1: Define `O5Transport` Protocol

**File**: `/Users/james/repos/OmnipodKit/OmnipodKit/PumpManager/MessageTransport.swift`

Add the following protocol after the existing `MessageTransport` protocol (line 40):

```swift
/// Protocol for O5-specific transport operations.
/// Extends MessageTransport with O5 AID command and signed message methods.
protocol O5Transport: MessageTransport {
    func sendO5AidCommand(_ wrappedPayload: Data, responsePrefix: String) throws -> Data
    func sendO5SignedMessage(_ message: Message, certStore: O5CertificateStore) throws -> Message
}
```

### Change 2: Conform `BlePodMessageTransport` to `O5Transport`

**File**: `/Users/james/repos/OmnipodKit/OmnipodKit/Bluetooth/BleMessageTransport.swift`

Change line 90 from:

```swift
class BlePodMessageTransport: MessageTransport {
```

to:

```swift
class BlePodMessageTransport: O5Transport {
```

No other changes needed -- `BlePodMessageTransport` already implements both `sendO5AidCommand(_:responsePrefix:)` (line 528) and `sendO5SignedMessage(_:certStore:)` (line 607).

### Change 3: Update `PodCommsSession.o5Send()` to use `O5Transport`

**File**: `/Users/james/repos/OmnipodKit/OmnipodKit/PumpManager/PodCommsSession.swift`

At line 441, change:

```swift
guard let bleTransport = transport as? BlePodMessageTransport else {
    log.error("o5Send: Transport is not BlePodMessageTransport, cannot send signed message")
    throw PodCommsError.diagnosticMessage(str: "O5 signed messages require BLE transport")
}
```

to:

```swift
guard let o5Transport = transport as? O5Transport else {
    log.error("o5Send: Transport does not conform to O5Transport, cannot send signed message")
    throw PodCommsError.diagnosticMessage(str: "O5 signed messages require O5Transport")
}
```

And at line 458, change:

```swift
let response = try bleTransport.sendO5SignedMessage(message, certStore: certStore)
```

to:

```swift
let response = try o5Transport.sendO5SignedMessage(message, certStore: certStore)
```

### Change 4: Update `BlePodComms.o5SendAidSetupCommands()` Accessibility and Parameter Type

**File**: `/Users/james/repos/OmnipodKit/OmnipodKit/Bluetooth/BlePodComms.swift`

At line 365, change from `private` to `internal` (remove `private` keyword) and widen the parameter type:

```swift
// Before:
private func o5SendAidSetupCommands(transport: BlePodMessageTransport) throws {

// After:
func o5SendAidSetupCommands(transport: O5Transport) throws {
```

This allows `@testable import OmnipodKit` to access the method for testing, and allows passing a mock `O5Transport`.

**Important**: The call site at line 345 passes a `BlePodMessageTransport`, which already conforms to `O5Transport` after Change 2, so no call-site changes are needed.

### Summary of Production Code Changes

| File | Line(s) | Change |
|------|---------|--------|
| `MessageTransport.swift` | After line 40 | Add `O5Transport` protocol definition |
| `BleMessageTransport.swift` | Line 90 | Change class declaration to `: O5Transport` |
| `PodCommsSession.swift` | Lines 441, 458 | Cast to `O5Transport` instead of `BlePodMessageTransport` |
| `BlePodComms.swift` | Line 365 | Remove `private`, change param type to `O5Transport` |

Total: approximately 10 lines changed across 4 files.

## Mock Implementation

### `MockO5Transport`

This mock captures all commands in order, distinguishing between standard `sendMessage()`, O5 AID `sendO5AidCommand()`, and signed `sendO5SignedMessage()` calls.

```swift
import Foundation
@testable import OmnipodKit

/// Records the type and identity of each command sent through the transport.
class MockO5Transport: O5Transport {

    // MARK: - Command Recording

    /// Discriminated union of all command types that can be sent.
    enum RecordedCommand: CustomStringConvertible {
        /// Standard encrypted command via sendMessage(). Records the MessageBlockType(s).
        case standard(blockTypes: [MessageBlockType])
        /// O5 AID command via sendO5AidCommand(). Records the ASCII prefix (e.g., "SE255.2=").
        case aidCommand(prefix: String)
        /// O5 signed command via sendO5SignedMessage(). Records the MessageBlockType(s).
        case signedMessage(blockTypes: [MessageBlockType])

        var description: String {
            switch self {
            case .standard(let types):
                return "standard(\(types))"
            case .aidCommand(let prefix):
                return "aidCommand(\(prefix))"
            case .signedMessage(let types):
                return "signedMessage(\(types))"
            }
        }
    }

    /// All commands recorded in the order they were sent.
    var recordedCommands: [RecordedCommand] = []

    // MARK: - Pre-configured Responses

    /// Responses for sendMessage() calls, consumed in order.
    var standardResponses: [MessageBlock] = []
    private var standardResponseIndex = 0

    /// Responses for sendO5AidCommand() calls, consumed in order.
    var aidResponses: [Data] = []
    private var aidResponseIndex = 0

    /// Responses for sendO5SignedMessage() calls, consumed in order.
    var signedResponses: [MessageBlock] = []
    private var signedResponseIndex = 0

    // MARK: - MessageTransport Conformance

    var messageNumber: Int = 0
    weak var delegate: MessageTransportDelegate?

    private let responseAddress: UInt32

    init(responseAddress: UInt32 = 0xffffffff) {
        self.responseAddress = responseAddress
    }

    func sendMessage(_ message: Message) throws -> Message {
        let blockTypes = message.messageBlocks.map { $0.blockType }
        recordedCommands.append(.standard(blockTypes: blockTypes))

        guard standardResponseIndex < standardResponses.count else {
            throw PodCommsError.noResponse
        }
        let response = standardResponses[standardResponseIndex]
        standardResponseIndex += 1
        return Message(
            address: responseAddress,
            messageBlocks: [response],
            sequenceNum: message.sequenceNum
        )
    }

    func assertOnSessionQueue() {
        // No-op in tests
    }

    // MARK: - O5Transport Conformance

    func sendO5AidCommand(_ wrappedPayload: Data, responsePrefix: String) throws -> Data {
        // Extract the command prefix from the payload ASCII text.
        // Payloads look like "SE255.2=1771222561" or "S3.2=0003000E00,G3.2" or "G3.12".
        let payloadStr = String(data: wrappedPayload, encoding: .utf8) ?? ""
        let prefix: String
        if payloadStr.hasPrefix("SE") {
            // Extended SET: prefix is everything up to and including "="
            if let eqIdx = payloadStr.firstIndex(of: "=") {
                prefix = String(payloadStr[...eqIdx])
            } else {
                prefix = payloadStr
            }
        } else if payloadStr.hasPrefix("S") {
            // SET+GET: prefix is everything up to and including "="
            if let eqIdx = payloadStr.firstIndex(of: "=") {
                prefix = String(payloadStr[...eqIdx])
            } else {
                prefix = payloadStr
            }
        } else if payloadStr.hasPrefix("G") {
            // GET-only: the whole payload is the prefix (no "=")
            prefix = payloadStr
        } else {
            prefix = payloadStr
        }

        recordedCommands.append(.aidCommand(prefix: prefix))

        guard aidResponseIndex < aidResponses.count else {
            throw PodCommsError.noResponse
        }
        let response = aidResponses[aidResponseIndex]
        aidResponseIndex += 1
        return response
    }

    func sendO5SignedMessage(_ message: Message, certStore: O5CertificateStore) throws -> Message {
        let blockTypes = message.messageBlocks.map { $0.blockType }
        recordedCommands.append(.signedMessage(blockTypes: blockTypes))

        guard signedResponseIndex < signedResponses.count else {
            throw PodCommsError.noResponse
        }
        let response = signedResponses[signedResponseIndex]
        signedResponseIndex += 1
        return Message(
            address: responseAddress,
            messageBlocks: [response],
            sequenceNum: message.sequenceNum
        )
    }
}
```

### Key Design Decisions

1. **Prefix extraction logic**: The mock parses the ASCII payload to extract the command prefix. For SET+GET commands (`"S3.2=0003000E00,G3.2"`), it extracts `"S3.2="`. For Extended SET (`"SE255.2=1771222561"`), it extracts `"SE255.2="`. For GET-only (`"G3.12"`), it extracts the full string `"G3.12"`.

2. **Response address**: Defaults to `0xffffffff` (the address used before setPodUid). Tests that verify post-setPodUid behavior should set this to the assigned pod address.

3. **No `O5CertificateStore` needed for mock**: The mock's `sendO5SignedMessage` accepts the cert store parameter but does not use it, avoiding the need to construct real crypto objects in tests.

## Test Cases

### Test Group 1: AID Command Payload Format (Unit Tests, No Mocking Needed)

These tests verify the static payload constructors in `O5AidCommands` produce correctly formatted ASCII data. They require no mocking or protocol changes.

**Source file to read**: `/Users/james/repos/OmnipodKit/OmnipodKit/Bluetooth/O5AidCommands.swift`

#### Test 1.1: `testUtcCommandPayload`

```swift
func testUtcCommandPayload() {
    let (data, prefix) = O5AidCommands.UtcCommand.payload(timestamp: 1771222561)
    let str = String(data: data, encoding: .utf8)!
    XCTAssertEqual(str, "SE255.2=1771222561")
    XCTAssertEqual(prefix, "ES255.2=")
}
```

Verifies:
- Extended SET format: `SE[feature].[attr]=[data]`
- Response prefix uses `ES` (Extended SET response)
- Timestamp is rendered as decimal ASCII

#### Test 1.2: `testUtcCommandUsesCurrentTimeByDefault`

```swift
func testUtcCommandUsesCurrentTimeByDefault() {
    let before = UInt64(Date().timeIntervalSince1970)
    let (data, _) = O5AidCommands.UtcCommand.payload()
    let after = UInt64(Date().timeIntervalSince1970)
    let str = String(data: data, encoding: .utf8)!
    XCTAssertTrue(str.hasPrefix("SE255.2="))
    let timestampStr = String(str.dropFirst("SE255.2=".count))
    let ts = UInt64(timestampStr)!
    XCTAssertGreaterThanOrEqual(ts, before)
    XCTAssertLessThanOrEqual(ts, after)
}
```

#### Test 1.3: `testTdiCommandPayload`

```swift
func testTdiCommandPayload() {
    let (data, prefix) = O5AidCommands.TdiCommand.payload()
    let str = String(data: data, encoding: .utf8)!
    XCTAssertEqual(str, "S3.2=0003000E00,G3.2")
    XCTAssertEqual(prefix, "3.2=")
}
```

Verifies:
- SET+GET format: `S[f].[a]=[data],G[f].[a]`
- Default TDI data is `"0003000E00"`
- Response prefix is `"3.2="` (no `S` prefix in response)

#### Test 1.4: `testTargetBgProfilePayload`

```swift
func testTargetBgProfilePayload() {
    let (data, prefix) = O5AidCommands.TargetBgProfileCommand.payload()
    let str = String(data: data, encoding: .utf8)!
    XCTAssertTrue(str.hasPrefix("S3.1=00C0"))
    XCTAssertTrue(str.hasSuffix(",G3.1"))
    XCTAssertEqual(prefix, "3.1=")
    // 48 targets at 110 mg/dL (0x0000006E) = "0000006E" repeated 48 times
    // Total hex data: "00C0" (4) + 48 * 8 = 388 chars
    // Full string: "S3.1=" (5) + 388 + ",G3.1" (5) = 398
    XCTAssertEqual(data.count, 398)
    // Verify the first target value (110 = 0x6E)
    XCTAssertTrue(str.contains("0000006E"))
}
```

#### Test 1.5: `testDiaCommandPayload`

```swift
func testDiaCommandPayload() {
    let (data, prefix) = O5AidCommands.DiaCommand.payload()
    let str = String(data: data, encoding: .utf8)!
    XCTAssertEqual(str, "S3.9=8,G3.9")
    XCTAssertEqual(prefix, "3.9=")
}
```

#### Test 1.6: `testEgvCommandPayload`

```swift
func testEgvCommandPayload() {
    let (data, prefix) = O5AidCommands.EgvCommand.payload()
    let str = String(data: data, encoding: .utf8)!
    XCTAssertEqual(str, "S3.7=3670015,G3.7")
    XCTAssertEqual(prefix, "3.7=")
}
```

#### Test 1.7: `testAlgorithmInsulinHistoryPayload`

```swift
func testAlgorithmInsulinHistoryPayload() {
    let (data, prefix) = O5AidCommands.AlgorithmInsulinHistoryCommand.payload()
    let str = String(data: data, encoding: .utf8)!
    XCTAssertTrue(str.hasPrefix("SE2.1=00A8"))
    XCTAssertEqual(prefix, "ES2.1=")
    // "SE2.1=" (6) + "00A8" (4) + 24*7*2 hex chars (336) = 346
    XCTAssertEqual(data.count, 346)
    // All zeros: 336 hex chars of "0"
    let hexPart = String(str.dropFirst("SE2.1=00A8".count))
    XCTAssertEqual(hexPart.count, 336)
    XCTAssertTrue(hexPart.allSatisfy { $0 == "0" })
}
```

Note: `hexadecimalString` in this codebase uses lowercase `%02hhx` format (see `/Users/james/repos/OmnipodKit/OmnipodKit/Common/Data.swift` line 87-88). The zero records produce `"00"` for each byte, so the all-zeros check works regardless.

#### Test 1.8: `testUnifiedAidPodStatusPayload`

```swift
func testUnifiedAidPodStatusPayload() {
    let (data, prefix) = O5AidCommands.UnifiedAidPodStatusCommand.payload()
    let str = String(data: data, encoding: .utf8)!
    XCTAssertEqual(str, "G3.12")
    XCTAssertEqual(prefix, "3.12=")
}
```

### Test Group 2: AID Command Ordering (Requires O5Transport Protocol)

These tests verify that `o5SendAidSetupCommands()` sends the 9 AID commands in the exact order specified by the Frida capture.

**Source file to read**: `/Users/james/repos/OmnipodKit/OmnipodKit/Bluetooth/BlePodComms.swift`, lines 365-455

#### Test 2.1: `testAidSetupCommandOrdering`

```swift
func testAidSetupCommandOrdering() throws {
    let mock = MockO5Transport()

    // Pre-load 9 AID responses (minimal valid data)
    mock.aidResponses = [
        Data("0".utf8),                     // 1: UtcCommand -> "0"
        Data("0003000E00".utf8),            // 2: TdiCommand echo
        Data(repeating: 0, count: 192),     // 3: TargetBgProfile (192 bytes)
        Data("8".utf8),                     // 4: DiaCommand echo
        Data("3670015".utf8),               // 5: EgvCommand echo
        Data("0".utf8),                     // 6: InsulinHistory #1
        Data("0".utf8),                     // 7: InsulinHistory #2
        Data("0".utf8),                     // 8: InsulinHistory #3
        Data(repeating: 0, count: 29),      // 9: AidPodStatus (29 bytes)
    ]

    // Call the method under test.
    // After Change 4, o5SendAidSetupCommands is internal and takes O5Transport.
    let comms = BlePodComms(podState: nil, podType: omnipod5Type)
    try comms.o5SendAidSetupCommands(transport: mock)

    // Verify exactly 9 commands were sent
    XCTAssertEqual(mock.recordedCommands.count, 9,
        "Expected 9 AID commands, got \(mock.recordedCommands.count)")

    // Verify ordering by prefix
    let expectedPrefixes = [
        "SE255.2=",   // 1: UtcCommand
        "S3.2=",      // 2: TdiCommand
        "S3.1=",      // 3: TargetBgProfile
        "S3.9=",      // 4: DiaCommand
        "S3.7=",      // 5: EgvCommand
        "SE2.1=",     // 6: AlgorithmInsulinHistory #1
        "SE2.1=",     // 7: AlgorithmInsulinHistory #2
        "SE2.1=",     // 8: AlgorithmInsulinHistory #3
        "G3.12",      // 9: UnifiedAidPodStatus (GET-only, no "=")
    ]

    for (i, expected) in expectedPrefixes.enumerated() {
        guard case .aidCommand(let prefix) = mock.recordedCommands[i] else {
            XCTFail("Command \(i) should be an AID command, got \(mock.recordedCommands[i])")
            continue
        }
        XCTAssertEqual(prefix, expected,
            "AID command \(i) prefix mismatch: expected '\(expected)', got '\(prefix)'")
    }
}
```

**Important call-out**: `o5SendAidSetupCommands(transport:)` is currently a `private` method on `BlePodComms`. Change 4 (above) must be applied first to make it `internal`. Additionally, `BlePodComms` has an `init(podState:podType:myId:podId:)` that the implementer should verify can be called with `podState: nil` for this test (the method does not access `self.podState` directly -- it only uses the transport). If the assertion `assert(!podStateLock.try(), ...)` at the top of the calling function causes problems, the implementer should call `o5SendAidSetupCommands` directly, bypassing `o5PreSetupSteps`.

If `BlePodComms` cannot be instantiated easily in tests (due to `BluetoothManager` or other dependencies initialized in its `init`), an alternative approach is to **extract `o5SendAidSetupCommands` into a free function or a static method** that takes only an `O5Transport` parameter:

```swift
// Alternative: extract as a static or free function
static func sendO5AidSetupCommands(transport: O5Transport) throws {
    // ... same body ...
}
```

The implementer should read the `BlePodComms.init` carefully to determine which approach works. The key lines are `/Users/james/repos/OmnipodKit/OmnipodKit/Bluetooth/BlePodComms.swift` lines 39-46.

#### Test 2.2: `testAidSetupCommandsAreAllAidType`

Verify that no standard or signed messages are mixed into the AID sequence:

```swift
func testAidSetupCommandsAreAllAidType() throws {
    let mock = MockO5Transport()
    mock.aidResponses = Array(repeating: Data("0".utf8), count: 9)

    let comms = BlePodComms(podState: nil, podType: omnipod5Type)
    try comms.o5SendAidSetupCommands(transport: mock)

    for (i, cmd) in mock.recordedCommands.enumerated() {
        guard case .aidCommand = cmd else {
            XCTFail("Command \(i) should be .aidCommand, but was \(cmd)")
            continue
        }
    }
}
```

#### Test 2.3: `testAidSetupThreeInsulinHistoryBatches`

Verify exactly 3 insulin history batches are sent:

```swift
func testAidSetupThreeInsulinHistoryBatches() throws {
    let mock = MockO5Transport()
    mock.aidResponses = Array(repeating: Data("0".utf8), count: 9)

    let comms = BlePodComms(podState: nil, podType: omnipod5Type)
    try comms.o5SendAidSetupCommands(transport: mock)

    let historyCommands = mock.recordedCommands.filter {
        if case .aidCommand(let prefix) = $0, prefix == "SE2.1=" {
            return true
        }
        return false
    }
    XCTAssertEqual(historyCommands.count, 3,
        "Expected exactly 3 AlgorithmInsulinHistory batches")
}
```

### Test Group 3: Phase 1 Prime Command Ordering (Requires O5Transport Protocol)

These tests verify that `o5Prime()` sends the 3 alerts and 1 signed prime bolus in the correct order. This tests through `PodCommsSession`.

**Source files to read**:
- `/Users/james/repos/OmnipodKit/OmnipodKit/PumpManager/PodCommsSession+O5Activation.swift` (lines 40-103)
- `/Users/james/repos/OmnipodKit/OmnipodKit/PumpManager/PodCommsSession.swift` (lines 434-485, 487-494)

#### Helper: Create Test PodState

The existing test infrastructure in `PodCommsSessionTests.swift` shows how to create a `PodState`. For O5 activation tests, we need `podType: omnipod5Type` and `setupProgress: .podPaired`:

```swift
/// Creates a PodState suitable for O5 Phase 1 activation testing.
/// setupProgress must be .podPaired for o5Prime() to attempt priming.
private func makeO5PodState(setupProgress: SetupProgress = .podPaired) -> PodState {
    var state = PodState(
        address: 0x00277d19,
        firmwareVersion: "4.23.1.21",
        iFirmwareVersion: "1.0.0",
        lotNo: 12345,
        lotSeq: 67890,
        insulinType: .novolog,
        podType: omnipod5Type,
        bleMessageTransportState: BleMessageTransportState(),
        ltk: Data(repeating: 0xAB, count: 16),
        bleIdentifier: "test-ble-id"
    )
    state.setupProgress = setupProgress
    return state
}
```

**Important**: Check if `setupProgress` is settable. If it is `private(set)`, the implementer may need to use the existing test patterns from `PodCommsSessionTests.swift` or initialize with appropriate parameters. Read `/Users/james/repos/OmnipodKit/OmnipodKit/PumpManager/PodState.swift` to verify access control on `setupProgress`.

#### Helper: Create StatusResponse for Mock Responses

The mock needs `StatusResponse` objects to return from alert and prime commands. Use the same pattern as `PodCommsSessionTests`:

```swift
/// Creates a minimal StatusResponse for mock transport responses.
private func makeStatusResponse(
    podProgress: PodProgressStatus = .pairingCompleted,
    deliveryStatus: DeliveryStatus = .scheduledBasal
) -> StatusResponse {
    return StatusResponse(
        deliveryStatus: deliveryStatus,
        podProgressStatus: podProgress,
        timeActive: .minutes(5),
        reservoirLevel: Pod.reservoirLevelAboveThresholdMagicNumber,
        insulinDelivered: 0,
        bolusNotDelivered: 0,
        lastProgrammingMessageSeqNum: 0,
        alerts: AlertSet(slots: [])
    )
}
```

#### Test 3.1: `testO5PrimeCommandOrdering`

```swift
func testO5PrimeCommandOrdering() throws {
    let mock = MockO5Transport(responseAddress: 0x00277d19)

    // Pre-load responses: 3 configureAlerts (standard) + 1 prime bolus (signed)
    mock.standardResponses = [
        makeStatusResponse(),  // Alert #1: low reservoir
        makeStatusResponse(),  // Alert #2: setup reminder
        makeStatusResponse(),  // Alert #3: user expiry
    ]
    mock.signedResponses = [
        makeStatusResponse(podProgress: .priming),  // Prime bolus
    ]

    let podState = makeO5PodState(setupProgress: .podPaired)
    let session = PodCommsSession(
        podState: podState,
        transport: mock,
        delegate: self,
        o5CertStore: nil  // See note below about o5CertStore
    )

    _ = try session.o5Prime()

    // Verify: 3 standard (configureAlerts) + 1 signed (prime bolus)
    XCTAssertEqual(mock.recordedCommands.count, 4,
        "Expected 4 commands (3 alerts + 1 prime), got \(mock.recordedCommands.count)")

    // Command 0: configureAlerts (low reservoir) -- standard Type 1
    guard case .standard(let types0) = mock.recordedCommands[0] else {
        XCTFail("Command 0 should be standard, got \(mock.recordedCommands[0])")
        return
    }
    XCTAssertTrue(types0.contains(.configureAlerts),
        "Command 0 should contain .configureAlerts")

    // Command 1: configureAlerts (setup reminder) -- standard Type 1
    guard case .standard(let types1) = mock.recordedCommands[1] else {
        XCTFail("Command 1 should be standard, got \(mock.recordedCommands[1])")
        return
    }
    XCTAssertTrue(types1.contains(.configureAlerts),
        "Command 1 should contain .configureAlerts")

    // Command 2: configureAlerts (user expiry) -- standard Type 1
    guard case .standard(let types2) = mock.recordedCommands[2] else {
        XCTFail("Command 2 should be standard, got \(mock.recordedCommands[2])")
        return
    }
    XCTAssertTrue(types2.contains(.configureAlerts),
        "Command 2 should contain .configureAlerts")

    // Command 3: prime bolus -- signed Type 4
    guard case .signedMessage(let types3) = mock.recordedCommands[3] else {
        XCTFail("Command 3 should be signedMessage, got \(mock.recordedCommands[3])")
        return
    }
    XCTAssertTrue(types3.contains(.setInsulinSchedule),
        "Command 3 should contain .setInsulinSchedule")
    XCTAssertTrue(types3.contains(.bolusExtra),
        "Command 3 should contain .bolusExtra")
}
```

**Critical note on `o5CertStore`**: The `o5Send()` method at line 436-438 of `PodCommsSession.swift` checks `guard let certStore = o5CertStore else { throw }`. For this test to work, either:

1. Pass a real `O5CertificateStore` (requires valid crypto keys -- see `/Users/james/repos/OmnipodKit/OmnipodKit/Bluetooth/Pair/O5CertificateStore.swift`), OR
2. The mock's `sendO5SignedMessage()` is called before `o5Send()` checks the cert store. **This is NOT the case** -- `o5Send()` checks `o5CertStore` first, then calls `sendO5SignedMessage`.

Therefore, the implementer must provide a valid `O5CertificateStore`. The simplest approach:

```swift
let certStore = try O5CertificateStore()
```

This uses `O5RegistrationData.active` which contains the hardcoded pdmid 2587928 keys. The implementer should verify this initialization succeeds in the test environment. If it fails (e.g., missing CryptoKit availability), the alternative is to:
- Make `o5CertStore` check skippable in tests by adding a `bypassCertStoreCheck` flag, OR
- Extract the cert store check into the transport layer so the mock can handle it

#### Test 3.2: `testO5PrimeAlertsAreStandardNotSigned`

Verify that alert commands use standard Type 1 (not signed Type 4):

```swift
func testO5PrimeAlertsAreStandardNotSigned() throws {
    let mock = MockO5Transport(responseAddress: 0x00277d19)
    mock.standardResponses = [
        makeStatusResponse(),
        makeStatusResponse(),
        makeStatusResponse(),
    ]
    mock.signedResponses = [
        makeStatusResponse(podProgress: .priming),
    ]

    let podState = makeO5PodState(setupProgress: .podPaired)
    let certStore = try O5CertificateStore()
    let session = PodCommsSession(
        podState: podState,
        transport: mock,
        delegate: self,
        o5CertStore: certStore
    )

    _ = try session.o5Prime()

    // First 3 commands must be standard (Type 1), not signed
    for i in 0..<3 {
        if case .signedMessage = mock.recordedCommands[i] {
            XCTFail("Alert command \(i) should NOT be signed (Type 4). " +
                    "Only programBolus uses Type 4.")
        }
    }
}
```

This is important because a previous bug had all O5 commands using Type 4 signing, but Frida captures proved only `programBolus` uses Type 4.

#### Test 3.3: `testO5PrimeBolusisSigned`

Verify the prime bolus specifically uses signed (Type 4) transport:

```swift
func testO5PrimeBolusIsSigned() throws {
    let mock = MockO5Transport(responseAddress: 0x00277d19)
    mock.standardResponses = [
        makeStatusResponse(),
        makeStatusResponse(),
        makeStatusResponse(),
    ]
    mock.signedResponses = [
        makeStatusResponse(podProgress: .priming),
    ]

    let podState = makeO5PodState(setupProgress: .podPaired)
    let certStore = try O5CertificateStore()
    let session = PodCommsSession(
        podState: podState,
        transport: mock,
        delegate: self,
        o5CertStore: certStore
    )

    _ = try session.o5Prime()

    // Last command must be signed
    guard case .signedMessage(let types) = mock.recordedCommands.last else {
        XCTFail("Prime bolus should use signed transport (Type 4)")
        return
    }
    XCTAssertTrue(types.contains(.setInsulinSchedule))
    XCTAssertTrue(types.contains(.bolusExtra))
}
```

### Test Group 4: Full Activation Sequence Ordering (Integration)

This is the most comprehensive test. It verifies the complete command ordering from getPodVersion through prime. This tests through `BlePodComms.blePairAndSetupPod()` indirectly by testing the individual sub-methods in sequence.

**Note**: `blePairAndSetupPod()` is tightly coupled to `PeripheralManager`, `BluetoothManager`, and BLE session establishment. Testing it end-to-end as a unit test is not practical. Instead, compose the sub-method tests to verify the full ordering.

#### Test 4.1: `testFullPhase1SequenceOrdering`

This test calls the sub-methods in the same order as `blePairAndSetupPod()` and verifies the complete command trace:

```swift
func testFullPhase1SequenceOrdering() throws {
    let mock = MockO5Transport(responseAddress: 0x00277d19)

    // Responses for the AID setup (9 commands)
    mock.aidResponses = Array(repeating: Data("0".utf8), count: 9)

    // Responses for standard commands:
    // [0] getPodVersion (AssignAddress) -> VersionResponse
    // [1-3] three configureAlerts -> StatusResponse
    // Note: setupPod (SetupPod) would also be here but is handled separately
    let versionResponse = ... // See helper below
    mock.standardResponses = [
        versionResponse,        // getPodVersion
        makeStatusResponse(),   // setupPod -> VersionResponse (see note)
        makeStatusResponse(),   // Alert #1: low reservoir
        makeStatusResponse(),   // Alert #2: setup reminder
        makeStatusResponse(),   // Alert #3: user expiry
    ]

    // Responses for signed commands:
    mock.signedResponses = [
        makeStatusResponse(podProgress: .priming),  // Prime bolus
    ]

    // Simulate the sequence:
    // 1. getPodVersion (sendMessage with AssignAddress)
    // 2. AID setup (9x sendO5AidCommand)
    // 3. setupPod (sendMessage with SetupPod)
    // 4. o5Prime: 3x configureAlerts (sendMessage) + 1x prime (sendO5SignedMessage)

    // ... verify mock.recordedCommands has 15 entries in order:
    // [0]  standard(.assignAddress)
    // [1]  aidCommand("SE255.2=")
    // [2]  aidCommand("S3.2=")
    // [3]  aidCommand("S3.1=")
    // [4]  aidCommand("S3.9=")
    // [5]  aidCommand("S3.7=")
    // [6]  aidCommand("SE2.1=")
    // [7]  aidCommand("SE2.1=")
    // [8]  aidCommand("SE2.1=")
    // [9]  aidCommand("G3.12")
    // [10] standard(.setupPod)
    // [11] standard(.configureAlerts)
    // [12] standard(.configureAlerts)
    // [13] standard(.configureAlerts)
    // [14] signedMessage([.setInsulinSchedule, .bolusExtra])
}
```

**Implementation note**: This test is aspirational and depends on the ability to drive the sub-methods (`bleSendPairMessage`, `o5PreSetupSteps`, `setupPod`, `o5Prime`) against the mock. The implementer should determine the best approach:

- **Option A**: Call each sub-method sequentially against the same `MockO5Transport` to build up the full command trace. This requires the sub-methods to be accessible (some are `private`).
- **Option B**: Skip the full sequence test and rely on Test Groups 2 and 3 independently verifying sub-sequences. Document the expected overall ordering in comments.

**Recommendation**: Start with Option B (independent sub-sequence tests) and add Option A only if the accessibility refactoring is straightforward. Test Groups 2 and 3 together cover the most critical ordering constraints.

### Test Group 5: Negative / Regression Tests

#### Test 5.1: `testAidCommandsNotSentViaStandardTransport`

Regression test for the bug where AID commands were incorrectly sent through `sendMessage()` (standard Omnipod command format with `S0.0=...G0.0` wrapping) instead of `sendO5AidCommand()`:

```swift
func testAidCommandsNotSentViaStandardTransport() throws {
    let mock = MockO5Transport()
    mock.aidResponses = Array(repeating: Data("0".utf8), count: 9)

    let comms = BlePodComms(podState: nil, podType: omnipod5Type)
    try comms.o5SendAidSetupCommands(transport: mock)

    // No commands should have gone through sendMessage()
    let standardCommands = mock.recordedCommands.filter {
        if case .standard = $0 { return true }
        return false
    }
    XCTAssertEqual(standardCommands.count, 0,
        "AID commands should use sendO5AidCommand, not sendMessage. " +
        "Found \(standardCommands.count) standard commands.")
}
```

#### Test 5.2: `testNoGetStatusBetweenAidAndSetupPod`

Regression test for test #17 (GetStatus at FILLED state causes error 19):

```swift
func testNoGetStatusBetweenAidAndSetupPod() throws {
    let mock = MockO5Transport()
    mock.aidResponses = Array(repeating: Data("0".utf8), count: 9)

    let comms = BlePodComms(podState: nil, podType: omnipod5Type)
    try comms.o5SendAidSetupCommands(transport: mock)

    // Verify NO getStatus (.getStatus = 0x0e) in the command sequence
    for (i, cmd) in mock.recordedCommands.enumerated() {
        if case .standard(let types) = cmd, types.contains(.getStatus) {
            XCTFail("GetStatus found at position \(i). " +
                    "O5 pods at FILLED state reject GetStatus with error 19.")
        }
    }
}
```

#### Test 5.3: `testAlertsSentBeforePrime`

Regression test to ensure alerts are always configured before the prime bolus:

```swift
func testAlertsSentBeforePrime() throws {
    let mock = MockO5Transport(responseAddress: 0x00277d19)
    mock.standardResponses = [
        makeStatusResponse(),
        makeStatusResponse(),
        makeStatusResponse(),
    ]
    mock.signedResponses = [
        makeStatusResponse(podProgress: .priming),
    ]

    let podState = makeO5PodState(setupProgress: .podPaired)
    let certStore = try O5CertificateStore()
    let session = PodCommsSession(
        podState: podState,
        transport: mock,
        delegate: self,
        o5CertStore: certStore
    )

    _ = try session.o5Prime()

    // Find the index of the signed prime command
    let primeIndex = mock.recordedCommands.firstIndex {
        if case .signedMessage = $0 { return true }
        return false
    }
    XCTAssertNotNil(primeIndex, "Prime bolus command not found")

    // All commands before prime must be configureAlerts
    for i in 0..<(primeIndex ?? 0) {
        guard case .standard(let types) = mock.recordedCommands[i] else {
            XCTFail("Pre-prime command \(i) should be standard")
            continue
        }
        XCTAssertTrue(types.contains(.configureAlerts),
            "Pre-prime command \(i) should be configureAlerts, got \(types)")
    }
}
```

## Test Class Structure

```swift
import XCTest
@testable import OmnipodKit

class O5ActivationOrderingTests: XCTestCase, PodCommsSessionDelegate {

    var lastPodStateUpdate: PodState?

    // MARK: - PodCommsSessionDelegate

    func podCommsSession(_ podCommsSession: PodCommsSession, didChange state: PodState) {
        lastPodStateUpdate = state
    }

    // MARK: - Helpers

    private func makeO5PodState(setupProgress: SetupProgress = .podPaired) -> PodState {
        // ... as defined above ...
    }

    private func makeStatusResponse(...) -> StatusResponse {
        // ... as defined above ...
    }

    // MARK: - Test Group 1: AID Payload Format

    func testUtcCommandPayload() { ... }
    func testUtcCommandUsesCurrentTimeByDefault() { ... }
    func testTdiCommandPayload() { ... }
    func testTargetBgProfilePayload() { ... }
    func testDiaCommandPayload() { ... }
    func testEgvCommandPayload() { ... }
    func testAlgorithmInsulinHistoryPayload() { ... }
    func testUnifiedAidPodStatusPayload() { ... }

    // MARK: - Test Group 2: AID Command Ordering

    func testAidSetupCommandOrdering() throws { ... }
    func testAidSetupCommandsAreAllAidType() throws { ... }
    func testAidSetupThreeInsulinHistoryBatches() throws { ... }

    // MARK: - Test Group 3: Phase 1 Prime Ordering

    func testO5PrimeCommandOrdering() throws { ... }
    func testO5PrimeAlertsAreStandardNotSigned() throws { ... }
    func testO5PrimeBolusIsSigned() throws { ... }

    // MARK: - Test Group 5: Negative / Regression

    func testAidCommandsNotSentViaStandardTransport() throws { ... }
    func testNoGetStatusBetweenAidAndSetupPod() throws { ... }
    func testAlertsSentBeforePrime() throws { ... }
}
```

## Implementation Order

1. **Read all source files** listed in the "Source files to read" section above. Pay special attention to:
   - The `MessageTransport` protocol definition and all its requirements
   - The `O5CertificateStore` init and whether it can be constructed in test context
   - The `PodState` init and `setupProgress` access control
   - The `BlePodComms` init and what dependencies it creates

2. **Apply production code changes** (Changes 1-4) in order. After each change, verify the project still compiles with:
   ```
   xcodebuild -scheme OmnipodKit -destination 'generic/platform=iOS' build
   ```
   Note: the standalone build may fail with missing modules (LoopKit, etc.) since this is a framework consumed by Loop. If so, verify changes are syntactically correct by inspection.

3. **Create the test file** at `/Users/james/repos/OmnipodKit/OmniTests/O5ActivationOrderingTests.swift` with:
   - The `MockO5Transport` class
   - Test Group 1 (AID payload format) -- these should work immediately with no production changes
   - Test Group 2 (AID command ordering) -- requires Changes 1-4
   - Test Group 3 (Phase 1 prime ordering) -- requires Changes 1-3 and a valid `O5CertificateStore`
   - Test Group 5 (regression tests) -- mix of requirements from Groups 2 and 3

4. **Verify tests compile and run**. If the test target cannot build standalone, at minimum verify:
   - Test Group 1 tests compile and produce correct assertions
   - The `MockO5Transport` conforms to `O5Transport`
   - The production code changes compile without errors

## Build and Test Commands

```bash
# Build framework (may fail on missing LoopKit -- expected for standalone)
xcodebuild -scheme OmnipodKit -destination 'generic/platform=iOS' build

# Run tests (requires Loop workspace context -- check if OmniTests can run standalone)
xcodebuild test -scheme OmnipodKit -destination 'platform=iOS Simulator,name=iPhone 15'
```

## Risk Areas

1. **`BlePodComms` instantiation in tests**: `BlePodComms.init` creates a `BluetoothManager()` and may interact with CoreBluetooth. If this causes test failures (no BLE available in test runner), the implementer should extract `o5SendAidSetupCommands` to a location that does not require `BlePodComms` instantiation.

2. **`O5CertificateStore` construction**: Requires P256 private key parsing from `O5RegistrationData.active`. If CryptoKit is not available in the test environment, the prime ordering tests (Group 3) will need a workaround.

3. **`setupProgress` mutability**: If `PodState.setupProgress` is `private(set)` or has custom setter logic, the test helper `makeO5PodState` may need adjustment. Check the `PodState` struct definition.

4. **`assertOnSessionQueue` assertions**: Several methods in `BlePodComms` have `assert(!podStateLock.try(), ...)` preconditions. These will fire in tests unless the lock is acquired beforehand. The implementer should either acquire the lock in tests or disable assertions for testing.

5. **`hexadecimalString` case**: The `hexadecimalString` extension uses lowercase (`%02hhx`), but `O5AidCommands` constructs uppercase hex strings (`String(format: "%08X", target)` and `String(format: "%04X", totalBytes)`). Tests must account for this mixed casing -- the payload strings contain uppercase hex but `Data.hexadecimalString` would produce lowercase.
