//
//  CalendarEventWriter.swift
//  Shake Cursor
//
//  Created by Codex on 2026/5/16.
//

import EventKit
import Foundation

struct CalendarCreationResult {
    let message: String
}

enum CalendarEventWriterError: LocalizedError {
    case accessDenied
    case restricted
    case noWritableCalendar
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "没有日历权限，无法写入本机日程。"
        case .restricted:
            return "系统限制了日历访问，无法写入本机日程。"
        case .noWritableCalendar:
            return "没有找到可写入的本机日历。"
        case .saveFailed:
            return "日程写入失败。"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .accessDenied:
            return "请在系统设置里允许 Shake Cursor 访问日历。"
        case .restricted:
            return "请检查系统设置中的隐私与安全性限制。"
        case .noWritableCalendar:
            return "请先在 macOS 日历中创建或启用一个可写日历。"
        case .saveFailed(let detail):
            return detail
        }
    }
}

@MainActor
final class CalendarEventWriter {
    static let shared = CalendarEventWriter()

    private let eventStore = EKEventStore()

    private init() {}

    func createEvent(from draft: CalendarEventDraft) async throws -> CalendarCreationResult {
        guard try await requestAccess() else {
            throw CalendarEventWriterError.accessDenied
        }

        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw CalendarEventWriterError.noWritableCalendar
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = draft.title
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.notes = draft.notes
        event.isAllDay = draft.isAllDay
        event.calendar = calendar

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return CalendarCreationResult(message: Self.successMessage(for: draft))
        } catch {
            throw CalendarEventWriterError.saveFailed(error.localizedDescription)
        }
    }

    func requestAccessForGuide() async throws -> Bool {
        try await requestAccess()
    }

    private func requestAccess() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        CodexBridgeLog.write("calendar authorization status=\(Self.statusDescription(status))")

        switch status {
        case .authorized, .fullAccess, .writeOnly:
            return true
        case .denied:
            throw CalendarEventWriterError.accessDenied
        case .restricted:
            throw CalendarEventWriterError.restricted
        case .notDetermined:
            break
        @unknown default:
            break
        }

        if #available(macOS 14.0, *) {
            let granted = try await eventStore.requestWriteOnlyAccessToEvents()
            CodexBridgeLog.write("calendar requestWriteOnly result=\(granted)")
            return granted
        }

        return try await withCheckedThrowingContinuation { continuation in
            eventStore.requestAccess(to: .event) { granted, error in
                CodexBridgeLog.write("calendar legacy requestAccess result=\(granted), error=\(String(describing: error))")
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private static func statusDescription(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .fullAccess:
            return "fullAccess"
        case .writeOnly:
            return "writeOnly"
        @unknown default:
            return "unknown"
        }
    }

    private static func successMessage(for draft: CalendarEventDraft) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = draft.isAllDay ? "M月d日" : "M月d日 HH:mm"

        if draft.isAllDay {
            return "已写入日历：\(draft.title)，\(formatter.string(from: draft.startDate))。"
        }

        return "已写入日历：\(draft.title)，\(formatter.string(from: draft.startDate))。"
    }
}
