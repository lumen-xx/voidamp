import AppKit
import SwiftUI
import Combine
import ApplicationServices

/// Replaces the system volume and brightness overlay while Voidamp runs. The keys are caught with an event tap
/// (Accessibility permission), applied by Voidamp, and shown in a glass pill centred on the display with the mouse. When Voidamp
/// quits the tap goes away and macOS shows its own overlay again. Keys Voidamp cannot apply, such as volume on a
/// device that controls its own level or brightness without a built-in display, are passed to macOS unchanged.
@MainActor
final class ControlOverlay {
    static let enabledKey = "controlOverlayEnabled"
    private static let promptedKey = "controlOverlayPrompted"

    private let audio: AudioController
    private let panelShown: () -> Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var trustTimer: Timer?
    private let model = OverlayModel()
    private lazy var window = OverlayWindow(model: model)
    private var hideWork: DispatchWorkItem?
    /// Watches the pointer while the card is up. The card lets clicks through to the window underneath until the
    /// pointer has moved onto it and rested briefly, so a click on a browser tab under it never sets the volume.
    private var hoverTimer: Timer?
    private var restingSince: Date?
    private var pointerAtShow = NSPoint.zero
    /// Keys whose press was handled, so their release is swallowed too and the two always agree.
    fileprivate var swallowedKeys: Set<Int32> = []

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey); newValue ? start(prompt: true) : stop() }
    }
    var trusted: Bool { AXIsProcessTrusted() }

    init(audio: AudioController, panelShown: @escaping () -> Bool) {
        self.audio = audio
        self.panelShown = panelShown
        model.setLevel = { [weak self] in self?.apply(level: $0) }
        model.toggleMute = { [weak self] in self?.toggleMute() }
        model.activeChanged = { [weak self] active in
            guard let self else { return }
            if active {
                self.hideWork?.cancel()
                // Caught while fading out: bring it back.
                if self.window.isVisible { NSAnimationContext.runAnimationGroup { $0.duration = 0.12; self.window.animator().alphaValue = 1 } }
            } else {
                self.scheduleHide()
            }
        }
    }

    /// Installs the tap, asking for Accessibility once; afterwards it waits quietly until permission is granted.
    func start(prompt: Bool = false) {
        guard enabled, tap == nil else { return }
        if !trusted {
            let firstTime = !UserDefaults.standard.bool(forKey: Self.promptedKey)
            if prompt || firstTime {
                UserDefaults.standard.set(true, forKey: Self.promptedKey)
                // The first time, say why before macOS asks; "Not Now" turns the overlay off instead.
                if firstTime && !prompt && !explainAccessibility() {
                    UserDefaults.standard.set(false, forKey: Self.enabledKey)
                    return
                }
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            trustTimer?.invalidate()
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.trusted else { return }
                    self.trustTimer?.invalidate(); self.trustTimer = nil
                    self.start()
                }
            }
            return
        }
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED: media and brightness keys
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                          callback: overlayTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func explainAccessibility() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Use Voidamp for the volume and brightness keys?"
        alert.informativeText = "Voidamp can show its own card when you change the volume or brightness. macOS asks you to allow Accessibility so Voidamp can see those keys; it doesn’t see anything you type. You can change this later in Voidamp’s Settings."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func stop() {
        trustTimer?.invalidate(); trustTimer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil; source = nil
        model.dragging = false
        window.orderOut(nil)
    }

    fileprivate func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    /// Applies a key press and returns whether it was handled. Unhandled keys reach macOS unchanged.
    fileprivate func handle(key: Int32, flags: NSEvent.ModifierFlags) -> Bool {
        // Option alone opens Sound or Displays settings in macOS; leave that to the system.
        if flags.contains(.option) && !flags.contains(.shift) { return false }
        let steps: Double = flags.contains(.option) && flags.contains(.shift) ? 64 : 16
        switch key {
        case NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE:
            guard let output = audio.sources.first(where: { !$0.input && $0.isDefault }), !output.channels.isEmpty else { return false }
            if key == NX_KEYTYPE_MUTE {
                audio.toggleSoundMute()
            } else {
                // However it was muted, turning the volume up or down should be heard.
                audio.unmuteSound()
                let current = audio.displayVolume(output)
                audio.setVolume(output, Self.step(current, up: key == NX_KEYTYPE_SOUND_UP, steps: steps))
            }
            let live = audio.sources.first(where: { $0.id == output.id }) ?? output
            show(.volume, level: audio.displayVolume(live), muted: soundIsMuted, title: audio.displayName(live))
            return true
        case NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN:
            guard let current = DisplayBrightness.level() else { return false }
            let next = Self.step(Double(current), up: key == NX_KEYTYPE_BRIGHTNESS_UP, steps: steps)
            guard DisplayBrightness.set(Float(next)) else { return false }
            show(.brightness, level: next, muted: false, title: DisplayBrightness.name)
            return true
        default:
            return false
        }
    }

    /// Muted by Voidamp or by the output's own mute switch.
    private var soundIsMuted: Bool {
        audio.soundMuted || (audio.sources.first(where: { !$0.input && $0.isDefault })?.hardwareMuted ?? false)
    }

    /// Moves to the next step on the grid, like the system: 16 steps, or 64 with Option-Shift.
    static func step(_ value: Double, up: Bool, steps: Double) -> Double {
        let position = (value * steps).rounded()
        return min(1, max(0, (position + (up ? 1 : -1)) / steps))
    }

    private func show(_ kind: OverlayModel.Kind, level: Double, muted: Bool, title: String) {
        model.kind = kind; model.level = level; model.muted = muted; model.title = title
        // Voidamp's own panel already shows the level.
        guard !panelShown() else { return }
        window.placeCentred()
        if !window.isVisible || window.alphaValue < 1 {
            if !window.isVisible {
                window.ignoresMouseEvents = true
                pointerAtShow = NSEvent.mouseLocation
                restingSince = nil
            }
            window.alphaValue = window.isVisible ? window.alphaValue : 0
            window.orderFrontRegardless()
            watchPointer()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; window.animator().alphaValue = 1 }
        }
        scheduleHide()
    }

    /// Fades the card out after a pause, unless the pointer is on it.
    private func scheduleHide() {
        hideWork?.cancel()
        guard !model.active else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.active else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; self.window.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated { if self.window.alphaValue == 0 { self.window.orderOut(nil) } }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func watchPointer() {
        guard hoverTimer == nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerTick() }
        }
        RunLoop.main.add(hoverTimer!, forMode: .common)
    }

    private func pointerTick() {
        guard window.isVisible else {
            hoverTimer?.invalidate(); hoverTimer = nil
            window.ignoresMouseEvents = true
            model.dragging = false
            model.hovering = false
            return
        }
        // A drag SwiftUI cancelled without ending: the button is up, so show the pointer again.
        if model.dragging, NSEvent.pressedMouseButtons == 0 { model.dragging = false }
        let pointer = NSEvent.mouseLocation
        let card = window.frame.insetBy(dx: 20, dy: 20)
        // A pointer that was already resting where the card appeared doesn't count until it moves.
        guard NSMouseInRect(pointer, card, false), pointer != pointerAtShow else {
            restingSince = nil
            if !model.dragging {
                window.ignoresMouseEvents = true
                model.hovering = false
            }
            return
        }
        let since = restingSince ?? Date()
        restingSince = since
        if Date().timeIntervalSince(since) >= 0.25 {
            window.ignoresMouseEvents = false
            model.hovering = true
        }
    }

    /// Sets the level from the card, when it is dragged or clicked.
    private func apply(level: Double) {
        let level = min(1, max(0, level))
        switch model.kind {
        case .volume:
            guard let output = audio.sources.first(where: { !$0.input && $0.isDefault }), !output.channels.isEmpty else { return }
            audio.unmuteSound()
            audio.setVolume(output, level)
            model.level = level; model.muted = false
        case .brightness:
            if DisplayBrightness.set(Float(level)) { model.level = level }
        }
    }

    private func toggleMute() {
        guard model.kind == .volume else { return }
        audio.toggleSoundMute()
        model.muted = soundIsMuted
    }
}

