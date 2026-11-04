import Foundation

struct TouchPoint: Sendable, Equatable {
    var x: Double
    var y: Double

    func distance(to other: TouchPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

struct TouchSample: Sendable {
    var id: Int32
    var state: UInt32
    var position: TouchPoint
}

struct TouchFrame: Sendable {
    var device: UInt
    var timestamp: Double
    var touches: [TouchSample]
}

enum GestureAction: String, Sendable {
    case copy = "复制 Command-C"
    case paste = "粘贴 Command-V"
    case screenshot = "区域截图（PNG + 剪贴板）"
    case deleteBackward = "退格"
}

struct Recognition: Sendable {
    var action: GestureAction
    var device: UInt
    var timestamp: Double
    var detail: String
}

struct GestureConfiguration: Sendable {
    var settlingDuration = 0.06
    var maximumGestureDuration = 1.5
    var pinchInRatio = 0.72
    var pinchOutRatio = 1.35
    var minimumDistanceChange = 0.045
    var maximumCentroidDrift = 0.16
    var maximumTapDuration = 0.32
    var maximumTapMovement = 0.035
    var deleteHoldActivationDelay = 0.22
    var deleteRepeatDelay = 0.4
    var deleteRepeatRate = 0.08
    var rearmDelay = 0.35
}

private struct FingerTrack {
    var first: TouchPoint
    var current: TouchPoint
}

private struct PinchCandidate {
    var count: Int
    var ids: Set<Int32>
    var startedAt: Double
    var baselineAt: Double?
    var baselineDistance = 0.0
    var baselineCentroid = TouchPoint(x: 0, y: 0)
}

private struct DeviceSession {
    var startedAt = 0.0
    var tracks: [Int32: FingerTrack] = [:]
    var candidate: PinchCandidate?
    var triggered = false
    var sawFour = false
    var maximumActiveCount = 0
    var tapCancelled = false
    var fourRepeatCancelled = false
    var fourStartedAt: Double?
    var fourNextRepeatAt = 0.0
    var fourRepeating = false
}

struct GestureRecognizer: Sendable {
    var configuration = GestureConfiguration()
    private var sessions: [UInt: DeviceSession] = [:]
    private var lastRecognitionAt: [UInt: Double] = [:]

    mutating func process(_ frame: TouchFrame) -> [Recognition] {
        let active = frame.touches.filter { (3...5).contains($0.state) }
        if active.isEmpty {
            return finishSession(device: frame.device, timestamp: frame.timestamp)
        }

        var session = sessions[frame.device] ?? DeviceSession(startedAt: frame.timestamp)
        for touch in active {
            if var track = session.tracks[touch.id] {
                track.current = touch.position
                session.tracks[touch.id] = track
            } else {
                session.tracks[touch.id] = FingerTrack(first: touch.position, current: touch.position)
            }
        }

        session.maximumActiveCount = max(session.maximumActiveCount, active.count)
        session.sawFour = session.sawFour || active.count == 4
        if active.count > 4 || frame.timestamp - session.startedAt > configuration.maximumTapDuration {
            session.tapCancelled = true
        }
        if active.count > 4 || session.tracks.values.contains(where: { $0.first.distance(to: $0.current) > configuration.maximumTapMovement }) {
            session.tapCancelled = true
            session.fourRepeatCancelled = true
        }

        var recognitions: [Recognition] = []
        if active.count == 4 {
            if session.fourStartedAt == nil {
                session.fourStartedAt = frame.timestamp
            }
            let fourStart = session.fourStartedAt ?? frame.timestamp
            if !session.triggered, !session.fourRepeatCancelled,
               frame.timestamp - fourStart >= configuration.deleteHoldActivationDelay,
               frame.timestamp - (lastRecognitionAt[frame.device] ?? -.infinity) >= configuration.rearmDelay {
                recognitions.append(Recognition(action: .deleteBackward, device: frame.device, timestamp: frame.timestamp,
                                                detail: "四指退格（首次）"))
                session.triggered = true
                session.fourRepeating = true
                session.fourNextRepeatAt = fourStart + configuration.deleteRepeatDelay
                lastRecognitionAt[frame.device] = frame.timestamp
            }
            if session.fourRepeating, !session.fourRepeatCancelled, frame.timestamp + 0.000_001 >= session.fourNextRepeatAt {
                recognitions.append(Recognition(action: .deleteBackward, device: frame.device, timestamp: frame.timestamp,
                                                detail: "四指长按连续退格"))
                session.fourNextRepeatAt = frame.timestamp + configuration.deleteRepeatRate
                lastRecognitionAt[frame.device] = frame.timestamp
            }
        } else {
            session.fourStartedAt = nil
            session.fourRepeating = false
        }

        if !session.triggered, active.count == 2 || active.count == 3 {
            if let recognition = recognizePinch(frame: frame, active: active, session: &session) {
                recognitions.append(recognition)
                session.triggered = true
                session.tapCancelled = true
                lastRecognitionAt[frame.device] = frame.timestamp
            }
        } else if active.count != 2 && active.count != 3 {
            session.candidate = nil
        }
        sessions[frame.device] = session
        return recognitions
    }

    private mutating func finishSession(device: UInt, timestamp: Double) -> [Recognition] {
        guard let session = sessions.removeValue(forKey: device) else { return [] }
        let duration = timestamp - session.startedAt
        let isTap = session.sawFour && session.maximumActiveCount == 4 && !session.tapCancelled &&
            !session.triggered && duration >= 0 && duration <= configuration.maximumTapDuration &&
            timestamp - (lastRecognitionAt[device] ?? -.infinity) >= configuration.rearmDelay
        guard isTap else { return [] }
        lastRecognitionAt[device] = timestamp
        return [Recognition(action: .deleteBackward, device: device, timestamp: timestamp,
                            detail: String(format: "四指轻点，时长 %.0f ms", duration * 1000))]
    }

    private func recognizePinch(frame: TouchFrame, active: [TouchSample], session: inout DeviceSession) -> Recognition? {
        let ids = Set(active.map(\.id))
        if frame.timestamp - (lastRecognitionAt[frame.device] ?? -.infinity) < configuration.rearmDelay {
            return nil
        }
        if var candidate = session.candidate, candidate.count == active.count, candidate.ids == ids {
            if frame.timestamp - candidate.startedAt > configuration.maximumGestureDuration {
                session.candidate = nil
                return nil
            }
            guard let positions = positionsByID(active: active, ids: ids) else { return nil }
            let distance = meanPairDistance(Array(positions.values))
            let centroid = centroidOf(Array(positions.values))
            guard let baselineAt = candidate.baselineAt else {
                if frame.timestamp - candidate.startedAt >= configuration.settlingDuration {
                    candidate.baselineAt = frame.timestamp
                    candidate.baselineDistance = distance
                    candidate.baselineCentroid = centroid
                }
                session.candidate = candidate
                return nil
            }
            guard frame.timestamp > baselineAt, candidate.baselineDistance > 0.05 else { return nil }
            let ratio = distance / candidate.baselineDistance
            let change = abs(distance - candidate.baselineDistance)
            let drift = centroid.distance(to: candidate.baselineCentroid)
            guard change >= configuration.minimumDistanceChange,
                  drift <= configuration.maximumCentroidDrift,
                  ratio <= configuration.pinchInRatio || ratio >= configuration.pinchOutRatio else {
                return nil
            }
            let inward = ratio <= configuration.pinchInRatio
            let action: GestureAction = active.count == 2 ? (inward ? .copy : .paste) : (inward ? .screenshot : .paste)
            let name = active.count == 2 ? "双指" : "三指"
            return Recognition(action: action, device: frame.device, timestamp: frame.timestamp,
                               detail: String(format: "%@%@，间距比例 %.2f，位移 %.3f", name,
                                              inward ? "并拢" : "分开", ratio, drift))
        } else {
            session.candidate = PinchCandidate(count: active.count, ids: ids, startedAt: frame.timestamp)
            return nil
        }
    }

    private func positionsByID(active: [TouchSample], ids: Set<Int32>) -> [Int32: TouchPoint]? {
        var result: [Int32: TouchPoint] = [:]
        for touch in active where ids.contains(touch.id) {
            result[touch.id] = touch.position
        }
        return result.count == ids.count ? result : nil
    }

    private func meanPairDistance(_ points: [TouchPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var sum = 0.0
        var pairs = 0
        for i in points.indices {
            for j in points.indices where j > i {
                sum += points[i].distance(to: points[j])
                pairs += 1
            }
        }
        return sum / Double(pairs)
    }

    private func centroidOf(_ points: [TouchPoint]) -> TouchPoint {
        let sum = points.reduce(TouchPoint(x: 0, y: 0)) { TouchPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return TouchPoint(x: sum.x / Double(points.count), y: sum.y / Double(points.count))
    }
}
