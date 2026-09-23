//
//  G7PairingViewModel.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import G7SensorKit

/// Drives one pairing attempt for the pairing screen.
final class G7PairingViewModel: ObservableObject {

    @Published private(set) var state: G7PairingState = .idle

    /// Every sensor the run has heard from, kept after it ends so the screen
    /// can still show what happened to each one.
    @Published private(set) var candidates: [G7PairingCandidate] = []

    /// Assumed fine until the radio says otherwise, so the screen does not
    /// flash a warning before the central has reported in.
    @Published private(set) var bluetoothState: CBManagerState = .poweredOn

    let pairingCode: String
    let serial: String?
    private let excludedPeripheral: UUID?

    private let service: G7PairingService
    private let onSuccess: (_ peripheralIdentifier: UUID, _ sharedKey: Data, _ deviceName: String?, _ model: G7SensorModel, _ handoff: G7PairingHandoff?) -> Void
    private let onLog: ((String) -> Void)?

    /// - Parameter cgmManager: the manager being re-paired, if any. Its
    ///   session's Bluetooth central is borrowed for the run.
    init(
        pairingCode: String,
        serial: String?,
        cgmManager: G7CGMManager?,
        onLog: ((String) -> Void)? = nil,
        onSuccess: @escaping (_ peripheralIdentifier: UUID, _ sharedKey: Data, _ deviceName: String?, _ model: G7SensorModel, _ handoff: G7PairingHandoff?) -> Void
    ) {
        self.pairingCode = pairingCode
        // The sensor a session already holds is not the one being replaced;
        // trying it with the new code just earns a rejection. The same code
        // entered again means the same sensor, though: re-pairing it, so it
        // is the one to look for, by serial when the session has learned it.
        let isCurrentSensor = cgmManager?.state.pairingCode == pairingCode
        self.serial = serial ?? (isCurrentSensor ? cgmManager?.state.transmitterVersion?.serialNumberString : nil)
        self.excludedPeripheral = isCurrentSensor ? nil : cgmManager?.state.peripheralIdentifier
        self.onLog = onLog
        self.onSuccess = onSuccess
        service = G7PairingService(cgmManager: cgmManager)

        service.onLog = onLog
        service.onBluetoothStateChange = { [weak self] state in
            self?.bluetoothState = state
        }
        service.onStateChange = { [weak self] state in
            guard let self = self else { return }
            self.state = state
            if case .running(let candidates) = state {
                self.candidates = candidates
            }
            if case .succeeded(let peripheralIdentifier, let sharedKey, let deviceName) = state {
                self.onSuccess(peripheralIdentifier, sharedKey, deviceName, self.pairedModel, self.service.handOff())
            }
        }
    }

    func start() {
        candidates = []
        service.start(pairingCode: pairingCode, serial: serial, excludingPeripheral: excludedPeripheral)
    }

    func retry() {
        start()
    }

    func cancel() {
        service.cancel()
    }

    var scanStartedAt: Date? {
        service.scanStartedAt
    }

    /// The sensor being worked on right now, if any.
    var activeCandidate: G7PairingCandidate? {
        candidates.first { $0.status.isActive }
    }

    /// The candidates in reading order, newest activity first: what pairing is
    /// doing now, then what it will try next, then the sensors it has ruled
    /// out with the most recent verdict first. `candidates` keeps the order
    /// the run tries them in, which puts the settled ones at the top; that is
    /// the right order for the planner and the wrong one for someone watching.
    var displayCandidates: [G7PairingCandidate] {
        let current = candidates.filter { $0.status.isActive || $0.status == .paired }
        let waiting = candidates.filter { $0.status == .waiting }
        // Above the sensors that really are finished with: a busy one the run
        // is still listening to is what the run is waiting on, and burying it
        // at the bottom of the list says the opposite.
        let busy = candidates.filter(\.isAwaitingASlotToFree)
        let out = candidates.filter { $0.status.ruleOutReason != nil && !$0.isAwaitingASlotToFree }
        return current + busy + waiting + out.reversed()
    }

    /// Which product to picture: the sensor under trial, or the most recent
    /// one heard from before that. G7 until one of them says otherwise, since
    /// the screen has to show something while the scan is still empty.
    var displayModel: G7SensorModel {
        activeCandidate?.model ?? candidates.last(where: { $0.model != nil })?.model ?? .g7
    }

    /// The model that paired, from the advertised name of the sensor that
    /// answered. The session only learns the sensor's identity from its first
    /// reading, minutes later, so the pairing run is the only thing that knows
    /// it in time for the screen that follows.
    var pairedModel: G7SensorModel {
        candidates.first { $0.status == .paired }?.model ?? displayModel
    }

    /// The serial the scan is narrowed to: the one from the scanned
    /// applicator (or the one the session already knows, when re-pairing its
    /// own sensor), and only when it can actually narrow anything.
    var filteredSerial: String? {
        guard let serial = serial, G7PairingService.canFilterBySerial(serial) else {
            return nil
        }
        return serial
    }

    /// Says so on screen when the run is only looking for one sensor. A user
    /// watching it pass over a sensor sitting right next to the phone should
    /// be able to see why.
    var serialFilterNote: String? {
        guard let serial = filteredSerial, !isIdle, !isSucceeded else {
            return nil
        }
        return String(
            format: LocalizedString(
                "Waiting for the sensor with serial %@, from the applicator you scanned. Sensors in range that cannot have that serial are skipped.",
                comment: "Pairing note shown while the scan is narrowed to a scanned sensor's serial (1: serial number)"
            ),
            serial
        )
    }

