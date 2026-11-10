import Foundation

/// A snapshot cannot end an active presentation. Only its matching stopped
/// event can. Timeouts and late replies cannot complete a replacement request.
struct WebPiPSessionState {
    private(set) var sessionID: String?
    private(set) var requestID: String?
    private(set) var supported = false
    private(set) var pending = false
    private(set) var active = false
    private(set) var error = ""

    mutating func begin(requestID: String) -> String? {
        guard supported, !pending, !active, let sessionID else { return nil }
        self.requestID = requestID; pending = true; error = ""
        return sessionID
    }

    mutating func snapshot(_ state: [String: Any]) {
        guard let session = state["pipSessionID"] as? String, !session.isEmpty else { return }
        let request = state["pipRequestID"] as? String ?? ""
        if pending || active {
            guard session == sessionID, request == requestID else { return }
        } else if sessionID != session {
            sessionID = session; requestID = nil; error = ""
        }
        supported = state["pipSupported"] as? Bool == true
        if state["pipActive"] as? Bool == true {
            requestID = request; active = true; pending = false; error = ""
        } else if !active, state["pipPending"] as? Bool != true, request == requestID {
            pending = false; error = state["pipError"] as? String ?? ""
        }
    }

    mutating func event(_ state: [String: String]) {
        guard state["sessionID"] == sessionID, state["requestID"] == requestID else { return }
        switch state["status"] {
        case "active": active = true; pending = false; error = ""
        case "stopped": active = false; pending = false; error = ""
        case "error" where !active: pending = false; error = state["error"] ?? "rejected"
        default: break
        }
    }

    mutating func fail(requestID: String, sessionID: String, reason: String) {
        guard self.requestID == requestID, self.sessionID == sessionID, pending, !active else { return }
        pending = false; error = reason
    }
}
