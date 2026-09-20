import AppKit
import AVFoundation

/// Mirror of `AccessibilityPermission` for the microphone. Voice In can't record without it, and
/// the hardened runtime additionally requires the audio-input entitlement (set in project.yml).
enum MicrophonePermission {
    enum Status { case granted, denied, notDetermined }

    static func status() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    static func isGranted() -> Bool { status() == .granted }

    /// Shows the system prompt the first time; afterwards resolves from the stored decision.
    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
