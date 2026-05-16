//
//  CodexBridge.swift
//  Shake Cursor
//
//  Created by Codex on 2026/5/15.
//

import CoreGraphics
import Foundation

enum CodexBridgeLog {
    private static let url = URL(fileURLWithPath: "/tmp/shake-cursor-codex.log")

    static func write(_ message: String) {
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

struct FortuneResponse {
    let title: String
    let message: String
    let detail: String
    let energy: String
}

struct AssistantResponse {
    let text: String
    let calendarEvent: CalendarEventDraft?
}

struct CalendarEventDraft {
    let title: String
    let startDate: Date
    let endDate: Date
    let notes: String?
    let isAllDay: Bool
}

struct FortuneRequestContext {
    let point: CGPoint
}

enum CodexBridgeError: LocalizedError {
    case executableNotFound
    case appServerUnavailable(String)
    case configurationUnavailable(String)
    case threadUnavailable(String)
    case turnUnavailable(String)
    case emptyResponse
    case timeout

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "没有找到本机 Codex，请先安装并登录 Codex。"
        case .appServerUnavailable:
            return "当前 Codex 版本不支持本地 Bridge。"
        case .configurationUnavailable:
            return "请先打开 Codex 完成登录。"
        case .threadUnavailable:
            return "Codex 线程暂时不可用。"
        case .turnUnavailable:
            return "Codex 本次回复暂时失败。"
        case .emptyResponse:
            return "Codex 这次没有返回内容。"
        case .timeout:
            return "Codex 回复超时了，可以稍后再试。"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .appServerUnavailable(let detail),
             .configurationUnavailable(let detail),
             .threadUnavailable(let detail),
             .turnUnavailable(let detail):
            return detail
        default:
            return nil
        }
    }
}

@MainActor
final class CodexBridge {
    static let shared = CodexBridge()

    private let client: CodexAppServerClient
    private let threadStore = CodexThreadStore()
    private let lifeContextStore = LifeContextStore()
    private var didPrepare = false
    private var activeTurns: [String: ActiveTurn] = [:]
    private var runningChannels: Set<PromptChannel> = []
    private var promptStartedAt: [PromptChannel: Date] = [:]

    private init() {
        client = CodexAppServerClient()
        client.onEvent = { [weak self] message in
            self?.handleAppServerEvent(message)
        }
    }

    func drawFortune(context: FortuneRequestContext) async throws -> FortuneResponse {
        CodexBridgeLog.write("drawFortune requested model=\(Self.selectedModel)")
        let prompt = Self.buildFortunePrompt(
            context: context,
            sharedContext: lifeContextStore.promptContext()
        )
        let text = try await runPrompt(prompt, channel: .fortune)
        CodexBridgeLog.write("drawFortune received chars=\(text.count)")
        let response = try Self.parseFortuneResponse(text)
        lifeContextStore.recordFortune(response, point: context.point)
        return response
    }

    func askLifeAssistant(text: String, context: String = "") async throws -> AssistantResponse {
        CodexBridgeLog.write("askLifeAssistant requested model=\(Self.selectedModel), chars=\(text.count)")
        let prompt = Self.buildAssistantPrompt(
            text: text,
            context: context,
            sharedContext: lifeContextStore.promptContext()
        )
        let answer = try await runPrompt(prompt, channel: .assistant)
        CodexBridgeLog.write("askLifeAssistant received chars=\(answer.count)")
        let response = Self.parseAssistantResponse(answer)
        lifeContextStore.recordAssistant(input: text, response: response, attachedContext: context)
        return response
    }

    func interruptActiveTurns() async {
        for (threadId, turn) in activeTurns {
            guard let turnId = turn.turnId else { continue }
            try? await client.request(
                method: "turn/interrupt",
                params: [
                    "threadId": threadId,
                    "turnId": turnId
                ]
            )
        }
    }

    private func prepareIfNeeded() async throws {
        guard !didPrepare else { return }

        do {
            _ = try await client.requestWithTimeout(method: "config/read", params: [:])
            CodexBridgeLog.write("config/read ok")
            didPrepare = true
        } catch let error as CodexBridgeError {
            CodexBridgeLog.write("config/read bridge error=\(error.localizedDescription) \(error.recoverySuggestion ?? "")")
            throw error
        } catch {
            CodexBridgeLog.write("config/read error=\(String(describing: error))")
            throw CodexBridgeError.configurationUnavailable(String(describing: error))
        }
    }

