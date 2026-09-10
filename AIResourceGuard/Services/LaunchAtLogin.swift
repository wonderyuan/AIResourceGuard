import Foundation
import ServiceManagement

/// Launch at Login via the public SMAppService API (macOS 13+).
/// Note: works best when the app sits at a stable path (e.g. /Applications).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