/// System-defined events carry media keys as subtype 8: the key code in the upper 16 bits of data1 and the
/// key state (0xA down, 0xB up) in bits 8–15.
private func overlayTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let overlay = Unmanaged<ControlOverlay>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { overlay.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let system = NSEvent(cgEvent: event), system.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
    let key = Int32((system.data1 & 0xFFFF0000) >> 16)
    let down = ((system.data1 & 0x0000FF00) >> 8) == 0xA
    guard [NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE, NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN].contains(key) else { return Unmanaged.passUnretained(event) }
    let flags = system.modifierFlags.intersection(.deviceIndependentFlagsMask)
    // The event tap runs on the main run loop, so the overlay can be used directly. A press is swallowed only when
    // Voidamp applied it; its release follows the press, so macOS never sees half a key.
    let swallow = MainActor.assumeIsolated { () -> Bool in
        if down {
            let handled = overlay.wouldHandle(key: key, flags: flags) && overlay.handle(key: key, flags: flags)
            if handled { overlay.swallowedKeys.insert(key) } else { overlay.swallowedKeys.remove(key) }
            return handled
        }
        return overlay.swallowedKeys.remove(key) != nil
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

extension ControlOverlay {
    /// Whether a key would be handled, decided before acting so presses and releases are treated alike.
    fileprivate func wouldHandle(key: Int32, flags: NSEvent.ModifierFlags) -> Bool {
        if flags.contains(.option) && !flags.contains(.shift) { return false }
        switch key {
        case NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE:
            return audio.sources.first(where: { !$0.input && $0.isDefault }).map { !$0.channels.isEmpty } ?? false
        case NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN:
            // Only the built-in display, and only with the pointer on it; other displays are macOS's to handle.
            return DisplayBrightness.level() != nil && DisplayBrightness.pointerOnBuiltIn
        default:
            return false
        }
    }
}

/// Hides the pointer while Voidamp is in the background. NSCursor.hide only works for the active app, so this asks
/// the window server to let a background app set the cursor first (a private call, skipped if it is missing).
@MainActor
enum BackgroundCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private static let graphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    private static var hidden = false

    static func hide() {
        guard !hidden else { return }
        if let graphics, let connection = dlsym(graphics, "_CGSDefaultConnection"), let set = dlsym(graphics, "CGSSetConnectionProperty") {
            let id = unsafeBitCast(connection, to: DefaultConnection.self)()
            _ = unsafeBitCast(set, to: SetProperty.self)(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        }
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
    }
    static func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }
}

/// Built-in display brightness through DisplayServices, the private framework macOS uses itself. There is no public
/// API for it; when the framework or a built-in display is missing, brightness keys go to macOS.
enum DisplayBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter: Get? = framework.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
    private static let setter: Set? = framework.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }

    static var builtIn: CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.first { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 }
    }
    /// Whether the pointer is on the built-in display, which the brightness keys then belong to.
    static var pointerOnBuiltIn: Bool {
        let mouse = NSEvent.mouseLocation
        guard let builtIn, let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return false }
        return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == builtIn
    }
    static var name: String {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == builtIn }?.localizedName ?? "Built-in Display"
    }
    static func level() -> Float? {
        guard let getter, let display = builtIn else { return nil }
        var value: Float = 0
        return getter(display, &value) == 0 ? value : nil
    }
    static func set(_ value: Float) -> Bool {
        guard let setter, let display = builtIn else { return false }
        return setter(display, min(1, max(0, value))) == 0
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    enum Kind { case volume, brightness }
    @Published var kind = Kind.volume
    @Published var level = 0.5
    @Published var muted = false
    /// The output device or display being changed.
    @Published var title = ""
    /// The pointer is on the card or dragging its bar; the card can be edited and stays up.
    @Published private(set) var active = false
    var hovering = false { didSet { updateActive() } }
    var dragging = false {
        didSet {
            guard dragging != oldValue else { return }
            // The pointer would cover the bar; it comes back where the drag ends.
            dragging ? BackgroundCursor.hide() : BackgroundCursor.show()
            updateActive()
        }
    }
    var setLevel: (Double) -> Void = { _ in }
    var toggleMute: () -> Void = {}
    var activeChanged: (Bool) -> Void = { _ in }

    private func updateActive() {
        let now = hovering || dragging
        guard now != active else { return }
        active = now
        activeChanged(now)
    }
}

