//
//  ShakeInputOverlay.swift
//  Shake Cursor
//
//  Created by Codex on 2026/5/13.
//

import AppKit
import SwiftUI

@MainActor
final class ShakeInputOverlayPresenter {
    private static var sharedPanel: ShakeFortunePanel?

    func show(at point: CGPoint) {
        let size = CGSize(width: 520, height: 330)
        let panel = Self.sharedPanel ?? makePanel(size: size)
        if panel.isVisible {
            CodexBridgeLog.write("overlay already visible")
            panel.makeKeyAndOrderFront(nil)
            return
        }
        Self.sharedPanel = panel
        CodexBridgeLog.write("overlay show point=(\(Int(point.x)),\(Int(point.y)))")

        let hostingView = NSHostingView(
            rootView: FortuneOverlayView(triggerPoint: point, canvasSize: size) {
                self.close()
            }
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView

        panel.setFrame(NSRect(origin: clampedOrigin(for: point, size: size), size: size), display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        Self.sharedPanel?.orderOut(nil)
    }

    private func makePanel(size: CGSize) -> ShakeFortunePanel {
        let panel = ShakeFortunePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.level = .floating

        return panel
    }

    private func clampedOrigin(for point: CGPoint, size: CGSize) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        let preferredOrigin = CGPoint(
            x: point.x - 134,
            y: point.y - 164
        )

        let x = min(max(preferredOrigin.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        let y = min(max(preferredOrigin.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)

        return CGPoint(x: x, y: y)
    }
}

private final class ShakeFortunePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct Fortune: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let detail: String
    let energy: String
    let blessing: String
    let tint: Color

    static let empty = Fortune(title: "", message: "", detail: "", energy: "", blessing: "", tint: .cyan)

    func replacing(with response: FortuneResponse) -> Fortune {
        Fortune(
            title: response.title,
            message: response.message,
            detail: response.detail,
            energy: response.energy,
            blessing: blessing,
            tint: tint
        )
    }
}

private enum DrawPhase {
    case drawing
    case revealed
}

private enum DeviceMotionPhase {
    case idle
    case resolving
    case revealed
}

private struct FortuneOverlayView: View {
    @State private var fortune = Fortune.empty
    @State private var phase: DrawPhase = .drawing
    @State private var appeared = false
    @State private var jarShake = false
    @State private var jarSquash = false
    @State private var shine = false
    @State private var resultVisible = false
    @State private var slipTextVisible = false
    @State private var particlesVisible = false
    @State private var starDrift = 0.0
    @State private var ritualRotation = 0.0
    @State private var litMarkerCount = 0
    @State private var ritualText = "静心摇签"
    @State private var bridgeNotice: String?
    @State private var drawTask: Task<Void, Never>?
    @State private var isDrawingWithCodex = false
    @State private var deviceBreath = false
    @State private var scanSweep = false
    @State private var deviceFrameIndex = 0
    @State private var deviceAnimationTask: Task<Void, Never>?
    @State private var assistantText = ""
    @State private var assistantReply: String?
    @State private var isAskingAssistant = false
    @FocusState private var isAssistantFocused: Bool

    let triggerPoint: CGPoint
    let canvasSize: CGSize
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .center) {
            HStack(alignment: .center, spacing: 0) {
                closeButton
                    .padding(.trailing, 6)

                commandColumn
                    .frame(width: assistantColumnWidth, alignment: .leading)

                compactFortuneCard
                    .frame(width: 226)
                    .padding(.leading, -10)
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .frame(width: 444, height: 254)
        }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .compositingGroup()
            .scaleEffect(appeared ? 1 : 0.96)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                    appeared = true
                }
                withAnimation(.linear(duration: 36).repeatForever(autoreverses: false)) {
                    ritualRotation = 360
                }
                withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) {
                    starDrift = 1
                }
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                    deviceBreath = true
                }
                withAnimation(.easeInOut(duration: 1.16).repeatForever(autoreverses: false)) {
                    scanSweep = true
                }
                startDeviceAnimation()
                drawFortune()
                Task {
                    try? await Task.sleep(for: .milliseconds(240))
                    await MainActor.run {
                        isAssistantFocused = true
                    }
                }
            }
            .onDisappear {
                drawTask?.cancel()
                deviceAnimationTask?.cancel()
                Task {
                    await CodexBridge.shared.interruptActiveTurns()
                }
            }
    }

    private var commandColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            assistantPanel
        }
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(techAccent.opacity(isAskingAssistant || isDrawingWithCodex ? 0.32 : 0.18))
                    .frame(width: 18, height: 18)
                    .blur(radius: isAskingAssistant || isDrawingWithCodex ? 5 : 3)

                Circle()
                    .fill(isAskingAssistant || isDrawingWithCodex ? techAccent : Color.white.opacity(0.84))
                    .frame(width: 7, height: 7)
            }

            Text("Shake Cursor")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(graphite)
        }
        .padding(.leading, 4)
    }

    private var statusText: String {
        if isAskingAssistant { return "正在回应" }
        if isDrawingWithCodex { return "正在成签" }
        return "Codex 在线"
    }

    private var stage: some View {
        ZStack {
            RitualStageView(rotation: ritualRotation, litMarkerCount: litMarkerCount)

            PremiumRevealAuraView(tint: ritualGold, isRevealed: phase == .revealed)
                .transition(.scale(scale: 0.55).combined(with: .opacity))

            PremiumFortuneJarView(
                tint: ritualGold,
                isShaking: jarShake,
                isSquashed: jarSquash,
                isDimmed: phase == .revealed
            )
            .offset(y: phase == .revealed ? 42 : 50)
            .scaleEffect(phase == .revealed ? 0.9 : 0.98)

            PremiumFortuneStickView(fortune: fortune, phase: phase, shine: shine)
                .offset(y: phase == .revealed ? -78 : 18)
                .scaleEffect(phase == .revealed ? 0.68 : 0.42)
                .opacity(phase == .revealed ? 1 : 0)
        }
        .frame(width: 380, height: 318)
        .contentShape(Rectangle())
        .onTapGesture {
            if phase == .revealed {
                drawFortune()
            }
        }
    }

    private var ritualGold: Color {
        techAccent
    }

    private var ritualRed: Color {
        Color(red: 0.44, green: 0.34, blue: 0.72)
    }

    private var techAccent: Color {
        Color(red: 0.76, green: 0.70, blue: 1.0)
    }

    private var graphite: Color {
        Color(red: 0.12, green: 0.15, blue: 0.17)
    }

    private var devicePhase: DeviceMotionPhase {
        if isDrawingWithCodex { return .resolving }
        if resultVisible { return .revealed }
        return .idle
    }

    private var deviceFrameName: String {
        "fortune-device-frame-\(deviceFrameIndex)"
    }

    private var ritualCaption: some View {
        HStack(spacing: 8) {
            Image(systemName: resultVisible ? "sparkles" : "circle.dotted")
                .font(.system(size: 11, weight: .bold))
                .symbolEffect(.pulse, value: ritualText)

            Text(ritualText)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .contentTransition(.opacity)
        }
        .foregroundStyle(ritualGold)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(Color(red: 0.16, green: 0.06, blue: 0.03).opacity(0.76))
                .overlay {
                    Capsule()
                        .stroke(ritualGold.opacity(0.5), lineWidth: 1)
                }
        }
        .shadow(color: ritualGold.opacity(0.24), radius: 14, y: 5)
    }

    private var resultCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(resultVisible ? fortune.title : "抽签中")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(resultVisible ? fortune.tint : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill((resultVisible ? fortune.tint : Color.secondary).opacity(0.13))
                            .overlay {
                                Capsule()
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            }
                    )

                Text(resultVisible ? fortune.energy : "正在摇出一点好运")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .offset(y: resultVisible ? 0 : 6)

            Text(resultVisible ? fortune.message : "摇出一支签")
                .font(.system(size: 27, weight: .heavy, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .scaleEffect(resultVisible ? 1 : 0.96)

            Text(resultVisible ? fortune.detail : " ")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 36)
                .contentTransition(.opacity)

            if let bridgeNotice, resultVisible {
                Text(bridgeNotice)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.82))
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, bridgeNotice == nil ? 16 : 12)
        .frame(width: 324, height: bridgeNotice == nil ? 146 : 156)
        .background { FortuneResultCardBackground(tint: ritualGold, isVisible: resultVisible) }
        .opacity(resultVisible ? 1 : 0.76)
        .offset(y: resultVisible ? 0 : 10)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: resultVisible)
    }

    private var assistantPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            inputBar

            if assistantReply != nil || isAskingAssistant {
                assistantReplyPanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: assistantReply)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isAskingAssistant)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("", text: $assistantText)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))
                .tint(Color(red: 0.78, green: 0.68, blue: 1.0))
                .focused($isAssistantFocused)
                .onSubmit {
                    askAssistant()
                }

            Button {
                askAssistant()
            } label: {
                Image(systemName: isAskingAssistant ? "hourglass" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .symbolEffect(.pulse, value: isAskingAssistant)
            }
            .buttonStyle(PrimaryIconButtonStyle(isEnabled: canAskAssistant))
            .disabled(!canAskAssistant)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(width: assistantInputWidth, height: 46)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.32),
                                    techAccent.opacity(isAssistantFocused ? 0.14 : 0.05),
                                    Color.black.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    Capsule()
                        .stroke(isAssistantFocused ? techAccent.opacity(0.72) : Color.white.opacity(0.28), lineWidth: 1)
                }
        }
        .shadow(color: Color.black.opacity(0.13), radius: 24, y: 12)
        .shadow(color: isAssistantFocused ? techAccent.opacity(0.20) : Color.clear, radius: 20)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: assistantInputWidth)
    }

    private var assistantInputWidth: CGFloat {
        let trimmedCount = assistantText.trimmingCharacters(in: .whitespacesAndNewlines).count
        let growth = CGFloat(min(trimmedCount, 12)) * 3.3
        return min(148, max(106, 106 + growth))
    }

    private var assistantColumnWidth: CGFloat {
        if assistantReply != nil || isAskingAssistant {
            return 136
        }

        return assistantInputWidth
    }

    private var assistantReplyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isAskingAssistant && assistantReply == nil {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(techAccent.opacity(0.78))
                            .frame(width: 5, height: 5)
                            .scaleEffect(isAskingAssistant ? 1.0 : 0.7)
                            .animation(
                                .easeInOut(duration: 0.48)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.12),
                                value: isAskingAssistant
                            )
                    }
                }
                .frame(height: 24)
            } else if let assistantReply {
                Text(assistantReply)
                    .font(.custom("Songti SC", size: 12).weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.94))
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 116, alignment: .topLeading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.52, green: 0.42, blue: 0.96).opacity(0.78),
                                        Color(red: 0.20, green: 0.13, blue: 0.42).opacity(0.66)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
                            }
                    }
                    .shadow(color: techAccent.opacity(0.24), radius: 18, y: 8)
                    .shadow(color: Color.black.opacity(0.14), radius: 12, y: 6)
                    .contentTransition(.opacity)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .padding(.top, 1)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: assistantReply)
    }

    private var compactFortuneCard: some View {
        VStack(spacing: 2) {
            ZStack {
                AmbientFortuneParticles(
                    isActive: isDrawingWithCodex || resultVisible,
                    progress: starDrift,
                    tint: techAccent
                )
                .frame(width: 236, height: 248)
                .opacity(isDrawingWithCodex || resultVisible ? 1 : 0.46)

                techFortuneDevice
                    .frame(height: 148)
                    .opacity(resultVisible ? 0 : 1)
                    .scaleEffect(resultVisible ? 0.86 : 1)
                    .blur(radius: resultVisible ? 5 : 0)

                fortuneGlassSlip
                    .opacity(resultVisible ? 1 : 0)
            }
            .frame(width: 236, height: 248)

        }
        .frame(maxHeight: .infinity)
        .opacity(resultVisible ? 1 : 0.86)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: fortune.id)
    }

    private var techFortuneDevice: some View {
        ZStack {
            Image("fortune-ritual-halo")
                .resizable()
                .scaledToFit()
                .frame(width: devicePhase == .resolving ? 166 : 158, height: devicePhase == .resolving ? 166 : 158)
                .rotationEffect(.degrees(devicePhase == .resolving ? ritualRotation * 0.24 : ritualRotation * 0.08))
                .opacity(devicePhase == .resolving ? 0.52 : 0.28)
                .scaleEffect(deviceBreath ? 1.025 : 0.99)
                .shadow(color: techAccent.opacity(devicePhase == .resolving ? 0.20 : 0.16), radius: 18)

            Image(deviceFrameName)
                .resizable()
                .scaledToFit()
                .frame(width: 116, height: 146)
                .scaleEffect(devicePhase == .idle && deviceBreath ? 1.008 : 1)
                .shadow(color: Color.black.opacity(0.16), radius: 14, y: 8)
                .shadow(color: techAccent.opacity(devicePhase == .resolving ? 0.36 : 0.14), radius: devicePhase == .resolving ? 22 : 14)
                .contentTransition(.opacity)

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(techAccent.opacity(devicePhase == .resolving ? 0.28 : 0.22))
                .frame(width: devicePhase == .resolving ? 42 : 32, height: 2)
                .blur(radius: 2.6)
                .offset(y: -50)
                .opacity(devicePhase == .idle ? 0.30 : 0.42)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: devicePhase)
    }

    private var fortuneGlassSlip: some View {
        ZStack {
            Image("fortune-stick")
                .resizable()
                .frame(width: 202, height: 296)
                .shadow(color: Color.black.opacity(0.18), radius: 18, y: 10)
                .shadow(color: techAccent.opacity(0.26), radius: 26)
                .overlay {
                    SlipTwinkleField(tint: techAccent)
                        .frame(width: 202, height: 296)
                        .mask {
                            Image("fortune-stick")
                                .resizable()
                                .frame(width: 202, height: 296)
                        }
                        .allowsHitTesting(false)
                }

            VStack(spacing: 8) {
                Text(fortune.title)
                    .font(FortuneTypography.caption(size: 10.8))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .shadow(color: Color(red: 0.64, green: 0.54, blue: 1.0).opacity(0.62), radius: 6)

                Text(fortune.message)
                    .font(FortuneTypography.headline(size: 17.2))
                    .foregroundStyle(Color.white.opacity(0.96))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.60)
                    .lineSpacing(2.2)
                    .tracking(0.1)
                    .frame(width: 92)
                    .shadow(color: Color.black.opacity(0.30), radius: 3, y: 1)
                    .shadow(color: Color(red: 0.72, green: 0.62, blue: 1.0).opacity(0.46), radius: 8)

                Text(fortune.detail)
                    .font(FortuneTypography.body(size: 9.8))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.56)
                    .lineSpacing(1.2)
                    .frame(width: 88)
                    .shadow(color: Color.black.opacity(0.24), radius: 2, y: 1)

                if !fortune.energy.isEmpty {
                    Text(fortune.energy)
                        .font(FortuneTypography.caption(size: 9.6))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .shadow(color: Color(red: 0.66, green: 0.56, blue: 1.0).opacity(0.48), radius: 7)
                }
            }
            .frame(width: 98, height: 168)
            .offset(y: 0)
            .clipped()
            .opacity(slipTextVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.34), value: slipTextVisible)
            .zIndex(2)

        }
        .frame(width: 242, height: 306)
    }

    private var canAskAssistant: Bool {
        !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isAskingAssistant
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                drawFortune()
            } label: {
                Label("再摇", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .frame(width: 102, height: 34)
            }
            .buttonStyle(FortunePillButtonStyle(tint: ritualRed, isPrimary: true))
            .disabled(phase != .revealed || isDrawingWithCodex || isAskingAssistant)

            Button {
                onDismiss()
            } label: {
                Label("收下", systemImage: "checkmark")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .frame(width: 102, height: 34)
            }
            .buttonStyle(FortunePillButtonStyle(tint: ritualGold, isPrimary: false))
        }
        .padding(.top, 2)
        .opacity(resultVisible ? 1 : 0)
        .offset(y: resultVisible ? 0 : 8)
        .animation(.easeOut(duration: 0.24), value: resultVisible)
    }

    private var closeButton: some View {
        Button {
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(.ultraThinMaterial, in: Circle())
        .overlay {
            Circle()
                .stroke(Color.white.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
        .keyboardShortcut(.cancelAction)
    }

    private func drawFortune() {
        drawTask?.cancel()
        fortune = .empty
        phase = .drawing
        resultVisible = false
        slipTextVisible = false
        shine = false
        particlesVisible = false
        litMarkerCount = 0
        ritualText = "签筒醒来"
        bridgeNotice = "Codex 正在成签..."
        assistantReply = nil
        isDrawingWithCodex = true
        let startedAt = Date()

        drawTask = Task {
            do {
                let response = try await CodexBridge.shared.drawFortune(
                    context: FortuneRequestContext(
                        point: triggerPoint
                    )
                )
                guard !Task.isCancelled else { return }

                let remainingRitualTime = 2.65 - Date().timeIntervalSince(startedAt)
                if remainingRitualTime > 0 {
                    try? await Task.sleep(for: .milliseconds(Int(remainingRitualTime * 1000)))
                }
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(.spring(response: 0.56, dampingFraction: 0.88)) {
                        fortune = fortune.replacing(with: response)
                        bridgeNotice = "Codex 已为你成签"
                        isDrawingWithCodex = false
                        resultVisible = true
                        phase = .revealed
                    }
                }

                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    slipTextVisible = true
                }
            } catch {
                guard !Task.isCancelled else { return }

                let remainingRitualTime = 1.0 - Date().timeIntervalSince(startedAt)
                if remainingRitualTime > 0 {
                    try? await Task.sleep(for: .milliseconds(Int(remainingRitualTime * 1000)))
                }
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.22)) {
                        bridgeNotice = displayMessage(for: error)
                        fortune = Fortune(
                            title: "未成签",
                            message: "Codex 暂时没有回应",
                            detail: displayMessage(for: error),
                            energy: "重试",
                            blessing: "",
                            tint: .cyan
                        )
                        isDrawingWithCodex = false
                        resultVisible = true
                        phase = .revealed
                    }
                }

                Task {
                    try? await Task.sleep(for: .milliseconds(180))
                    await MainActor.run {
                        slipTextVisible = true
                    }
                }
            }
        }

        withAnimation(.easeInOut(duration: 0.22).repeatCount(6, autoreverses: true)) {
            jarShake = true
        }

        withAnimation(.easeInOut(duration: 0.34).repeatCount(4, autoreverses: true)) {
            jarSquash = true
        }

        Task {
            try? await Task.sleep(for: .milliseconds(520))

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.58)) {
                    litMarkerCount = 14
                    ritualText = "好运聚拢"
                }
            }

            try? await Task.sleep(for: .milliseconds(760))

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.62)) {
                    litMarkerCount = 32
                    ritualText = "签意生成中"
                }
            }

            try? await Task.sleep(for: .milliseconds(1120))

            await MainActor.run {
                withAnimation(.spring(response: 0.54, dampingFraction: 0.64)) {
                    jarShake = false
                    jarSquash = false
                    particlesVisible = true
                    litMarkerCount = 48
                    ritualText = "一签已成"
                }
            }

            try? await Task.sleep(for: .milliseconds(120))

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.5)) {
                    shine = true
                }
            }

            try? await Task.sleep(for: .milliseconds(80))

            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    ritualText = "请收下今天的灵感"
                }
            }
        }
    }

    private func startDeviceAnimation() {
        deviceAnimationTask?.cancel()
        deviceAnimationTask = Task {
            var idleCursor = 0
            var resolvingCursor = 0
            let idleFrames = [0, 1, 0]
            let resolvingFrames = [0, 1, 3, 1]

            while !Task.isCancelled {
                await MainActor.run {
                    switch devicePhase {
                    case .idle:
                        deviceFrameIndex = idleFrames[idleCursor % idleFrames.count]
                        idleCursor += 1
                    case .resolving:
                        deviceFrameIndex = resolvingFrames[resolvingCursor % resolvingFrames.count]
                        resolvingCursor += 1
                    case .revealed:
                        deviceFrameIndex = 1
                        resolvingCursor = 0
                    }
                }

                let delay: Duration = await MainActor.run {
                    switch devicePhase {
                    case .idle:
                        return .milliseconds(1500)
                    case .resolving:
                        return .milliseconds(460)
                    case .revealed:
                        return .milliseconds(1200)
                    }
                }

                try? await Task.sleep(for: delay)
            }
        }
    }

    private func askAssistant() {
        let text = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAskingAssistant else { return }

        isAskingAssistant = true
        assistantReply = nil

        Task {
            do {
                let response = try await CodexBridge.shared.askLifeAssistant(
                    text: text,
                    context: fortune.message.isEmpty ? "" : "用户刚通过摇一摇抽到：\(fortune.title) / \(fortune.message) / \(fortune.detail)"
                )

                await MainActor.run {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        assistantReply = response.text
                    }
                }

                if let calendarEvent = response.calendarEvent {
                    do {
                        let result = try await CalendarEventWriter.shared.createEvent(from: calendarEvent)
                        await MainActor.run {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                assistantReply = "\(response.text)\n\(result.message)"
                            }
                        }
                    } catch {
                        await MainActor.run {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                assistantReply = "\(response.text)\n\(displayMessage(for: error))"
                            }
                        }
                    }
                }

                await MainActor.run {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        assistantText = ""
                        isAskingAssistant = false
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.22)) {
                        assistantReply = displayMessage(for: error)
                        isAskingAssistant = false
                    }
                }
            }
        }
    }

    private func displayMessage(for error: Error) -> String {
        let nsError = error as NSError
        if let suggestion = nsError.localizedRecoverySuggestion, !suggestion.isEmpty {
            return "\(error.localizedDescription)：\(String(suggestion.prefix(120)))"
        }

        return error.localizedDescription
    }
}

