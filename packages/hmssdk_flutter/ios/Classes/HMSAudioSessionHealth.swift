import AVFoundation
import Flutter
import HMSWebRTC
import UIKit

/// Repairs and diagnoses the process-wide iOS audio session used by WebRTC.
///
/// Why this exists: `AVAudioSession` and WebRTC's `RTCAudioSession` (exposed by
/// HMSWebRTC as `HMSRTCAudioSession`) are process-wide singletons that survive
/// `HMSSDK.destroy()`. If an interruption, route change, CallKit call or
/// media-services reset leaves them unable to capture, every later call in the
/// same app process publishes an unmuted mic that sends 0 bytes - until the app
/// is killed. This class restarts WebRTC's audio unit and resets the session in
/// place, so no restart is needed.
///
/// It also records audio-session events from app launch (interruptions, route
/// changes, media-services resets) in a small ring buffer, so the Dart side can
/// log what happened between calls when the next call starts.
///
/// Channel: `hmssdk_flutter/audio_session_health`
///  * `getState` -> session/WebRTC snapshot
///  * `drainEvents` -> buffered events since the last drain (oldest first)
///  * `recover` {fullReset: Bool} -> restart the audio unit (+ session reset)
///  * `resetForCall` -> full session reset before a new preview/join
final class HMSAudioSessionHealth: NSObject {

    static let channelName = "hmssdk_flutter/audio_session_health"

    private static var shared: HMSAudioSessionHealth?

