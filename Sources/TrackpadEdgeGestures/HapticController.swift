import AppKit
import TEGCore

/// Subtle trackpad pulses at value boundaries. The call can succeed without the user feeling anything
/// (the system may skip haptics), so this never claims more than "request issued".
final class HapticController {
    private var policy = HapticPolicy()

    /// Call on the gesture queue.
    func configure(from s: AppSettings) {
        policy.enabled = s.hapticsEnabled
        policy.intervalPoints = s.hapticIntervalPoints
        policy.atLimits = s.hapticAtLimits
    }

    func beginGesture() {
        policy.beginGesture()
    }

    func evaluate(old: Float, new: Float, now: Double) {
        guard policy.shouldPulse(old: old, new: new, now: now) else { return }
        DispatchQueue.main.async {
            // Fetch the performer each time: the current input device can change.
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }
}