private struct AmbientFortuneParticles: View {
    let isActive: Bool
    let progress: Double
    let tint: Color

    var body: some View {
        ZStack {
            ForEach(0..<22, id: \.self) { index in
                let phase = progress * .pi * 2 + Double(index) * 0.47
                let radius = 58 + CGFloat((index * 13) % 38)
                let x = CGFloat(cos(phase)) * radius * (index.isMultiple(of: 3) ? 0.62 : 0.88)
                let y = CGFloat(sin(phase * 0.82)) * radius
                let size = CGFloat(2 + (index % 4))
                let alpha = isActive ? 0.34 + 0.38 * abs(sin(phase)) : 0.14

                Circle()
                    .fill(index.isMultiple(of: 4) ? Color.white.opacity(alpha) : tint.opacity(alpha))
                    .frame(width: size, height: size)
                    .blur(radius: index.isMultiple(of: 5) ? 0.4 : 0)
                    .offset(x: x, y: y)
            }

            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .trim(from: 0.08, to: 0.22)
                    .stroke(tint.opacity(isActive ? 0.22 : 0.08), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .frame(width: 112 + CGFloat(index * 24), height: 174 + CGFloat(index * 18))
                    .rotationEffect(.degrees(progress * 360 + Double(index) * 64))
                    .blur(radius: 0.2)
            }
        }
        .drawingGroup()
    }
}

