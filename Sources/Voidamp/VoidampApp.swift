import SwiftUI
import AppKit
import Combine

@MainActor
final class VoidampRuntime: ObservableObject {
    static let shared = VoidampRuntime()
    let audio = AudioController()
    let updater = AppUpdater()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var iconSubscription: AnyCancellable?
    private var focusSubscription: AnyCancellable?
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var lastClose = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--updater-check") {
            let updater = VoidampRuntime.shared.updater
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard updater.canCheckForUpdates else {
                    print("FAIL: Sparkle did not become ready")
                    exit(1)
                }
                print("PASS: Sparkle initializes and can check for updates")
                exit(0)
            }
            return
        }
        configureStatusItem()
    }

    private func configureStatusItem() {
        let runtime = VoidampRuntime.shared
        let host = FirstClickHostingController(rootView: MixerView(audio: runtime.audio, updater: runtime.updater))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        // Closing is ours: a transient popover closes on the status item's mouse-down, and the button's
        // action then reopened it, so the icon could never hide the panel.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async {
                guard let self, self.popover.isShown, !self.statusItemContains(location) else { return }
                self.closePanel()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, event.keyCode == 53, event.window === self.popover.contentViewController?.view.window else { return event }
            self.closePanel()
            return nil
        }
        focusSubscription = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                // Menu windows can take key focus without deactivating the app.
                // Only dismiss when another application actually becomes active.
                guard !NSApplication.shared.isActive else { return }
                self?.closePanel()
            }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "VoidampSound"
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item
        iconSubscription = runtime.audio.$sources.combineLatest(runtime.audio.$soundMuted)
            .receive(on: RunLoop.main).sink { [weak self] _, _ in
                let audio = VoidampRuntime.shared.audio
                let symbol = audio.statusSymbol
                if self?.statusItem?.button?.image?.accessibilityDescription != symbol {
                    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
                    image?.isTemplate = true
                    self?.statusItem?.button?.image = image
                    self?.statusItem?.button?.setAccessibilityLabel("Voidamp")
                }
                self?.statusItem?.button?.toolTip = "Voidamp · \(audio.statusDescription)"
            }
    }

    private func statusItemContains(_ location: NSPoint) -> Bool {
        guard let window = statusItem?.button?.window else { return false }
        return window.frame.contains(location)
    }

    @objc private func togglePanel() {
        if popover.isShown { closePanel(); return }
        // The click that just dismissed the panel (outside-click monitor or focus loss) is this same click.
        guard Date().timeIntervalSince(lastClose) > 0.35 else { return }
        guard let button = statusItem?.button, let host = popover.contentViewController else { return }
        // Become the active app before anything in the panel is clicked. Otherwise that first click
        // activates Voidamp, and the activation dismisses the menu it just opened.
        NSApplication.shared.activate(ignoringOtherApps: true)
        host.view.layoutSubtreeIfNeeded()
        popover.contentSize = host.view.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        host.view.window?.makeKey()
        button.highlight(true)
    }

    private func closePanel() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        lastClose = Date()
        statusItem?.button?.highlight(false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        VoidampRuntime.shared.audio.shutDown()
    }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FirstClickHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = FirstClickHostingView(rootView: rootView)
    }
}