/// A borderless panel above everything, on every Space and over full-screen apps. It never becomes key, so using it
/// leaves the focus where it was.
@MainActor
final class OverlayWindow: NSPanel {
    init(model: OverlayModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: OverlayCard.size.width + 40, height: OverlayCard.size.height + 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        // Clicks pass through until the pointer rests on the card; ControlOverlay switches this.
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        let host = OverlayHostingView(rootView: OverlayCard(model: model).padding(20))
        host.frame = contentRect(forFrameRect: frame)
        contentView = host
    }

    /// Places the card at the top centre of the display the mouse is on, just below the menu bar and notch.
    func placeCentred() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let size = frame.size
        // The visible frame stops below the menu bar; with the menu bar hidden, the notch's safe area still counts.
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        // The card sits 8 pt below that, inside the window's 20 pt margin.
        setFrameOrigin(NSPoint(x: (screen.frame.midX - size.width / 2).rounded(), y: (top - 8 + 20 - size.height).rounded()))
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click without activating Voidamp, once the card accepts clicks at all.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The card: a small icon, a thick level bar and a large icon on a rounded glass pill. With the pointer on it, the bar
/// can be dragged or clicked and the card stays up; clicking the speaker mutes.
struct OverlayCard: View {
    static let size = CGSize(width: 240, height: 48)
    @ObservedObject var model: OverlayModel
    @Environment(\.colorScheme) private var scheme
    /// One fixed ink per appearance. Liquid Glass adapts semantic colours to whatever is behind the card, which
    /// mixed dark and light parts over bright wallpapers.
    private var ink: Color { scheme == .dark ? .white : .black }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: lowSymbol).font(.system(size: 11, weight: .semibold)).frame(width: 16, height: 24)
                .contentTransition(.symbolEffect(.replace))
                .contentShape(Rectangle())
                .onTapGesture { model.toggleMute() }
            LevelBar(level: model.muted ? 0 : model.level, dimmed: model.muted, ink: ink, active: model.active,
                     changed: { model.setLevel($0) }, dragging: { model.dragging = $0 })
            Image(systemName: highSymbol).font(.system(size: 14, weight: .semibold)).frame(width: 22)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 16)
        .frame(width: Self.size.width, height: Self.size.height)
        .modifier(OverlaySurface())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.kind == .volume ? "Volume" : "Brightness"), \(model.title)")
        .accessibilityValue(model.muted ? "Muted" : "\(Int((model.level * 100).rounded())) percent")
    }

    private var lowSymbol: String {
        if model.kind == .brightness { return "sun.min.fill" }
        return model.muted ? "speaker.slash.fill" : "speaker.fill"
    }
    private var highSymbol: String { model.kind == .brightness ? "sun.max.fill" : "speaker.wave.3.fill" }
}