private struct RitualStageView: View {
    let rotation: Double
    let litMarkerCount: Int

    private let ritualGold = Color(red: 0.98, green: 0.72, blue: 0.25)

    var body: some View {
        ZStack {
            Image("fortune-ritual-halo")
                .resizable()
                .scaledToFit()
                .frame(width: 344, height: 344)
                .rotationEffect(.degrees(rotation * 0.12))
                .shadow(color: ritualGold.opacity(0.16), radius: 18)

            ForEach(0..<3) { index in
                RitualRippleRing(tint: ritualGold, delay: Double(index) * 0.75)
                    .frame(width: 214 + CGFloat(index * 36), height: 214 + CGFloat(index * 36))
            }

            ForEach(0..<48, id: \.self) { index in
                let isLit = index < litMarkerCount

                Capsule()
                    .fill(isLit ? ritualGold.opacity(0.95) : Color.white.opacity(0.0))
                    .frame(width: isLit ? 2.2 : 1.2, height: isLit ? 12 : 5)
                    .offset(y: -135)
                    .rotationEffect(.degrees(Double(index) * 7.5))
                    .shadow(color: isLit ? ritualGold.opacity(0.58) : Color.clear, radius: 7)
                    .animation(.easeOut(duration: 0.28).delay(Double(index) * 0.006), value: litMarkerCount)
            }
        }
    }
}

