import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// The Voidamp Suite: a node editor that wires apps and inputs to outputs. The sidebar lists everything that can
/// be wired; drag an item onto the board to place it. Sources have a port on their right edge, outputs on their
/// left. Drag between ports to connect; an app without wires plays on the default output, drawn as a faint
/// dashed wire when both are on the board. The mouse wheel zooms, dragging the empty board pans.
@MainActor
final class SuiteWindowController: NSObject, NSWindowDelegate {
    static let shared = SuiteWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Voidamp Suite"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.minSize = NSSize(width: 820, height: 480)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SuiteView(audio: VoidampRuntime.shared.audio))
            window.setFrameAutosaveName("VoidampSuite")
            if !window.setFrameUsingName("VoidampSuite") { window.center() }
            self.window = window
        }
        // A Dock icon and Command-Tab entry while the Suite is open, like any other window.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var windowNumber: Int? { window?.windowNumber }

    func windowWillClose(_ notification: Notification) {
        // Dropping the window stops its meters and animation.
        window?.contentView = nil
        window = nil
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

// MARK: Model

enum SuiteNodeKind { case app, input, output }

/// Something that can sit on the board: an app, an input or an output. Ids carry their kind: "app:", "in:", "out:".
struct SuiteItem: Identifiable, Equatable {
    let id: String
    let kind: SuiteNodeKind
    let title: String
    let icon: NSImage?
    let symbol: String
    var playing = false
    var isSource: Bool { kind != .output }

    static func == (lhs: SuiteItem, rhs: SuiteItem) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.playing == rhs.playing && lhs.symbol == rhs.symbol
    }
    /// The controller's id: the app id or the device UID.
    var key: String { String(id.drop { $0 != ":" }.dropFirst()) }
}

struct SuiteWire: Identifiable, Equatable {
    let from: String
    let to: String
    /// The implicit wire of an unconnected app to where it plays anyway; it can't be removed.
    let implicit: Bool
    /// Says why an implicit wire goes where it does: "default" or "app’s choice".
    var label: String? = nil
    var id: String { "\(from)→\(to)" }
}

enum SuiteMetrics {
    static let nodeSize = CGSize(width: 236, height: 108)
    static let port: CGFloat = 13
    static let zoomRange: ClosedRange<CGFloat> = 0.5...1.5
}

/// What is on the board, where, and the view onto it. Positions are board points; the screen shows
/// `board × zoom + pan`.
@MainActor
final class SuiteBoard: ObservableObject {
    @Published private(set) var placed: [String: CGPoint]
    /// Names of placed apps, so an app that isn't running keeps its node.
    @Published private(set) var names: [String: String]
    @Published var zoom: CGFloat
    @Published var pan: CGSize
    private let defaults = UserDefaults.standard

    init() {
        let stored = defaults.dictionary(forKey: "suiteBoard") as? [String: [Double]] ?? [:]
        placed = stored.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        names = defaults.dictionary(forKey: "suiteBoardNames") as? [String: String] ?? [:]
        let view = defaults.array(forKey: "suiteBoardView") as? [Double] ?? []
        zoom = view.count == 3 ? min(SuiteMetrics.zoomRange.upperBound, max(SuiteMetrics.zoomRange.lowerBound, view[0])) : 1
        pan = view.count == 3 ? CGSize(width: view[1], height: view[2]) : .zero
    }

    func place(_ item: SuiteItem, at origin: CGPoint) {
        placed[item.id] = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        if item.kind == .app { names[item.id] = item.title }
        save()
    }
    func move(_ id: String, to origin: CGPoint) {
        guard placed[id] != nil else { return }
        placed[id] = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        save()
    }
    func remove(_ id: String) {
        placed.removeValue(forKey: id)
        names.removeValue(forKey: id)
        save()
    }
    func clear() {
        placed = [:]; names = [:]
        save()
    }

    /// A free spot for an item added without dragging: below the others of its side.
    func freeSpot(for item: SuiteItem) -> CGPoint {
        let x: CGFloat = item.isSource ? 40 : 40 + SuiteMetrics.nodeSize.width + 260
        let sameSide = placed.filter { $0.key.hasPrefix("out:") == !item.isSource }.values
        let y = (sameSide.map(\.y).max().map { $0 + SuiteMetrics.nodeSize.height + 18 }) ?? 40
        return CGPoint(x: x, y: y)
    }

    func toScreen(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * zoom + pan.width, y: point.y * zoom + pan.height) }
    func toBoard(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - pan.width) / zoom, y: (point.y - pan.height) / zoom) }
    func screenFrame(_ id: String) -> CGRect? {
        guard let origin = placed[id] else { return nil }
        let size = SuiteMetrics.nodeSize
        return CGRect(origin: toScreen(origin), size: CGSize(width: size.width * zoom, height: size.height * zoom))
    }

    /// Zooms by `factor`, keeping the board point under `anchor` (a screen point) in place.
    func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let next = min(SuiteMetrics.zoomRange.upperBound, max(SuiteMetrics.zoomRange.lowerBound, zoom * factor))
        guard next != zoom else { return }
        let ratio = next / zoom
        pan = CGSize(width: anchor.x - (anchor.x - pan.width) * ratio, height: anchor.y - (anchor.y - pan.height) * ratio)
        zoom = next
        saveView()
    }
    func saveView() {
        defaults.set([Double(zoom), Double(pan.width), Double(pan.height)], forKey: "suiteBoardView")
    }
    private func save() {
        defaults.set(placed.mapValues { [Double($0.x), Double($0.y)] }, forKey: "suiteBoard")
        defaults.set(names, forKey: "suiteBoardNames")
        // In patchbay mode, placing an app without wires silences it.
        VoidampRuntime.shared.audio.boardChanged()
    }
}

