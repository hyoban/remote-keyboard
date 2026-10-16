import AppKit
import os

private let detectorLog = Logger(subsystem: "dev.hyoban.remote-keyboard", category: "remote")

/// Listens (read-only) to mouse and keyboard events to tell remote control from local use:
/// hardware input has source PID 0, while remote desktop apps post events under their own PID
/// (e.g. UU Remote's UURemoteServer).
final class RemoteDetector {
    /// Called when the input source switches between remote and local; true means remote.
    var onChange: ((Bool) -> Void)?
    /// Called on every mouse down with the Quartz global location (origin at the top left of the main screen).
    var onClick: ((CGPoint) -> Void)?
    private(set) var isRemote: Bool?

    private var tap: CFMachPort?
    private let ownPID = getpid()
    private var loggedUnknown: Set<pid_t> = []

    /// Process names (lowercase substrings) of common remote desktop apps that post events.
    private static let remoteProcessKeywords = [
        "uuremote", "todesk", "sunlogin", "anydesk", "teamviewer", "rustdesk", "parsec",
        "screensharingd", "ardagent",
    ]

    func start() {
        guard tap == nil else { return }
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        // Scroll wheel events are ignored: tools like Mac Mouse Fix rewrite them and would cause false positives.
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
                // Events posted by other tools (key remappers, automation scripts) don't count.
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