private struct RitualRippleRing: View {
    let tint: Color
    let delay: Double
    @State private var scale = 0.82
    @State private var opacity = 0.0

    var body: some View {
        Circle()
            .stroke(tint.opacity(0.24), lineWidth: 1)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(delay)) {
                    scale = 1.22
                    opacity = 0
                }

                withAnimation(.easeOut(duration: 0.18).delay(delay)) {
                    opacity = 1
                }
            }
    }
}

private struct FortuneResultCardBackground: View {
    let tint: Color
    let isVisible: Bool

    var body: some View {
        Image("fortune-result-card")
            .resizable()
            .scaledToFit()
            .frame(width: 352, height: 172)
            .shadow(color: Color.black.opacity(0.18), radius: 22, y: 12)
            .overlay {
                Circle()
                    .fill(tint.opacity(isVisible ? 0.08 : 0.03))
                    .frame(width: 120, height: 120)
                    .blur(radius: 28)
                    .offset(x: -70, y: -28)
            }
    }
}

private struct QuietIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(configuration.isPressed ? 0.9 : 0.52))
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.76), value: configuration.isPressed)
    }
}

private struct PrimaryIconButtonStyle: ButtonStyle {
    let isEnabled: Bool
    private let accent = Color(red: 0.16, green: 0.44, blue: 0.60)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.white : Color.secondary.opacity(0.58))
            .background {
                Circle()
                    .fill(isEnabled ? accent : Color.secondary.opacity(0.12))
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(isEnabled ? 0.18 : 0.08), lineWidth: 1)
                    }
            }
            .shadow(color: isEnabled ? accent.opacity(0.22) : .clear, radius: 10, y: 5)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.76), value: configuration.isPressed)
    }
}

