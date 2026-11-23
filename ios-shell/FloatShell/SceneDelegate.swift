import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ShellViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    /// 进入后台：启动静音保活，维持 WebSocket 长连接。
    func sceneDidEnterBackground(_ scene: UIScene) {
        KeepAliveAudio.shared.start()
    }

    /// 回到前台：停止保活音频，避免影响通话与状态栏。
    func sceneWillEnterForeground(_ scene: UIScene) {
        KeepAliveAudio.shared.stop()
    }
}