extension SuiteBoard {
    /// Takes items off the board and removes their wires: a node you can't see never routes audio.
    func remove(_ ids: [String], audio: AudioController, catalog: [SuiteItem]) {
        for id in ids {
            if let item = catalog.first(where: { $0.id == id }) {
                switch item.kind {
                case .app: audio.clearWiring(audio.appSource(id: item.key, name: item.title, icon: item.icon))
                case .input: audio.clearWiring(input: item.key)
                case .output: audio.clearWiring(output: item.key)
                }
            }
            remove(id)
        }
    }
}

/// Regular apps that are running, so they can be wired before they play.
@MainActor
final class RunningApps: ObservableObject {
    @Published private(set) var apps: [NSRunningApplication] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }
    deinit { observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }

    private func refresh() {
        apps = NSWorkspace.shared.runningApplications.filter {
            guard $0.activationPolicy == .regular, let id = $0.bundleIdentifier else { return false }
            // Finder and Mail only play alerts, which System Sounds covers.
            return id != "app.voidamp.mac" && !AppSource.alertAppIDs.contains(id) && $0.processIdentifier != getpid()
        }
    }
}

/// Level meters, read about 30 times a second while the Suite is on screen, with a gentle fall-off.
@MainActor
final class SuiteMeters: ObservableObject {
    @Published private(set) var levels: [String: Double] = [:]
    @Published private(set) var phase: Double = 0
    private var timer: Timer?
    private weak var audio: AudioController?

    func start(_ audio: AudioController) {
        self.audio = audio
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let audio else { return }
        let peaks = audio.takePeaks()
        var next: [String: Double] = [:]
        let readings = peaks.sources.map { ("src:" + $0.key, $0.value) } + peaks.outputs.map { ("out:" + $0.key, $0.value) }
        for (id, peak) in readings {
            // Decibel scale over 60 dB, so quiet audio still moves the meter.
            let db = 20 * log10(max(Double(peak), 0.000_001))
            next[id] = max(0, min(1, (db + 60) / 60))
        }
        for (id, level) in levels where (next[id] ?? 0) < level {
            next[id] = max(next[id] ?? 0, level - 0.06)
        }
        next = next.filter { $0.value > 0.001 }
        if next != levels { levels = next }
        if !next.isEmpty { phase = (phase + 1.2).truncatingRemainder(dividingBy: 1000) }
    }
}

// MARK: Window content

struct SuiteView: View {
    @ObservedObject var audio: AudioController
    @StateObject private var board = SuiteBoard()
    @StateObject private var running = RunningApps()
    /// Held without observing: only the meters and wires redraw when levels change, not the whole editor.
    @State private var meters = SuiteMeters()

    var body: some View {
        let catalog = makeCatalog()
        NavigationSplitView {
            SuiteSidebar(audio: audio, board: board, catalog: catalog)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            SuiteCanvas(audio: audio, board: board, meters: meters, catalog: catalog)
        }
        .onAppear { meters.start(audio) }
        .onDisappear { meters.stop() }
        .alert("Audio control", isPresented: Binding(get: { audio.error != nil }, set: { if !$0 { audio.error = nil } })) {
            Button("OK") { audio.error = nil }
        } message: { Text(audio.error ?? "") }
    }

    /// Everything that can go on the board: apps playing, running or placed earlier, then inputs and outputs.
    private func makeCatalog() -> [SuiteItem] {
        var apps: [String: SuiteItem] = [:]
        for app in running.apps {
            guard let id = app.bundleIdentifier else { continue }
            apps["app:" + id] = SuiteItem(id: "app:" + id, kind: .app, title: app.localizedName ?? id, icon: app.icon, symbol: "app.dashed")
        }
        for (id, name) in board.names where apps[id] == nil {
            let key = String(id.dropFirst(4))
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key).map { NSWorkspace.shared.icon(forFile: $0.path) }
            apps[id] = SuiteItem(id: id, kind: .app, title: name, icon: icon, symbol: "app.dashed")
        }
        for app in audio.apps {
            let id = "app:" + app.id
            apps[id] = SuiteItem(id: id, kind: .app, title: app.name, icon: app.icon ?? apps[id]?.icon,
                                 symbol: app.isSystem ? "bell.fill" : "app.dashed", playing: app.isPlaying)
        }
        let sortedApps = apps.values.sorted {
            let systemA = $0.id == "app:" + AppSource.systemSoundsID, systemB = $1.id == "app:" + AppSource.systemSoundsID
            if systemA != systemB { return systemA }
            if $0.playing != $1.playing { return $0.playing }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        let inputs = audio.sources.filter(\.input).map {
            SuiteItem(id: "in:" + $0.uid, kind: .input, title: audio.displayName($0), icon: nil, symbol: "mic.fill")
        }
        let outputs = audio.sources.filter { !$0.input }.map {
            SuiteItem(id: "out:" + $0.uid, kind: .output, title: audio.displayName($0), icon: nil, symbol: Self.outputSymbol($0))
        }
        return sortedApps + inputs + outputs
    }

    static func outputSymbol(_ output: AudioSource) -> String {
        let name = output.name.lowercased()
        if name.contains("airpods") { return "airpods" }
        if ["headphone", "headset", "arctis", "evolve", "beats"].contains(where: name.contains) { return "headphones" }
        if ["display", "hdmi", "monitor", "tv", "i27"].contains(where: name.contains) { return "display" }
        if output.isBuiltIn || name.contains("macbook") { return "laptopcomputer" }
        return "hifispeaker"
    }
}