private struct FortunePillButtonStyle: ButtonStyle {
    let tint: Color
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isPrimary ? Color.white : tint)
            .background {
                Capsule()
                    .fill(isPrimary ? tint : Color.clear)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(isPrimary ? Color.white.opacity(0.18) : tint.opacity(0.26), lineWidth: 1)
                    }
            }
            .shadow(color: isPrimary ? tint.opacity(0.26) : Color.black.opacity(0.08), radius: 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct PremiumFortuneJarView: View {
    let tint: Color
    let isShaking: Bool
    let isSquashed: Bool
    let isDimmed: Bool

    var body: some View {
        ZStack {
            ShadowShape()
                .fill(Color.black.opacity(0.2))
                .frame(width: 184, height: 28)
                .blur(radius: 14)
                .offset(y: 92)

            Image("fortune-jar")
                .resizable()
                .scaledToFit()
                .frame(width: 210, height: 210)
                .saturation(isDimmed ? 0.82 : 1.04)
                .brightness(isShaking ? 0.04 : 0)
                .shadow(color: Color.black.opacity(0.2), radius: 16, y: 10)
                .shadow(color: tint.opacity(isShaking ? 0.28 : 0.1), radius: isShaking ? 22 : 8)
                .opacity(isDimmed ? 0.7 : 1)

            if isShaking {
                Capsule()
                    .fill(tint.opacity(0.22))
                    .frame(width: 118, height: 8)
                    .blur(radius: 7)
                    .offset(y: -12)
            }
        }
        .rotationEffect(.degrees(isShaking ? -5.5 : 3.5))
        .scaleEffect(x: isSquashed ? 1.05 : 1, y: isSquashed ? 0.96 : 1, anchor: .bottom)
        .animation(.easeInOut(duration: 0.08), value: isShaking)
        .animation(.easeInOut(duration: 0.14), value: isSquashed)
    }

    private var backSticks: some View {
        ZStack {
            ForEach(0..<9) { index in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(stickGradient(index))
                    .frame(width: 12, height: 124)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(index.isMultiple(of: 2) ? 0.18 : 0.1))
                            .frame(width: 5, height: 90)
                            .offset(x: -2, y: 8)
                    }
                    .rotationEffect(.degrees(Double(index - 4) * 6.5))
                    .offset(x: CGFloat(index - 4) * 9.5, y: -28)
                    .opacity(isDimmed ? 0.28 : 0.96)
            }
        }
    }

    private var jarBody: some View {
        VStack(spacing: -2) {
            ZStack {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.82, blue: 0.42),
                                Color(red: 0.92, green: 0.18, blue: 0.13),
                                Color(red: 0.42, green: 0.02, blue: 0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 150, height: 30)
                    .shadow(color: tint.opacity(isShaking ? 0.34 : 0.16), radius: isShaking ? 18 : 8)

                Capsule()
                    .stroke(Color(red: 1.0, green: 0.84, blue: 0.46).opacity(0.88), lineWidth: 2)
                    .frame(width: 148, height: 28)

                Capsule()
                    .fill(tint.opacity(isShaking ? 0.3 : 0.12))
                    .frame(width: isShaking ? 118 : 58, height: 6)
                    .blur(radius: 5)
            }

            ZStack {
                JarBodyShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.98, green: 0.21, blue: 0.15),
                                Color(red: 0.74, green: 0.05, blue: 0.07),
                                Color(red: 0.36, green: 0.02, blue: 0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 128, height: 116)
                    .overlay {
                        JarBodyShape()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1.0, green: 0.78, blue: 0.36).opacity(0.8),
                                        Color.white.opacity(0.12),
                                        Color.black.opacity(0.22)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                    }

                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 17, height: 72)
                    .rotationEffect(.degrees(15))
                    .offset(x: -32, y: -8)
                    .blur(radius: 0.4)

                VStack(spacing: 2) {
                    Text("签")
                        .font(.system(size: 44, weight: .black, design: .serif))
                    Text("LUCK")
                        .font(.system(size: 7, weight: .black, design: .rounded))
                        .tracking(1.4)
                }
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.86, blue: 0.42),
                            Color(red: 0.86, green: 0.55, blue: 0.16)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Color.black.opacity(0.16), radius: 2, y: 1)
                .offset(y: -2)
            }
        }
        .shadow(color: Color.black.opacity(0.24), radius: 18, y: 12)
        .opacity(isDimmed ? 0.64 : 1)
    }

    private func stickGradient(_ index: Int) -> LinearGradient {
        let warm = index.isMultiple(of: 2)
        return LinearGradient(
            colors: warm
                ? [Color(red: 1.0, green: 0.82, blue: 0.44), Color(red: 0.9, green: 0.49, blue: 0.18)]
                : [Color(red: 0.98, green: 0.68, blue: 0.32), Color(red: 0.74, green: 0.28, blue: 0.12)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct PremiumFortuneStickView: View {
    let fortune: Fortune
    let phase: DrawPhase
    let shine: Bool

    var body: some View {
        ZStack {
            if phase == .revealed {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(fortune.tint.opacity(0.42), lineWidth: 4)
                    .frame(width: 68, height: 212)
                    .blur(radius: 11)
                    .opacity(0.48)
            }

            Image("fortune-stick")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 228)
                .shadow(color: Color.black.opacity(0.2), radius: 14, y: 9)
                .shadow(color: fortune.tint.opacity(phase == .revealed ? 0.2 : 0), radius: 18)
                .overlay(alignment: .center) {
                    Text(phase == .revealed ? fortune.blessing : "")
                        .font(.system(size: 28, weight: .black, design: .serif))
                        .foregroundStyle(Color.black.opacity(0.48))
                        .offset(y: -2)
                }
                .overlay {
                    Capsule()
                        .fill(Color.white.opacity(0.42))
                        .frame(width: 10, height: 176)
                        .blur(radius: 4)
                        .rotationEffect(.degrees(10))
                        .offset(x: shine ? 48 : -48)
                        .opacity(phase == .revealed ? 0.82 : 0)
                }
        }
        .rotationEffect(.degrees(phase == .drawing ? -7 : -2))
        .animation(.spring(response: 0.46, dampingFraction: 0.7), value: phase)
        .animation(.easeInOut(duration: 0.5), value: shine)
    }
}

private struct FortuneRibbonView: View {
    let tint: Color

    var body: some View {
        HStack(spacing: 50) {
            RibbonTailShape(direction: -1)
                .fill(tint.opacity(0.88))
                .frame(width: 54, height: 18)
                .shadow(color: tint.opacity(0.24), radius: 8, y: 4)

            RibbonTailShape(direction: 1)
                .fill(tint.opacity(0.88))
                .frame(width: 54, height: 18)
                .shadow(color: tint.opacity(0.24), radius: 8, y: 4)
        }
    }
}

private struct SlipTwinkleField: View {
    let tint: Color

    private let points = SlipTwinkleField.makePoints()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            Canvas(rendersAsynchronously: true) { context, size in
                var layer = context
                layer.blendMode = .plusLighter

                for point in points {
                    let center = CGPoint(x: point.x * size.width, y: point.y * size.height)
                    let visualSize = min(point.size * 1.18, 1.72)
                    let phase = (time / point.period + point.offset).truncatingRemainder(dividingBy: 1)
                    let sine = 0.5 + 0.5 * sin(phase * .pi * 2)
                    let pulse = pow(sine, point.kind == .glint ? 7.2 : 4.6)
                    let slowBreath = 0.5 + 0.5 * sin((time / (point.period * 2.1) + point.offset * 0.37) * .pi * 2)
                    let spark = pulse * (0.62 + 0.38 * slowBreath)
                    let idleAlpha = point.kind == .glint ? 0.075 : 0.05
                    let coreAlpha = idleAlpha + point.alpha * 0.56 * spark
                    let haloAlpha = point.alpha * 0.24 * spark
                    let coreRadius = visualSize * (0.86 + CGFloat(spark) * 0.22)

                    layer.fill(
                        Path(ellipseIn: CGRect(
                            x: center.x - visualSize * 3.8,
                            y: center.y - visualSize * 3.8,
                            width: visualSize * 7.6,
                            height: visualSize * 7.6
                        )),
                        with: .radialGradient(
                            Gradient(colors: [
                                Color.white.opacity(haloAlpha),
                                tint.opacity(haloAlpha * 0.7),
                                Color.clear
                            ]),
                            center: center,
                            startRadius: 0,
                            endRadius: visualSize * 4.8
                        )
                    )

                    layer.fill(
                        Path(ellipseIn: CGRect(
                            x: center.x - coreRadius * 0.5,
                            y: center.y - coreRadius * 0.5,
                            width: coreRadius,
                            height: coreRadius
                        )),
                        with: .color(Color.white.opacity(coreAlpha))
                    )
                }
            }
        }
        .opacity(0.96)
        .drawingGroup(opaque: false, colorMode: .linear)
    }

    private static func makePoints() -> [SlipTwinklePoint] {
        var points: [SlipTwinklePoint] = [
            .init(x: 0.50, y: 0.146, size: 1.8, period: 5.8, offset: 0.02, kind: .glint, rotation: 0.08, alpha: 0.94),
            .init(x: 0.50, y: 0.174, size: 1.5, period: 6.9, offset: 0.42, kind: .dust, rotation: 0.0, alpha: 0.62),
            .init(x: 0.50, y: 0.203, size: 1.7, period: 7.4, offset: 0.68, kind: .dust, rotation: 0.0, alpha: 0.58),
            .init(x: 0.50, y: 0.233, size: 2.1, period: 6.2, offset: 0.26, kind: .glint, rotation: 0.20, alpha: 0.88),

            .init(x: 0.36, y: 0.132, size: 1.6, period: 6.6, offset: 0.12, kind: .dust, rotation: 0.0, alpha: 0.56),
            .init(x: 0.38, y: 0.146, size: 2.0, period: 5.5, offset: 0.58, kind: .glint, rotation: -0.34, alpha: 0.90),
            .init(x: 0.34, y: 0.174, size: 1.7, period: 7.2, offset: 0.34, kind: .dust, rotation: 0.0, alpha: 0.58),
            .init(x: 0.31, y: 0.201, size: 1.6, period: 6.1, offset: 0.74, kind: .dust, rotation: 0.0, alpha: 0.54),
            .init(x: 0.64, y: 0.132, size: 1.6, period: 7.0, offset: 0.50, kind: .dust, rotation: 0.0, alpha: 0.56),
            .init(x: 0.62, y: 0.146, size: 2.0, period: 5.9, offset: 0.18, kind: .glint, rotation: 0.42, alpha: 0.90),
            .init(x: 0.66, y: 0.174, size: 1.7, period: 7.6, offset: 0.86, kind: .dust, rotation: 0.0, alpha: 0.58),
            .init(x: 0.69, y: 0.201, size: 1.6, period: 6.4, offset: 0.38, kind: .dust, rotation: 0.0, alpha: 0.54),

            .init(x: 0.30, y: 0.267, size: 1.7, period: 6.8, offset: 0.08, kind: .glint, rotation: -0.22, alpha: 0.76),
            .init(x: 0.30, y: 0.324, size: 1.6, period: 7.8, offset: 0.46, kind: .dust, rotation: 0.0, alpha: 0.54),
            .init(x: 0.30, y: 0.461, size: 1.5, period: 8.4, offset: 0.82, kind: .dust, rotation: 0.0, alpha: 0.50),
            .init(x: 0.30, y: 0.541, size: 1.7, period: 6.5, offset: 0.22, kind: .glint, rotation: 0.36, alpha: 0.68),
            .init(x: 0.30, y: 0.704, size: 1.6, period: 7.1, offset: 0.64, kind: .dust, rotation: 0.0, alpha: 0.54),
            .init(x: 0.30, y: 0.774, size: 1.7, period: 6.0, offset: 0.36, kind: .glint, rotation: -0.46, alpha: 0.78),
            .init(x: 0.70, y: 0.267, size: 1.7, period: 6.3, offset: 0.70, kind: .glint, rotation: 0.46, alpha: 0.76),
            .init(x: 0.70, y: 0.324, size: 1.6, period: 7.3, offset: 0.16, kind: .dust, rotation: 0.0, alpha: 0.54),
            .init(x: 0.70, y: 0.461, size: 1.5, period: 8.1, offset: 0.52, kind: .dust, rotation: 0.0, alpha: 0.50),
            .init(x: 0.70, y: 0.541, size: 1.7, period: 6.7, offset: 0.88, kind: .glint, rotation: -0.18, alpha: 0.68),
            .init(x: 0.70, y: 0.704, size: 1.6, period: 7.5, offset: 0.28, kind: .dust, rotation: 0.0, alpha: 0.54),
            .init(x: 0.70, y: 0.774, size: 1.7, period: 6.2, offset: 0.60, kind: .glint, rotation: 0.28, alpha: 0.78),

            .init(x: 0.50, y: 0.821, size: 2.1, period: 5.7, offset: 0.32, kind: .glint, rotation: -0.08, alpha: 0.92),
            .init(x: 0.50, y: 0.858, size: 1.7, period: 7.9, offset: 0.76, kind: .dust, rotation: 0.0, alpha: 0.58),
            .init(x: 0.50, y: 0.887, size: 1.5, period: 6.6, offset: 0.10, kind: .dust, rotation: 0.0, alpha: 0.54),
            .init(x: 0.50, y: 0.912, size: 1.4, period: 7.2, offset: 0.48, kind: .dust, rotation: 0.0, alpha: 0.50),

            .init(x: 0.34, y: 0.856, size: 1.7, period: 6.0, offset: 0.92, kind: .dust, rotation: 0.0, alpha: 0.54),
            .init(x: 0.38, y: 0.880, size: 1.9, period: 5.6, offset: 0.24, kind: .glint, rotation: 0.38, alpha: 0.84),
            .init(x: 0.44, y: 0.891, size: 1.5, period: 7.4, offset: 0.66, kind: .dust, rotation: 0.0, alpha: 0.52),
            .init(x: 0.56, y: 0.891, size: 1.5, period: 7.7, offset: 0.40, kind: .dust, rotation: 0.0, alpha: 0.52),
            .init(x: 0.62, y: 0.880, size: 1.9, period: 5.9, offset: 0.06, kind: .glint, rotation: -0.30, alpha: 0.84),
            .init(x: 0.66, y: 0.856, size: 1.7, period: 6.4, offset: 0.56, kind: .dust, rotation: 0.0, alpha: 0.54)
        ]

        var seed: UInt64 = 0x5A7A_2026_0516
        for index in 0..<44 {
            let y = CGFloat(0.18 + nextUnit(&seed) * 0.66)
            let width = interiorWidth(at: y)
            let x = CGFloat(0.5 - width / 2 + nextUnit(&seed) * Double(width))
            let isGlint = index % 8 == 0 || (index % 13 == 0 && y < 0.72)
            let size = CGFloat(0.68 + nextUnit(&seed) * (isGlint ? 0.66 : 0.54))
            let period = 6.2 + nextUnit(&seed) * 5.8
            let offset = nextUnit(&seed)
            let rotation = nextUnit(&seed) * .pi - .pi / 2
            let alpha = isGlint ? 0.34 + nextUnit(&seed) * 0.24 : 0.18 + nextUnit(&seed) * 0.22

            points.append(
                .init(
                    x: x,
                    y: y,
                    size: size,
                    period: period,
                    offset: offset,
                    kind: isGlint ? .glint : .dust,
                    rotation: rotation,
                    alpha: alpha
                )
            )
        }

        return points
    }

    private static func nextUnit(_ seed: inout UInt64) -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(UInt64.max >> 11)
    }

    private static func interiorWidth(at y: CGFloat) -> CGFloat {
        if y < 0.24 {
            return 0.22 + (y - 0.18) / 0.06 * 0.22
        }
        if y > 0.80 {
            return 0.42 - (y - 0.80) / 0.06 * 0.16
        }
        return 0.46
    }
}

