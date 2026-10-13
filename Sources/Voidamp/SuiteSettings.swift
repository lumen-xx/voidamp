import SwiftUI
import AppKit
import ApplicationServices

/// What the Suite's sidebar shows: the items to place on the board, or Voidamp's settings.
enum SuiteTab: String, CaseIterable {
    case board = "Nodes", settings = "Settings"
    var symbol: String { self == .board ? "point.3.connected.trianglepath.dotted" : "gearshape" }
    /// ⌘1 and ⌘2.
    var shortcut: KeyEquivalent { self == .board ? "1" : "2" }
    var tooltip: String { "\(rawValue) (⌘\(self == .board ? 1 : 2))" }
}

/// The sidebar's switch between the nodes to place and the settings: two full-width halves with icons, the
/// selection sliding across when it changes.
struct SuiteTabSwitcher: View {
    @Binding var tab: SuiteTab
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SuiteTab.allCases, id: \.self) { item in
                let selected = tab == item
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { tab = item }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol).font(.system(size: 11, weight: .semibold))
                        Text(item.rawValue).font(.system(size: 12, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background {
                        if selected {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.12))
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "selection", in: selection)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(item.shortcut, modifiers: .command)
                .help(item.tooltip)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

@MainActor
final class SuiteNavigation: ObservableObject {
    static let shared = SuiteNavigation()
    @Published var tab = SuiteTab.board
}

/// Voidamp's general settings, in the Suite's sidebar. The menu bar panel keeps only what is used every day.
struct SuiteSettings: View {
    @ObservedObject var audio: AudioController
    @ObservedObject var loginItem: LoginItem
    @ObservedObject var updater: AppUpdater
    @ObservedObject private var virtualMics = VirtualMics.shared
    @AppStorage(ControlOverlay.enabledKey) private var overlayEnabled = true
    @State private var accessibilityAllowed = AXIsProcessTrusted()

    var body: some View {
        List {
            Section("General") {
                Toggle("Start at Login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.setEnabled($0) }))
                if loginItem.needsApproval {
                    note("macOS needs your approval in Login Items.", action: "Approve…") { loginItem.openSettings() }
                }
                Toggle("Show System Sounds", isOn: $audio.showSystemSounds)
                    .help("One row for alerts and other sounds from macOS")
            }
            Section("Volume and Brightness Keys") {
                Toggle("Voidamp’s Overlay", isOn: Binding(get: { overlayEnabled }, set: { VoidampRuntime.shared.overlay?.enabled = $0; overlayEnabled = $0 }))
                    .help("Shows Voidamp’s card instead of macOS’s when you change the volume or brightness")
                if overlayEnabled && !accessibilityAllowed {
                    note("Needs Accessibility to see the keys.", action: "Allow…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            Section("Suite") {
                Toggle("Suite Wiring", isOn: $audio.suiteEnabled)
                    .help("Off pauses every wire and microphone monitor; your wiring is kept")
                Toggle("Patchbay Mode", isOn: $audio.patchbayMode)
                    .help("Apps on the board play only where they’re wired")
            }
            Section("Virtual Mics") { virtualMicsSettings }
            Section("Profiles") { profiles }
            Section("Updates") {
                HStack {
                    Text(version).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                }
            }
            Section {
                Button("Quit Voidamp") { NSApplication.shared.terminate(nil) }
                // As in opyuii's other apps; stacked, because the sidebar is narrow. A sidebar list draws no
                // section footers, so this is a row.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Link("GitHub", destination: URL(string: "https://github.com/lumen-xx/voidamp-releases")!)
                        Link("opyuii.com", destination: URL(string: "https://opyuii.com")!)
                    }
                    Text("© \(String(Calendar.current.component(.year, from: Date()))) opyuii. All rights reserved.")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(.top, 6)
            }
        }
        .listStyle(.sidebar)
        .scrollIndicators(.never)
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 12))
        .onAppear {
            loginItem.refresh()
            virtualMics.refresh()
            accessibilityAllowed = AXIsProcessTrusted()
        }
        // Permission changes happen in System Settings; check again when coming back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityAllowed = AXIsProcessTrusted()
            loginItem.refresh()
        }
    }

    @ViewBuilder private var virtualMicsSettings: some View {
        switch virtualMics.state {
        case .installed:
            HStack {
                Text("Voidamp Mic 1 and 2").foregroundStyle(.secondary)
                Spacer()
                Button("Remove…") { virtualMics.uninstall() }
            }
        case .outdated:
            note("A newer version is ready.", action: "Update…") { virtualMics.install() }
        case .notInstalled:
            note("Mics for Discord, FL Studio and more.", action: "Add…") { virtualMics.install() }
        case .unavailable:
            Text("Not included in this build").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var profiles: some View {
        if audio.profiles.isEmpty {
            Text("Save devices, levels and wiring.").foregroundStyle(.secondary)
        }
        ForEach(audio.profiles) { profile in
            HStack(spacing: 6) {
                Image(systemName: audio.selectedProfile == profile.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(audio.selectedProfile == profile.id ? Color.accentColor : .secondary)
                Text(profile.name).lineLimit(1)
                Spacer()
                Button("Use") { audio.applyProfile(profile) }.disabled(audio.selectedProfile == profile.id)
                Button { audio.deleteProfile(profile.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete “\(profile.name)”")
                    .accessibilityLabel("Delete \(profile.name)")
            }
        }
        Button("Save Current Setup…") { VoidampRuntime.shared.askToSaveProfile() }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "development"
        let build = info?["CFBundleVersion"] as? String
        return "Voidamp \(short)" + (build.map { " (\($0))" } ?? "")
    }

    private func note(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action, action: perform)
        }
    }
}
