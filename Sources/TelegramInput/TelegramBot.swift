import AppKit
import Security
import os

private let tgLog = Logger(subsystem: "dev.hyoban.telegram-input", category: "bot")

/// Telegram 机器人：在手机 Telegram 里给它发消息，文字会上屏到 Mac 当前光标处。
/// Mac 主动长轮询 Telegram 服务器，不需要开端口或组网。只响应配对过的那一个账号。
final class TelegramBot {
    enum Status {
        case notConfigured
        case connecting
        case waitingForPairing
        case connected
        case error(String)
    }

    private(set) var status: Status = .notConfigured { didSet { onStatusChange?() } }
    private(set) var botUsername: String?
    var onStatusChange: (() -> Void)?

    // 测试用环境变量：RK_TG_API（API 地址）、RK_TG_TOKEN、RK_TG_PAIRING_CODE、RK_DRY_RUN（只记录不注入）。
    private static let env = ProcessInfo.processInfo.environment

    /// 每次启动随机生成；未配对时把它发给机器人即可绑定账号。
    private(set) var pairingCode = TelegramBot.env["RK_TG_PAIRING_CODE"] ?? TelegramBot.makePairingCode()

    private let defaults = UserDefaults.standard
    private let apiBase = TelegramBot.env["RK_TG_API"] ?? "https://api.telegram.org"
    private let dryRun = TelegramBot.env["RK_DRY_RUN"] != nil
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 70
        return URLSession(configuration: config)
    }()
    private var token: String?
    private var offset = 0
    /// 每次重启轮询都加一，旧的轮询看到编号变了就自行结束。
    private var generation = 0

    var enabled: Bool {
        get { defaults.object(forKey: "tg.enabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "tg.enabled")
            start()
        }
    }

    var isConfigured: Bool { token != nil }
    var isPaired: Bool { allowedUserID != nil }

    private var allowedUserID: Int? {
        get { defaults.object(forKey: "tg.userID") as? Int }
        set { defaults.set(newValue, forKey: "tg.userID") }
    }

    private var autoReturn: Bool {
        get { defaults.bool(forKey: "tg.autoReturn") }
        set { defaults.set(newValue, forKey: "tg.autoReturn") }
    }

    init() {
        token = Self.env["RK_TG_TOKEN"] ?? Keychain.read()
    }

    func setToken(_ newToken: String) {
        Keychain.write(newToken)
        token = newToken
        botUsername = nil
        start()
    }

    func unpair() {
        allowedUserID = nil
        pairingCode = Self.makePairingCode()
        refreshStatus()
    }

    func start() {
        generation += 1
        guard enabled, let token else {
            status = .notConfigured
            return
        }
        let gen = generation
        status = .connecting
        call("getMe", [:], token: token) { [weak self] result in
            guard let self, gen == self.generation else { return }
            switch result {
            case .success(let me):
                self.botUsername = (me as? [String: Any])?["username"] as? String
                tgLog.notice("connected as @\(self.botUsername ?? "?", privacy: .public)")
                self.refreshStatus()
                self.poll(gen)
            case .failure(let error):
                self.status = .error(error.localizedDescription)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    if gen == self?.generation { self?.start() }
                }
            }
        }
    }

    func stop() {
        generation += 1
        status = .notConfigured
    }

    private func refreshStatus() {
        status = isPaired ? .connected : .waitingForPairing
    }

    // MARK: 轮询

    private func poll(_ gen: Int) {
        guard gen == generation, let token else { return }
        let params: [String: Any] = ["offset": offset, "timeout": 50, "allowed_updates": ["message"]]
        call("getUpdates", params, token: token) { [weak self] result in
            guard let self, gen == self.generation else { return }
            switch result {
            case .success(let updates):
                if case .error = self.status { self.refreshStatus() }
                for update in updates as? [[String: Any]] ?? [] {
                    if let id = update["update_id"] as? Int { self.offset = max(self.offset, id + 1) }
                    self.handle(update)
                }
                self.poll(gen)
            case .failure(let error):
                self.status = .error(error.localizedDescription)
                tgLog.notice("getUpdates failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.poll(gen) }
            }
        }
    }

    private func handle(_ update: [String: Any]) {
        guard let message = update["message"] as? [String: Any],
              let chat = message["chat"] as? [String: Any], chat["type"] as? String == "private",
              let chatID = chat["id"] as? Int,
              let userID = (message["from"] as? [String: Any])?["id"] as? Int,
              let messageID = message["message_id"] as? Int,
              let text = message["text"] as? String
        else { return }

        guard let allowed = allowedUserID else {
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == pairingCode {
                allowedUserID = userID
                tgLog.notice("paired with user \(userID)")
                refreshStatus()
                send(chatID, "✅ 配对成功。现在发给我的文字会直接打到 Mac 当前的光标位置，下面的按钮可以发送按键。", keyboard: true)
            } else {
                send(chatID, "请发送 Mac 菜单栏「Telegram 输入」里显示的 6 位配对码。")
            }
            return
        }
        guard userID == allowed else {
            tgLog.notice("ignored message from user \(userID)")
            return
        }
        // Mac 离线期间积压的消息不再执行，免得重新联网时突然打出一堆字。
        if let date = message["date"] as? Int, Date().timeIntervalSince1970 - Double(date) > 120 {
            send(chatID, "这条消息发送超过 2 分钟了，已忽略。", replyTo: messageID)
            return
        }

        if text == "/start" || text == "/keyboard" {
            send(chatID, "发文字：上屏到 Mac 当前光标处。\n按钮：发送对应按键。\n「自动回车」打开后，每条文字上屏后会再按一次回车。", keyboard: true)
            return
        }
        if text == Self.autoReturnLabel(true) || text == Self.autoReturnLabel(false) {
            autoReturn.toggle()
            send(chatID, autoReturn ? "已开启自动回车。" : "已关闭自动回车。", keyboard: true)
            return
        }
        guard AXIsProcessTrusted() else {
            send(chatID, "⚠️ Mac 上的「Telegram 输入」还没有辅助功能权限，没法打字。", replyTo: messageID)
            return
        }

        if let action = Self.buttons[text] {
            tgLog.notice("button \(text, privacy: .public)")
            if !dryRun { action() }
        } else {
            tgLog.notice("text, \(text.count) chars, autoReturn=\(self.autoReturn)")
            if !dryRun {
                KeySender.type(text)
                if autoReturn {
                    // 等粘贴或输入完成后再回车。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        KeySender.press(keyCodes["return"]!, flags: [])
                    }
                }
            }
        }
        call("setMessageReaction", [
            "chat_id": chatID, "message_id": messageID,
            "reaction": [["type": "emoji", "emoji": "👍"]],
        ], token: token ?? "") { _ in }
    }

    // MARK: 按钮

    private static func key(_ name: String, _ flags: CGEventFlags = []) -> () -> Void {
        { KeySender.press(keyCodes[name]!, flags: flags) }
    }

    private static let buttons: [String: () -> Void] = [
        "⏎": key("return"), "⌫": key("backspace"), "⎋ Esc": key("escape"), "⇥ Tab": key("tab"),
        "←": key("left"), "↑": key("up"), "↓": key("down"), "→": key("right"),
        "⌘C": key("c", .maskCommand), "⌘V": key("v", .maskCommand),
        "⌘Z": key("z", .maskCommand), "⌘A": key("a", .maskCommand),
        "⌘Tab": key("tab", .maskCommand), "⌘W": key("w", .maskCommand),
        "⌃C": key("c", .maskControl), "中/EN": { InputSources.selectNext() },
    ]

    private static func autoReturnLabel(_ on: Bool) -> String { on ? "自动回车：开" : "自动回车：关" }

    private func keyboardMarkup() -> [String: Any] {
        let rows = [
            ["⏎", "⌫", "⎋ Esc", "⇥ Tab"],
            ["←", "↑", "↓", "→"],
            ["⌘C", "⌘V", "⌘Z", "⌘A"],
            ["⌘Tab", "⌘W", "⌃C", "中/EN"],
            [Self.autoReturnLabel(autoReturn)],
        ]
        return [
            "keyboard": rows.map { $0.map { ["text": $0] } },
            "resize_keyboard": true,
            "is_persistent": true,
            "input_field_placeholder": "输入要发到 Mac 的文字",
        ]
    }

    // MARK: Bot API

    private func send(_ chatID: Int, _ text: String, keyboard: Bool = false, replyTo: Int? = nil) {
        var params: [String: Any] = ["chat_id": chatID, "text": text]
        if keyboard { params["reply_markup"] = keyboardMarkup() }
        if let replyTo { params["reply_parameters"] = ["message_id": replyTo] }
        call("sendMessage", params, token: token ?? "") { result in
            if case .failure(let error) = result {
                tgLog.notice("sendMessage failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func call(_ method: String, _ params: [String: Any], token: String,
                      completion: @escaping (Result<Any, Error>) -> Void) {
        guard let url = URL(string: "\(apiBase)/bot\(token)/\(method)") else {
            completion(.failure(BotError("无效的 token")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: params)
        session.dataTask(with: request) { data, _, error in
            let result: Result<Any, Error>
            if let error {
                result = .failure(error)
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if json["ok"] as? Bool == true {
                    result = .success(json["result"] ?? NSNull())
                } else {
                    result = .failure(BotError(json["description"] as? String ?? "未知错误"))
                }
            } else {
                result = .failure(BotError("无法解析 Telegram 的响应"))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }
}

struct BotError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// bot token 存在钥匙串里，不写进普通的偏好设置文件。
private enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.hyoban.telegram-input",
        kSecAttrAccount as String: "bot-token",
    ]

    static func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
