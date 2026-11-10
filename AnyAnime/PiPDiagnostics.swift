import UIKit

/// DEBUG-only, whitelisted fields: no media URLs, headers, cookies or tokens.
enum PiPDiagnostics {
    @MainActor static func record(_ event: String, backend: String, sessionID: String,
                                  trigger: String, view: UIView?, time: Double,
                                  facts: [String: Bool] = [:]) {
        #if DEBUG
        let window = view?.window
        var value: [String: Any] = ["event": event, "backend": backend, "sessionID": sessionID,
            "trigger": trigger, "applicationState": UIApplication.shared.applicationState.rawValue,
            "sceneState": window?.windowScene?.activationState.rawValue ?? -1,
            "sourceAttached": window != nil, "time": time.isFinite ? time : 0,
            "uptime": ProcessInfo.processInfo.systemUptime]
        for (key, flag) in facts where ["frameReady", "outputPrimed", "possible", "supported", "pending", "active", "prepared"].contains(key) { value[key] = flag }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print("[PiP] " + line) }
        #endif
    }
}