private struct SlipTwinklePoint {
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let period: Double
    let offset: Double
    let kind: SlipTwinkleKind
    let rotation: Double
    let alpha: Double
}

private enum SlipTwinkleKind {
    case dust
    case glint
}

private enum FortuneTypography {
    private static let fortuneFamily = firstAvailable([
        "LXGWWenKaiLite-Medium",
        "LXGWWenKaiLite-Regular",
        "Kai",
        "Kaiti SC",
        "STKaiti",
        "BiauKaiTC",
        "Songti SC"
    ])

    private static let supportFamily = firstAvailable([
        "LXGWWenKaiLite-Regular",
        "LXGWWenKaiLite-Medium",
        "Kai",
        "Kaiti SC",
        "Songti SC",
        "PingFang SC"
    ])

    static func headline(size: CGFloat) -> Font {
        .custom(fortuneFamily, size: size).weight(.semibold)
    }

    static func body(size: CGFloat) -> Font {
        .custom(supportFamily, size: size).weight(.medium)
    }

    static func caption(size: CGFloat) -> Font {
        .custom(supportFamily, size: size).weight(.medium)
    }

    private static func firstAvailable(_ names: [String]) -> String {
        let families = Set(NSFontManager.shared.availableFontFamilies)
        return names.first { NSFont(name: $0, size: 12) != nil || families.contains($0) } ?? "Songti SC"
    }
}

