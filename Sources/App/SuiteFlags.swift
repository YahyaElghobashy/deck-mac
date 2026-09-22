import AppKit
import AVFoundation
import ServiceManagement
import Speech

/// Launch arguments used by the Yaya Suite installer.
///   --permissions-json      print this app's permission state as JSON and exit
///   --login-item on|off     register / unregister the login item, then continue normally
enum SuiteFlags {
    static func handle(appName: String) {
        let args = CommandLine.arguments
        if args.contains("--permissions-json") {
            let mic = AVCaptureDevice.authorizationStatus(for: .audio)
            let speech = SFSpeechRecognizer.authorizationStatus()
            let json: [String: Any] = [
                "app": appName,
                "accessibility": AXIsProcessTrusted(),
                "microphone": mic == .authorized ? "granted" : (mic == .notDetermined ? "undetermined" : "denied"),
                "speech": speech == .authorized ? "granted" : (speech == .notDetermined ? "undetermined" : "denied"),
                "loginItem": SMAppService.mainApp.status == .enabled,
            ]
            if let d = try? JSONSerialization.data(withJSONObject: json), let s = String(data: d, encoding: .utf8) { print(s) }
            fflush(stdout)
            exit(0)
        }
        if let i = args.firstIndex(of: "--login-item"), i + 1 < args.count {
            let on = args[i + 1].lowercased() == "on"
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                DebugLog.write("login item \(on ? "registered" : "unregistered") by suite")
            } catch { DebugLog.write("login item change failed: \(error)") }
        }
        if args.contains("--request-permissions") {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            SFSpeechRecognizer.requestAuthorization { _ in }
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
    }
}