    private func runPrompt(_ prompt: String, channel: PromptChannel) async throws -> String {
        var lockWaitStartedAt = Date()
        while runningChannels.contains(channel) {
            if Date().timeIntervalSince(lockWaitStartedAt) > 2.0 {
                CodexBridgeLog.write("prompt lock stale channel=\(channel.rawValue), recovering active turns")
                await recoverFromStalledPrompt(channel: channel)
                lockWaitStartedAt = Date()
                break
            }
            try await Task.sleep(for: .milliseconds(120))
        }

        runningChannels.insert(channel)
        promptStartedAt[channel] = Date()
        defer {
            runningChannels.remove(channel)
            promptStartedAt[channel] = nil
        }

        try await prepareIfNeeded()
        let threadId = try await openThread(channel: channel)
        CodexBridgeLog.write("runPrompt channel=\(channel.rawValue) thread=\(threadId)")

        return try await withTimeout(seconds: 90) { [self] in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.activeTurns[threadId] = ActiveTurn(channel: channel, continuation: continuation)

                    Task {
                        do {
                            let response = try await self.client.requestWithTimeout(
                                method: "turn/start",
                                params: [
                                    "threadId": threadId,
                                    "input": [
                                        [
                                            "type": "text",
                                            "text": prompt,
                                            "text_elements": []
                                        ]
                                    ],
                                    "cwd": FileManager.default.homeDirectoryForCurrentUser.path,
                                    "approvalPolicy": "on-request",
                                    "sandboxPolicy": [
                                        "type": "readOnly",
                                        "access": [
                                            "type": "fullAccess"
                                        ],
                                        "networkAccess": false
                                    ],
                                    "model": Self.selectedModel
                                ]
                            )

                            self.captureTurnId(from: response, threadId: threadId)
                            CodexBridgeLog.write("turn/start ok thread=\(threadId)")
                        } catch {
                            CodexBridgeLog.write("turn/start error=\(String(describing: error))")
                            self.finishTurn(threadId: threadId, result: .failure(CodexBridgeError.turnUnavailable(String(describing: error))))
                        }
                    }
                }
            } onCancel: {
                Task {
                    await self.interrupt(threadId: threadId)
                }
            }
        }
    }

    private func recoverFromStalledPrompt(channel: PromptChannel) async {
        let stalledThreadIds = activeTurns
            .filter { $0.value.channel == channel }
            .map(\.key)

        for threadId in stalledThreadIds {
            await interrupt(threadId: threadId)
            finishTurn(threadId: threadId, result: .failure(CodexBridgeError.timeout))
        }

        runningChannels.remove(channel)
        promptStartedAt[channel] = nil
        didPrepare = false
        if activeTurns.isEmpty {
            await client.restart()
        }
    }

    private func openThread(channel: PromptChannel) async throws -> String {
        if let savedThreadId = threadStore.threadId(for: channel) {
            do {
                let response = try await client.requestWithTimeout(
                    method: "thread/resume",
                    params: threadParams(threadId: savedThreadId)
                )
                let threadId = try extractThreadId(from: response, fallback: savedThreadId)
                CodexBridgeLog.write("thread/resume ok channel=\(channel.rawValue) thread=\(threadId)")
                return threadId
            } catch {
                CodexBridgeLog.write("thread/resume failed channel=\(channel.rawValue), clearing saved thread. error=\(String(describing: error))")
                threadStore.setThreadId(nil, for: channel)
            }
        }

        do {
            let response = try await client.requestWithTimeout(
                method: "thread/start",
                params: threadParams(threadId: nil)
            )
            let threadId = try extractThreadId(from: response, fallback: nil)
            threadStore.setThreadId(threadId, for: channel)
            CodexBridgeLog.write("thread/start ok channel=\(channel.rawValue) thread=\(threadId)")
            return threadId
        } catch {
            CodexBridgeLog.write("thread/start error channel=\(channel.rawValue) \(String(describing: error))")
            throw CodexBridgeError.threadUnavailable(String(describing: error))
        }
    }

    private func threadParams(threadId: String?) -> [String: Any] {
        var params: [String: Any] = [
            "cwd": FileManager.default.homeDirectoryForCurrentUser.path,
            "approvalPolicy": "on-request",
            "sandbox": "read-only",
            "model": Self.selectedModel,
            "persistExtendedHistory": true,
            "experimentalRawEvents": false
        ]

        if let threadId {
            params["threadId"] = threadId
        }

        return params
    }

    private func extractThreadId(from response: [String: Any], fallback: String?) throws -> String {
        if let thread = response["thread"] as? [String: Any],
           let id = thread["id"] as? String {
            return id
        }

        if let fallback {
            return fallback
        }

        throw CodexBridgeError.threadUnavailable("Codex app-server did not return a thread id.")
    }

    private func captureTurnId(from response: [String: Any], threadId: String) {
        guard var activeTurn = activeTurns[threadId],
              let turn = response["turn"] as? [String: Any],
              let turnId = turn["id"] as? String else {
            return
        }

        activeTurn.turnId = turnId
        activeTurns[threadId] = activeTurn
    }

    private func interrupt(threadId: String) async {
        guard let turnId = activeTurns[threadId]?.turnId else { return }
        try? await client.request(
            method: "turn/interrupt",
            params: [
                "threadId": threadId,
                "turnId": turnId
            ]
        )
    }

    private func handleAppServerEvent(_ message: [String: Any]) {
        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else {
            return
        }
        CodexBridgeLog.write("event \(method)")

        if method == "__connection_closed__" {
            let detail = params["message"] as? String ?? "Codex app-server connection closed."
            CodexBridgeLog.write("connection closed detail=\(detail)")
            for threadId in activeTurns.keys {
                finishTurn(threadId: threadId, result: .failure(CodexBridgeError.appServerUnavailable(detail)))
            }
            return
        }

        guard let threadId = params["threadId"] as? String,
              var activeTurn = activeTurns[threadId] else {
            return
        }

        switch method {
        case "turn/started":
            if let turn = params["turn"] as? [String: Any],
               let turnId = turn["id"] as? String {
                activeTurn.turnId = turnId
                activeTurns[threadId] = activeTurn
            }

        case "item/started":
            if let item = params["item"] as? [String: Any],
               let id = item["id"] as? String,
               let phase = item["phase"] as? String {
                activeTurn.itemPhases[id] = phase
                activeTurns[threadId] = activeTurn
            }

        case "item/agentMessage/delta":
            let itemId = params["itemId"] as? String
            let phase = itemId.flatMap { activeTurn.itemPhases[$0] }
            if phase == nil || phase == "final_answer" {
                activeTurn.finalText += params["delta"] as? String ?? ""
                activeTurns[threadId] = activeTurn
            }

        case "item/completed":
            if let item = params["item"] as? [String: Any],
               item["type"] as? String == "agentMessage",
               item["phase"] as? String == "final_answer",
               let text = item["text"] as? String,
               !text.isEmpty {
                activeTurn.finalText = text
                activeTurns[threadId] = activeTurn
                CodexBridgeLog.write("final item completed chars=\(text.count)")
                finishTurn(threadId: threadId, result: .success(text))
            }

        case "error":
            let errorText = String(describing: params["error"] ?? params)
            CodexBridgeLog.write("turn error params=\(errorText)")
            if errorText.localizedCaseInsensitiveContains("Reconnecting") {
                return
            }
            finishTurn(threadId: threadId, result: .failure(CodexBridgeError.turnUnavailable(errorText)))

        case "turn/completed":
            if let turn = params["turn"] as? [String: Any] {
                activeTurn.finalText = Self.extractFinalText(from: turn, fallback: activeTurn.finalText)
                activeTurns[threadId] = activeTurn

                if let error = turn["error"] {
                    CodexBridgeLog.write("turn/completed error=\(String(describing: error))")
                    finishTurn(threadId: threadId, result: .failure(CodexBridgeError.turnUnavailable(String(describing: error))))
                    return
                }
            }

            let answer = activeTurns[threadId]?.finalText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            finishTurn(threadId: threadId, result: answer.isEmpty ? .failure(CodexBridgeError.emptyResponse) : .success(answer))

        default:
            break
        }
    }

    private func finishTurn(threadId: String, result: Result<String, Error>) {
        guard let activeTurn = activeTurns.removeValue(forKey: threadId) else { return }

        switch result {
        case .success(let text):
            CodexBridgeLog.write("finishTurn success thread=\(threadId) chars=\(text.count)")
            activeTurn.continuation.resume(returning: text)
        case .failure(let error):
            CodexBridgeLog.write("finishTurn failure thread=\(threadId) error=\(String(describing: error))")
            activeTurn.continuation.resume(throwing: error)
        }
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CodexBridgeError.timeout
            }

            guard let result = try await group.next() else {
                throw CodexBridgeError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private static func extractFinalText(from turn: [String: Any], fallback: String) -> String {
        guard let items = turn["items"] as? [[String: Any]] else {
            return fallback
        }

        for item in items.reversed() {
            if item["type"] as? String == "agentMessage",
               item["phase"] as? String == "final_answer",
               let text = item["text"] as? String,
               !text.isEmpty {
                return text
            }
        }

        return fallback
    }

    private static func buildFortunePrompt(context: FortuneRequestContext, sharedContext: String) -> String {
        """
        你是一个 macOS 上的生活灵感助手，不是代码助手。用户刚刚快速晃动鼠标，触发了一次「摇一摇抽签」。

        请结合当前时间、动作入口和轻微的仪式感，为用户生成一支中文签。语气要短、克制、积极、有余味，不要油腻，不要提代码实现。
        你看到的是同一个「生活入口」的共享记忆。底层可能来自不同 worker thread，但对用户来说你要保持连续、稳定、像同一个助手。

        当前时间：\(Date().formatted(date: .complete, time: .complete))
        时区：\(TimeZone.current.identifier)
        摇动位置：x=\(Int(context.point.x)), y=\(Int(context.point.y))
        共享生活上下文：
        \(sharedContext)

        请只返回 JSON，不要 Markdown，不要解释：
        {
          "title": "2到5个字，例如 上上签/灵感签/定心签",
          "message": "8到14个中文字，适合作为主签文",
          "detail": "18到32个中文字，给出今天的温柔行动建议",
          "energy": "2到6个中文字，像状态标签"
        }

        如果你无法判断，就保持轻盈，把这次摇动理解为一次把注意力收回来的提醒。
        """
    }

    private static var selectedModel: String {
        ProcessInfo.processInfo.environment["HUGE_CURSOR_CODEX_MODEL"] ?? "gpt-5.5"
    }

    private static func buildAssistantPrompt(text: String, context: String, sharedContext: String) -> String {
        """
        你是一个 macOS 上随手唤出的日常生活助手，不是代码助手。你需要帮助用户把模糊想法变成短小、可执行的下一步。
        如果用户表达了创建日程、会议、提醒、安排、约见、截止时间、待办时间点等意图，请把它结构化为可写入 macOS 日历的事件草稿。
        你看到的是同一个「生活入口」的共享记忆。底层可能来自不同 worker thread，但对用户来说你要保持连续、稳定、像同一个助手。

        当前时间：\(Date().formatted(date: .complete, time: .complete))
        时区：\(TimeZone.current.identifier)
        附加上下文：\(context.isEmpty ? "无" : context)
        共享生活上下文：
        \(sharedContext)

        用户输入：
        \(text)

        回复要求：
        - 使用中文
        - reply 最多 80 个中文字
        - 不要长篇说教
        - 如果像待办，就提炼成 1 到 3 个行动项
        - 如果像问题，就直接给建议
        - 不要提到你是模型或系统
        - 请只返回 JSON，不要 Markdown，不要解释

        JSON 格式：
        {
          "reply": "给用户看的短回复",
          "calendarEvent": null
        }

        如果需要创建日程，calendarEvent 使用：
        {
          "title": "短标题",
          "startDate": "ISO-8601 带时区，例如 2026-05-16T10:00:00+08:00",
          "endDate": "ISO-8601 带时区；如果用户没说时长，默认 30 分钟",
          "notes": "可选备注，简短",
          "isAllDay": false
        }

        如果用户没有明确时间，不要创建 calendarEvent，只在 reply 里追问缺失时间。
        """
    }

    private static func parseFortuneResponse(_ text: String) throws -> FortuneResponse {
        let cleaned = cleanedJSONText(text)
        guard let data = cleaned.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let plain = cleanedPlainText(text)
            guard !plain.isEmpty else {
                throw CodexBridgeError.emptyResponse
            }

            return FortuneResponse(
                title: "成签",
                message: String(plain.prefix(18)),
                detail: plain,
                energy: "Codex"
            )
        }

        guard let message = nonEmptyString(object["message"]) else {
            throw CodexBridgeError.emptyResponse
        }

        return FortuneResponse(
            title: nonEmptyString(object["title"]) ?? "成签",
            message: message,
            detail: nonEmptyString(object["detail"]) ?? "",
            energy: nonEmptyString(object["energy"]) ?? ""
        )
    }

    private static func parseAssistantResponse(_ text: String) -> AssistantResponse {
        let cleaned = cleanedJSONText(text)
        guard let data = cleaned.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AssistantResponse(text: cleanedPlainText(text), calendarEvent: nil)
        }

        let reply = nonEmptyString(object["reply"]) ?? cleanedPlainText(text)
        let eventObject = object["calendarEvent"] as? [String: Any]
        let event = eventObject.flatMap(parseCalendarEventDraft)
        return AssistantResponse(text: reply, calendarEvent: event)
    }

    private static func parseCalendarEventDraft(_ object: [String: Any]) -> CalendarEventDraft? {
        guard let title = nonEmptyString(object["title"]),
              let startText = nonEmptyString(object["startDate"]),
              let startDate = parseDate(startText) else {
            return nil
        }

        let parsedEndDate = nonEmptyString(object["endDate"]).flatMap(parseDate)
        let endDate = parsedEndDate ?? startDate.addingTimeInterval(30 * 60)
        return CalendarEventDraft(
            title: title,
            startDate: startDate,
            endDate: max(endDate, startDate.addingTimeInterval(15 * 60)),
            notes: nonEmptyString(object["notes"]),
            isAllDay: (object["isAllDay"] as? Bool) ?? false
        )
    }

    private static func parseDate(_ text: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: text) {
            return date
        }

        isoFormatter.formatOptions = [.withInternetDateTime]
        return isoFormatter.date(from: text)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cleanedJSONText(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            return String(cleaned[start...end])
        }

        return cleaned
    }

    private static func cleanedPlainText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum PromptChannel: String, Hashable {
    case fortune
    case assistant
}