// MARK: Sidebar

private struct SuiteSidebar: View {
    @ObservedObject var audio: AudioController
    @ObservedObject var board: SuiteBoard
    let catalog: [SuiteItem]

    var body: some View {
        List {
            section("Apps", kind: .app)
            section("Inputs", kind: .input)
            section("Outputs", kind: .output)
        }
        .listStyle(.sidebar)
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom) { controls }
    }

    private func section(_ title: String, kind: SuiteNodeKind) -> some View {
        Section(title) {
            ForEach(catalog.filter { $0.kind == kind }) { item in
                row(item)
            }
        }
    }

    private func row(_ item: SuiteItem) -> some View {
        let onBoard = board.placed[item.id] != nil
        return HStack(spacing: 8) {
            Group {
                if let icon = item.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: item.symbol).foregroundStyle(.secondary) }
            }
            .frame(width: 18, height: 18)
            Text(item.title).lineLimit(1)
            Spacer(minLength: 4)
            if item.playing {
                Image(systemName: "waveform").font(.system(size: 10)).foregroundStyle(.secondary).help("Playing")
            }
            if onBoard {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tint).help("On the board")
            }
        }
        .contentShape(Rectangle())
        .draggable(item.id) {
            Label(item.title, systemImage: item.symbol).padding(6)
        }
        .contextMenu {
            if onBoard {
                Button("Remove from Board") { board.remove([item.id], audio: audio, catalog: catalog) }
            } else {
                Button("Add to Board") { board.place(item, at: board.freeSpot(for: item)) }
            }
        }
        .help(onBoard ? "\(item.title) is on the board" : "Drag \(item.title) onto the board")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Button { audio.toggleSoundMute() } label: {
                    Label("Sound", systemImage: audio.soundMuted ? "speaker.slash.fill" : "speaker.wave.2")
                        .frame(maxWidth: .infinity)
                }
                .help(audio.soundMuted ? "Unmute sound" : "Mute sound")
                Button { audio.toggleMicMute() } label: {
                    Label("Mic", systemImage: audio.micMuted ? "mic.slash.fill" : "mic")
                        .frame(maxWidth: .infinity)
                }
                .help(audio.micMuted ? "Unmute microphones" : "Mute microphones")
            }
            .controlSize(.small)
            if audio.captureBlocked {
                Label("Voidamp can’t hear apps", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                HStack {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") { NSWorkspace.shared.open(url) }
                    }
                    Button("Retry") { audio.retryMixing() }
                }
                .controlSize(.small)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14).padding(.bottom, 12)
    }
}

// MARK: Board

private struct SuiteCanvas: View {
    @ObservedObject var audio: AudioController
    @ObservedObject var board: SuiteBoard
    let meters: SuiteMeters
    let catalog: [SuiteItem]
    @State private var nodeDrag: (id: String, translation: CGSize)?
    @State private var panStart: CGSize?
    @State private var pending: (from: String, point: CGPoint)?
    @State private var selectedWire: String?
    @State private var hoveredTarget: String?
    @State private var magnifyStart: CGFloat?
    @State private var dropTargeted = false
    @State private var selectedNodes: Set<String> = []

    var body: some View {
        GeometryReader { geometry in
            let nodes = catalog.filter { board.placed[$0.id] != nil }
            let frames = screenFrames(nodes)
            let wires = makeWires(nodes)
            ZStack(alignment: .topLeading) {
                SuiteGrid(zoom: board.zoom, pan: board.pan)
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture(coordinateSpace: .named("canvas")) { point in
                        selectedWire = hitWire(at: point, wires: wires, frames: frames)
                        selectedNodes = []
                    }
                SuiteWires(wires: wires, frames: frames, pending: pendingLine(frames), selected: selectedWire, zoom: board.zoom,
                           paused: !audio.mixingEnabled || !audio.suiteEnabled, meters: meters)
                    .allowsHitTesting(false)
                ForEach(nodes) { item in
                    if let frame = frames[item.id] {
                        node(item, wires: wires, frame: frame)
                    }
                }
                if let selectedWire, let wire = wires.first(where: { $0.id == selectedWire && !$0.implicit }),
                   let from = frames[wire.from], let to = frames[wire.to] {
                    Button { disconnect(wire); self.selectedWire = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.red))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help("Disconnect")
                    .position(SuiteWires.midpoint(from: SuiteWires.start(from), to: SuiteWires.end(to)))
                }
                if nodes.isEmpty { emptyState.frame(width: geometry.size.width, height: geometry.size.height) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .coordinateSpace(name: "canvas")
            .background(CanvasEvents(onKey: handleKey) { delta, precise, point in
                if precise {
                    // Trackpad scrolling pans; the mouse wheel zooms.
                    board.pan.width += delta.width; board.pan.height += delta.height
                    board.saveView()
                } else if delta.height != 0 {
                    board.zoom(by: delta.height > 0 ? 1.1 : 1 / 1.1, around: point)
                }
            })
            .gesture(MagnifyGesture()
                .onChanged { value in
                    let start = magnifyStart ?? board.zoom
                    magnifyStart = start
                    board.zoom(by: start * value.magnification / board.zoom, around: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2))
                }
                .onEnded { _ in magnifyStart = nil })
            .dropDestination(for: String.self) { ids, location in
                drop(ids, at: location)
            } isTargeted: { dropTargeted = $0 }
            .overlay(alignment: .bottomTrailing) { zoomControl(size: geometry.size) }
            .overlay(alignment: .topTrailing) { suiteSwitch }
            .overlay(alignment: .top) { pausedNotice }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 2).padding(6).allowsHitTesting(false)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // The board runs up under the transparent title bar; there is no header.
        .ignoresSafeArea(.container, edges: .top)
    }

