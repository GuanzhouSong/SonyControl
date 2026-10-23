import Foundation
import IOBluetooth

// Sony "MDR" protocol over RFCOMM, as reverse-engineered by Gadgetbridge.
enum NoiseMode: String, CaseIterable, Identifiable {
    case noiseCancelling = "Noise Cancelling"
    case ambient = "Ambient Sound"
    case off = "Off"
    var id: String { rawValue }
}

struct AmbientState: Equatable {
    var mode: NoiseMode
    var focusOnVoice: Bool
    var level: Int  // 0...20
}

struct Battery: Equatable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
}

final class SonyLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    static let serviceV2 = sdpUUID("956C7B26-D49A-4BA8-B03F-B17D393CB6E2")
    static let serviceV1 = sdpUUID("96CC203E-5068-46AD-B32D-E316F5E069BA")

    private static func sdpUUID(_ s: String) -> IOBluetoothSDPUUID {
        var u = UUID(uuidString: s)!.uuid
        return withUnsafeBytes(of: &u) { IOBluetoothSDPUUID(bytes: $0.baseAddress, length: 16) }
    }

    var onAmbient: ((AmbientState) -> Void)?
    var onBattery: ((Battery) -> Void)?
    var onStatus: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var log: ((String) -> Void)?

    private(set) var deviceName: String?
    private var channel: IOBluetoothRFCOMMChannel?
    private var rx = [UInt8]()
    private var seq: UInt8 = 0
    private var queue = [[UInt8]]()
    private var awaitingAck = false
    private var ackTimer: Timer?
    private var battery = Battery()
    // WF-1000XM5 fw 6.x answers sub-type 0x17 (7 bytes); older models use 0x15, some add a wind byte.
    private var ambientKind: UInt8 = 0x17
    private var ambientHasWind = false
    private var lastAmbientPayload: [UInt8]?

    var isConnected: Bool { channel?.isOpen() ?? false }
    var isIdle: Bool { channel == nil }

    static func findDevice() -> IOBluetoothDevice? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let sony = paired.filter { ($0.name ?? "").contains("WF-1000XM5") || ($0.name ?? "").contains("WH-1000XM") || ($0.name ?? "").contains("WF-1000XM") }
        return sony.first(where: { $0.isConnected() }) ?? sony.first
    }

    private var warmedUp = false

    func connect() {
        guard channel == nil else { return }
        // IOBluetooth spins up its daemon session lazily; opening a channel before it reports
        // powered-on fails with "API MISUSE", so touch it first and retry shortly after.
        if !warmedUp {
            warmedUp = true
            _ = IOBluetoothDevice.pairedDevices()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.connect() }
            return
        }
        guard let dev = Self.findDevice() else { onStatus?("No paired Sony headphones found"); return }
        deviceName = dev.name
        guard dev.isConnected() else { onStatus?("\(dev.name ?? "Headphones") not connected"); return }

        // Cached SDP records are usually there; query once if not.
        if dev.services == nil || dev.services.isEmpty { dev.performSDPQuery(nil) }
        let record = dev.getServiceRecord(for: Self.serviceV2) ?? dev.getServiceRecord(for: Self.serviceV1)
        var channelID: BluetoothRFCOMMChannelID = 0
        guard let record, record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            onStatus?("Sony control service not found")
            return
        }

        log?("rfcomm channel \(channelID)")
        var ch: IOBluetoothRFCOMMChannel?
        let r = dev.openRFCOMMChannelAsync(&ch, withChannelID: channelID, delegate: self)
        guard r == kIOReturnSuccess, let ch else { onStatus?("Open failed (\(r))"); return }
        channel = ch
        onStatus?("Connecting…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak ch] in
            guard let self, let ch, self.channel === ch, !ch.isOpen() else { return }
            self.disconnect()
            self.onStatus?("Connect timed out")
        }
    }

    func disconnect() {
        channel?.close()
        reset()
    }

    private func reset() {
        channel = nil
        rx.removeAll(); queue.removeAll()
        awaitingAck = false
        ackTimer?.invalidate()
        seq = 0
    }

    // MARK: Commands

    func refresh() {
        send([0x66, ambientKind])          // ambient sound get
        send([0x22, 0x01])                 // battery L/R
        send([0x22, 0x0a])                 // battery case
    }

    func setAmbient(_ s: AmbientState) {
        let level = UInt8(max(0, min(20, s.level)))
        let on: UInt8 = s.mode == .off ? 0 : 1
        let asm: UInt8 = s.mode == .ambient ? 1 : 0
        var p: [UInt8] = [0x68, ambientKind, 0x01, on, asm]
        if ambientHasWind { p.append(0x02) }
        p += [s.focusOnVoice ? 1 : 0, level]
        send(p)
    }

    func sendRaw(_ payload: [UInt8]) { send(payload) }

    // MARK: Framing

    private func send(_ payload: [UInt8], type: UInt8 = 0x0c) {
        queue.append(payload)
        pump()
    }

    private func pump() {
        guard !awaitingAck, isConnected, !queue.isEmpty else { return }
        let payload = queue.removeFirst()
        awaitingAck = true
        write(frame(type: 0x0c, seq: seq, payload: payload))
        log?("→ \(hex(payload))")
        ackTimer?.invalidate()
        ackTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.awaitingAck = false
            self?.pump()
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let channel else { return }
        var b = bytes
        let mtu = Int(channel.getMTU())
        var off = 0
        while off < b.count {
            let n = min(mtu, b.count - off)
            _ = b.withUnsafeMutableBytes { channel.writeSync($0.baseAddress! + off, length: UInt16(n)) }
            off += n
        }
    }

    private func frame(type: UInt8, seq: UInt8, payload: [UInt8]) -> [UInt8] {
        let len = UInt32(payload.count)
        var body: [UInt8] = [type, seq, UInt8(len >> 24), UInt8((len >> 16) & 0xff), UInt8((len >> 8) & 0xff), UInt8(len & 0xff)] + payload
        body.append(body.reduce(0) { $0 &+ $1 })
        var out: [UInt8] = [0x3e]
        for b in body {
            if b == 0x3c || b == 0x3d || b == 0x3e { out += [0x3d, b & 0xef] } else { out.append(b) }
        }
        out.append(0x3c)
        return out
    }

    private func handleFrame(_ raw: [UInt8]) {
        var m = [UInt8]()
        var i = 0
        while i < raw.count {
            if raw[i] == 0x3d, i + 1 < raw.count { m.append(raw[i + 1] | 0x10); i += 2 } else { m.append(raw[i]); i += 1 }
        }
        guard m.count >= 7 else { return }
        let sum = m.dropLast().reduce(0) { $0 &+ $1 }
        guard sum == m.last! else { log?("bad checksum"); return }
        let type = m[0], s = m[1]
        let payload = Array(m[6..<(m.count - 1)])

        if type == 0x01 {
            seq = s
            awaitingAck = false
            ackTimer?.invalidate()
            pump()
            return
        }
        write(frame(type: 0x01, seq: 1 &- s, payload: []))
        guard !payload.isEmpty else { return }
        log?("← \(String(format: "%02x", type)) \(hex(payload))")
        if type == 0x0c { handlePayload(payload) }
    }

    private func handlePayload(_ p: [UInt8]) {
        switch p[0] {
        case 0x01:
            onStatus?("Connected")
            refresh()
        case 0x67, 0x69:
            parseAmbient(p)
        case 0x23, 0x25:
            parseBattery(p)
        default:
            break
        }
    }

    private func parseAmbient(_ p: [UInt8]) {
        guard p.count >= 6, [0x15, 0x17].contains(p[1]) else { return }
        ambientKind = p[1]
        let hasWind = p[1] == 0x17 && p.count > 7
        ambientHasWind = hasWind
        let mode: NoiseMode
        if p[3] == 0 { mode = .off }
        else if hasWind, p[5] == 0x03 || p[5] == 0x05 { mode = .noiseCancelling }
        else { mode = p[4] == 1 ? .ambient : .noiseCancelling }
        let st = AmbientState(mode: mode, focusOnVoice: p[p.count - 2] == 1, level: Int(p[p.count - 1]))
        onAmbient?(st)
    }

    private func parseBattery(_ p: [UInt8]) {
        guard p.count >= 3 else { return }
        switch p[1] {
        case 0x01, 0x09:
            guard p.count >= 6 else { return }
            battery.left = p[2] == 0 ? nil : Int(p[2])
            battery.right = p[4] == 0 ? nil : Int(p[4])
        case 0x0a:
            battery.caseLevel = p[2] == 0 ? nil : Int(p[2])
        default:
            return
        }
        onBattery?(battery)
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        log?("open complete: \(error)")
        guard error == kIOReturnSuccess else {
            onStatus?("Connect failed (\(error))")
            reset()
            return
        }
        seq = 0
        queue.insert([0x00, 0x00], at: 0)  // init
        pump()
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data ptr: UnsafeMutableRawPointer!, length: Int) {
        rx += Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: length))
        while let start = rx.firstIndex(of: 0x3e) {
            guard let end = rx[start...].firstIndex(of: 0x3c) else {
                rx.removeFirst(start)
                return
            }
            let frame = Array(rx[(start + 1)..<end])
            rx.removeFirst(end + 1)
            handleFrame(frame)
        }
        rx.removeAll()
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        reset()
        onStatus?("Disconnected")
        onDisconnect?()
    }
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: ":") }
