import AppKit
import os

private let detectorLog = Logger(subsystem: "dev.hyoban.remote-keyboard", category: "remote")

/// 只读监听鼠标和键盘事件，判断当前是在远程控制还是本地操作：
/// 真实硬件输入的来源 PID 是 0，远程控制软件注入的事件带着它自己的 PID（如 UU 远程的 UURemoteServer）。
final class RemoteDetector {
    /// 输入来源在“远程/本地”之间切换时回调，true 表示远程。
    var onChange: ((Bool) -> Void)?
    /// 每次鼠标按下时回调，参数是 Quartz 全局坐标（原点在主屏左上角）。
    var onClick: ((CGPoint) -> Void)?
    private(set) var isRemote: Bool?

    private var tap: CFMachPort?
    private let ownPID = getpid()
    private var loggedUnknown: Set<pid_t> = []

    /// 常见远程控制软件注入事件的进程名（小写匹配）。
    private static let remoteProcessKeywords = [
        "uuremote", "todesk", "sunlogin", "anydesk", "teamviewer", "rustdesk", "parsec",
        "screensharingd", "ardagent",
    ]

    func start() {
        guard tap == nil else { return }
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        // 不监听滚轮：Mac Mouse Fix 这类工具会改写滚轮事件，容易误判。
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .mouseMoved, .leftMouseDragged, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<RemoteDetector>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            detectorLog.notice("failed to create event tap")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        guard pid != ownPID else { return }
        if type == .leftMouseDown || type == .rightMouseDown { onClick?(event.location) }

        let remote: Bool
        if pid == 0 {
            remote = false
        } else {
            let name = Self.processName(pid)
            let lower = name.lowercased()
            guard Self.remoteProcessKeywords.contains(where: lower.contains) else {
                // 其他工具注入的事件（键位映射、自动化脚本等）不参与判断。
                if loggedUnknown.insert(pid).inserted {
                    detectorLog.notice("ignoring events from pid=\(pid) \(name, privacy: .public)")
                }
                return
            }
            remote = true
        }
        guard remote != isRemote else { return }
        isRemote = remote
        detectorLog.notice("input source -> \(remote ? "remote" : "local", privacy: .public) (pid=\(pid) \(Self.processName(pid), privacy: .public))")
        onChange?(remote)
    }

    static func processName(_ pid: pid_t) -> String {
        if pid == 0 { return "(hardware)" }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "?" }
        let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (path as NSString).lastPathComponent
    }
}