/// A thick rounded track with the filled level. It thickens slightly while the card is active, and dragging or
/// clicking anywhere along it sets the level.
private struct LevelBar: View {
    let level: Double
    let dimmed: Bool
    let ink: Color
    let active: Bool
    let changed: (Double) -> Void
    let dragging: (Bool) -> Void
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(0.16))
                Capsule().fill(ink.opacity(dimmed ? 0.4 : 0.95))
                    .frame(width: geometry.size.width * CGFloat(min(1, max(0, level))))
            }
            .frame(height: active ? 12 : 9)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragging(true)
                    changed(Double(value.location.x / max(1, geometry.size.width)))
                }
                .onEnded { _ in dragging(false) })
        }
        .frame(height: 28)
        .animation(.easeOut(duration: 0.15), value: active)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

/// A glass pill with the fade of the system's suggestion cards: deep and solid at the top, thinning out toward the
/// bottom edge so the backdrop shows through, with a faint light rim. Dark in dark mode, bright in light mode.
/// Material and a hairline before macOS 26.
private struct OverlaySurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = Capsule(style: .continuous)
        let dark = scheme == .dark
        let body = dark ? Color.black : Color.white
        // The fade: solid at the top, almost clear at the bottom edge.
        // Light mode keeps it thinner so more of the glass shows.
        let fade = LinearGradient(stops: [.init(color: body.opacity(dark ? 0.82 : 0.72), location: 0),
                                          .init(color: body.opacity(dark ? 0.6 : 0.5), location: 0.45),
                                          .init(color: body.opacity(dark ? 0.08 : 0.14), location: 1)],
                                  startPoint: .top, endPoint: .bottom)
        // A light rim, brightest along the top and bottom edges, like light caught in the glass.
        let rim = LinearGradient(stops: [.init(color: .white.opacity(dark ? 0.28 : 0.9), location: 0),
                                         .init(color: .white.opacity(0.02), location: 0.4),
                                         .init(color: .white.opacity(0.02), location: 0.7),
                                         .init(color: .white.opacity(dark ? 0.22 : 0.6), location: 1)],
                                 startPoint: .top, endPoint: .bottom)
        if #available(macOS 26.0, *) {
            content
                .background(fade.clipShape(shape))
                .overlay(shape.strokeBorder(rim, lineWidth: 1))
                .modifier(Glass(dark: dark, shape: shape))
                .shadow(color: .black.opacity(dark ? 0.35 : 0.12), radius: 14, y: 6)
        } else {
            content
                .background(fade.clipShape(shape))
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(rim, lineWidth: 1))
                .shadow(color: .black.opacity(dark ? 0.35 : 0.12), radius: 14, y: 6)
        }
    }
}