@main
struct VoidampApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.contains("--route-check") {
            // Uses its own preferences so the check never changes the user's saved levels.
            let suite = "app.voidamp.route-check.\(UUID().uuidString)"
            let preferences = UserDefaults(suiteName: suite)!
            let controller = AudioController(preferences: preferences)
            controller.enableMixing()
            // Untouched apps play directly; a level other than 100% makes each playing app use a route.
            for app in controller.apps where app.isPlaying { controller.setAppGain(app, 0.98) }
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            preferences.removePersistentDomain(forName: suite)
            for line in controller.routingDiagnostics() { print(line) }
            if let error = controller.error { print(error) }
            controller.shutDown()
            exit(0)
        }
        if CommandLine.arguments.contains("--self-check") {
            let suite = "app.voidamp.check.\(UUID().uuidString)"
            let preferences = UserDefaults(suiteName: suite)!
            let controller = AudioController(preferences: preferences, autoStartMixing: false)
            let initialOrder = controller.sources.map(\.id)
            controller.refresh()
            precondition(controller.sources.map(\.id) == initialOrder, "Device order changed")
            controller.saveProfile(name: "Test constellation")
            let reloaded = AudioController(preferences: preferences, autoStartMixing: false)
            precondition(reloaded.profiles.count == 1)
            precondition(reloaded.profiles[0].devices == controller.profiles[0].devices)
            precondition(reloaded.profiles[0].outputUID == controller.sources.first(where: { !$0.input && $0.isDefault })?.uid)
            precondition(reloaded.profiles[0].inputUID == controller.sources.first(where: { $0.input && $0.isDefault })?.uid)
            reloaded.deleteProfile(reloaded.profiles[0].id)
            let deleted = AudioController(preferences: preferences, autoStartMixing: false)
            precondition(deleted.profiles.isEmpty)
            precondition(MixerGain.adjusted(0.98, snapping: true) == 1)
            precondition(MixerGain.adjusted(1.02, snapping: true) == 1)
            precondition(MixerGain.adjusted(1.2, snapping: true) == 1.2)
            precondition(MixerGain.adjusted(1.02, snapping: false) == 1.02)
            precondition(MixerGain.adjusted(3, snapping: false) == 2)
            precondition(MixerGain.adjusted(-1, snapping: false) == 0)
            precondition(controller.apps.contains(where: \.isSystem), "System Sounds row missing")
            controller.showSystemSounds = false
            precondition(!controller.apps.contains(where: \.isSystem), "System Sounds row still shown")
            let hidden = AudioController(preferences: preferences, autoStartMixing: false)
            precondition(!hidden.showSystemSounds, "System Sounds setting not saved")
            hidden.shutDown()
            print("PASS: stable device order, profile persistence/deletion, 100% snapping, gain bounds, System Sounds setting")
            for source in controller.sources { print("\(source.input ? "Input" : "Output"): \(source.name) · \(source.channels.count) volume controls") }
            for app in controller.apps { print("App: \(app.name)") }
            controller.shutDown(); reloaded.shutDown(); deleted.shutDown()
            preferences.removePersistentDomain(forName: suite)
            exit(0)
        }
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct MixerView: View {
    @ObservedObject var audio: AudioController
    @ObservedObject var updater: AppUpdater
    @StateObject private var loginItem = LoginItem()
    @State private var devicesExpanded = false
    @State private var renamingDevice: AudioSource?
    @State private var deviceName = ""
    @State private var savingProfile = false
    @State private var profileName = ""
    @State private var measuredContentHeight: CGFloat = 1
    @State private var draggingApps: Set<String> = []
    private let accent = Color.accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                muteButton("Sound", icon: audio.soundMuted ? "speaker.slash.fill" : "speaker.wave.2", active: audio.soundMuted) { audio.toggleSoundMute() }
                muteButton("Mic", icon: audio.micMuted ? "mic.slash.fill" : "mic", active: audio.micMuted) { audio.toggleMicMute() }
                HStack(spacing: 8) {
                    // AppKit menus instead of SwiftUI's Menu: they open only once Voidamp is the active app,
                    // so the activation from a first click can't dismiss them a moment after they appear.
                    HStack(spacing: 5) {
                        Image(systemName: audio.selectedProfile == nil ? "square.stack" : "square.stack.fill")
                        Text(selectedProfileName ?? "Profiles").lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                    }
                    .font(MixerStyle.caption)
                    .foregroundStyle(audio.selectedProfile == nil ? Color.secondary : Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
                    .overlay(PopUpMenuButton(label: selectedProfileName.map { "Profiles, \($0) selected" } ?? "Profiles", makeMenu: profilesMenu))
                    .help(selectedProfileName.map { "Selected profile: \($0)" } ?? "Profiles")
                    HStack(spacing: 3) {
                        Image(systemName: "ellipsis")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
                    .overlay(PopUpMenuButton(label: "More options", makeMenu: moreMenu))
                    .fixedSize().help("More")
                }
                .padding(.horizontal, 10)
                .frame(width: 138, height: 30)
                .modifier(ToolbarIslandSurface())
            }
            .frame(height: 30)
            if savingProfile {
                HStack(spacing: 8) {
                    TextField("Profile name", text: $profileName).textFieldStyle(.roundedBorder)
                        .onSubmit { saveProfile() }
                    Button("Save") { saveProfile() }.disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button { savingProfile = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(MixerStyle.body)
            }
            Divider()
            SoundLevelSlider(value: Binding(get: {
                selectedOutput.map { audio.displayVolume($0) } ?? 0
            }, set: { volume in
                if let source = selectedOutput { audio.setVolume(source, volume) }
            }), muted: audio.soundMuted)
            .disabled(selectedOutput?.channels.isEmpty ?? true)
            .help(selectedOutput.map { "\(audio.displayName($0)) volume" } ?? "No output device")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Apps").font(MixerStyle.section).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Mixing", isOn: Binding(get: { audio.mixingEnabled }, set: { enabled in
                            if enabled { audio.enableMixing() } else { audio.disableMixing() }
                        }))
                        .toggleStyle(.switch).controlSize(.mini).fixedSize()
                        .font(MixerStyle.caption)
                        .help("Mix application audio · up to 200%")
                    }
                    if !audio.apps.contains(where: { !$0.isSystem }) {
                        Text("Play audio in an app to see it here.").font(MixerStyle.body).foregroundStyle(.secondary).padding(.vertical, 4)
                    }
                    ForEach(audio.apps) { app in appRow(app) }
                    if !audio.mixingEnabled {
                        Text("Turn on mixing to adjust each app.").font(MixerStyle.caption).foregroundStyle(.secondary)
                    } else if audio.captureBlocked {
                        captureNotice
                    }
                    Divider()
                    Button { devicesExpanded.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: devicesExpanded ? "chevron.down" : "chevron.right")
                                .font(MixerStyle.caption).frame(width: 10)
                            Text("Devices").font(MixerStyle.section)
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityValue(devicesExpanded ? "Expanded" : "Collapsed")
                    if devicesExpanded {
                        VStack(alignment: .leading, spacing: 12) {
                            deviceSection("Output", input: false)
                            deviceSection("Microphone", input: true)
                        }
                    }
                }
                .padding(.vertical, 2)
                .background(HideNativeScrollbars())
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: MixerContentHeight.self, value: geometry.size.height)
                })
            }
            // .hidden still lays the content out 17 pt narrower for a scroll bar it never shows; .never gives the full width.
            .scrollIndicators(.never)
            .scrollDisabled(measuredContentHeight <= 380)
            .frame(height: min(380, measuredContentHeight))
            .onPreferenceChange(MixerContentHeight.self) { measuredContentHeight = ceil($0) }
        }
        .padding(14)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .font(MixerStyle.body)
        .tint(accent)
        .modifier(NativePanelSurface())
        .alert("Rename device", isPresented: Binding(get: { renamingDevice != nil }, set: { if !$0 { renamingDevice = nil } })) {
            TextField("Device name", text: $deviceName)
            Button("Cancel", role: .cancel) { renamingDevice = nil }
            Button("Save") {
                if let source = renamingDevice { audio.renameDevice(source, to: deviceName) }
                renamingDevice = nil
            }
        } message: { Text("This name is only used in Voidamp. Leave empty to restore the original name.") }
        .onReceive(loginItem.$error.compactMap { $0 }) { message in
            audio.error = message
            loginItem.error = nil
        }
        .alert("Audio control", isPresented: Binding(get: { audio.error != nil }, set: { if !$0 { audio.error = nil } })) {
            Button("OK") { audio.error = nil }
        } message: { Text(audio.error ?? "") }
    }

    private var selectedOutput: AudioSource? {
        audio.sources.first { !$0.input && $0.isDefault }
    }

    private var selectedProfileName: String? {
        audio.profiles.first(where: { $0.id == audio.selectedProfile })?.name
    }

    private func saveProfile() {
        audio.saveProfile(name: profileName)
        savingProfile = false
    }
    private func muteButton(_ label: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            muteLabel(label, icon: icon)
                .foregroundStyle(active ? Color.white : Color.primary)
                .modifier(MuteControlSurface(active: active))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .help(active ? "Unmute \(label.lowercased())" : "Mute \(label.lowercased())")
        .accessibilityLabel(active ? "Unmute \(label.lowercased())" : "Mute \(label.lowercased())")
        .accessibilityValue(active ? "Muted" : "Unmuted")
    }
    private func muteLabel(_ label: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 15)
            Text(label)
        }
        .font(MixerStyle.caption)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .contentShape(Capsule())
    }

    private func appRow(_ app: AppSource) -> some View {
        let adjustable = audio.canAdjust(app)
        let failure = audio.routeFailures[app.id]
        return HStack(spacing: 8) {
            Group {
                if let icon = app.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: app.isSystem ? "bell.fill" : "app.dashed").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.frame(width: 16, height: 16)
            Text(app.name).font(MixerStyle.body).lineLimit(1).frame(width: 80, alignment: .leading).help(app.name)
            Slider(value: Binding(get: { audio.apps.first(where: { $0.id == app.id })?.gain ?? app.gain }, set: { audio.setAppGain(app, $0, snapping: draggingApps.contains(app.id)) }), in: 0...2, onEditingChanged: { editing in
                    if editing { draggingApps.insert(app.id) } else { draggingApps.remove(app.id) }
                })
                .help("App volume · snaps to 100% · boost up to 200%")
                .disabled(!adjustable).accessibilityLabel("\(app.name) volume, up to 200 percent")
            if let failure {
                Button { audio.retryMixing() } label: {
                    Image(systemName: "exclamationmark.triangle").font(MixerStyle.value).foregroundStyle(.orange)
                        .frame(width: 34, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .help(failureText(failure, app: app) + " Click to try again.")
                .accessibilityLabel("Retry mixing \(app.name)")
            } else {
                // Clicking the level returns the app to 100%.
                Button { audio.setAppGain(app, 1) } label: {
                    Text("\(Int((app.gain * 100).rounded()))%").font(MixerStyle.value).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!adjustable)
                .help(abs(app.gain - 1) < 0.005 ? "\(app.name) plays at 100%" : "Reset \(app.name) to 100%")
                .accessibilityLabel("Reset \(app.name) to 100 percent")
            }
            Button { audio.toggleAppMute(app) } label: {
                Image(systemName: app.muted ? "speaker.slash" : "speaker.wave.1").frame(width: 14)
            }.buttonStyle(.plain).disabled(!adjustable).foregroundStyle(app.muted ? accent : .secondary)
                .help(app.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        }.opacity(adjustable ? 1 : 0.55)
    }

    private func failureText(_ failure: RouteFailure, app: AppSource) -> String {
        switch failure {
        case .noAudio: return "Voidamp can’t hear \(app.name), so it plays normally."
        case .message(let message): return "Voidamp can’t mix \(app.name), so it plays normally. \(message)"
        }
    }

    /// Shown instead of an alert when capturing app audio produced nothing, which nearly always means macOS
    /// no longer grants Voidamp Screen & System Audio Recording (for example after an update).
    private var captureNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Apps play normally because Voidamp can’t hear them. Turn Voidamp off and on again in Screen & System Audio Recording, then retry.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(MixerStyle.caption)
            HStack(spacing: 8) {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Retry") { audio.retryMixing() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.1)))
    }

    private func profilesMenu() -> NSMenu {
        let menu = NSMenu()
        if audio.profiles.isEmpty {
            menu.addItem(ClosureMenuItem("No saved profiles", enabled: false) {})
        } else {
            for profile in audio.profiles {
                let selected = audio.selectedProfile == profile.id
                menu.addItem(ClosureMenuItem(profile.name, checked: selected) { [audio] in
                    if selected { audio.selectedProfile = nil } else { audio.applyProfile(profile) }
                })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Save current as profile…") { profileName = ""; savingProfile = true })
        if let id = audio.selectedProfile {
            menu.addItem(ClosureMenuItem("Delete selected profile") { [audio] in audio.deleteProfile(id) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Clear current profile", enabled: audio.selectedProfile != nil) { [audio] in audio.selectedProfile = nil })
        return menu
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Check for Updates…", enabled: updater.canCheckForUpdates) { [updater] in updater.checkForUpdates() })
        menu.addItem(ClosureMenuItem("Refresh sources") { [audio] in audio.refresh() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Show System Sounds in Mixing", checked: audio.showSystemSounds) { [audio] in audio.showSystemSounds.toggle() })
        menu.addItem(ClosureMenuItem("Start at Login", checked: loginItem.enabled) { [loginItem] in loginItem.setEnabled(!loginItem.enabled) })
        if loginItem.needsApproval {
            menu.addItem(ClosureMenuItem("Approve Start at Login…") { [loginItem] in loginItem.openSettings() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Voidamp") { [audio] in audio.shutDown(); NSApplication.shared.terminate(nil) })
        return menu
    }

    private func deviceSymbol(_ source: AudioSource) -> String {
        let name = source.name.lowercased()
        if name.contains("airpods") { return source.input ? "mic" : "airpods" }
        if name.contains("headphone") || name.contains("headset") || name.contains("beats") { return source.input ? "mic" : "headphones" }
        if name.contains("display") || name.contains("hdmi") || name.contains("monitor") || name.contains("tv") { return "display" }
        if name.contains("macbook") || name.contains("built-in") || name.contains("internal") { return source.input ? "mic" : "laptopcomputer" }
        if name.contains("bluetooth") { return source.input ? "mic" : "hifispeaker" }
        if name.contains("usb") || name.contains("interface") { return source.input ? "mic" : "cable.connector" }
        return source.input ? "mic" : "speaker.wave.2"
    }
    private func deviceSection(_ title: String, input: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(MixerStyle.section).foregroundStyle(.tertiary)
            ForEach(audio.sources.filter { $0.input == input }) { source in
                let live = audio.sources.first(where: { $0.id == source.id }) ?? source
                // The icon is centred beside the name and its volume; the selected device shows through its
                // accent background, icon and name weight rather than a checkmark.
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: deviceSymbol(source)).font(MixerStyle.body).frame(width: 18)
                        .foregroundStyle(live.isDefault ? accent : .secondary)
                        .opacity((input ? audio.micMuted : audio.soundMuted) ? 0.4 : 1)
                    VStack(alignment: .leading, spacing: 6) {
                        Button { audio.select(source) } label: {
                            HStack(spacing: 8) {
                                Text(audio.displayName(source)).font(live.isDefault ? MixerStyle.section : MixerStyle.body).lineLimit(1)
                                Spacer(minLength: 0)
                            }.opacity((input ? audio.micMuted : audio.soundMuted) ? 0.4 : 1).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Use \(audio.displayName(source)) · \(source.name)")
                        .accessibilityLabel(audio.displayName(source))
                        .accessibilityAddTraits(live.isDefault ? .isSelected : [])
                        .contextMenu {
                            Button("Rename…") {
                                deviceName = audio.displayName(source)
                                renamingDevice = source
                            }
                            if audio.displayName(source) != source.name {
                                Button("Restore original name") { audio.renameDevice(source, to: "") }
                            }
                        }
                        if source.channels.isEmpty {
                            Text("Volume is controlled by this device").font(MixerStyle.caption).foregroundStyle(.tertiary)
                        } else {
                            HStack(spacing: 8) {
                                Slider(value: Binding(get: { audio.displayVolume(source) }, set: { audio.setVolume(source, $0) }), in: 0...1)
                                    .controlSize(.small)
                                    .saturation((input ? audio.micMuted : audio.soundMuted) ? 0 : 1)
                                    .opacity((input ? audio.micMuted : audio.soundMuted) ? 0.5 : 1)
                                    .accessibilityLabel("\(source.name) \(input ? "input gain" : "output volume")")
                                Text("\(Int((audio.displayVolume(source) * 100).rounded()))%").font(MixerStyle.value).monospacedDigit().lineLimit(1).fixedSize().frame(width: 38, alignment: .trailing)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(live.isDefault ? accent.opacity(0.12) : Color.primary.opacity(0.04)))
            }
        }
    }
}

private struct NativePanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            content.background(.regularMaterial)
        }
    }
}

// San Francisco throughout: one body size, one caption size, medium section labels.
private enum MixerStyle {
    static let body = Font.system(size: 12)
    static let section = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11)
    static let value = Font.system(size: 11)
}

private struct MixerContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// Belt and braces next to .scrollIndicators(.never): keeps the AppKit scroller in overlay style with no scrollers,
// so macOS's legacy or Always scroll-bar setting cannot bring a gutter back, while wheel and trackpad scrolling stay.
private struct HideNativeScrollbars: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollbarHider { ScrollbarHider() }
    func updateNSView(_ view: ScrollbarHider, context: Context) {
        DispatchQueue.main.async { view.hideScrollbars() }
    }
}

private final class ScrollbarHider: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { self.hideScrollbars() }
    }
    override func layout() { super.layout(); hideScrollbars() }
    func hideScrollbars() {
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView {
                if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
                scroll.automaticallyAdjustsContentInsets = false
                if !NSEdgeInsetsEqual(scroll.contentInsets, NSEdgeInsetsZero) { scroll.contentInsets = NSEdgeInsetsZero }
                if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
                if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
                scroll.autohidesScrollers = true
            }
            ancestor = view.superview
        }
    }
}

private struct ToolbarIslandSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        }
    }
}

private struct MuteControlSurface: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.tint(.red).interactive(), in: .capsule)
            } else {
                content.background(Color.red, in: Capsule())
            }
        } else { content }
    }
}