private struct PremiumRevealAuraView: View {
    let tint: Color
    let isRevealed: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: 184, height: 184)
                .blur(radius: 18)

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            tint.opacity(0.0),
                            tint.opacity(0.42),
                            Color.white.opacity(0.34),
                            tint.opacity(0.0)
                        ],
                        center: .center
                    ),
                    lineWidth: 2
                )
                .frame(width: 172, height: 172)

            Circle()
                .stroke(tint.opacity(0.12), lineWidth: 12)
                .frame(width: 116, height: 116)
                .blur(radius: 8)
        }
        .offset(y: -28)
        .opacity(isRevealed ? 1 : 0.42)
        .scaleEffect(isRevealed ? 1.08 : 0.92)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isRevealed)
    }
}

private struct FloatingBlessingParticles: View {
    let tint: Color
    let isVisible: Bool

    private let particles: [(CGFloat, CGFloat, CGFloat, Double)] = [
        (-116, -70, 5, 0.0),
        (-82, -122, 3, 0.08),
        (-38, -154, 4, 0.14),
        (34, -150, 3, 0.2),
        (84, -112, 5, 0.06),
        (120, -68, 3, 0.18),
        (-122, 12, 3, 0.1),
        (126, 10, 4, 0.16)
    ]

    var body: some View {
        ZStack {
            ForEach(particles.indices, id: \.self) { index in
                let particle = particles[index]

                Circle()
                    .fill(index.isMultiple(of: 2) ? tint.opacity(0.72) : Color.white.opacity(0.78))
                    .frame(width: particle.2, height: particle.2)
                    .offset(x: isVisible ? particle.0 : particle.0 * 0.18, y: isVisible ? particle.1 : 4)
                    .opacity(isVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.54).delay(particle.3), value: isVisible)
            }
        }
    }
}

private struct JarBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let topInset = rect.width * 0.08
        let bottomInset = rect.width * 0.2
        let radius: CGFloat = 18

        path.move(to: CGPoint(x: rect.minX + topInset + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topInset - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - topInset, y: rect.minY + radius), control: CGPoint(x: rect.maxX - topInset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - bottomInset, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - bottomInset - radius, y: rect.maxY), control: CGPoint(x: rect.maxX - bottomInset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bottomInset + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + bottomInset, y: rect.maxY - radius), control: CGPoint(x: rect.minX + bottomInset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + topInset, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topInset + radius, y: rect.minY), control: CGPoint(x: rect.minX + topInset, y: rect.minY))
        path.closeSubpath()

        return path
    }
}

private struct RibbonTailShape: Shape {
    let direction: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        if direction < 0 {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + 8, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + 8, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - 8, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - 8, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        path.closeSubpath()
        return path
    }
}

private struct ShadowShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: rect)
    }
}
