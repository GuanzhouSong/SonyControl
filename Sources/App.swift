import ServiceManagement
import SwiftUI

@MainActor
final class Model: ObservableObject {
    @Published var status = "Searching…"
    @Published var connected = false
    @Published var state = AmbientState(mode: .noiseCancelling, focusOnVoice: false, level: 20)
    @Published var battery = Battery()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    let link = SonyLink()
    private var timer: Timer?

    init() {
        link.onStatus = { [weak self] s in
            self?.status = s
            self?.connected = self?.link.isConnected ?? false
        }
        link.onAmbient = { [weak self] s in self?.state = s }
        link.onBattery = { [weak self] b in self?.battery = b }
        link.connect()
        // Earbuds come and go (case, other devices); keep retrying quietly.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.link.isIdle else { return }
                self.link.connect()
            }
        }
    }

    func set(mode: NoiseMode) {
        state.mode = mode
        link.setAmbient(state)
    }

    func apply() { link.setAmbient(state) }

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            status = "Login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var icon: String {
        guard connected else { return "earbuds" }
        switch state.mode {
        case .noiseCancelling: return "ear.fill"
        case .ambient: return "ear.and.waveform"
        case .off: return "ear"
        }
    }
}

struct Panel: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(m.link.deviceName ?? "Sony headphones").font(.headline)
                Spacer()
                Text(m.status).font(.caption).foregroundStyle(.secondary)
            }

            if m.connected {
                HStack(spacing: 14) {
                    batteryLabel("L", m.battery.left)
                    batteryLabel("R", m.battery.right)
                    batteryLabel("Case", m.battery.caseLevel)
                }
                .font(.caption)

                Picker("", selection: Binding(get: { m.state.mode }, set: { m.set(mode: $0) })) {
                    Text("Noise Cancel").tag(NoiseMode.noiseCancelling)
                    Text("Ambient").tag(NoiseMode.ambient)
                    Text("Off").tag(NoiseMode.off)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if m.state.mode == .ambient {
                    HStack {
                        Text("Level")
                        Slider(value: Binding(get: { Double(m.state.level) }, set: { m.state.level = Int($0) }),
                               in: 1...20, step: 1) { editing in
                            if !editing { m.apply() }
                        }
                        Text("\(m.state.level)").monospacedDigit().frame(width: 22, alignment: .trailing)
                    }
                    Toggle("Focus on voice", isOn: Binding(get: { m.state.focusOnVoice }, set: { m.state.focusOnVoice = $0; m.apply() }))
                }
            } else {
                Text("Connect the earbuds to this Mac in Bluetooth settings; control attaches automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Toggle("Launch at login", isOn: Binding(get: { m.launchAtLogin }, set: { _ in m.toggleLaunchAtLogin() }))
                    .toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func batteryLabel(_ name: String, _ v: Int?) -> some View {
        Label("\(name) \(v.map { "\($0)%" } ?? "–")", systemImage: "battery.75percent")
    }
}

@main
struct SonyControlApp: App {
    @StateObject private var m = Model()

    var body: some Scene {
        MenuBarExtra {
            Panel(m: m)
        } label: {
            Image(systemName: m.icon)
        }
        .menuBarExtraStyle(.window)
    }
}
