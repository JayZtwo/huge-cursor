//
//  ContentView.swift
//  Shake Cursor
//
//  Created by Rokid on 2026/5/13.
//

import AppKit
import ApplicationServices
import EventKit
import SwiftUI

struct ContentView: View {
    @StateObject private var monitor = MouseShakeMonitor()
    @State private var overlayPresenter = ShakeInputOverlayPresenter()
    @State private var readiness = DesktopReadinessState.current()

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(width: 276)
                .frame(maxHeight: .infinity)

            rightPanel
                .frame(width: 484)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 760, height: 464)
        .background(Color(red: 0.965, green: 0.963, blue: 0.974))
        .onAppear {
            monitor.start()
            refreshState()
        }
        .onChange(of: monitor.latestTrigger?.id) {
            guard let trigger = monitor.latestTrigger else { return }
            overlayPresenter.show(at: trigger.point)
        }
    }

    private var leftPanel: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.11, blue: 0.21),
                    Color(red: 0.28, green: 0.23, blue: 0.50),
                    Color(red: 0.45, green: 0.36, blue: 0.84)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 210, height: 210)
                .blur(radius: 32)
                .offset(x: 96, y: -80)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    appMark

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Shake Cursor")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("摇一摇入口")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                }
                .padding(.bottom, 42)

                VStack(alignment: .leading, spacing: 18) {
                    FlowStep(number: "01", title: "晃动鼠标", detail: "在当前位置唤起浮层")
                    FlowStep(number: "02", title: "输入想法", detail: "抽签、提问、安排日程")
                    FlowStep(number: "03", title: "写入日历", detail: "明确时间后自动创建事件")
                }

                Spacer(minLength: 24)

                Button {
                    hideMainWindow()
                } label: {
                    Label("隐藏到后台", systemImage: "minus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(tint: .white, prominent: false))
            }
            .padding(.top, 30)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var appMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .frame(width: 52, height: 52)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                }

            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("启动检查")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.15))

                Text("完成状态检查后，关闭窗口也会继续监听。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: readiness.readyCount == 4 ? "checkmark.circle.fill" : "circle.dotted")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(readiness.readyCount == 4 ? Color(red: 0.12, green: 0.56, blue: 0.35) : Color(red: 0.42, green: 0.34, blue: 0.82))

                Text("\(readiness.readyCount)/4")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.14, blue: 0.36))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.72), in: Capsule())
        }
        .padding(.bottom, 2)
    }

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            topBar
            BackgroundWakeHint()

            VStack(spacing: 10) {
                ReadinessCard(
                    icon: "cursorarrow.motionlines",
                    title: "摇一摇入口",
                    message: monitor.isMonitoring ? "后台监听已启动。" : "监听未启动。",
                    state: monitor.isMonitoring ? .ready : .warning,
                    actionTitle: monitor.isMonitoring ? nil : "启动",
                    action: monitor.start
                )

                ReadinessCard(
                    icon: "sparkles",
                    title: "Codex 连接",
                    message: readiness.codexMessage,
                    state: readiness.codexState,
                    actionTitle: "刷新",
                    action: refreshState
                )

                ReadinessCard(
                    icon: "calendar.badge.plus",
                    title: "日历写入",
                    message: readiness.calendarMessage,
                    state: readiness.calendarState,
                    actionTitle: readiness.calendarActionTitle,
                    action: handleCalendarAction
                )

                ReadinessCard(
                    icon: "hand.raised",
                    title: "辅助功能",
                    message: readiness.accessibilityMessage,
                    state: readiness.accessibilityState,
                    actionTitle: readiness.accessibilityActionTitle,
                    action: handleAccessibilityAction
                )
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 22)
        .padding(.horizontal, 26)
        .padding(.bottom, 22)
    }

    private func refreshState() {
        readiness = DesktopReadinessState.current()
    }

    private func handleCalendarAction() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            Task {
                _ = try? await CalendarEventWriter.shared.requestAccessForGuide()
                await MainActor.run { refreshState() }
            }
        case .authorized, .fullAccess, .writeOnly:
            refreshState()
        default:
            openSystemSettings(anchor: "Privacy_Calendars")
        }
    }

    private func handleAccessibilityAction() {
        if AXIsProcessTrusted() {
            refreshState()
        } else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            openSystemSettings(anchor: "Privacy_Accessibility")
        }
    }

    private func hideMainWindow() {
        NSApp.windows
            .filter { !($0 is NSPanel) }
            .forEach { $0.orderOut(nil) }
    }

    private func openSystemSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct DesktopReadinessState {
    let codexState: ReadinessState
    let codexMessage: String
    let calendarState: ReadinessState
    let calendarMessage: String
    let calendarActionTitle: String
    let accessibilityState: ReadinessState
    let accessibilityMessage: String
    let accessibilityActionTitle: String

    var readyCount: Int {
        1 + [codexState, calendarState, accessibilityState].filter { $0 == .ready }.count
    }

    static func current() -> DesktopReadinessState {
        let codexExists = FileManager.default.fileExists(atPath: "/Applications/Codex.app")
        let calendarStatus = EKEventStore.authorizationStatus(for: .event)
        let accessibilityReady = AXIsProcessTrusted()

        return DesktopReadinessState(
            codexState: codexExists ? .ready : .blocked,
            codexMessage: codexExists ? "已找到 Codex Desktop。请确认已登录。" : "未找到 Codex Desktop，需要先安装并登录。",
            calendarState: calendarState(for: calendarStatus),
            calendarMessage: calendarMessage(for: calendarStatus),
            calendarActionTitle: calendarActionTitle(for: calendarStatus),
            accessibilityState: accessibilityReady ? .ready : .warning,
            accessibilityMessage: accessibilityReady ? "已授权，后台监听更稳定。" : "建议开启。未授权时部分系统环境下后台监听可能不稳定。",
            accessibilityActionTitle: accessibilityReady ? "刷新" : "打开设置"
        )
    }

    private static func calendarState(for status: EKAuthorizationStatus) -> ReadinessState {
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            return .ready
        case .notDetermined:
            return .warning
        case .denied, .restricted:
            return .blocked
        @unknown default:
            return .warning
        }
    }

    private static func calendarMessage(for status: EKAuthorizationStatus) -> String {
        switch status {
        case .authorized, .fullAccess:
            return "已授权完整访问，可创建日程。"
        case .writeOnly:
            return "已授权写入，可创建日程。"
        case .notDetermined:
            return "尚未授权。点击请求授权会弹出系统确认。"
        case .denied:
            return "已被拒绝。需要到系统设置中允许日历访问。"
        case .restricted:
            return "系统限制了日历访问。"
        @unknown default:
            return "状态未知，请刷新或打开系统设置检查。"
        }
    }

    private static func calendarActionTitle(for status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "请求授权"
        case .authorized, .fullAccess, .writeOnly:
            return "刷新"
        default:
            return "打开设置"
        }
    }
}