private struct ActiveTurn {
    let channel: PromptChannel
    let continuation: CheckedContinuation<String, Error>
    var finalText = ""
    var itemPhases: [String: String] = [:]
    var turnId: String?
}

private final class CodexThreadStore {
    private let legacyLifeKey = "HugeCursor.CodexBridge.lifeThreadId"
    private let fortuneKey = "HugeCursor.CodexBridge.fortuneThreadId"
    private let assistantKey = "HugeCursor.CodexBridge.assistantThreadId"

    func threadId(for channel: PromptChannel) -> String? {
        let key = storageKey(for: channel)
        if let value = UserDefaults.standard.string(forKey: key) {
            return value
        }

        if channel == .fortune,
           let legacyValue = UserDefaults.standard.string(forKey: legacyLifeKey) {
            UserDefaults.standard.set(legacyValue, forKey: fortuneKey)
            return legacyValue
        }

        return nil
    }

    func setThreadId(_ value: String?, for channel: PromptChannel) {
        let key = storageKey(for: channel)
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func storageKey(for channel: PromptChannel) -> String {
        switch channel {
        case .fortune:
            return fortuneKey
        case .assistant:
            return assistantKey
        }
    }
}

private final class LifeContextStore {
    private let storageKey = "HugeCursor.LifeContextStore.v1"
    private let maxFortunes = 8
    private let maxAssistantTurns = 10
    private let maxCalendarDrafts = 8

