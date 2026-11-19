import AVFoundation
import Flutter
import HMSWebRTC
import UIKit

/// DEM-3564: repairs a silent mic in place. `AVAudioSession` and WebRTC's
/// `RTCAudioSession` are process-wide and survive `HMSSDK.destroy()`, so once
/// broken the mic sent 0 bytes until the app was killed.
///
/// Channel `hmssdk_flutter/audio_session_health`, method `recover`
/// {fullReset: Bool} -> {outputs, error?} or {skipped}; `cancel` drops a
/// pending restart (call left).
final class HMSAudioSessionHealth: NSObject {

    private static var shared: HMSAudioSessionHealth?
    private static var isInterrupted = false
    /// Bumped by `cancel`; a pending restart from an older generation is dropped.
    private static var generation = 0

    /// Called for every FlutterEngine; the observer is shared.
    static func register(with registrar: FlutterPluginRegistrar) {
        if shared == nil {
            let instance = HMSAudioSessionHealth()
            NotificationCenter.default.addObserver(instance, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
            // iOS does not always post "interruption ended".
            NotificationCenter.default.addObserver(instance, selector: #selector(handleDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
            shared = instance
        }
        let channel = FlutterMethodChannel(name: "hmssdk_flutter/audio_session_health", binaryMessenger: registrar.messenger())
        channel.setMethodCallHandler { call, result in
            if call.method == "cancel" {
                generation += 1
                result(nil)
                return
            }
            guard call.method == "recover" else {
                result(FlutterMethodNotImplemented)
                return
            }
            let fullReset = (call.arguments as? [String: Any])?["fullReset"] as? Bool ?? false
            recover(fullReset: fullReset, completion: result)
        }
    }

    /// Restarts WebRTC's audio unit (toggling `isAudioEnabled` under
    /// `useManualAudio`, original values restored). `fullReset` also
    /// deactivates the session once the unit has stopped. Keeps the current mode/options and speaker/earpiece.
    /// Skipped during an interruption or when the app manages audio itself.
    private static func recover(fullReset: Bool, completion: @escaping FlutterResult) {
        let rtc = HMSRTCAudioSession.sharedInstance()
        let session = AVAudioSession.sharedInstance()
        let wasManualAudio = rtc.useManualAudio
        let wasAudioEnabled = rtc.isAudioEnabled
        if isInterrupted || (wasManualAudio && !rtc.isAudioEnabled) {
            completion(["skipped": isInterrupted ? "interrupted" : "audio_disabled_by_app"])
            return
        }
        let wasSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        let isCallSession = session.category == .playAndRecord
        let mode = isCallSession ? session.mode : .voiceChat
        let options: AVAudioSession.CategoryOptions = isCallSession ? session.categoryOptions : [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]

        // Stop the unit; unlock so WebRTC's worker thread can stop it.
        rtc.lockForConfiguration()
        rtc.useManualAudio = true
        rtc.isAudioEnabled = false
        rtc.unlockForConfiguration()

        let startGeneration = generation
        let restart = {
            var errors = [String]()
            rtc.lockForConfiguration()
            // Call left while waiting: restore and stop.
            guard startGeneration == generation else {
                rtc.isAudioEnabled = true
                rtc.useManualAudio = wasManualAudio
                rtc.isAudioEnabled = wasAudioEnabled
                rtc.unlockForConfiguration()
                completion(["skipped": "call_ended"])
                return
            }
            rtc.canUseMic = true
            if fullReset {
                do { try session.setActive(false, options: .notifyOthersOnDeactivation) } catch { errors.append("deactivate: \(error.localizedDescription)") }
            }
            do { try rtc.setCategory(.playAndRecord, mode: mode, options: options) } catch { errors.append("setCategory: \(error.localizedDescription)") }
            // Raw activation: mid-call RTCAudioSession already counts it active.
            // Retried once; a failure is reported so Dart logs it as failed.
            if (try? session.setActive(true)) == nil {
                Thread.sleep(forTimeInterval: 0.2)
                do { try session.setActive(true) } catch { errors.append("setActive: \(error.localizedDescription)") }
            }
            let isSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
            if wasSpeaker != isSpeaker {
                try? session.overrideOutputAudioPort(wasSpeaker ? .speaker : .none)
            }
            rtc.isAudioEnabled = true
            rtc.useManualAudio = wasManualAudio
            rtc.isAudioEnabled = wasAudioEnabled
            rtc.unlockForConfiguration()

            var payload: [String: Any] = ["outputs": session.currentRoute.outputs.map { $0.portType.rawValue }]
            if !errors.isEmpty { payload["error"] = errors.joined(separator: "; ") }
            completion(payload)
        }
        // Give WebRTC's worker thread time to stop the unit before it is
        // started again (and, for fullReset, before deactivating).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: restart)
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        DispatchQueue.main.async {
            HMSAudioSessionHealth.isInterrupted = value == AVAudioSession.InterruptionType.began.rawValue
        }
    }

    /// Fallback for a missing "interruption ended" (posted on main).
    @objc private func handleDidBecomeActive() {
        HMSAudioSessionHealth.isInterrupted = false
    }
}
