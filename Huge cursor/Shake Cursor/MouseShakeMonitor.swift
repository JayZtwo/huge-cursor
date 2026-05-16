//
//  MouseShakeMonitor.swift
//  Shake Cursor
//
//  Created by Codex on 2026/5/13.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class MouseShakeMonitor: ObservableObject {
    struct ShakeTrigger: Identifiable {
        let id = UUID()
        let point: CGPoint
    }

    struct Snapshot {
        var speed: Double = 0
        var peakSpeed: Double = 0
        var directionChanges: Int = 0
        var distance: Double = 0
        var confidence: Double = 0
    }

    @Published private(set) var isMonitoring = false
    @Published private(set) var isShakeActive = false
    @Published private(set) var latestTrigger: ShakeTrigger?
    @Published private(set) var snapshot = Snapshot()
    @Published var sensitivity: Double = 0.62

    private struct Sample {
        let point: CGPoint
        let time: TimeInterval
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pollingTask: Task<Void, Never>?
    private var samples: [Sample] = []
    private var activeResetTask: Task<Void, Never>?
    private var lastTriggerTime: TimeInterval = 0
    private var lastRecordedPoint: CGPoint?
    private var lastRecordedTime: TimeInterval = 0

    private let sampleWindow: TimeInterval = 0.52
    private let activeDuration: TimeInterval = 0.95
    private let triggerCooldown: TimeInterval = 0.9

    deinit {
        activeResetTask?.cancel()

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        pollingTask?.cancel()
    }

    func start() {
        guard !isMonitoring else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in
                self?.recordCurrentMouseLocation()
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in
                self?.recordCurrentMouseLocation()
            }
            return event
        }

        startPollingMouseLocation()
        isMonitoring = true
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        globalMonitor = nil
        localMonitor = nil
        pollingTask?.cancel()
        pollingTask = nil
        isMonitoring = false
        isShakeActive = false
        samples.removeAll()
        snapshot = Snapshot()
        activeResetTask?.cancel()
    }

    private func startPollingMouseLocation() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    self?.recordCurrentMouseLocation()
                }

                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func recordCurrentMouseLocation() {
        let now = ProcessInfo.processInfo.systemUptime
        let point = NSEvent.mouseLocation
        let lastPoint = lastRecordedPoint
        let lastTime = lastRecordedTime

        if let lastPoint,
           hypot(point.x - lastPoint.x, point.y - lastPoint.y) < 1,
           now - lastTime < 0.05 {
            return
        }

        if now - lastTime < 0.006 {
            return
        }

        samples.append(Sample(point: point, time: now))
        lastRecordedPoint = point
        lastRecordedTime = now
        samples.removeAll { now - $0.time > sampleWindow }

        updateSnapshot(now: now)
    }

    private func updateSnapshot(now: TimeInterval) {
        guard samples.count >= 3 else { return }

        var distance = 0.0
        var peakSpeed = 0.0
        var currentSpeed = 0.0
        var directionChanges = 0
        var previousTrend: CGVector?
        var accumulatedTrend = CGVector(dx: 0, dy: 0)

        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            let deltaX = current.point.x - previous.point.x
            let deltaY = current.point.y - previous.point.y
            let deltaTime = max(current.time - previous.time, 0.001)
            let segmentDistance = hypot(deltaX, deltaY)
            let segmentSpeed = segmentDistance / deltaTime

            distance += segmentDistance
            peakSpeed = max(peakSpeed, segmentSpeed)
            currentSpeed = segmentSpeed

            let vector = CGVector(dx: deltaX, dy: deltaY)
            accumulatedTrend.dx += vector.dx
            accumulatedTrend.dy += vector.dy

            if hypot(accumulatedTrend.dx, accumulatedTrend.dy) >= minimumDirectionalMovement {
                if let previousTrend,
                   didChangeDirection(from: previousTrend, to: accumulatedTrend) {
                    directionChanges += 1
                }

                previousTrend = accumulatedTrend
                accumulatedTrend = CGVector(dx: 0, dy: 0)
            }
        }

        let thresholds = thresholdsForCurrentSensitivity()
        let directionScore = min(Double(directionChanges) / Double(thresholds.directionChanges), 1)
        let distanceScore = min(distance / thresholds.distance, 1)
        let speedScore = min(peakSpeed / thresholds.peakSpeed, 1)
        let confidence = (directionScore * 0.45) + (distanceScore * 0.25) + (speedScore * 0.3)

        snapshot = Snapshot(
            speed: currentSpeed,
            peakSpeed: peakSpeed,
            directionChanges: directionChanges,
            distance: distance,
            confidence: confidence
        )

        let didShake = directionChanges >= thresholds.directionChanges
            && distance >= thresholds.distance
            && peakSpeed >= thresholds.peakSpeed

        if didShake, now - lastTriggerTime > triggerCooldown {
            activateShake(at: now, point: samples.last?.point ?? NSEvent.mouseLocation)
        }
    }

    private func activateShake(at time: TimeInterval, point: CGPoint) {
        lastTriggerTime = time
        isShakeActive = true
        latestTrigger = ShakeTrigger(point: point)
        CodexBridgeLog.write("shake trigger point=(\(Int(point.x)),\(Int(point.y)))")
        samples.removeAll()
        snapshot = Snapshot()
        lastRecordedPoint = nil
        lastRecordedTime = 0

        activeResetTask?.cancel()
        activeResetTask = Task { [activeDuration] in
            try? await Task.sleep(for: .seconds(activeDuration))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.isShakeActive = false
            }
        }
    }

    private var minimumDirectionalMovement: Double {
        18
    }

    private func didChangeDirection(from previous: CGVector, to current: CGVector) -> Bool {
        let dotProduct = previous.dx * current.dx + previous.dy * current.dy
        let previousLength = hypot(previous.dx, previous.dy)
        let currentLength = hypot(current.dx, current.dy)
        let cosine = dotProduct / max(previousLength * currentLength, 0.001)

        return cosine < -0.18
    }

    private func thresholdsForCurrentSensitivity() -> (directionChanges: Int, distance: Double, peakSpeed: Double) {
        let normalized = min(max(sensitivity, 0), 1)
        let strictness = 1 - normalized

        return (
            directionChanges: normalized > 0.78 ? 3 : 4,
            distance: 300 + (strictness * 360),
            peakSpeed: 1050 + (strictness * 950)
        )
    }
}