    func promptContext() -> String {
        let state = load()
        var lines: [String] = []

        if state.recentFortunes.isEmpty,
           state.recentAssistantTurns.isEmpty,
           state.recentCalendarDrafts.isEmpty {
            return "暂无可用记忆。把这次请求当作一次新的生活入口触发。"
        }

        if !state.recentFortunes.isEmpty {
            lines.append("最近签文：")
            for item in state.recentFortunes.suffix(4).reversed() {
                lines.append("- \(format(item.createdAt)) \(item.title)：\(item.message)。\(item.detail)")
            }
        }

        if !state.recentAssistantTurns.isEmpty {
            lines.append("最近助手对话：")
            for item in state.recentAssistantTurns.suffix(4).reversed() {
                lines.append("- \(format(item.createdAt)) 用户：\(item.input)；助手：\(item.reply)")
            }
        }

        if !state.recentCalendarDrafts.isEmpty {
            lines.append("最近日程草稿：")
            for item in state.recentCalendarDrafts.suffix(3).reversed() {
                lines.append("- \(format(item.createdAt)) \(item.title)：\(item.startText)")
            }
        }

        lines.append("使用原则：这些内容只作为连续感参考，不要机械复述；当用户意图与记忆冲突时，以当前输入为准。")
        return lines.joined(separator: "\n")
    }