    private static let callCategoryOptions: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]

    private static let maxBufferedEvents = 50

    /// Delay between stopping WebRTC's audio unit and deactivating the
    /// session: the stop runs on WebRTC's worker thread, and deactivating
    /// while the VoIP unit still does I/O fails with "session busy".
    private static let unitStopDelay: TimeInterval = 0.5

    private var channels = [FlutterMethodChannel]()
    private let eventsQueue = DispatchQueue(label: "live.100ms.audio-session-health")
    private var bufferedEvents = [[String: Any]]()

    /// True between interruption began/ended: iOS owns the mic (phone call,
    /// Siri), so a silent mic is expected and must not be "repaired".
    private static var isInterrupted = false

    /// Called for every FlutterEngine that registers the plugin. Observers and
    /// the event buffer are shared; each engine gets its own channel.
    static func register(with registrar: FlutterPluginRegistrar) {
        let instance: HMSAudioSessionHealth
        if let existing = shared {
            instance = existing
        } else {
            instance = HMSAudioSessionHealth()
            instance.startObserving()
            shared = instance
        }
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        channel.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
        instance.channels.append(channel)
    }

    private override init() {
        super.init()
    }

    // MARK: - Method channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "getState":
            result(HMSAudioSessionHealth.snapshot())
        case "drainEvents":
            result(drainEvents())
        case "recover":
            let fullReset = args?["fullReset"] as? Bool ?? false
            HMSAudioSessionHealth.restartAudioUnit(fullReset: fullReset, completion: result)
        case "resetForCall":
            result(HMSAudioSessionHealth.resetForCall())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Repair

    /// Restarts WebRTC's VoIP audio unit in place - the part of an app restart
    /// that brings the mic back. Toggling `isAudioEnabled` (only honoured with
    /// `useManualAudio`) makes WebRTC stop + uninitialize the audio unit and
    /// then initialize + start it again on a re-asserted voice-call session.
    /// `fullReset` also deactivates the AVAudioSession once the unit has
    /// stopped, so iOS hands the session back from whatever owner left it
    /// unusable. The original `useManualAudio` / `isAudioEnabled` are restored
    /// and the current category options and output route are kept.
    ///
    /// Skipped (`skipped` in the result) during an audio interruption, or when
    /// the app drives WebRTC audio itself and has audio disabled (CallKit
    /// style: `useManualAudio` on, `isAudioEnabled` off).
    private static func restartAudioUnit(fullReset: Bool, completion: @escaping FlutterResult) {
        let rtc = HMSRTCAudioSession.sharedInstance()
        let before = snapshot()
        if isInterrupted {
            completion(["skipped": "interrupted", "before": before])
            return
        }
        let wasManualAudio = rtc.useManualAudio
        let wasAudioEnabled = rtc.isAudioEnabled
        if wasManualAudio && !wasAudioEnabled {
            completion(["skipped": "audio_disabled_by_app", "before": before])
            return
        }
        let previousOutputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType }

        // Stop the unit; unlock so WebRTC's worker thread can do the stop.
        rtc.lockForConfiguration()
        rtc.useManualAudio = true
        rtc.isAudioEnabled = false
        rtc.unlockForConfiguration()

        let restart = {
            let session = AVAudioSession.sharedInstance()
            var errors = [String]()
            rtc.lockForConfiguration()
            rtc.canUseMic = true
            if fullReset {
                do {
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                } catch {
                    errors.append("deactivate: \(error.localizedDescription)")
                }
            }
            do {
                try rtc.setCategory(.playAndRecord, mode: currentCallMode(), options: currentCallOptions())
            } catch {
                errors.append("setCategory: \(error.localizedDescription)")
            }
            do {
                // Raw activation: RTCAudioSession.setActive skips the real call if
                // its bookkeeping already thinks it is active. Mid-call that
                // bookkeeping is active, so its activation count stays correct.
                try session.setActive(true)
            } catch {
                errors.append("setActive: \(error.localizedDescription)")
            }
            restoreOutput(previousOutputs)
            // Starts the unit again. Equals the original value: with manual
            // audio it was true (else skipped above); without, it is ignored.
            rtc.isAudioEnabled = true
            rtc.useManualAudio = wasManualAudio
            rtc.unlockForConfiguration()

            var payload: [String: Any] = ["fullReset": fullReset, "before": before, "after": snapshot()]
            if !errors.isEmpty {
                payload["error"] = errors.joined(separator: "; ")
            }
            completion(payload)
        }
        if fullReset {
            DispatchQueue.main.asyncAfter(deadline: .now() + unitStopDelay, execute: restart)
        } else {
            restart()
        }
    }

    /// Mode/options of the current call session, so a repair does not change
    /// what the SDK or user chose; falls back to voice-call defaults.
    private static func currentCallMode() -> AVAudioSession.Mode {
        let session = AVAudioSession.sharedInstance()
        return session.category == .playAndRecord ? session.mode : .voiceChat
    }

    private static func currentCallOptions() -> AVAudioSession.CategoryOptions {
        let session = AVAudioSession.sharedInstance()
        return session.category == .playAndRecord ? session.categoryOptions : callCategoryOptions
    }

    /// Re-applies a loudspeaker / earpiece choice that the category reset
    /// dropped. Other routes (Bluetooth, wired) are picked by iOS itself.
    private static func restoreOutput(_ previous: [AVAudioSession.Port]) {
        let session = AVAudioSession.sharedInstance()
        let now = session.currentRoute.outputs.map { $0.portType }
        if previous.contains(.builtInSpeaker) && !now.contains(.builtInSpeaker) {
            try? session.overrideOutputAudioPort(.speaker)
        } else if previous.contains(.builtInReceiver) && now.contains(.builtInSpeaker) {
            try? session.overrideOutputAudioPort(.none)
        }
    }

    /// Session reset before a new preview captures the mic. Used only after
    /// a silent mic was seen earlier in this process. The session is left
    /// inactive: WebRTC activates it through RTCAudioSession when the preview
    /// starts audio, so its bookkeeping stays correct and nothing stays
    /// active if the user backs out of the preview.
    private static func resetForCall() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let before = snapshot()
        let rtc = HMSRTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        rtc.canUseMic = true
        rtc.unlockForConfiguration()

        var errors = [String]()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            errors.append("deactivate: \(error.localizedDescription)")
        }
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: callCategoryOptions)
        } catch {
            errors.append("setCategory: \(error.localizedDescription)")
        }
        var payload: [String: Any] = ["before": before, "after": snapshot()]
        if !errors.isEmpty {
            payload["error"] = errors.joined(separator: "; ")
        }
        return payload
    }

    // MARK: - Diagnostics

    private static func snapshot() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let rtc = HMSRTCAudioSession.sharedInstance()
        return [
            "category": session.category.rawValue,
            "mode": session.mode.rawValue,
            "inputAvailable": session.isInputAvailable,
            "inputs": session.currentRoute.inputs.map { $0.portType.rawValue },
            "outputs": session.currentRoute.outputs.map { $0.portType.rawValue },
            "otherAudioPlaying": session.isOtherAudioPlaying,
            "recordPermission": recordPermissionString(),
            "interrupted": isInterrupted,
            "webrtc": [
                "isActive": rtc.isActive,
                "useManualAudio": rtc.useManualAudio,
                "isAudioEnabled": rtc.isAudioEnabled,
                "canUseMic": rtc.canUseMic,
            ],
        ]
    }

    private static func recordPermissionString() -> String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    private func startObserving() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: session)
        center.addObserver(self, selector: #selector(handleRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: session)
        center.addObserver(self, selector: #selector(handleMediaServicesLost(_:)), name: AVAudioSession.mediaServicesWereLostNotification, object: session)
        center.addObserver(self, selector: #selector(handleMediaServicesReset(_:)), name: AVAudioSession.mediaServicesWereResetNotification, object: session)
        center.addObserver(self, selector: #selector(handleDidBecomeActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    private func record(_ payload: [String: Any]) {
        var event = payload
        event["at"] = ISO8601DateFormatter().string(from: Date())
        event["category"] = AVAudioSession.sharedInstance().category.rawValue
        event["inputs"] = AVAudioSession.sharedInstance().currentRoute.inputs.map { $0.portType.rawValue }
        event["outputs"] = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }
        DispatchQueue.main.async {
            let state = UIApplication.shared.applicationState
            event["appState"] = state == .active ? "active" : (state == .background ? "background" : "inactive")
            self.eventsQueue.async {
                self.bufferedEvents.append(event)
                if self.bufferedEvents.count > HMSAudioSessionHealth.maxBufferedEvents {
                    self.bufferedEvents.removeFirst(self.bufferedEvents.count - HMSAudioSessionHealth.maxBufferedEvents)
                }
            }
        }
    }

    private func drainEvents() -> [[String: Any]] {
        eventsQueue.sync {
            let events = bufferedEvents
            bufferedEvents.removeAll()
            return events
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        HMSAudioSessionHealth.isInterrupted = type == .began
        var payload: [String: Any] = ["event": type == .began ? "interruption_began" : "interruption_ended"]
        if type == .ended, let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
            payload["shouldResume"] = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
        }
        if #available(iOS 14.5, *), let reasonValue = info[AVAudioSessionInterruptionReasonKey] as? UInt {
            payload["reason"] = reasonValue
        }
        record(payload)
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        let reasonName: String
        switch reason {
        case .newDeviceAvailable: reasonName = "new_device_available"
        case .oldDeviceUnavailable: reasonName = "old_device_unavailable"
        case .categoryChange: reasonName = "category_change"
        case .override: reasonName = "override"
        case .wakeFromSleep: reasonName = "wake_from_sleep"
        case .noSuitableRouteForCategory: reasonName = "no_suitable_route_for_category"
        case .routeConfigurationChange: reasonName = "route_configuration_change"
        default: reasonName = "unknown"
        }
        var payload: [String: Any] = ["event": "route_change", "reason": reasonName]
        if let previous = info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
            payload["previousInputs"] = previous.inputs.map { $0.portType.rawValue }
            payload["previousOutputs"] = previous.outputs.map { $0.portType.rawValue }
        }
        record(payload)
    }

    @objc private func handleMediaServicesLost(_ notification: Notification) {
        record(["event": "media_services_lost"])
    }

    /// iOS does not always post "interruption ended"; back in the foreground
    /// the interruption is over.
    @objc private func handleDidBecomeActive(_ notification: Notification) {
        HMSAudioSessionHealth.isInterrupted = false
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        HMSAudioSessionHealth.isInterrupted = false
        record(["event": "media_services_reset"])
    }
}