/// A transparent hit area over a SwiftUI label that pops up an AppKit menu. If Voidamp isn't active yet, the
/// click activates it first and the menu opens once activation lands, so it can't vanish after a moment.
private struct PopUpMenuButton: NSViewRepresentable {
    let label: String
    let makeMenu: () -> NSMenu
    func makeNSView(context: Context) -> PopUpMenuView { PopUpMenuView() }
    func updateNSView(_ view: PopUpMenuView, context: Context) {
        view.makeMenu = makeMenu
        view.setAccessibilityLabel(label)
    }
}

private final class PopUpMenuView: NSView {
    var makeMenu: (() -> NSMenu)?
    private var activationObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityPerformPress() -> Bool { open(); return true }
    override func mouseDown(with event: NSEvent) { open() }

    private func open() {
        if NSApplication.shared.isActive { present(); return }
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activationFinished() }
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Don't wait forever if macOS declines to activate Voidamp.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.activationFinished() }
    }

    private func activationFinished() {
        guard let observer = activationObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        activationObserver = nil
        present()
    }

    private func present() {
        guard window != nil, let menu = makeMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(runHandler) : nil, keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func runHandler() { handler() }
}

/// The output level, drawn like the Sound slider in Control Centre: a thick track, a white fill carrying
/// the speaker symbol, and a round knob at the end. Click anywhere to jump there, or drag.
private struct SoundLevelSlider: View {
    @Binding var value: Double
    let muted: Bool
    @Environment(\.isEnabled) private var isEnabled
    private let height: CGFloat = 24
    private let step = 1.0 / 16