    /// Patchbay mode and the Suite's master switch, in the title bar's corner.
    private var suiteSwitch: some View {
        HStack(spacing: 16) {
            Toggle(isOn: $audio.patchbayMode) {
                Text("Patchbay").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .help(audio.patchbayMode ? "Patchbay: apps on the board play only where they’re wired; without a wire they’re silent."
                                     : "Turn on Patchbay so apps on the board play only where they’re wired. Apps not on the board play as usual.")
            Toggle(isOn: $audio.suiteEnabled) {
                Text("Suite").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .help(audio.suiteEnabled ? "Turn the Suite off: every app plays on the default output and monitoring stops. Your wiring is kept."
                                     : "Turn the Suite on to use your wiring again")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.top, 14).padding(.trailing, 16)
    }

    /// Why the wires are dashed: the Suite is off, or mixing is off in the menu bar.
    @ViewBuilder private var pausedNotice: some View {
        if !audio.suiteEnabled || !audio.mixingEnabled {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
                Text(audio.suiteEnabled ? "Mixing is off in the menu bar, so wires are paused." : "The Suite is off. Apps play on the default output.")
                    .font(.system(size: 12))
                if audio.suiteEnabled {
                    Button("Turn On Mixing") { audio.enableMixing() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .modifier(SuiteNodeSurface(highlighted: false, radius: 12))
            .padding(.top, 12)
        }
    }

    // MARK: Selection and keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let nodes = catalog.filter { board.placed[$0.id] != nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            if !selectedNodes.isEmpty {
                board.remove(Array(selectedNodes), audio: audio, catalog: catalog)
                selectedNodes = []; selectedWire = nil
                return true
            }
            if let selectedWire, let wire = makeWires(nodes).first(where: { $0.id == selectedWire && !$0.implicit }) {
                disconnect(wire); self.selectedWire = nil
                return true
            }
            return false
        case 0 where flags.contains(.command) || flags.contains(.control): // A
            selectedNodes = Set(nodes.map(\.id)); selectedWire = nil
            return true
        case 53: // Escape
            guard !selectedNodes.isEmpty || selectedWire != nil else { return false }
            selectedNodes = []; selectedWire = nil
            return true
        default:
            return false
        }
    }

    private func select(_ id: String) {
        selectedWire = nil
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
            if selectedNodes.contains(id) { selectedNodes.remove(id) } else { selectedNodes.insert(id) }
        } else {
            selectedNodes = [id]
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text("Drag apps, inputs and outputs here").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            Text("Then drag from a port to wire them together.").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .allowsHitTesting(false)
    }

    private func zoomControl(size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return HStack(spacing: 2) {
            Button { board.zoom(by: 1 / 1.1, around: center) } label: { Image(systemName: "minus").frame(width: 22, height: 20) }
                .help("Zoom out")
            Button { board.zoom(by: 1 / board.zoom, around: center) } label: {
                Text("\(Int((board.zoom * 100).rounded()))%").monospacedDigit().frame(width: 44, height: 20)
            }
            .help("Actual size")
            Button { board.zoom(by: 1.1, around: center) } label: { Image(systemName: "plus").frame(width: 22, height: 20) }
                .help("Zoom in")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .modifier(SuiteNodeSurface(highlighted: false, radius: 10))
        .padding(14)
    }

    // MARK: Nodes

    private func node(_ item: SuiteItem, wires: [SuiteWire], frame: CGRect) -> some View {
        let size = SuiteMetrics.nodeSize
        return nodeContent(item, wires: wires)
            .frame(width: size.width, height: size.height)
            .modifier(SuiteNodeSurface(highlighted: hoveredTarget == item.id || selectedNodes.contains(item.id)))
            .overlay(alignment: .top) {
                // The top strip moves the node.
                // The top strip selects the node on click and moves it on drag.
                Color.clear.frame(height: 40).contentShape(Rectangle())
                    .onTapGesture { select(item.id) }
                    .gesture(DragGesture(coordinateSpace: .named("canvas"))
                        .onChanged { nodeDrag = (item.id, $0.translation) }
                        .onEnded { value in
                            if let origin = board.placed[item.id] {
                                board.move(item.id, to: CGPoint(x: origin.x + value.translation.width / board.zoom,
                                                                y: origin.y + value.translation.height / board.zoom))
                            }
                            nodeDrag = nil
                        })
            }
            .contextMenu { contextMenu(item, wires: wires) }
            .scaleEffect(board.zoom)
            .position(x: frame.midX, y: frame.midY)
            .overlay {
                port(item, wires: wires, frame: frame)
            }
    }

    @ViewBuilder
    private func nodeContent(_ item: SuiteItem, wires: [SuiteWire]) -> some View {
        switch item.kind {
        case .app:
            SuiteAppNode(audio: audio, app: audio.appSource(id: item.key, name: item.title, icon: item.icon), meters: meters,
                         wires: wires.filter { $0.from == item.id })
        case .input:
            if let input = audio.sources.first(where: { $0.input && $0.uid == item.key }) {
                SuiteInputNode(audio: audio, input: input, meters: meters)
            }
        case .output:
            if let output = audio.sources.first(where: { !$0.input && $0.uid == item.key }) {
                SuiteOutputNode(audio: audio, output: output, meters: meters, symbol: item.symbol)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ item: SuiteItem, wires: [SuiteWire]) -> some View {
        let removable = wires.filter { !$0.implicit && ($0.from == item.id || $0.to == item.id) }
        if !removable.isEmpty {
            Button(item.kind == .app ? "Back to Default Output" : "Disconnect All") { removable.forEach(disconnect) }
        }
        if item.kind == .output, let output = audio.sources.first(where: { !$0.input && $0.uid == item.key }), !output.isDefault {
            Button("Use as Default Output") { audio.select(output) }
        }

        if item.kind == .input, let input = audio.sources.first(where: { $0.input && $0.uid == item.key }), !input.isDefault {
            Button("Use as Default Microphone") { audio.select(input) }
        }
        Divider()
        Button(selectedNodes.count > 1 && selectedNodes.contains(item.id) ? "Remove \(selectedNodes.count) Items from Board" : "Remove from Board") {
            let ids = selectedNodes.contains(item.id) ? Array(selectedNodes) : [item.id]
            board.remove(ids, audio: audio, catalog: catalog)
            selectedNodes.subtract(ids)
        }
    }

    // MARK: Geometry

    private func screenFrames(_ nodes: [SuiteItem]) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for item in nodes {
            guard var frame = board.screenFrame(item.id) else { continue }
            if let nodeDrag, nodeDrag.id == item.id { frame = frame.offsetBy(dx: nodeDrag.translation.width, dy: nodeDrag.translation.height) }
            frames[item.id] = frame
        }
        return frames
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let start = panStart ?? board.pan
                panStart = start
                board.pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { _ in panStart = nil; board.saveView() }
    }

    private func drop(_ ids: [String], at location: CGPoint) -> Bool {
        var offset: CGFloat = 0
        var placedAny = false
        for id in ids {
            guard let item = catalog.first(where: { $0.id == id }) else { continue }
            let center = board.toBoard(location)
            board.place(item, at: CGPoint(x: center.x - SuiteMetrics.nodeSize.width / 2 + offset, y: center.y - SuiteMetrics.nodeSize.height / 2 + offset))
            offset += 24
            placedAny = true
        }
        return placedAny
    }

    // MARK: Wiring

    private func makeWires(_ nodes: [SuiteItem]) -> [SuiteWire] {
        let onBoard = Set(nodes.map(\.id))
        var wires: [SuiteWire] = []
        let outputs = audio.sources.filter { !$0.input }
        let defaultOutput = outputs.first(where: \.isDefault)
        for item in nodes where item.kind == .app {
            let app = audio.appSource(id: item.key, name: item.title, icon: item.icon)
            let wired = audio.wiredOutputs(app).filter { uid in outputs.contains { $0.uid == uid } }
            if app.isSystem, let alert = wired.first {
                let onDefault = alert == defaultOutput?.uid
                wires.append(SuiteWire(from: item.id, to: "out:" + alert, implicit: onDefault, label: onDefault ? "default" : nil))
            } else if wired.isEmpty, audio.isSilencedByPatchbay(app) {
                // Patchbay: nothing plays it, so no line.
                continue
            } else if wired.isEmpty, let target = audio.unwiredOutput(app) {
                // Unwired apps play where they would anyway: their own output setting, or the default output.
                let label = target.uid == defaultOutput?.uid ? "default" : "app’s choice"
                wires.append(SuiteWire(from: item.id, to: "out:" + target.uid, implicit: true, label: label))
            } else {
                wires += wired.map { SuiteWire(from: item.id, to: "out:" + $0, implicit: false) }
            }
        }
        for item in nodes where item.kind == .input {
            guard let input = audio.sources.first(where: { $0.input && $0.uid == item.key }) else { continue }
            for uid in audio.monitorOutputs(input) where outputs.contains(where: { $0.uid == uid }) {
                wires.append(SuiteWire(from: item.id, to: "out:" + uid, implicit: false))
            }
            // Apps recording from this microphone, chosen in the app's own settings: shown, not wireable.
            for id in audio.appIDsUsing(input: input) where onBoard.contains("app:" + id) {
                wires.append(SuiteWire(from: item.id, to: "app:" + id, implicit: true, label: "mic in use"))
            }
        }
        // Only wires whose two ends are on the board are drawn.
        return wires.filter { onBoard.contains($0.from) && onBoard.contains($0.to) }
    }

    private func port(_ item: SuiteItem, wires: [SuiteWire], frame: CGRect) -> some View {
        let connected = wires.contains { !$0.implicit && ($0.from == item.id || $0.to == item.id) }
        let center = item.isSource ? SuiteWires.start(frame) : SuiteWires.end(frame)
        return SuitePort(connected: connected, active: hoveredTarget == item.id)
            .position(center)
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                .onChanged { value in
                    pending = (item.id, value.location)
                    hoveredTarget = target(at: value.location, from: item)
                }
                .onEnded { value in
                    if let target = target(at: value.location, from: item) {
                        connect(item.isSource ? item.id : target, item.isSource ? target : item.id)
                    }
                    pending = nil
                    hoveredTarget = nil
                })
            .help(item.isSource ? "Drag to an output" : "Drag to a source")
    }

    /// The node under the pointer that a wire from `item` can end on: anywhere on a node of the other side.
    private func target(at point: CGPoint, from item: SuiteItem) -> String? {
        let nodes = catalog.filter { board.placed[$0.id] != nil && $0.isSource != item.isSource }
        return nodes.first { board.screenFrame($0.id)?.insetBy(dx: -14, dy: -6).contains(point) ?? false }?.id
    }

    private func pendingLine(_ frames: [String: CGRect]) -> (CGPoint, CGPoint)? {
        guard let pending, let frame = frames[pending.from] else { return nil }
        return pending.from.hasPrefix("out:") ? (pending.point, SuiteWires.end(frame)) : (SuiteWires.start(frame), pending.point)
    }

    private func connect(_ sourceID: String, _ outputID: String) {
        guard let output = audio.sources.first(where: { !$0.input && "out:" + $0.uid == outputID }),
              let item = catalog.first(where: { $0.id == sourceID }) else { return }
        if item.kind == .app {
            audio.connect(audio.appSource(id: item.key, name: item.title, icon: item.icon), to: output)
        } else if let input = audio.sources.first(where: { $0.input && $0.uid == item.key }) {
            audio.connect(input: input, to: output)
        }
    }

    private func disconnect(_ wire: SuiteWire) {
        guard !wire.implicit, let item = catalog.first(where: { $0.id == wire.from }) else { return }
        let outputUID = String(wire.to.dropFirst(4))
        if item.kind == .app {
            audio.disconnect(audio.appSource(id: item.key, name: item.title, icon: item.icon), from: outputUID)
        } else if let input = audio.sources.first(where: { $0.input && $0.uid == item.key }) {
            audio.disconnect(input: input, from: outputUID)
        }
    }

    private func hitWire(at point: CGPoint, wires: [SuiteWire], frames: [String: CGRect]) -> String? {
        wires.reversed().first { wire in
            guard !wire.implicit, let from = frames[wire.from], let to = frames[wire.to] else { return false }
            return SuiteWires.path(from: SuiteWires.start(from), to: SuiteWires.end(to), zoom: board.zoom)
                .strokedPath(StrokeStyle(lineWidth: 14, lineCap: .round)).contains(point)
        }?.id
    }
}

/// Reports mouse wheel and trackpad scrolling over the board, and key presses in its window, which SwiftUI
/// doesn't expose reliably on macOS 14.
private struct CanvasEvents: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool
    let onScroll: (CGSize, Bool, CGPoint) -> Void
    func makeNSView(context: Context) -> CanvasEventView { CanvasEventView() }
    func updateNSView(_ view: CanvasEventView, context: Context) { view.onScroll = onScroll; view.onKey = onKey }
}

private final class CanvasEventView: NSView {
    var onScroll: ((CGSize, Bool, CGPoint) -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    private var monitors: [Any] = []
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitors()
        guard window != nil else { return }
        // Monitors, because the nodes above this view would otherwise receive the wheel first.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            self.onScroll?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), event.hasPreciseScrollingDeltas, point)
            return nil
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // Typing in a text field keeps its keys.
            if event.window?.firstResponder is NSText { return event }
            return self.onKey?(event) == true ? nil : event
        }) { monitors.append(monitor) }
    }
    override func removeFromSuperview() {
        removeMonitors()
        super.removeFromSuperview()
    }
    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

