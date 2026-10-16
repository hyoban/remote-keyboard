// remote-keyboard: 手机网页打字 → 注入到 Mac 当前光标位置。
// 单文件 Swift，无第三方依赖。构建：./build.sh

import AppKit
import ApplicationServices
import Carbon
import CoreImage
import Foundation
import Network
import Security

// MARK: - 配置

struct Options {
    var port: UInt16 = 8765
    var bind: String? = nil
    var resetToken = false
}

func parseOptions() -> Options {
    var opts = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--port", "-p":
            if let v = args.next(), let p = UInt16(v) { opts.port = p }
        case "--bind", "-b":
            opts.bind = args.next()
        case "--reset-token":
            opts.resetToken = true
        case "--help", "-h":
            print("""
            用法: remote-keyboard [--port 8765] [--bind 127.0.0.1] [--reset-token]
              --port         监听端口，默认 8765
              --bind         只监听指定地址（配合 tailscale serve 时用 127.0.0.1）
              --reset-token  重新生成访问 token
            环境变量 RK_TOKEN 可直接指定 token。
            """)
            exit(0)
        default:
            print("未知参数: \(arg)")
            exit(1)
        }
    }
    return opts
}

func configDir() -> URL {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/remote-keyboard")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func loadToken(reset: Bool) -> String {
    if let t = ProcessInfo.processInfo.environment["RK_TOKEN"], !t.isEmpty { return t }
    let file = configDir().appendingPathComponent("token")
    if !reset,
       let t = try? String(contentsOf: file, encoding: .utf8)
           .trimmingCharacters(in: .whitespacesAndNewlines),
       !t.isEmpty {
        return t
    }
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let t = bytes.map { String(format: "%02x", $0) }.joined()
    try? t.write(to: file, atomically: true, encoding: .utf8)
    chmod(file.path, 0o600)
    return t
}

func findWebDir() -> URL? {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["RK_WEB"] {
        return URL(fileURLWithPath: env)
    }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent()
    let candidates = [
        exe.appendingPathComponent("web"),
        exe.deletingLastPathComponent().appendingPathComponent("web"),
        URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("web"),
    ]
    return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
}

// MARK: - 按键注入

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47, "`": 50,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53, "esc": 53,
    "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]

let arrowKeys: Set<CGKeyCode> = [123, 124, 125, 126]
let fnKeys: Set<CGKeyCode> = [115, 119, 116, 121, 117]