    private var isIdle: Bool {
        if case .idle = state {
            return true
        }
        return false
    }

    private var isSucceeded: Bool {
        if case .succeeded = state {
            return true
        }
        return false
    }

    /// Why pairing cannot make progress right now, if the radio is the reason.
    var bluetoothProblem: String? {
        guard isWorking else { return nil }
        switch bluetoothState {
        case .poweredOff:
            return LocalizedString("Bluetooth is off. Turn it on in Settings or Control Center to pair.", comment: "Pairing screen notice when Bluetooth is powered off")
        case .unauthorized:
            return LocalizedString("Bluetooth access is not allowed. Turn it on for this app in Settings › Privacy & Security › Bluetooth.", comment: "Pairing screen notice when the app lacks Bluetooth permission")
        default:
            return nil
        }
    }

    var isWorking: Bool {
        switch state {
        case .running:
            return true
        case .idle, .succeeded, .failed:
            return false
        }
    }

    var statusTitle: String {
        if bluetoothProblem != nil {
            return LocalizedString("Bluetooth Unavailable", comment: "Pairing status while the radio is off or not permitted")
        }
        switch state {
        case .idle:
            return LocalizedString("Preparing…", comment: "Pairing status before the scan starts")
        case .running:
            switch activeCandidate?.status {
            case .connecting?:
                return LocalizedString("Connecting…", comment: "Pairing status while connecting to a sensor")
            case .pairing?:
                return LocalizedString("Pairing…", comment: "Pairing status during the handshake")
            default:
                return LocalizedString("Searching for sensor…", comment: "Pairing status while scanning")
            }
        case .succeeded:
            return LocalizedString("Paired", comment: "Pairing status on success")
        case .failed:
            return LocalizedString("Pairing Failed", comment: "Pairing status on failure")
        }
    }

    var statusDetail: String? {
        switch state {
        case .idle:
            return nil
        case .running:
            // Deliberately about the run, not about a candidate. Which sensor
            // is under trial and what became of the last one are true but not
            // things the user can act on, and read as claims about their
            // situation: a neighbour's sensor rejecting the code is how the
            // run learns it is a neighbour, not a sign the code is wrong.
            // That detail is a disclosure away, and in the log.
            if candidates.isEmpty {
                return LocalizedString(
                    "Keep your phone near the sensor. A sensor that was recently used by the Dexcom app or another phone can take up to 15 minutes to become available; this screen will keep looking.",
                    comment: "Pairing guidance while scanning"
                )
            }
            return LocalizedString(
                "Checking the sensors in range. This can take a few minutes.",
                comment: "Pairing guidance while working through the sensors that have been found"
            )
        case .succeeded(_, _, let deviceName):
            return deviceName
        case .failed(let reason):
            return reason
        }
    }

    /// The one thing mid-run the user can do something about: a sensor whose
    /// display slot belongs to something else.
    ///
    /// Worth its own line because it explains a wait that is otherwise
    /// inexplicably long, and because there is an action that ends it. It
    /// says "another app", not "another phone": in the common case it is the
    /// Dexcom app on this very phone, and sending someone to look for a
    /// second phone they do not own is worse than saying nothing.
    var busyNotice: String? {
        guard isWorking, candidates.contains(where: \.isAwaitingASlotToFree) else {
            return nil
        }
        return LocalizedString(
            "A sensor in range is in use by another app. Pairing keeps trying while it frees up, which takes up to 15 minutes. Removing the Dexcom app frees it sooner.",
            comment: "Pairing notice while waiting for a sensor whose display slot another app holds"
        )
    }

    /// The nudge for a run where the code itself looks wrong: every sensor
    /// that answered proved it holds a different one.
    var wrongCodeHint: String? {
        guard isWorking,
              activeCandidate == nil,
              !candidates.isEmpty,
              candidates.contains(where: { $0.status.ruleOutReason == .wrongPairingCode })
        else {
            return nil
        }
        return String(
            format: LocalizedString(
                "No sensor found so far uses the code %@. Check the code on the applicator if this continues.",
                comment: "Pairing hint when every sensor tried rejected the entered code (1: the pairing code)"
            ),
            pairingCode
        )
    }

    /// The one-line status for a sensor in the list on screen.
    func detail(for candidate: G7PairingCandidate) -> String {
        // A sensor on a later turn is one whose slot freed up after it turned
        // us away. Worth saying, without the count: a countdown invites
        // cancelling before it runs out, and cancelling throws away the
        // held-slot evidence and restarts the clock.
        if candidate.turn > 1, !candidate.status.isSettled {
            return LocalizedString("Trying again", comment: "Status of a G7 sensor being tried again after its display slot freed up)")
        }

        switch candidate.status {
        case .waiting:
            return candidate.isPhoneSlotHeld
                ? LocalizedString("Waiting; in use by another app", comment: "Status of a discovered G7 sensor whose display slot is taken, waiting its turn")
                : LocalizedString("Waiting its turn", comment: "Status of a discovered G7 sensor waiting its turn")
        case .connecting:
            return LocalizedString("Connecting", comment: "Status of the G7 sensor being connected to")
        case .pairing:
            return LocalizedString("Pairing", comment: "Status of the G7 sensor under handshake")
        case .ruledOut where candidate.isAwaitingASlotToFree:
            // Set aside, not finished with: the run is still listening to it.
            return LocalizedString("In use by another app; waiting for it to free up", comment: "Status of a G7 sensor set aside as busy while the run waits for its display slot to free")
        case .ruledOut(let reason):
            return reason.localizedDescription
        case .paired:
            return LocalizedString("Paired", comment: "Status of the G7 sensor that paired")
        }
    }
}
