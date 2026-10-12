import AppKit

/// Installs the Voidamp Mic driver that ships inside Voidamp. Core Audio only loads drivers from
/// /Library/Audio/Plug-Ins/HAL, so installing needs an administrator password and restarts the audio system,
/// which silences every app for a moment.
@MainActor
final class VirtualMics: ObservableObject {
    static let shared = VirtualMics()
    nonisolated static let uidPrefix = "app.voidamp.mic."
    private static let installed = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/VoidampMic.driver")

    enum State: Equatable { case unavailable, notInstalled, outdated, installed }
    @Published private(set) var state = State.unavailable
    /// When Voidamp last installed the driver: the devices take a moment to appear afterwards.
    @Published private(set) var installedAt: Date?

    private var bundled: URL? { Bundle.main.url(forResource: "VoidampMic", withExtension: "driver") }

    init() { refresh() }

    func refresh() {
        let next: State
        guard let bundled else { state = Self.version(at: Self.installed) == nil ? .unavailable : .installed; return }
        switch (Self.version(at: Self.installed), Self.version(at: bundled)) {
        case (nil, _): next = .notInstalled
        case (let installed?, let shipped?) where installed < shipped: next = .outdated
        default: next = .installed
        }
        if next != state { state = next }
    }

    /// The driver's build number, which only changes when the driver does.
    private static func version(at url: URL) -> Int? {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return Int(info["CFBundleVersion"] as? String ?? "")
    }

    func install() {
        guard let bundled else { return }
        let alert = NSAlert()
        alert.messageText = state == .outdated ? "Update Voidamp’s Virtual Mics?" : "Add Voidamp’s Virtual Mics?"
        alert.informativeText = """
            Adds “Voidamp Mic 1” and “Voidamp Mic 2”. Choose one as the microphone in an app such as Discord, then wire a microphone or an app into it in the Suite.

            macOS asks for your password. Sound stops for a moment while the audio system restarts, including in calls.
            """
        alert.addButton(withTitle: state == .outdated ? "Update" : "Add Virtual Mics")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Copied beside the old driver first and checked, then swapped in, so a failed copy never leaves the audio
        // system without a driver or with a damaged one. The copy's name doesn't end in .driver, so Core Audio
        // ignores it until it is moved into place.
        let target = quoted(Self.installed.path)
        let staged = quoted(Self.installed.deletingLastPathComponent().appendingPathComponent(".VoidampMic.driver.new").path)
        let previous = quoted(Self.installed.deletingLastPathComponent().appendingPathComponent(".VoidampMic.driver.old").path)
        run("""
            set -e; mkdir -p /Library/Audio/Plug-Ins/HAL; rm -rf \(staged) \(previous); cp -R \(quoted(bundled.path)) \(staged); \
            codesign --verify --strict -R='identifier "app.voidamp.mic"' \(staged); chown -R root:wheel \(staged); \
            xattr -dr com.apple.quarantine \(staged) || true; if [ -e \(target) ]; then mv \(target) \(previous); fi; \
            if mv \(staged) \(target); then rm -rf \(previous); else mv \(previous) \(target); exit 1; fi; killall coreaudiod || true
            """, prompt: "Voidamp wants to add its virtual microphones.")
        installedAt = Date()
    }

    func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Remove Voidamp’s Virtual Mics?"
        alert.informativeText = "Apps using Voidamp Mic 1 or 2 lose that microphone. macOS asks for your password, and sound stops for a moment while the audio system restarts."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Wires into the virtual mics go too; otherwise an app sent only to a call would fall back to the speakers.
        for index in 1...2 { VoidampRuntime.shared.audio.clearWiring(output: Self.uidPrefix + String(index)) }
        run("rm -rf \(quoted(Self.installed.path)) && (killall coreaudiod || true)", prompt: "Voidamp wants to remove its virtual microphones.")
    }

    /// Runs a shell command as administrator through macOS's own password prompt.
    private func run(_ command: String, prompt: String) {
        let escape = { (text: String) in text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let source = "do shell script \"\(escape(command))\" with administrator privileges with prompt \"\(escape(prompt))\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        // -128: the person cancelled the password prompt.
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            VoidampRuntime.shared.audio.error = "Couldn’t change the virtual mics: \(error[NSAppleScript.errorMessage] as? String ?? "unknown error")."
        }
        refresh()
        // The audio system takes a moment to come back with the new devices.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { VoidampRuntime.shared.audio.refresh() }
    }

    private func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension AudioSource {
    /// One of Voidamp's own virtual microphones: apps record from its input, Voidamp plays into its output.
    var isVirtualMic: Bool { uid.hasPrefix(VirtualMics.uidPrefix) }
}
