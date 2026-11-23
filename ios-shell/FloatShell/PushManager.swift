import Foundation
import UIKit
import UserNotifications
import WebKit

/// 复刻安卓壳 PushService 的自建长连接推送：
/// 用 WebView 已登录的站点 Cookie 调站点接口拿到 Supabase 地址 / anon key / 当前用户 id，
/// 然后直连 Supabase Realtime，订阅个人频道 shellpush:<userId>，收到 notify 广播即弹本地通知。
/// 服务端 push-service.ts 识别 shell: 前缀订阅后会往该频道广播，无需改后端。
///
/// 后台保活靠 AppDelegate 里的静音音频（UIBackgroundModes = audio），让 App 退后台后不断线。
final class PushManager {
    static let shared = PushManager()

    private struct Config {
        let supabaseUrl: String
        let anonKey: String
        let userId: String
    }

    private let queue = DispatchQueue(label: "shell.push.loop")
    private var running = false
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var msgSeq = 2
    private var registeredUserId: String?
    private var connectedStable = false

    private var siteURL: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "FloatSiteURL") as? String ?? ""
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private init() {}

    func start() {
        guard !running else { return }
        running = true
        session = URLSession(configuration: .default)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        queue.async { [weak self] in self?.connectionLoop() }
    }

    // MARK: - 连接循环

    private func connectionLoop() {
        var backoff = 5
        while running {
            guard let config = fetchConfig() else {
                Thread.sleep(forTimeInterval: 60)
                continue
            }
            connectedStable = false
            let normal = runSocket(config)
            guard running else { break }
            Thread.sleep(forTimeInterval: normal ? 3 : TimeInterval(backoff))
            backoff = normal ? 5 : min(backoff * 2, 120)
        }
    }

    // MARK: - 取配置 + 注册 shell 订阅

    private func fetchConfig() -> Config? {
        guard let host = URL(string: siteURL)?.host else { return nil }
        let cookie = cookieHeader(for: host)
        guard !cookie.isEmpty else { return nil }

        func get(_ path: String) -> [AnyHashable: Any]? {
            guard let url = URL(string: siteURL + path) else { return nil }
            var req = URLRequest(url: url)
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let sem = DispatchSemaphore(value: 0)
            var result: [AnyHashable: Any]?
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                defer { sem.signal() }
                if let d = data,
                   let r = resp as? HTTPURLResponse,
                   (200..<300).contains(r.statusCode) {
                    result = (try? JSONSerialization.jsonObject(with: d)) as? [AnyHashable: Any]
                }
            }.resume()
            sem.wait()
            return result
        }

        guard let me = get("/api/auth/me"),
              let account = me["account"] as? [AnyHashable: Any],
              let userId = account["id"] as? String, !userId.isEmpty else { return nil }
        guard let online = get("/api/online/config"),
              (online["configured"] as? Bool) == true,
              let url = online["supabaseUrl"] as? String, !url.isEmpty,
              let key = online["anonKey"] as? String, !key.isEmpty else { return nil }

        registerShellSubscription(cookie: cookie, userId: userId)
        return Config(
            supabaseUrl: url.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            anonKey: key,
            userId: userId
        )
    }

    private func cookieHeader(for host: String) -> String {
        let sem = DispatchSemaphore(value: 0)
        var header = ""
        // WKWebsiteDataStore / WKHTTPCookieStore 必须在主线程访问；后台队列直接调用会触发
        // WebKit 主线程断言崩溃（或回调无法派发导致信号量死锁）。这里派发到主线程执行，
        // 后台队列等待结果；主线程空闲，completion 能正常回调，不会死锁。
        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let parts = cookies.filter { cookie in
                    let d = cookie.domain.lowercased()
                    let h = host.lowercased()
                    return h == d || h.hasSuffix("." + d) || d.hasSuffix("." + h)
                }.map { "\($0.name)=\($0.value)" }
                header = parts.joined(separator: "; ")
                sem.signal()
            }
        }
        sem.wait()
        return header
    }

    /// 注册合成订阅 endpoint=shell:<userId>，让服务端往 shellpush 频道广播。
    private func registerShellSubscription(cookie: String, userId: String) {
        if registeredUserId == userId { return }
        guard let url = URL(string: siteURL + "/api/push/subscribe") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "endpoint": "shell:\(userId)",
            "keys": ["p256dh": "shell", "auth": "shell"],
        ])
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let r = resp as? HTTPURLResponse, (200..<300).contains(r.statusCode) {
                self.registeredUserId = userId
            }
            sem.signal()
        }.resume()
        sem.wait()
    }

    // MARK: - WebSocket

    private func runSocket(_ config: Config) -> Bool {
        var wsUrlString = config.supabaseUrl.replacingOccurrences(of: "http", with: "ws")
            + "/realtime/v1/websocket?apikey=\(config.anonKey)&vsn=1.0.0"
        wsUrlString = wsUrlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? wsUrlString
        guard let wsUrl = URL(string: wsUrlString) else { return false }

        var request = URLRequest(url: wsUrl)
        request.timeoutInterval = 30
        let t = session.webSocketTask(with: request)
        task = t
        let cond = NSCondition()
        var done = false

        t.resume()

        func receiveNext() {
            t.receive { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let message):
                    self.connectedStable = true
                    if case .string(let text) = message {
                        self.handleMessage(text)
                    }
                    if self.running { receiveNext() }
                case .failure:
                    cond.lock(); done = true; cond.signal(); cond.unlock()
                }
            }
        }
        receiveNext()

        // Phoenix 加入频道
        let join: [String: Any] = [
            "topic": "realtime:shellpush:\(config.userId)",
            "event": "phx_join",
            "ref": "1",
            "payload": [
                "config": [
                    "broadcast": ["self": false],
                    "presence": ["key": ""],
                ],
            ],
        ]
        sendJSON(join, on: t)
        startHeartbeat(on: t)

        cond.lock()
        while !done && running { cond.wait(until: Date().addingTimeInterval(30)) }
        cond.unlock()

        heartbeat?.invalidate()
        heartbeat = nil
        t.cancel(with: .goingAway, reason: nil)
        return connectedStable
    }

    private func sendJSON(_ obj: [String: Any], on t: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        t.send(.string(s)) { _ in }
    }

    private func startHeartbeat(on t: URLSessionWebSocketTask) {
        DispatchQueue.main.async {
            self.heartbeat?.invalidate()
            self.heartbeat = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let hb: [String: Any] = [
                    "topic": "phoenix",
                    "event": "heartbeat",
                    "payload": [:],
                    "ref": "\(self.msgSeq)",
                ]
                self.msgSeq += 1
                self.sendJSON(hb, on: t)
            }
        }
    }

    // MARK: - 通知

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (msg["event"] as? String) == "broadcast",
              let payload = msg["payload"] as? [String: Any],
              (payload["event"] as? String) == "notify",
              let body = payload["payload"] as? [String: Any] else { return }

        let title = (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Float"
        let message = (body["body"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "有新消息"
        let isCall = (body["kind"] as? String) == "call"

        // 前台时 WebView 内已经有实时 UI，不弹系统通知，避免重复
        if UIApplication.shared.applicationState != .active {
            showNotification(title: title, body: message, isCall: isCall)
        }
    }

    private func showNotification(title: String, body: String, isCall: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = isCall && body == "有新消息" ? "语音来电…" : body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
