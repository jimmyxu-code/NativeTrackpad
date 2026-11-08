import AppKit
import ApplicationServices
import Foundation

protocol ActionPerforming: Sendable {
    func perform(_ action: GestureAction)
}

final class SystemActionPerformer: @unchecked Sendable, ActionPerforming {
    private let lock = NSLock()
    private var screenshotInProgress = false
    private var screenshotProcess: Process?

    func perform(_ action: GestureAction) {
        switch action {
        case .copy:
            postKey(8, command: true)
        case .paste:
            postKey(9, command: true)
        case .deleteBackward:
            postKey(51, command: false)
        case .space:
            postKey(49, command: false)
        case .returnKey:
            postKey(36, command: false)
        case .screenshot:
            startScreenshot()
        }
    }

    private func postKey(_ keyCode: CGKeyCode, command: Bool) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            Log.error("无法创建键盘事件：\(keyCode)")
            return
        }
        down.flags = command ? .maskCommand : []
        up.flags = command ? .maskCommand : []
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)
        up.post(tap: .cghidEventTap)
        let name: String
        switch keyCode {
        case 51: name = "退格"
        case 49: name = "空格"
        case 36: name = "回车"
        case 8: name = "C"
        case 9: name = "V"
        default: name = "键码 \(keyCode)"
        }
        Log.info("已投递：\(command ? "Command-" : "")\(name)")
    }

    private func startScreenshot() {
        lock.lock()
        if screenshotInProgress {
            lock.unlock()
            Log.info("截图已在进行，忽略重复请求")
            return
        }
        screenshotInProgress = true
        lock.unlock()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "Screenshot_\(formatter.string(from: Date()))_\(String(format: "%08x", UInt32.random(in: .min ... .max))).png"
        let path = NSHomeDirectory() + "/Pictures/" + name
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-t", "png", path]
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { process in
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let copied = process.terminationStatus == 0 && self.copyPNGToPasteboard(fileAtPath: path)
            self.lock.lock()
            self.screenshotInProgress = false
            self.screenshotProcess = nil
            self.lock.unlock()
            if process.terminationStatus == 0 {
                if copied {
                    Log.info("区域截图已保存并复制到剪贴板：\(path)")
                } else if FileManager.default.fileExists(atPath: path) {
                    Log.error("PNG 已保存，但写入剪贴板失败：\(path)")
                } else {
                    Log.info("区域截图已取消，剪贴板保持不变")
                }
            } else {
                Log.error("截图失败（\(process.terminationStatus)）：\(detail)")
            }
        }
        lock.lock()
        screenshotProcess = process
        lock.unlock()
        do {
            try process.run()
            Log.info("已进入区域截图；按 Esc 可取消")
        } catch {
            lock.lock()
            screenshotInProgress = false
            screenshotProcess = nil
            lock.unlock()
            Log.error("无法启动 screencapture：\(error.localizedDescription)")
        }
    }

    func copyPNGToPasteboard(fileAtPath path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }
}

final class ObserveOnlyPerformer: ActionPerforming {
    func perform(_ action: GestureAction) {
        Log.info("仅观察，不执行：\(action.rawValue)")
    }
}

enum Log {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var verboseStorage = false
    static var verbose: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return verboseStorage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            verboseStorage = newValue
        }
    }

    static func info(_ message: String) {
        write("INFO", message)
    }

    static func debug(_ message: String) {
        guard verbose else { return }
        write("DEBUG", message)
    }

    static func error(_ message: String) {
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data("[\(level)] \(message)\n".utf8))
    }
}
