import Foundation
import EventKit
import UIKit
import NewtonCore

@MainActor final class CalendarTools {
    private let store = EKEventStore()
    private func authorize() async throws {
        guard try await store.requestFullAccessToEvents() else { throw HarnessError("Calendar access was denied. You can allow it in iOS Settings.") }
    }
    private func date(_ text: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: text) else { throw HarnessError("Use an ISO 8601 date including a timezone, such as 2026-09-15T09:00:00-04:00.") }
        return date
    }
    func list(start: String, end: String) async throws -> String {
        let from = try date(start), to = try date(end)
        guard to > from, to.timeIntervalSince(from) <= 60 * 60 * 24 * 31 else { throw HarnessError("Choose a calendar range of at most 31 days, with end after start.") }
        try await authorize()
        let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil)).sorted { $0.startDate < $1.startDate }
        return try JSONValue.object(["events": .array(events.prefix(100).map { event in
            .object(["id": .string(event.eventIdentifier ?? ""), "title": .string(event.title ?? "Untitled"),
                "start": .string(ISO8601DateFormatter().string(from: event.startDate)),
                "end": .string(ISO8601DateFormatter().string(from: event.endDate)),
                "calendar": .string(event.calendar.title)])
        }), "truncated": .bool(events.count > 100)]).encoded()
    }
    func save(id: String?, title: String, start: String, end: String, location: String?) async throws -> String {
        let from = try date(start), to = try date(end)
        guard to > from else { throw HarnessError("The event end must be after its start.") }
        try await authorize()
        let event: EKEvent
        if let id {
            guard let existing = store.event(withIdentifier: id) else { throw HarnessError("Event no longer exists. List the calendar again.") }
            guard !existing.hasRecurrenceRules else { throw HarnessError("Editing recurring events is not supported in this first version. Use Calendar.") }
            event = existing
        } else {
            guard let calendar = store.defaultCalendarForNewEvents else { throw HarnessError("No writable default calendar is available.") }
            event = EKEvent(eventStore: store); event.calendar = calendar
        }
        guard event.calendar.allowsContentModifications else { throw HarnessError("This calendar is read-only.") }
        event.title = title; event.startDate = from; event.endDate = to
        if let location { event.location = location }
        try store.save(event, span: .thisEvent, commit: true)
        return try JSONValue.object(["status": .string("saved"), "id": .string(event.eventIdentifier ?? "")]).encoded()
    }
    func delete(id: String) async throws -> String {
        try await authorize()
        guard let event = store.event(withIdentifier: id) else { throw HarnessError("Event no longer exists.") }
        guard !event.hasRecurrenceRules else { throw HarnessError("Deleting recurring events is not supported. Use Calendar.") }
        try store.remove(event, span: .thisEvent, commit: true)
        return "{\"status\":\"deleted\"}"
    }
}