    func recordFortune(_ response: FortuneResponse, point: CGPoint) {
        mutate { state in
            state.recentFortunes.append(
                LifeFortuneMemory(
                    createdAt: Date(),
                    title: Self.normalized(response.title, limit: 12),
                    message: Self.normalized(response.message, limit: 32),
                    detail: Self.normalized(response.detail, limit: 80),
                    energy: Self.normalized(response.energy, limit: 16),
                    pointX: Int(point.x),
                    pointY: Int(point.y)
                )
            )
        }
    }

    func recordAssistant(input: String, response: AssistantResponse, attachedContext: String) {
        mutate { state in
            state.recentAssistantTurns.append(
                LifeAssistantMemory(
                    createdAt: Date(),
                    input: Self.normalized(input, limit: 90),
                    reply: Self.normalized(response.text, limit: 120),
                    attachedContext: Self.normalized(attachedContext, limit: 100)
                )
            )

            if let calendarEvent = response.calendarEvent {
                state.recentCalendarDrafts.append(
                    LifeCalendarMemory(
                        createdAt: Date(),
                        title: Self.normalized(calendarEvent.title, limit: 40),
                        startText: Self.formatCalendarDate(calendarEvent.startDate),
                        endText: Self.formatCalendarDate(calendarEvent.endDate),
                        notes: Self.normalized(calendarEvent.notes ?? "", limit: 80),
                        isAllDay: calendarEvent.isAllDay
                    )
                )
            }
        }
    }

