import AppKit
import IslandCore

/// Presents duplicate-email messages in a user-visible alert (not console-only).
enum ClaudeDuplicateEmailUI {
    @MainActor
    static func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Claude account already connected"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
