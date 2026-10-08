import AppKit
import Combine
import ServiceManagement

@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published var error: String?
    private var activation: AnyCancellable?

    init() {
        refresh()
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        let status = SMAppService.mainApp.status
        needsApproval = status == .requiresApproval
        enabled = status == .enabled || needsApproval
    }
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else { try SMAppService.mainApp.unregister() }
            refresh()
            if needsApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            self.error = "Couldn’t change Start at Login: \(error.localizedDescription)"
            refresh()
        }
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
