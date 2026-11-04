import ApplicationServices
import CoreFoundation
import Darwin
import Foundation

final class GestureEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.native-trackpad.recognizer")
    private var recognizer = GestureRecognizer()
    private let performer: any ActionPerforming
    private let observe: Bool
    private var lastFrameLog = -Double.infinity
    private var lastCount = -1
    private var latestFrames: [UInt: (frame: TouchFrame, receivedAt: UInt64)] = [:]
    private var timer: DispatchSourceTimer?
    private var running = false

    init(performer: any ActionPerforming, observe: Bool) {
        self.performer = performer
        self.observe = observe
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            self.running = true
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.advanceClock() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            running = false
            timer?.cancel()
            timer = nil
            latestFrames = [:]
        }
    }

    func receive(_ frame: TouchFrame) {
        queue.async {
            self.latestFrames[frame.device] = (frame, DispatchTime.now().uptimeNanoseconds)
            self.process(frame, logFrame: true)
        }
    }

    private func advanceClock() {
        guard running else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        for latest in latestFrames.values {
            var frame = latest.frame
            frame.timestamp += Double(now - latest.receivedAt) / 1_000_000_000
            process(frame, logFrame: false)
        }
    }

    private func process(_ frame: TouchFrame, logFrame: Bool) {
        let recognitions = recognizer.process(frame)
        if logFrame, observe, Log.verbose, frame.timestamp - lastFrameLog >= 0.08 || logFrame && observe && frame.touches.count != lastCount {
            let touches = frame.touches.map { String(format: "%d:%d(%.3f,%.3f)", $0.id, $0.state, $0.position.x, $0.position.y) }
            Log.debug("device=\(frame.device) touches=[\(touches.joined(separator: " "))]")
            lastFrameLog = frame.timestamp
            lastCount = frame.touches.count
        }
        for recognition in recognitions {
            Log.info("识别：\(recognition.detail) -> \(recognition.action.rawValue)")
            performer.perform(recognition.action)
        }
    }
}

