import Foundation
import SwiftUI

/// Everything the menu and the Diagnostics tab display. Updated on the main thread only.
final class StatusModel: ObservableObject {
    @Published var summary = "Starting…"
    @Published var trackpad = "—"
    @Published var scrollTap = "—"
    @Published var playback = "—"
    @Published var volume = "—"
    @Published var brightness = "—"
    @Published var haptics = "Request is issued; whether it is felt is not detectable"
    @Published var accessibility = "—"
    @Published var loginItem = "—"
    @Published var errors: [String] = []

    @Published var liveEnabled = false
    @Published var liveText = ""

    func logError(_ message: String) {
        DispatchQueue.main.async {
            self.errors.append(message)
            if self.errors.count > 50 { self.errors.removeFirst(self.errors.count - 50) }
        }
    }
}
