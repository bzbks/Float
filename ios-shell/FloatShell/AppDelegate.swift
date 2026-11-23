import AVFoundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        configureAudioSession()
        PushManager.shared.start()
        return true
    }

    /// 语音条、TTS、通话都走媒体流；按 `.playAndRecord` + 外放避免走听筒。
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
        )
        try? session.setActive(true)
    }
}

/// 后台保活：声明 UIBackgroundModes=audio 后，后台循环播放静音可让 App 不被挂起，
/// 从而维持 PushManager 的 WebSocket 长连接。前台时停止，避免影响通话与状态栏显示。
final class KeepAliveAudio {
    static let shared = KeepAliveAudio()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var started = false
    private init() {}

    private var configured = false

    func start() {
        guard !started else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        if !configured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            configured = true
        }
        let frames = AVAudioFrameCount(44100 * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames // 零填充 = 静音
        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            player.play()
            started = true
        } catch {
            started = false
        }
    }

    func stop() {
        guard started else { return }
        player.stop()
        engine.stop()
        started = false
    }
}