extension AppModel {
    func makeTools() -> [AgentTool] {
        func tool(_ name: String, _ description: String, _ properties: [String: String], _ required: [String],
                  execute: @escaping ([String: JSONValue]) async throws -> String) -> AgentTool {
            AgentTool(ToolDefinition(name: name, description: description,
                parameters: ToolDefinition.schema(properties, required: required)), execute: execute)
        }
        func value(_ args: [String: JSONValue], _ key: String) -> String { args[key]?.string ?? "" }
        return [
            tool("messages_compose", "Present the system Messages composer. User must tap Send. Cannot read messages or choose iMessage vs SMS.",
                 ["recipient": "One explicit phone number or email address; never guess from a name", "body": "Exact message text"], ["recipient", "body"]) { [self] args in
                let recipient = value(args, "recipient")
                guard recipient.contains("@") || (recipient.filter(\.isNumber).count >= 7 && recipient.allSatisfy({ $0.isNumber || "+()- ".contains($0) })) else {
                    throw HarnessError("Provide the recipient's phone number or email, not a contact name.")
                }
                return try await composeMessage(recipient: recipient, body: value(args, "body"))
            },
            tool("calendar_list", "Read events in a range (up to 31 days and 100 events). Results are shared with the selected inference provider.",
                 ["start": "ISO 8601 range start with timezone", "end": "ISO 8601 range end with timezone"], ["start", "end"]) { [self] a in
                try await calendar.list(start: value(a, "start"), end: value(a, "end"))
            },
            tool("calendar_create", "Create an event in the default calendar. It remains in Calendar after Newton is deleted.",
                 ["title": "Title", "start": "ISO 8601 start with timezone", "end": "ISO 8601 end with timezone", "location": "Optional location"], ["title", "start", "end"]) { [self] a in
                try await calendar.save(id: nil, title: value(a, "title"), start: value(a, "start"), end: value(a, "end"), location: a["location"]?.string)
            },
            tool("calendar_update", "Update a non-recurring event by ID from calendar_list.",
                 ["id": "Exact event ID", "title": "New title", "start": "ISO 8601 start with timezone", "end": "ISO 8601 end with timezone", "location": "Optional new location"], ["id", "title", "start", "end"]) { [self] a in
                try await calendar.save(id: value(a, "id"), title: value(a, "title"), start: value(a, "start"), end: value(a, "end"), location: a["location"]?.string)
            },
            tool("calendar_delete", "Delete one non-recurring event using its exact ID from calendar_list.", ["id": "Exact event ID"], ["id"]) { [self] a in
                try await calendar.delete(id: value(a, "id"))
            },
            tool("notes_search", "Search Newton's local notes by title/body. Does not access Apple Notes. Returns up to 20 matches.",
                 ["query": "Search text; empty returns recent notes"], []) { [self] a in
                let query = value(a, "query")
                let matches = notes.filter { query.isEmpty || ($0.title + " " + $0.body).localizedCaseInsensitiveContains(query) }
                    .sorted { $0.updatedAt > $1.updatedAt }.prefix(20)
                return String(decoding: try JSONEncoder().encode(Array(matches)), as: UTF8.self)
            },
            tool("notes_create", "Create a note in Newton's private local store.", ["title": "Title", "body": "Note text"], ["title", "body"]) { [self] a in
                let note = StoredNote(title: value(a, "title"), body: value(a, "body"))
                try saveNotes([note] + notes)
                return try JSONValue.object(["status": .string("saved"), "id": .string(note.id.uuidString)]).encoded()
            },
            tool("notes_update", "Replace the title/body of a Newton note by ID.", ["id": "Note UUID", "title": "New title", "body": "New full text"], ["id", "title", "body"]) { [self] a in
                guard let id = UUID(uuidString: value(a, "id")), let index = notes.firstIndex(where: { $0.id == id }) else { throw HarnessError("Note not found.") }
                var next = notes; next[index].title = value(a, "title"); next[index].body = value(a, "body"); next[index].updatedAt = Date()
                try saveNotes(next); return "{\"status\":\"saved\"}"
            },
            tool("notes_delete", "Delete one Newton note by ID.", ["id": "Note UUID"], ["id"]) { [self] a in
                guard let id = UUID(uuidString: value(a, "id")), notes.contains(where: { $0.id == id }) else { throw HarnessError("Note not found.") }
                try saveNotes(notes.filter { $0.id != id }); return "{\"status\":\"deleted\"}"
            },
            tool("apple_notes_create", "Hand text to the configured user-installed Shortcut to create an Apple Note. Cannot read Apple Notes or confirm creation. Exported notes survive app deletion.",
                 ["title": "Title", "body": "Note text"], ["title", "body"]) { [self] a in
                guard !settings.notesShortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HarnessError("Set up the Apple Notes Shortcut in Settings first.") }
                var url = URLComponents(); url.scheme = "shortcuts"; url.host = "run-shortcut"
                url.queryItems = [URLQueryItem(name: "name", value: settings.notesShortcut), URLQueryItem(name: "input", value: "text"),
                    URLQueryItem(name: "text", value: value(a, "title") + "\n\n" + value(a, "body"))]
                guard let link = url.url, link.absoluteString.utf8.count < 8000 else { throw HarnessError("The note is too long for a Shortcut URL. Save it in Newton instead.") }
                guard await UIApplication.shared.open(link) else { throw HarnessError("Could not open Shortcuts.") }
                return "{\"status\":\"handed_off\",\"message\":\"Shortcuts opened. Note creation is unverified; ask the user to check Apple Notes.\"}"
            }
        ]
    }
}