// MARK: Pieces

private struct SuiteGrid: View {
    let zoom: CGFloat
    let pan: CGSize
    var body: some View {
        Canvas { context, size in
            let spacing = 22 * zoom
            let dot = max(1.2, 1.8 * zoom)
            var dots = Path()
            var y = pan.height.truncatingRemainder(dividingBy: spacing)
            if y < 0 { y += spacing }
            while y < size.height {
                var x = pan.width.truncatingRemainder(dividingBy: spacing)
                if x < 0 { x += spacing }
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                    x += spacing
                }
                y += spacing
            }
            context.fill(dots, with: .color(.primary.opacity(0.1)))
        }
    }
}

/// Wires as curves from a source's right edge to an output's left edge, in screen points. Wires carrying audio
/// through Voidamp glow and flow; the implicit default wire is faint and dashed.
private struct SuiteWires: View {
    let wires: [SuiteWire]
    let frames: [String: CGRect]
    let pending: (CGPoint, CGPoint)?
    let selected: String?
    let zoom: CGFloat
    /// The Suite or mixing is off: wires are kept but carry nothing.
    let paused: Bool
    @ObservedObject var meters: SuiteMeters

    var body: some View {
        Canvas { context, _ in
            let width = max(1.5, 2.5 * zoom)
            for wire in wires {
                guard let from = frames[wire.from], let to = frames[wire.to] else { continue }
                let path = Self.path(from: Self.start(from), to: Self.end(to), zoom: zoom)
                let color = SuitePalette.color(for: wire.from)
                let key = String(wire.from.drop { $0 != ":" }.dropFirst())
                let level = meters.levels["src:" + key] ?? 0
                if wire.implicit || paused {
                    context.stroke(path, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: width * 0.65, lineCap: .round, dash: [5 * zoom, 5 * zoom]))
                    if wire.implicit, let label = wire.label, zoom >= 0.7 {
                        // Named, so a dashed wire isn't mistaken for one you made.
                        let mid = Self.midpoint(from: Self.start(from), to: Self.end(to))
                        let text = context.resolve(Text(label).font(.system(size: 10 * zoom, weight: .medium)).foregroundStyle(.secondary))
                        let size = text.measure(in: CGSize(width: 200, height: 40))
                        let pill = CGRect(x: mid.x - size.width / 2 - 6 * zoom, y: mid.y - size.height / 2 - 2 * zoom,
                                          width: size.width + 12 * zoom, height: size.height + 4 * zoom)
                        context.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(Color(nsColor: .windowBackgroundColor)))
                        context.stroke(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                        context.draw(text, at: mid)
                    }
                    continue
                }
                let isSelected = wire.id == selected
                if level > 0 || isSelected {
                    context.stroke(path, with: .color(color.opacity(isSelected ? 0.35 : 0.25 * level)), style: StrokeStyle(lineWidth: width * (isSelected ? 4 : 3.2), lineCap: .round))
                }
                context.stroke(path, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: isSelected ? width * 1.4 : width, lineCap: .round))
                if level > 0 {
                    // Audio flowing toward the output.
                    context.stroke(path, with: .color(.white.opacity(0.55 * level)),
                                   style: StrokeStyle(lineWidth: width * 0.65, lineCap: .round, dash: [2 * zoom, 12 * zoom], dashPhase: -meters.phase * 4 * zoom))
                }
            }
            if let pending {
                let path = Self.path(from: pending.0, to: pending.1, zoom: zoom)
                context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [6, 4]))
            }
        }
    }

    static func start(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.maxX, y: frame.midY) }
    static func end(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.minX, y: frame.midY) }
    static func path(from a: CGPoint, to b: CGPoint, zoom: CGFloat) -> Path {
        let pull = max(60 * zoom, abs(b.x - a.x) * 0.45)
        var path = Path()
        path.move(to: a)
        path.addCurve(to: b, control1: CGPoint(x: a.x + pull, y: a.y), control2: CGPoint(x: b.x - pull, y: b.y))
        return path
    }
    static func midpoint(from a: CGPoint, to b: CGPoint) -> CGPoint {
        // The cubic's midpoint with symmetric handles is the average of its ends.
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

/// A steady colour per source, so wires from the same source match.
enum SuitePalette {
    private static let colors: [Color] = [
        Color(red: 0.36, green: 0.62, blue: 1.0), Color(red: 0.98, green: 0.55, blue: 0.24), Color(red: 0.33, green: 0.82, blue: 0.56),
        Color(red: 0.86, green: 0.42, blue: 0.95), Color(red: 1.0, green: 0.78, blue: 0.2), Color(red: 0.24, green: 0.82, blue: 0.86),
        Color(red: 1.0, green: 0.42, blue: 0.52), Color(red: 0.62, green: 0.56, blue: 1.0)
    ]
    static func color(for id: String) -> Color {
        // A stable hash: Swift's String hash changes between launches.
        let value = id.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return colors[Int(value % UInt32(colors.count))]
    }
}

private struct SuitePort: View {
    let connected: Bool
    let active: Bool
    @State private var hovering = false
    var body: some View {
        ZStack {
            Circle().fill(Color(nsColor: .windowBackgroundColor))
            Circle().strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
            if connected || active { Circle().fill(Color.primary.opacity(0.75)).padding(3.5) }
        }
        .frame(width: SuiteMetrics.port, height: SuiteMetrics.port)
        .scaleEffect(hovering || active ? 1.3 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering || active)
        .padding(8) // A larger target than the dot.
        .contentShape(Circle())
        .onHover { hovering = $0 }
    }
}

private struct SuiteNodeSurface: ViewModifier {
    let highlighted: Bool
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        }
        .overlay(shape.strokeBorder(highlighted ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: highlighted ? 2 : 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

/// A thin level meter that reddens near clipping.
private struct SuiteMeter: View {
    let level: Double
    let live: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(level > 0.92 ? Color.red : Color.primary.opacity(0.7))
                    .frame(width: geometry.size.width * level)
            }
        }
        .frame(height: 3)
        .opacity(live ? 1 : 0.4)
    }
}