    var body: some View {
        GeometryReader { geometry in
            track(width: geometry.size.width)
        }
        .frame(height: height)
        .allowsHitTesting(isEnabled)
        .accessibilityElement()
        .accessibilityLabel("Output volume")
        .accessibilityValue(muted ? "Muted" : "\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + step)
            case .decrement: value = max(0, value - step)
            @unknown default: break
            }
        }
    }

    private var dimmed: Bool { muted || !isEnabled }

    private func track(width: CGFloat) -> some View {
        let level = min(1, max(0, value))
        let travel = max(1, width - height)
        let knobCenter = height / 2 + travel * CGFloat(level)
        let knob = height - 2
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.1))
            Capsule().fill(Color.white.opacity(dimmed ? 0.45 : 1))
                .frame(width: knobCenter + height / 2)
            Circle().fill(Color.white)
                .shadow(color: Color.black.opacity(0.22), radius: 1.5, y: 0.5)
                .frame(width: knob, height: knob)
                .offset(x: knobCenter - knob / 2)
            Image(systemName: symbol(level))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.black.opacity(dimmed ? 0.35 : 0.55))
                .frame(width: height + 4, height: height)
        }
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            value = Double(min(1, max(0, (drag.location.x - height / 2) / travel)))
        })
    }

    private func symbol(_ level: Double) -> String {
        if muted { return "speaker.slash.fill" }
        if level <= 0 { return "speaker.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