final class Injector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var savedPasteboard: [NSPasteboardItem]?
    private var restoreWork: DispatchWorkItem?

    func pressKey(_ name: String, mods: [String], repeatCount: Int = 1) -> Bool {
        guard let code = keyCodes[name.lowercased()] else { return false }
        var flags = CGEventFlags()
        for m in mods {
            switch m.lowercased() {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: break
            }
        }
        if arrowKeys.contains(code) {
            flags.insert(.maskSecondaryFn)
            flags.insert(.maskNumericPad)
        } else if fnKeys.contains(code) {
            flags.insert(.maskSecondaryFn)
        }
        for _ in 0..<max(1, min(repeatCount, 500)) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            else { return false }
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(3000)
        }
        return true
    }

    func typeText(_ text: String, mode: String) {
        if mode == "paste" {
            paste(text)
            return
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        withKeyboardLayoutInput {
            for (i, line) in lines.enumerated() {
                if i > 0 { _ = pressKey("return", mods: []) }
                typeUnicode(line)
            }
        }
    }

    /// 直接把 Unicode 字符作为键盘事件发给前台 App，中英文都能上屏。
    private func typeUnicode(_ s: String) {
        let units = Array(s.utf16)
        var i = 0
        while i < units.count {
            var end = min(i + 16, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[i..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(4000)
            i = end
        }
    }

    /// Mac 当前是中文等输入法时，临时切到英文键盘布局，避免输入法截获注入的事件。
    private func withKeyboardLayoutInput(_ body: () -> Void) {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              !isKeyboardLayout(current),
              let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        else {
            body()
            return
        }
        TISSelectInputSource(ascii)
        usleep(40_000)
        body()
        usleep(40_000)
        TISSelectInputSource(current)
    }

    private func isKeyboardLayout(_ src: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceType) else { return true }
        let type = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        return type == (kTISTypeKeyboardLayout as String)
    }

    /// 剪贴板 + ⌘V，兼容性最好；粘贴后自动恢复原剪贴板内容。
    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        if savedPasteboard == nil {
            savedPasteboard = (pb.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for t in item.types {
                    if let d = item.data(forType: t) { copy.setData(d, forType: t) }
                }
                return copy
            }
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        usleep(20_000)
        _ = pressKey("v", mods: ["cmd"])
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restorePasteboard() }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func restorePasteboard() {
        guard let items = savedPasteboard else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
        savedPasteboard = nil
    }
}

// MARK: - 极简 HTTP 服务

struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct Response {
    var status: Int
    var contentType: String
    var body: Data

    static func json(_ status: Int, _ obj: [String: Any]) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return Response(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func text(_ status: Int, _ s: String) -> Response {
        Response(status: status, contentType: "text/plain; charset=utf-8", body: Data(s.utf8))
    }
}

let statusText: [Int: String] = [
    200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
    413: "Payload Too Large", 500: "Internal Server Error",
]

final class HTTPConnection {
    private let conn: NWConnection
    private let handler: (Request) -> Response
    private var buffer = Data()
    var onClose: (() -> Void)?

    init(_ conn: NWConnection, handler: @escaping (Request) -> Response) {
        self.conn = conn
        self.handler = handler
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.onClose?()
            default: break
            }
        }
        conn.start(queue: .main)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.process()
            }
            if isComplete || error != nil {
                self.conn.cancel()
                return
            }
            self.receive()
        }
    }

    private func process() {
        let separator = Data("\r\n\r\n".utf8)
        while let headerEnd = buffer.range(of: separator) {
            guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8)
            else { conn.cancel(); return }
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines[0].split(separator: " ")
            guard parts.count >= 2 else { conn.cancel(); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            if length > 1_000_000 {
                send(.text(413, "too large"), keepAlive: false)
                return
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.endIndex - bodyStart >= length else { return }
            let body = buffer[bodyStart..<(bodyStart + length)]
            let req = Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body))
            buffer = Data(buffer[(bodyStart + length)...])
            send(handler(req), keepAlive: headers["connection"]?.lowercased() != "close")
        }
    }

    private func send(_ resp: Response, keepAlive: Bool) {
        var head = "HTTP/1.1 \(resp.status) \(statusText[resp.status] ?? "OK")\r\n"
        head += "Content-Type: \(resp.contentType)\r\n"
        head += "Content-Length: \(resp.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        data.append(resp.body)
        conn.send(content: data, completion: .contentProcessed { [weak self] _ in
            if !keepAlive { self?.conn.cancel() }
        })
    }
}

final class HTTPServer {
    private let listener: NWListener
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private let handler: (Request) -> Response

    init(port: UInt16, bind: String?, handler: @escaping (Request) -> Response) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: port)!
        if let bind {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bind), port: nwPort)
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: nwPort)
        }
        self.handler = handler
    }

    func start() {
        listener.newConnectionHandler = { [weak self] nw in
            guard let self else { return }
            let c = HTTPConnection(nw, handler: self.handler)
            let id = ObjectIdentifier(c)
            self.connections[id] = c
            c.onClose = { [weak self] in self?.connections[id] = nil }
            c.start()
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                print("监听失败: \(err)")
                exit(1)
            }
        }
        listener.start(queue: .main)
    }
}

// MARK: - 网络地址与二维码

func localIPv4Addresses() -> [(name: String, ip: String)] {
    var result: [(String, String)] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        guard let addr = ptr.pointee.ifa_addr,
              addr.pointee.sa_family == UInt8(AF_INET),
              flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
        else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = String(cString: ptr.pointee.ifa_name)
            result.append((name, ip))
        }
    }
    return result
}

func isTailscaleIP(_ ip: String) -> Bool {
    let p = ip.split(separator: ".").compactMap { Int($0) }
    return p.count == 4 && p[0] == 100 && (64...127).contains(p[1])
}

/// 用 CoreImage 生成二维码，并用半格字符打印到终端（显式指定黑白色，深浅色终端都能扫）。
func qrMatrix(_ string: String) -> [[Bool]]? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(string.utf8), forKey: "inputMessage")
    filter.setValue("L", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage,
          let cg = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    let w = cg.width, h = cg.height
    var pixels = [UInt8](repeating: 255, count: w * h)
    let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return nil }
    return (0..<h).map { y in (0..<w).map { x in pixels[y * w + x] < 128 } }
}