    private func mutate(_ update: (inout LifeContextState) -> Void) {
        var state = load()
        update(&state)
        state.updatedAt = Date()
        state.recentFortunes = Array(state.recentFortunes.suffix(maxFortunes))
        state.recentAssistantTurns = Array(state.recentAssistantTurns.suffix(maxAssistantTurns))
        state.recentCalendarDrafts = Array(state.recentCalendarDrafts.suffix(maxCalendarDrafts))
        save(state)
        CodexBridgeLog.write(
            "life context updated fortunes=\(state.recentFortunes.count) assistant=\(state.recentAssistantTurns.count) calendars=\(state.recentCalendarDrafts.count)"
        )
    }

    private func load() -> LifeContextState {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(LifeContextState.self, from: data) else {
            return LifeContextState()
        }

        return state
    }

    private func save(_ state: LifeContextState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func format(_ date: Date) -> String {
        Self.contextDateFormatter.string(from: date)
    }

    private static func formatCalendarDate(_ date: Date) -> String {
        contextDateFormatter.string(from: date)
    }

    private static func normalized(_ text: String, limit: Int) -> String {
        let compact = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit)) + "..."
    }

    private static let contextDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

private struct LifeContextState: Codable {
    var updatedAt: Date?
    var recentFortunes: [LifeFortuneMemory] = []
    var recentAssistantTurns: [LifeAssistantMemory] = []
    var recentCalendarDrafts: [LifeCalendarMemory] = []
}

private struct LifeFortuneMemory: Codable {
    let createdAt: Date
    let title: String
    let message: String
    let detail: String
    let energy: String
    let pointX: Int
    let pointY: Int
}

private struct LifeAssistantMemory: Codable {
    let createdAt: Date
    let input: String
    let reply: String
    let attachedContext: String
}

private struct LifeCalendarMemory: Codable {
    let createdAt: Date
    let title: String
    let startText: String
    let endText: String
    let notes: String
    let isAllDay: Bool
}

final class CodexAppServerClient {
    var onEvent: (([String: Any]) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextRequestId = 1
    private var startTask: Task<Void, Error>?
    private var didInitialize = false

    deinit {
        process?.terminate()
    }

    func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        try await ensureStarted()
        let id = nextId()
        return try await sendRequest(id: id, method: method, params: params)
    }