private struct SuiteNodeHeader: View {
    let icon: AnyView
    let title: String
    let status: String
    var statusColor: Color = .secondary
    var body: some View {
        HStack(spacing: 9) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(status).font(.system(size: 11)).foregroundStyle(statusColor).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .help(title)
    }
}

private struct SuiteAppNode: View {
    @ObservedObject var audio: AudioController
    let app: AppSource
    @ObservedObject var meters: SuiteMeters
    let wires: [SuiteWire]
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SuiteNodeHeader(icon: AnyView(icon), title: app.name, status: status, statusColor: audio.routeFailures[app.id] == nil ? .secondary : .orange)
            SuiteMeter(level: meters.levels["src:" + app.id] ?? 0, live: audio.isRouted(app.id))
            HStack(spacing: 8) {
                Slider(value: Binding(get: { app.gain }, set: { audio.setAppGain(app, $0, snapping: dragging) }), in: 0...2,
                       onEditingChanged: { dragging = $0 })
                    .controlSize(.small)
                    .disabled(!audio.canAdjust(app))
                    .accessibilityLabel("\(app.name) volume, up to 200 percent")
                Button { audio.setAppGain(app, 1) } label: {
                    Text("\(Int((app.gain * 100).rounded()))%").font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
                .buttonStyle(.plain).disabled(!audio.canAdjust(app)).help("Reset to 100%")
                Button { audio.toggleAppMute(app) } label: {
                    Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.1").frame(width: 16)
                }
                .buttonStyle(.plain).foregroundStyle(app.muted ? Color.accentColor : .secondary)
                .disabled(!audio.canAdjust(app)).help(app.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .opacity(app.isPlaying || app.isSystem ? 1 : 0.75)
    }

    @ViewBuilder private var icon: some View {
        if let image = app.icon { Image(nsImage: image).resizable() }
        else { Image(systemName: app.isSystem ? "bell.fill" : "app.dashed").font(.system(size: 15)).foregroundStyle(.secondary) }
    }

    private var status: String {
        if let failure = audio.routeFailures[app.id] {
            return failure == .noAudio ? "Can’t hear it · plays normally" : "Can’t route · plays normally"
        }
        if app.isSystem { return "Alerts and sound effects" }
        let missing = audio.wiredOutputs(app).filter { uid in !audio.sources.contains { !$0.input && $0.uid == uid } }
        if !missing.isEmpty, wires.allSatisfy(\.implicit) { return "Output disconnected · on default" }
        if app.muted { return "Muted" }
        if audio.isSilencedByPatchbay(app) { return "Silent · wire it to an output" }
        guard app.isPlaying else { return "Not playing" }
        return wires.allSatisfy(\.implicit) ? (wires.first?.label == "app’s choice" ? "Playing on its own output" : "Playing on default") : "Playing"
    }
}

private struct SuiteInputNode: View {
    @ObservedObject var audio: AudioController
    let input: AudioSource
    @ObservedObject var meters: SuiteMeters

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SuiteNodeHeader(icon: AnyView(Image(systemName: "mic.fill").font(.system(size: 15)).foregroundStyle(.secondary)),
                            title: audio.displayName(input), status: status, statusColor: statusColor)
            SuiteMeter(level: meters.levels["src:" + input.uid] ?? 0, live: audio.isRouted(input.uid))
            HStack(spacing: 8) {
                Slider(value: Binding(get: { audio.monitorGain(input) }, set: { audio.setMonitorGain(input, MixerGain.adjusted($0, snapping: true)) }), in: 0...2)
                    .controlSize(.small)
                    .accessibilityLabel("\(audio.displayName(input)) monitoring level")
                Text("\(Int((audio.monitorGain(input) * 100).rounded()))%").font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                Image(systemName: audio.micMuted ? "mic.slash.fill" : "mic").frame(width: 16)
                    .foregroundStyle(audio.micMuted ? Color.accentColor : .secondary)
                    .help(audio.micMuted ? "Microphones are muted" : "Monitoring level")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var feedbackRisk: Bool {
        input.isBuiltIn && audio.monitorOutputs(input).contains { uid in audio.sources.contains { !$0.input && $0.uid == uid && $0.isBuiltIn } }
    }
    private var status: String {
        if let failure = audio.monitorFailures[input.uid] { return failure }
        if feedbackRisk { return "May feed back on the speakers" }
        if audio.micMuted { return "Muted" }
        // Which apps record from this microphone; each app picks its own input in its settings.
        let users = audio.appsUsing(input: input)
        let state = !users.isEmpty ? "Used by " + users.joined(separator: ", ")
            : audio.monitorOutputs(input).isEmpty ? "Wire to an output to listen" : "Monitoring"
        return input.isDefault ? "Default · " + state : state
    }
    private var statusColor: Color { audio.monitorFailures[input.uid] != nil || feedbackRisk ? .orange : .secondary }
}

private struct SuiteOutputNode: View {
    @ObservedObject var audio: AudioController
    let output: AudioSource
    @ObservedObject var meters: SuiteMeters
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SuiteNodeHeader(icon: AnyView(Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(output.isDefault ? Color.accentColor : .secondary)),
                            title: audio.displayName(output), status: status)
            SuiteMeter(level: meters.levels["out:" + output.uid] ?? 0, live: true)
            HStack(spacing: 8) {
                if output.channels.isEmpty {
                    Text("Volume is set on the device").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                } else {
                    Slider(value: Binding(get: { audio.displayVolume(output) }, set: { audio.setVolume(output, $0) }), in: 0...1)
                        .controlSize(.small)
                        .accessibilityLabel("\(audio.displayName(output)) volume")
                    Text("\(Int((audio.displayVolume(output) * 100).rounded()))%").font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
                if audio.sharesSource(output) || audio.syncOffset(output) != 0 {
                    SuiteSyncButton(audio: audio, output: output)
                }
                let muted = audio.isMuted(output)
                Button { audio.toggleMute(output: output) } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.1").frame(width: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(muted ? Color.accentColor : .secondary)
                .disabled(!audio.canMute(output))
                .help(!audio.canMute(output) ? "\(audio.displayName(output)) can’t be muted from the Mac" : muted ? "Unmute \(audio.displayName(output))" : "Mute \(audio.displayName(output))")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var status: String {
        let alerts = audio.alertOutput?.uid == output.uid
        var parts: [String] = []
        if output.isDefault { parts.append("Default") }
        if alerts { parts.append("alerts") }
        if audio.isMuted(output) { parts.append("muted") }
        // Held back so it plays in step with a slower output carrying the same app.
        let delay = audio.syncDelay(output)
        if delay >= 1 { parts.append("synced +\(Int(delay.rounded())) ms") }
        let text = parts.joined(separator: " · ")
        return text.isEmpty ? "Output" : text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Fine-tunes how much an output is held back, live, while the same app plays on another output. Device latency
/// reports are estimates; Bluetooth speakers often report far less than they really take.
private struct SuiteSyncButton: View {
    @ObservedObject var audio: AudioController
    let output: AudioSource
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "metronome").frame(width: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(audio.syncOffset(output) != 0 ? Color.accentColor : .secondary)
        .help("Sync with the other outputs")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sync \(audio.displayName(output))").font(.system(size: 13, weight: .semibold))
                Text("Play something on both outputs and move the slider until they sound as one. Move right if this output is early, left if it’s late.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { audio.syncOffset(output) }, set: { audio.setSyncOffset(output, milliseconds: ($0 / 5).rounded() * 5) }), in: -300...500)
                    Text(offsetText).font(.system(size: 11)).monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                HStack {
                    Text("Held back \(Int(audio.syncDelay(output).rounded())) ms in total").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Reset") { audio.setSyncOffset(output, milliseconds: 0) }.controlSize(.small).disabled(audio.syncOffset(output) == 0)
                }
            }
            .padding(14)
            .frame(width: 300)
        }
    }

    private var offsetText: String {
        let value = Int(audio.syncOffset(output))
        return value == 0 ? "0 ms" : "\(value > 0 ? "+" : "−")\(abs(value)) ms"
    }
}