func printQRCode(_ string: String) {
    guard let m = qrMatrix(string) else { return }
    let h = m.count, w = m.first?.count ?? 0
    let quiet = 2
    func dark(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && m[y][x] }
    var y = -quiet
    while y < h + quiet {
        var line = ""
        for x in -quiet..<(w + quiet) {
            let fg = dark(x, y) ? "30" : "97"
            let bg = dark(x, y + 1) ? "40" : "107"
            line += "\u{1B}[\(fg);\(bg)m▀"
        }
        print(line + "\u{1B}[0m")
        y += 2
    }
}

// MARK: - 主逻辑

setvbuf(stdout, nil, _IOLBF, 0)
let opts = parseOptions()
let token = loadToken(reset: opts.resetToken)
let injector = Injector()

guard let webDir = findWebDir() else {
    print("找不到 web/index.html，请在项目目录里运行，或设置 RK_WEB 环境变量。")
    exit(1)
}

func tokenMatches(_ given: String?) -> Bool {
    guard let given else { return false }
    let a = Array(given.utf8), b = Array(token.utf8)
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}

func serveFile(_ name: String, _ type: String) -> Response {
    guard let data = try? Data(contentsOf: webDir.appendingPathComponent(name)) else {
        return .text(404, "not found")
    }
    return Response(status: 200, contentType: type, body: data)
}

func runOp(_ op: [String: Any]) -> String? {
    switch op["type"] as? String {
    case "ping":
        return nil
    case "text":
        guard let text = op["text"] as? String else { return "缺少 text" }
        injector.typeText(text, mode: op["mode"] as? String ?? "unicode")
        print("[text] \(text.count) 个字符")
        return nil
    case "key":
        guard let key = op["key"] as? String else { return "缺少 key" }
        let mods = op["mods"] as? [String] ?? []
        let count = op["repeat"] as? Int ?? 1
        guard injector.pressKey(key, mods: mods, repeatCount: count) else { return "未知按键: \(key)" }
        print("[key] \((mods + [key]).joined(separator: "+"))\(count > 1 ? " ×\(count)" : "")")
        return nil
    default:
        return "未知指令"
    }
}

func handle(_ req: Request) -> Response {
    let path = String(req.path.split(separator: "?", maxSplits: 1).first ?? "/")
    switch (req.method, path) {
    case ("GET", "/"), ("GET", "/index.html"):
        return serveFile("index.html", "text/html; charset=utf-8")
    case ("GET", "/manifest.webmanifest"):
        return serveFile("manifest.webmanifest", "application/manifest+json")
    case ("GET", "/icon.svg"):
        return serveFile("icon.svg", "image/svg+xml")
    case ("POST", "/api"):
        guard tokenMatches(req.headers["x-token"]) else {
            return .json(401, ["ok": false, "error": "unauthorized"])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            return .json(400, ["ok": false, "error": "bad json"])
        }
        let ops = obj["ops"] as? [[String: Any]] ?? [obj]
        for op in ops {
            if let err = runOp(op) {
                return .json(400, ["ok": false, "error": err, "trusted": AXIsProcessTrusted()])
            }
        }
        return .json(200, ["ok": true, "trusted": AXIsProcessTrusted()])
    default:
        return .text(404, "not found")
    }
}

let shouldPrompt = ProcessInfo.processInfo.environment["RK_NO_PROMPT"] == nil
let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": shouldPrompt] as CFDictionary)

let server: HTTPServer
do {
    server = try HTTPServer(port: opts.port, bind: opts.bind, handler: handle)
} catch {
    print("启动失败: \(error)")
    exit(1)
}
server.start()

print("Remote Keyboard 已启动，端口 \(opts.port)\n")
if !trusted {
    print("⚠️  还没有辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，")
    print("   给运行本程序的终端（或本程序）打开开关，然后重启本程序。\n")
}

let addrs = localIPv4Addresses()
let tailscale = addrs.first { isTailscaleIP($0.ip) }
if let bind = opts.bind {
    print("仅监听 \(bind)。")
}
for a in addrs where opts.bind == nil {
    let tag = isTailscaleIP(a.ip) ? "  ← Tailscale，车上用这个" : ""
    print("  http://\(a.ip):\(opts.port)/?t=\(token)  (\(a.name))\(tag)")
}
print("")

if let ts = tailscale, opts.bind == nil {
    print("用手机扫码打开（Tailscale 地址）：")
    printQRCode("http://\(ts.ip):\(opts.port)/?t=\(token)")
} else if opts.bind == nil, let lan = addrs.first {
    print("没检测到 Tailscale，下面是局域网地址的二维码（只能在同一 Wi-Fi 下使用）：")
    printQRCode("http://\(lan.ip):\(opts.port)/?t=\(token)")
} else {
    print("Token: \(token)")
}

dispatchMain()