    func restart() async {
        CodexBridgeLog.write("restarting app-server")
        lock.lock()
        let process = self.process
        let stdoutPipe = self.stdoutPipe
        let stderrPipe = self.stderrPipe
        let pending = self.pending
        self.pending.removeAll()
        self.process = nil
        self.stdinPipe = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
        self.startTask = nil
        self.didInitialize = false
        lock.unlock()

        pending.values.forEach {
            $0.resume(throwing: CodexBridgeError.appServerUnavailable("Codex app-server restarted."))
        }

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if process?.isRunning == true {
            process?.terminate()
        }
    }

    func requestWithTimeout(method: String, params: [String: Any], seconds: TimeInterval = 15) async throws -> [String: Any] {
        try await ensureStarted()
        let id = nextId()

        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await self.sendRequest(id: id, method: method, params: params)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CodexBridgeError.timeout
            }

            do {
                guard let result = try await group.next() else {
                    cancelPendingRequest(id: id, error: CodexBridgeError.timeout)
                    await restart()
                    throw CodexBridgeError.timeout
                }
                group.cancelAll()
                return result
            } catch CodexBridgeError.timeout {
                group.cancelAll()
                cancelPendingRequest(id: id, error: CodexBridgeError.timeout)
                await restart()
                throw CodexBridgeError.timeout
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func cancelPendingRequest(id: Int, error: Error) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func ensureStarted() async throws {
        lock.lock()
        if didInitialize, process?.isRunning == true {
            lock.unlock()
            return
        }
        if let startTask {
            lock.unlock()
            try await startTask.value
            return
        }

        let task = Task {
            try await self.start()
        }
        startTask = task
        lock.unlock()

        do {
            try await task.value
            lock.lock()
            startTask = nil
            lock.unlock()
        } catch {
            lock.lock()
            startTask = nil
            lock.unlock()
            throw error
        }
    }

    private func start() async throws {
        guard let codexURL = Self.resolveCodexURL() else {
            CodexBridgeLog.write("codex executable not found")
            throw CodexBridgeError.executableNotFound
        }
        CodexBridgeLog.write("starting app-server path=\(codexURL.path) model=\(Self.selectedModel)")

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = codexURL
        process.arguments = [
            "app-server",
            "--listen",
            "stdio://",
            "-c",
            "skip_git_repo_check=true",
            "-c",
            "model_provider=\"shake-cursor-openai-http\"",
            "-c",
            "model_providers.shake-cursor-openai-http.name=\"Shake Cursor OpenAI HTTP\"",
            "-c",
            "model_providers.shake-cursor-openai-http.base_url=\"https://chatgpt.com/backend-api/codex\"",
            "-c",
            "model_providers.shake-cursor-openai-http.wire_api=\"responses\"",
            "-c",
            "model_providers.shake-cursor-openai-http.requires_openai_auth=true",
            "-c",
            "model_providers.shake-cursor-openai-http.supports_websockets=false",
            "-c",
            "model_providers.shake-cursor-openai-http.stream_max_retries=0",
            "-c",
            "model=\"\(Self.selectedModel)\""
        ]
        let realHome = NSHomeDirectory()
        process.currentDirectoryURL = URL(fileURLWithPath: realHome)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = realHome
        environment["CODEX_HOME"] = "\(realHome)/.codex"
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty, let process else { return }
            Task { @MainActor in
                self?.handleStdout(data, from: process)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty, let process, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendStderr(text, from: process)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.handleClose(
                    from: process,
                    detail: "Codex app-server exited with code \(process.terminationStatus)."
                )
            }
        }

        lock.lock()
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        stdoutBuffer = ""
        stderrBuffer = ""
        didInitialize = false
        lock.unlock()

        do {
            try process.run()
        } catch {
            CodexBridgeLog.write("process.run error=\(String(describing: error))")
            throw CodexBridgeError.appServerUnavailable(String(describing: error))
        }

        _ = try await sendRequest(
            id: 0,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "shake-cursor",
                    "version": "0.1.0"
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ]
        )
        try sendNotification(method: "initialized", params: nil)
        CodexBridgeLog.write("initialize ok")