/// Liquid Glass in dark mode. Light mode looks through a lightly blurred backdrop instead, because the glass blurs
/// heavily and its blur cannot be adjusted; the white fade on top keeps it bright and readable.
@available(macOS 26.0, *)
private struct Glass: ViewModifier {
    let dark: Bool
    let shape: Capsule
    func body(content: Content) -> some View {
        if dark || !BackdropBlur.available {
            content.glassEffect(dark ? .regular : .clear, in: shape)
        } else {
            content.background(BackdropBlur(radius: 6).clipShape(shape))
        }
    }
}

/// The window server's backdrop layer, as used by NSVisualEffectView, with a blur radius of our choosing. Private
/// classes; when they are missing the light card falls back to Liquid Glass.
private struct BackdropBlur: NSViewRepresentable {
    let radius: CGFloat
    static var available: Bool { NSClassFromString("CABackdropLayer") != nil && NSClassFromString("CAFilter") != nil }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        guard let layerType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterType = NSClassFromString("CAFilter") as AnyObject? else { return view }
        let backdrop = layerType.init()
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        let selector = NSSelectorFromString("filterWithType:")
        if filterType.responds(to: selector), let blur = filterType.perform(selector, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject {
            blur.setValue(radius, forKey: "inputRadius")
            backdrop.filters = [blur]
        }
        view.layer?.addSublayer(backdrop)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Renders sample overlay cards for review, then quits. The glass needs a real window, so the backdrop is a gradient.
@MainActor
enum OverlaySnapshot {
    static func render(to path: String, dark: Bool) {
        let volume = OverlayModel(); volume.title = "MacBook Air Speakers"; volume.level = 0.625
        let muted = OverlayModel(); muted.title = "MacBook Air Speakers"; muted.muted = true
        let brightness = OverlayModel(); brightness.kind = .brightness; brightness.title = "Built-in Retina Display"; brightness.level = 0.8
        let view = VStack(spacing: 4) { ForEach(Array([volume, muted, brightness].enumerated()), id: \.offset) { OverlayCard(model: $0.element).padding(14) } }
            .padding(10)
            .background(LinearGradient(colors: dark ? [Color(white: 0.18), Color(red: 0.12, green: 0.16, blue: 0.24)] : [Color(white: 0.93), Color(red: 0.82, green: 0.86, blue: 0.93)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, dark ? .dark : .light)
        if CommandLine.arguments.contains("--live-window") {
            // Captures the real overlay panel, shown on screen, instead of an off-screen copy.
            let panel = OverlayWindow(model: volume)
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            panel.setFrameOrigin(NSPoint(x: 200, y: 400)); panel.alphaValue = 1; panel.orderFrontRegardless()
            // With --hold, the muted and brightness states are shown below for the same screenshot.
            var extras: [OverlayWindow] = []
            if CommandLine.arguments.contains("--hold") {
                for (index, model) in [muted, brightness].enumerated() {
                    let extra = OverlayWindow(model: model)
                    extra.appearance = panel.appearance
                    extra.setFrameOrigin(NSPoint(x: 200, y: 400 - CGFloat(index + 1) * 96)); extra.alphaValue = 1; extra.orderFrontRegardless()
                    extras.append(extra)
                }
            }
            _ = extras
            if CommandLine.arguments.contains("--hold") {
                // Keeps the panel on screen for an external screenshot.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let content = panel.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
            return
        }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = window.appearance
        window.contentView = host
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }
}
