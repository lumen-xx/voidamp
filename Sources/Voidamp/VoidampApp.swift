import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var audio: AudioController?
    private var focusObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let updater = AppUpdater()
        if CommandLine.arguments.contains("--updater-check") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if updater.canCheckForUpdates {
                    print("PASS: Sparkle initializes from the app bundle and can check for updates")
                    exit(0)
                }
                print("FAIL: Sparkle did not become ready to check for updates")
                exit(1)
            }
            return
        }
        let audio = AudioController()
        self.audio = audio
        let host = FirstClickHostingController(rootView: MixerView(audio: audio, updater: updater))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        focusObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusPanel() }
        })
        focusObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        })
        focusObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let window = notification.object as? NSWindow,
                      window === self.popover.contentViewController?.view.window else { return }
                DispatchQueue.main.async {
                    if self.popover.isShown, !window.isKeyWindow, window.attachedSheet == nil {
                        self.popover.performClose(nil)
                    }
                }
            }
        })
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Voidamp")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Voidamp"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.async { self.togglePanel() }
        }
    }
    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem?.button {
            NSApplication.shared.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            focusPanel()
            // Activation completes asynchronously when another app owns focus.
            DispatchQueue.main.async { self.focusPanel() }
        }
    }
    private func focusPanel() {
        guard popover.isShown, NSApplication.shared.isActive else { return }
        popover.contentViewController?.view.window?.makeKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        audio?.shutDown()
        focusObservers.forEach(NotificationCenter.default.removeObserver)
    }
}

@main
struct VoidampApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.contains("--route-check") {
            let controller = AudioController()
            controller.enableMixing()
            RunLoop.current.run(until: Date().addingTimeInterval(3))
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
            print("PASS: stable device order, profile persistence/deletion, 100% snapping and gain bounds")
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
                    Menu {
                        if audio.profiles.isEmpty { Text("No saved profiles") }
                        else {
                            ForEach(audio.profiles) { profile in
                                Toggle(profile.name, isOn: Binding(get: {
                                    audio.selectedProfile == profile.id
                                }, set: { selected in
                                    if selected { audio.applyProfile(profile) }
                                    else if audio.selectedProfile == profile.id { audio.selectedProfile = nil }
                                }))
                            }
                        }
                        Divider()
                        Button("Save current as profile…") { profileName = ""; savingProfile = true }
                        if let id = audio.selectedProfile {
                            Button("Delete selected profile", role: .destructive) { audio.deleteProfile(id) }
                        }
                        Divider()
                        Button("Clear current profile") { audio.selectedProfile = nil }
                            .disabled(audio.selectedProfile == nil)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: audio.selectedProfile == nil ? "square.stack" : "square.stack.fill")
                            Text(selectedProfileName ?? "Profiles").lineLimit(1).truncationMode(.tail)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                        }
                        .font(MixerStyle.caption)
                        .foregroundStyle(audio.selectedProfile == nil ? Color.secondary : Color.accentColor)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(maxWidth: .infinity)
                    .help(selectedProfileName.map { "Selected profile: \($0)" } ?? "Profiles")
                    .accessibilityLabel(selectedProfileName.map { "Profiles, \($0) selected" } ?? "Profiles")
                    Menu {
                        Button("Check for Updates…") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                        Button("Refresh sources") { audio.refresh() }
                        Divider()
                        Button("Quit Voidamp") { audio.shutDown(); NSApplication.shared.terminate(nil) }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "ellipsis")
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                        }.foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize().help("More").accessibilityLabel("More options")
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
                    if audio.apps.isEmpty {
                        Text("Play audio in an app to see it here.").font(MixerStyle.body).foregroundStyle(.secondary).padding(.vertical, 4)
                    }
                    ForEach(audio.apps) { app in appRow(app) }
                    if !audio.mixingEnabled {
                        Text("Turn on mixing to adjust each app.").font(MixerStyle.caption).foregroundStyle(.secondary)
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
            .scrollIndicators(.hidden)
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
        .alert("Audio control", isPresented: Binding(get: { audio.error != nil }, set: { if !$0 { audio.error = nil } })) {
            Button("OK") { audio.error = nil }
            Button("Retry app mixing") { audio.error = nil; audio.disableMixing(); audio.enableMixing() }
        } message: { Text(audio.error ?? "") }
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
        let routed = audio.appIsRouted(app)
        return HStack(spacing: 8) {
            if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
            Text(app.name).font(MixerStyle.body).lineLimit(1).frame(width: 80, alignment: .leading).help(app.name)
            Slider(value: Binding(get: { audio.apps.first(where: { $0.id == app.id })?.gain ?? app.gain }, set: { audio.setAppGain(app, $0, snapping: draggingApps.contains(app.id)) }), in: 0...2, onEditingChanged: { editing in
                    if editing { draggingApps.insert(app.id) } else { draggingApps.remove(app.id) }
                })
                .help("App volume · snaps to 100% · boost up to 200%")
                .disabled(!routed).accessibilityLabel("\(app.name) volume, up to 200 percent")
            Text("\(Int((app.gain * 100).rounded()))%").font(MixerStyle.value).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            Button { audio.toggleAppMute(app) } label: {
                Image(systemName: app.muted ? "speaker.slash" : "speaker.wave.1").frame(width: 14)
            }.buttonStyle(.plain).disabled(!routed).foregroundStyle(app.muted ? accent : .secondary)
                .help(app.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        }.opacity(routed ? 1 : 0.55)
    }
    private func deviceSection(_ title: String, input: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(MixerStyle.section).foregroundStyle(.tertiary)
            ForEach(audio.sources.filter { $0.input == input }) { source in
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: {
                        audio.sources.first(where: { $0.id == source.id })?.isDefault ?? source.isDefault
                    }, set: { selected in
                        if selected { audio.select(source) }
                    })) {
                        Text(audio.displayName(source)).font(MixerStyle.body).lineLimit(1)
                    }
                    .toggleStyle(.checkbox).controlSize(.small)
                    .frame(width: 138, alignment: .leading)
                    .help("Use \(audio.displayName(source)) · \(source.name)")
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
                        Spacer()
                        Text("Fixed").font(MixerStyle.caption).foregroundStyle(.tertiary).help("Volume is controlled by this device")
                    } else {
                        Slider(value: Binding(get: { audio.sources.first(where: { $0.id == source.id })?.volume ?? source.volume }, set: { audio.setVolume(source, $0) }), in: 0...1)
                            .disabled(input ? audio.micMuted : audio.soundMuted)
                            .accessibilityLabel("\(source.name) \(input ? "input gain" : "output volume")")
                        Text("\(Int((source.volume * 100).rounded()))%").font(MixerStyle.value).monospacedDigit().lineLimit(1).fixedSize().frame(width: 38, alignment: .trailing)
                    }
                }
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

// SwiftUI's indicator preference can be overridden by macOS's Always scroll-bar setting.
// Disable the actual AppKit scrollers while retaining wheel and trackpad scrolling.
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

// Deliver the activating mouse-down to controls instead of consuming it for focus.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FirstClickHostingController<Content: View>: NSHostingController<Content> {
    private let initialContent: Content
    override init(rootView: Content) {
        initialContent = rootView
        super.init(rootView: rootView)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }
    override func loadView() {
        view = FirstClickHostingView(rootView: initialContent)
    }
}