        lock.lock()
        didInitialize = true
        lock.unlock()
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]) async throws -> [String: Any] {
        CodexBridgeLog.write("request id=\(id) method=\(method)")
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = continuation
            lock.unlock()

            do {
                try writeMessage([
                    "id": id,
                    "method": method,
                    "params": params
                ])
            } catch {
                lock.lock()
                pending.removeValue(forKey: id)
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]?) throws {
        var message: [String: Any] = ["method": method]
        if let params {
            message["params"] = params
        }
        try writeMessage(message)
    }

    private func writeMessage(_ message: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              var line = String(data: data, encoding: .utf8) else {
            throw CodexBridgeError.appServerUnavailable("Unable to encode JSON-RPC message.")
        }

        line.append("\n")

        guard let lineData = line.data(using: .utf8) else {
            throw CodexBridgeError.appServerUnavailable("Codex app-server stdin is unavailable.")
        }

        lock.lock()
        let handle = stdinPipe?.fileHandleForWriting
        let canWrite = process?.isRunning == true
        guard canWrite, let handle else {
            lock.unlock()
            throw CodexBridgeError.appServerUnavailable("Codex app-server stdin is unavailable.")
        }
        handle.write(lineData)
        lock.unlock()
    }

    private func handleStdout(_ data: Data, from sourceProcess: Process) {
        lock.lock()
        let isCurrentProcess = process === sourceProcess
        lock.unlock()
        guard isCurrentProcess else { return }

        guard let text = String(data: data, encoding: .utf8) else { return }

        lock.lock()
        stdoutBuffer += text
        let lines = stdoutBuffer.components(separatedBy: "\n")
        stdoutBuffer = lines.last ?? ""
        lock.unlock()

        for line in lines.dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            handleMessage(message)
        }
    }

    private func handleMessage(_ message: [String: Any]) {
        if let id = message["id"] as? Int,
           message["result"] != nil || message["error"] != nil {
            lock.lock()
            let continuation = pending.removeValue(forKey: id)
            lock.unlock()

            guard let continuation else { return }
            if let error = message["error"] {
                CodexBridgeLog.write("response id=\(id) error=\(String(describing: error))")
                continuation.resume(throwing: CodexBridgeError.appServerUnavailable(String(describing: error)))
            } else {
                CodexBridgeLog.write("response id=\(id) ok")
                continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
            }
            return
        }

        onEvent?(message)
    }

    private func appendStderr(_ text: String, from sourceProcess: Process) {
        lock.lock()
        let isCurrentProcess = process === sourceProcess
        lock.unlock()
        guard isCurrentProcess else { return }

        lock.lock()
        stderrBuffer = String((stderrBuffer + text).suffix(32_768))
        lock.unlock()
        if text.contains("\"level\":\"ERROR\"") || text.contains("\"level\":\"WARN\"") || text.localizedCaseInsensitiveContains("error") {
            CodexBridgeLog.write("stderr \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func handleClose(from closedProcess: Process, detail: String) {
        lock.lock()
        let isCurrentProcess = process === closedProcess
        lock.unlock()

        guard isCurrentProcess else {
            CodexBridgeLog.write("ignored stale app-server close detail=\(detail)")
            return
        }

        CodexBridgeLog.write("handleClose detail=\(detail)")
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        didInitialize = false
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        let pending = self.pending
        self.pending.removeAll()
        lock.unlock()

        pending.values.forEach {
            $0.resume(throwing: CodexBridgeError.appServerUnavailable(detail))
        }
        onEvent?([
            "method": "__connection_closed__",
            "params": [
                "message": detail
            ]
        ])
    }

    private func nextId() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextRequestId
        nextRequestId += 1
        return id
    }

    private static func resolveCodexURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["HUGE_CURSOR_CODEX_PATH"],
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            shellWhichCodex()
        ].compactMap { $0 }

        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private static var selectedModel: String {
        ProcessInfo.processInfo.environment["HUGE_CURSOR_CODEX_MODEL"] ?? "gpt-5.5"
    }

    private static func shellWhichCodex() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "codex"]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