func accessibilityTrusted(prompt: Bool) -> Bool {
    let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

func printHelp() {
    print("""
    TrackpadGestures — 不依赖 BetterTouchTool 的原生触控板手势

    用法：
      TrackpadGestures check              检查触控板接口、设备和辅助功能权限
      TrackpadGestures observe [--verbose] 只观察/识别，不执行按键或截图
      TrackpadGestures run                监听并执行五个手势
      TrackpadGestures self-test          运行合成触点与定时器自检
      TrackpadGestures action-check copy|paste|delete|hold
      TrackpadGestures action-check image-file <PNG路径>
                                          检查系统动作/截图剪贴板链路

    手势：双指并拢复制；双指分开粘贴；三指并拢截图到剪贴板并保存 PNG；三指分开粘贴；四指轻点/长按退格。
    四指保持 0.22 秒首次退格，0.4 秒起每 0.08 秒重复，移动或抬起停止。
    控制-C 停止。首次 run 需要辅助功能权限；截图需要 macOS 录屏权限。
    """)
}

final class SelfTestActionPerformer: @unchecked Sendable, ActionPerforming {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var recorded: [GestureAction] = []

    var actions: [GestureAction] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func perform(_ action: GestureAction) {
        lock.lock()
        recorded.append(action)
        lock.unlock()
        semaphore.signal()
    }

    func waitForActions(_ count: Int, timeout: Double) -> [GestureAction] {
        let deadline = DispatchTime.now() + timeout
        for _ in 0..<count {
            if semaphore.wait(timeout: deadline) == .timedOut { break }
        }
        return actions
    }
}

func verifyEngineHold() -> [GestureAction] {
    let points = [TouchPoint(x: 0.3, y: 0.4), TouchPoint(x: 0.45, y: 0.4),
                  TouchPoint(x: 0.6, y: 0.4), TouchPoint(x: 0.75, y: 0.4)]
    let frame = TouchFrame(device: 99, timestamp: 0,
                           touches: points.enumerated().map { TouchSample(id: Int32($0.offset + 1), state: 4, position: $0.element) })
    let performer = SelfTestActionPerformer()
    let engine = GestureEngine(performer: performer, observe: false)
    engine.start()
    engine.receive(frame)
    let actions = performer.waitForActions(3, timeout: 1.2)
    engine.stop()
    return actions
}

func runSelfTest() -> Int32 {
    var failures: [String] = []
    var checks = 0

    func frame(_ timestamp: Double, _ points: [TouchPoint], device: UInt = 1) -> TouchFrame {
        TouchFrame(device: device, timestamp: timestamp,
                   touches: points.enumerated().map { TouchSample(id: Int32($0.offset + 1), state: 4, position: $0.element) })
    }
    func pair(_ separation: Double, center: Double = 0.5) -> [TouchPoint] {
        [TouchPoint(x: center - separation / 2, y: 0.5), TouchPoint(x: center + separation / 2, y: 0.5)]
    }
    func triple(_ separation: Double) -> [TouchPoint] {
        [TouchPoint(x: 0.5 - separation / 2, y: 0.4), TouchPoint(x: 0.5 + separation / 2, y: 0.4),
         TouchPoint(x: 0.5, y: 0.4 + separation)]
    }
    func expect(_ name: String, _ frames: [TouchFrame], _ expected: [GestureAction]) {
        checks += 1
        var recognizer = GestureRecognizer()
        let actual = frames.flatMap { recognizer.process($0) }.map(\.action)
        if actual != expected { failures.append("\(name)：期望 \(expected)，实际 \(actual)") }
    }

    expect("双指并拢复制", [frame(0, pair(0.5)), frame(0.07, pair(0.5)), frame(0.15, pair(0.25)),
                          frame(0.2, pair(0.2)), frame(0.25, [])], [.copy])
    expect("双指分开粘贴", [frame(0, pair(0.25)), frame(0.07, pair(0.25)), frame(0.15, pair(0.5)), frame(0.2, [])], [.paste])
    expect("三指并拢截图", [frame(0, triple(0.45)), frame(0.07, triple(0.45)), frame(0.16, triple(0.2)), frame(0.2, [])], [.screenshot])
    expect("三指分开粘贴", [frame(0, triple(0.2)), frame(0.07, triple(0.2)), frame(0.16, triple(0.45)), frame(0.2, [])], [.paste])
    expect("四指轻点退格", [frame(0, [TouchPoint(x: 0.3, y: 0.4), TouchPoint(x: 0.45, y: 0.4),
                                      TouchPoint(x: 0.6, y: 0.4), TouchPoint(x: 0.75, y: 0.4)]),
                          frame(0.18, [])], [.deleteBackward])
    expect("双指滚动不误触", [frame(0, pair(0.4, center: 0.4)), frame(0.07, pair(0.4, center: 0.4)),
                             frame(0.15, pair(0.4, center: 0.7)), frame(0.2, [])], [])
    expect("四指长按连续退格", [frame(0, [TouchPoint(x: 0.3, y: 0.4), TouchPoint(x: 0.45, y: 0.4),
                                       TouchPoint(x: 0.6, y: 0.4), TouchPoint(x: 0.75, y: 0.4)]),
                               frame(0.22, [TouchPoint(x: 0.3, y: 0.4), TouchPoint(x: 0.45, y: 0.4),
                                            TouchPoint(x: 0.6, y: 0.4), TouchPoint(x: 0.75, y: 0.4)]),
                               frame(0.39, [TouchPoint(x: 0.3, y: 0.4), TouchPoint(x: 0.45, y: 0.4),
                                            TouchPoint(x: 0.6, y: 0.4), TouchPoint(x: 0.75, y: 0.4)]),
                               frame(0.4, [TouchPoint(x: 0.3, y: 0.4), TouchPoint(x: 0.45, y: 0.4),
                                           TouchPoint(x: 0.6, y: 0.4), TouchPoint(x: 0.75, y: 0.4)]),
                               frame(0.48, [TouchPoint(x: 0.3, y: 0.4), TouchPoint(x: 0.45, y: 0.4),
                                            TouchPoint(x: 0.6, y: 0.4), TouchPoint(x: 0.75, y: 0.4)]), frame(0.5, [])],
     [.deleteBackward, .deleteBackward, .deleteBackward])
    expect("小幅缩放不误触", [frame(0, pair(0.4)), frame(0.07, pair(0.4)), frame(0.15, pair(0.37)), frame(0.2, [])], [])
    expect("设备状态隔离", [frame(0, pair(0.5)), frame(0.07, pair(0.5)),
                           frame(0.1, [TouchPoint(x: 0.2, y: 0.2)], device: 2), frame(0.15, pair(0.25))], [.copy])
    expect("四指移动不误触", [frame(0, [TouchPoint(x: 0.3, y: 0.4), TouchPoint(x: 0.45, y: 0.4),
                                      TouchPoint(x: 0.6, y: 0.4), TouchPoint(x: 0.75, y: 0.4)]),
                             frame(0.1, [TouchPoint(x: 0.35, y: 0.4), TouchPoint(x: 0.5, y: 0.4),
                                         TouchPoint(x: 0.65, y: 0.4), TouchPoint(x: 0.8, y: 0.4)]), frame(0.18, [])], [])
    expect("超时合拢不误触", [frame(0, pair(0.5)), frame(0.07, pair(0.5)),
                             frame(1.6, pair(0.25)), frame(1.7, [])], [])
    expect("跨接触防连发", [frame(0, pair(0.5)), frame(0.07, pair(0.5)), frame(0.15, pair(0.25)), frame(0.2, []),
                           frame(0.21, [TouchPoint(x: 0.3, y: 0.4), TouchPoint(x: 0.45, y: 0.4),
                                       TouchPoint(x: 0.6, y: 0.4), TouchPoint(x: 0.75, y: 0.4)]), frame(0.3, [])], [.copy])

    checks += 1
    let timerActions = verifyEngineHold()
    if timerActions != [.deleteBackward, .deleteBackward, .deleteBackward] {
        failures.append("定时器无后续帧连续退格：实际 \(timerActions)")
    }

    if failures.isEmpty {
        print("self-test：\(checks)/\(checks) 通过")
        return 0
    }
    for failure in failures { FileHandle.standardError.write(Data("FAIL \(failure)\n".utf8)) }
    print("self-test：\(checks - failures.count)/\(checks) 通过")
    return 1
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "--help"
Log.verbose = arguments.contains("--verbose")

switch command {
case "--help", "-h", "help":
    printHelp()
case "self-test":
    exit(runSelfTest())
case "action-check":
    if arguments.count == 3, arguments[1] == "image-file" {
        let copied = SystemActionPerformer().copyPNGToPasteboard(fileAtPath: arguments[2])
        Log.info(copied ? "PNG 已写入剪贴板" : "无法读取 PNG 或写入剪贴板")
        exit(copied ? 0 : 1)
    }
    guard arguments.count == 2 else {
        Log.error("用法：TrackpadGestures action-check copy|paste|delete|hold|image-file <PNG路径>")
        exit(64)
    }
    guard accessibilityTrusted(prompt: false) else {
        Log.error("辅助功能权限未授予")
        exit(2)
    }
    if arguments[1] == "hold" {
        let points = [TouchPoint(x: 0.3, y: 0.4), TouchPoint(x: 0.45, y: 0.4),
                      TouchPoint(x: 0.6, y: 0.4), TouchPoint(x: 0.75, y: 0.4)]
        let frame = TouchFrame(device: 99, timestamp: 0,
                               touches: points.enumerated().map { TouchSample(id: Int32($0.offset + 1), state: 4, position: $0.element) })
        let engine = GestureEngine(performer: SystemActionPerformer(), observe: false)
        engine.start()
        engine.receive(frame)
        Thread.sleep(forTimeInterval: 0.54)
        engine.stop()
        exit(0)
    }
    let actions = ["copy": GestureAction.copy, "paste": .paste, "delete": .deleteBackward]
    guard let action = actions[arguments[1]] else {
        Log.error("未知动作：\(arguments[1])")
        exit(64)
    }
    SystemActionPerformer().perform(action)
    exit(0)
case "check", "observe", "run":
    do {
        let monitor = try MultitouchMonitor()
        let info = monitor.deviceInfos.map { "#\($0.index + 1) 内置=\($0.isBuiltIn.map(String.init) ?? "未知")" }.joined(separator: ", ")
        Log.info("检测到 \(monitor.deviceInfos.count) 个触控设备：\(info)")
        if command == "check" {
            print("MultitouchSupport：可用")
            print("触控设备：\(monitor.deviceInfos.count)")
            print("辅助功能权限：\(accessibilityTrusted(prompt: false) ? "已授予" : "未授予")")
            exit(0)
        }
        if command == "run", !accessibilityTrusted(prompt: !arguments.contains("--no-prompt")) {
            Log.error("请在系统设置 > 隐私与安全性 > 辅助功能中授权后重新运行；本次未启动监听")
            exit(2)
        }
        let observe = command == "observe"
        let performer: any ActionPerforming = observe ? ObserveOnlyPerformer() : SystemActionPerformer()
        let engine = GestureEngine(performer: performer, observe: observe)
        engine.start()
        try monitor.start { frame in engine.receive(frame) }
        Log.info(observe ? "只观察模式已启动，不会注入动作；Control-C 停止" : "手势监听已启动；Control-C 停止")

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        var signalSources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Log.info("正在停止")
                monitor.stop()
                engine.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
        withExtendedLifetime(signalSources) {
            RunLoop.main.run()
        }
    } catch {
        Log.error(error.localizedDescription)
        exit(1)
    }
default:
    FileHandle.standardError.write(Data("未知命令：\(command)\n".utf8))
    printHelp()
    exit(64)
}