private enum ReadinessState: Equatable {
    case ready
    case warning
    case blocked

    var title: String {
        switch self {
        case .ready:
            return "就绪"
        case .warning:
            return "待确认"
        case .blocked:
            return "需处理"
        }
    }

    var tint: Color {
        switch self {
        case .ready:
            return Color(red: 0.12, green: 0.56, blue: 0.35)
        case .warning:
            return Color(red: 0.72, green: 0.45, blue: 0.08)
        case .blocked:
            return Color(red: 0.70, green: 0.16, blue: 0.20)
        }
    }

    var symbol: String {
        switch self {
        case .ready:
            return "checkmark"
        case .warning:
            return "exclamationmark"
        case .blocked:
            return "xmark"
        }
    }
}

private struct BackgroundWakeHint: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 0.42, green: 0.34, blue: 0.82))

            Text("正常使用前，请点击左侧「隐藏到后台」")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color(red: 0.30, green: 0.28, blue: 0.40).opacity(0.82))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.91, green: 0.89, blue: 0.98).opacity(0.74))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(red: 0.42, green: 0.34, blue: 0.82).opacity(0.14), lineWidth: 1)
        }
    }
}

private struct ReadinessCard: View {
    let icon: String
    let title: String
    let message: String
    let state: ReadinessState
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(state.tint.opacity(0.12))
                    .frame(width: 42, height: 42)

                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(state.tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.15))

                    StatusBadge(state: state)
                }

                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            if let actionTitle, let action {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(PillButtonStyle(tint: state.tint, prominent: state != .ready))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(height: 74)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.78))
                .shadow(color: Color.black.opacity(0.045), radius: 18, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.72), lineWidth: 1)
        }
    }
}

private struct StatusBadge: View {
    let state: ReadinessState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbol)
                .font(.system(size: 8, weight: .bold))
            Text(state.title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(state.tint.opacity(0.12)))
    }
}

private struct FlowStep: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text(number)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.16)))
                .overlay {
                    Circle().stroke(.white.opacity(0.18), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
    }
}

private struct PillButtonStyle: ButtonStyle {
    let tint: Color
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? .white : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(prominent ? tint : tint.opacity(0.13))
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

#Preview {
    ContentView()
}
