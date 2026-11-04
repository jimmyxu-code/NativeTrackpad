import CoreFoundation
import Foundation

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var state: UInt32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVector
    var zTotal: Float
    var field9: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var field14: Int32
    var field15: Int32
    var zDensity: Float
}

private typealias MTDeviceCreateListFunction = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTDeviceStartFunction = @convention(c) (UnsafeRawPointer, Int32) -> Int32
private typealias MTDeviceStopFunction = @convention(c) (UnsafeRawPointer) -> Int32
private typealias MTDeviceIsBuiltInFunction = @convention(c) (UnsafeRawPointer) -> Bool
private typealias MTContactCallback = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?, Int, Double, Int, UnsafeMutableRawPointer?) -> Void
private typealias MTRegisterFunction = @convention(c) (UnsafeRawPointer, MTContactCallback?, UnsafeMutableRawPointer?) -> Void

private func contactCallback(device: UnsafeRawPointer?, touches: UnsafeMutableRawPointer?, count: Int,
                             timestamp: Double, frame: Int, context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let monitor = Unmanaged<MultitouchMonitor>.fromOpaque(context).takeUnretainedValue()
    var samples: [TouchSample] = []
    samples.reserveCapacity(count)
    if let touches {
        let touches = touches.assumingMemoryBound(to: MTTouch.self)
        for index in 0..<count {
            let touch = touches[index]
            samples.append(TouchSample(id: touch.pathIndex, state: touch.state,
                                       position: TouchPoint(x: Double(touch.normalizedVector.position.x),
                                                            y: Double(touch.normalizedVector.position.y))))
        }
    }
    monitor.receive(TouchFrame(device: device.map { UInt(bitPattern: $0) } ?? 0,
                               timestamp: timestamp, touches: samples))
}

struct TrackpadDeviceInfo: Sendable {
    var index: Int
    var isBuiltIn: Bool?
}

enum MultitouchError: LocalizedError {
    case frameworkUnavailable(String)
    case symbolUnavailable(String)
    case invalidABI
    case noDevices
    case startFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .frameworkUnavailable(let detail): "无法加载 MultitouchSupport：\(detail)"
        case .symbolUnavailable(let symbol): "MultitouchSupport 缺少符号：\(symbol)"
        case .invalidABI: "MTTouch 内存布局与预期不符，已停止以避免错误读取"
        case .noDevices: "没有发现可用的多点触控设备"
        case .startFailed(let status): "启动触控板监听失败，OSStatus=\(status)"
        }
    }
}

final class MultitouchMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.native-trackpad.frames")
    private var handle: UnsafeMutableRawPointer?
    private var deviceList: CFArray?
    private var devices: [UnsafeRawPointer] = []
    private var startedDevices: [UnsafeRawPointer] = []
    private var createList: MTDeviceCreateListFunction?
    private var startDevice: MTDeviceStartFunction?
    private var stopDevice: MTDeviceStopFunction?
    private var isBuiltIn: MTDeviceIsBuiltInFunction?
    private var register: MTRegisterFunction?
    private var frameHandler: (@Sendable (TouchFrame) -> Void)?
    private let stateLock = NSLock()
    private var running = false

    init() throws {
        guard MemoryLayout<MTTouch>.size == 96, MemoryLayout<MTTouch>.stride == 96,
              MemoryLayout<MTTouch>.offset(of: \MTTouch.normalizedVector) == 32 else {
            throw MultitouchError.invalidABI
        }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw MultitouchError.frameworkUnavailable(dlerror().map { String(cString: $0) } ?? "dlopen 失败")
        }
        self.handle = handle
        createList = try symbol("MTDeviceCreateList", as: MTDeviceCreateListFunction.self)
        startDevice = try symbol("MTDeviceStart", as: MTDeviceStartFunction.self)
        stopDevice = try symbol("MTDeviceStop", as: MTDeviceStopFunction.self)
        register = try symbol("MTRegisterContactFrameCallbackWithRefcon", as: MTRegisterFunction.self)
        isBuiltIn = try? symbol("MTDeviceIsBuiltIn", as: MTDeviceIsBuiltInFunction.self)
        guard let list = createList?()?.takeRetainedValue() else {
            throw MultitouchError.noDevices
        }
        deviceList = list
        let count = CFArrayGetCount(list)
        devices = (0..<count).compactMap { CFArrayGetValueAtIndex(list, $0) }
        guard !devices.isEmpty else { throw MultitouchError.noDevices }
    }

    deinit {
        stop()
    }

    var deviceInfos: [TrackpadDeviceInfo] {
        devices.enumerated().map { TrackpadDeviceInfo(index: $0.offset, isBuiltIn: isBuiltIn?($0.element)) }
    }

    func start(handler: @escaping @Sendable (TouchFrame) -> Void) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !running else { return }
        frameHandler = handler
        for device in devices {
            register?(device, contactCallback, Unmanaged.passUnretained(self).toOpaque())
            let status = startDevice?(device, 0) ?? -1
            guard status == 0 else {
                for started in startedDevices {
                    register?(started, nil, Unmanaged.passUnretained(self).toOpaque())
                    _ = stopDevice?(started)
                }
                startedDevices = []
                frameHandler = nil
                throw MultitouchError.startFailed(status)
            }
            startedDevices.append(device)
        }
        running = true
    }

    func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        let active = startedDevices
        startedDevices = []
        stateLock.unlock()
        guard wasRunning else { return }
        for device in active {
            register?(device, nil, Unmanaged.passUnretained(self).toOpaque())
            _ = stopDevice?(device)
        }
        queue.sync {
            frameHandler = nil
        }
    }

    fileprivate func receive(_ frame: TouchFrame) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.frameHandler?(frame)
        }
    }

    private func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard let pointer = dlsym(handle, name) else { throw MultitouchError.symbolUnavailable(name) }
        return unsafeBitCast(pointer, to: type)
    }
}
