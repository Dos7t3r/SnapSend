import Foundation

public enum DeliveryState: String, Codable, Sendable {
    case queued, preparing, submitting, sent, uncertain, failed
}
public struct DeliveryEntry: Codable, Identifiable, Sendable {
    public var id: UUID
    public var lessonID: UUID
    public var destination: String
    public var state: DeliveryState
    public var detail: String
}
public final class DeliveryLedger {
    public private(set) var entries: [DeliveryEntry]
    private let url: URL
    public init(directory: URL) throws {
        url = directory.appendingPathComponent("deliveries.json")
        entries = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([DeliveryEntry].self, from: Data(contentsOf: url)) : []
        // An interrupted attempt may already have reached the AI. Never replay it automatically.
        var recovered = entries
        for i in recovered.indices where [.preparing, .submitting].contains(recovered[i].state) {
            recovered[i].state = .uncertain
            recovered[i].detail = "上次发送被中断，请先在 AI 中核对，避免重复发送。"
        }
        if !recovered.elementsEqual(entries, by: { $0.state == $1.state }) { try commit(recovered) }
    }
    private func commit(_ value: [DeliveryEntry]) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic); entries = value
    }
    public func enqueue(id: UUID, lessonID: UUID, destination: String) throws {
        guard !entries.contains(where: { $0.id == id }) else { return }
        try commit(entries + [DeliveryEntry(id: id, lessonID: lessonID, destination: destination, state: .queued, detail: "等待发送")])
    }
    public func forceEnqueue(id: UUID, lessonID: UUID, destination: String) throws {
        var copy = entries
        if let idx = copy.firstIndex(where: { $0.id == id }) {
            guard ![.preparing, .submitting].contains(copy[idx].state) else { throw LedgerError.invalidTransition }
            guard copy[idx].lessonID == lessonID else { throw LedgerError.invalidTransition }
            copy[idx].state = .queued
            copy[idx].destination = destination
            copy[idx].detail = "手动加入投递队列"
        } else {
            copy.append(DeliveryEntry(id: id, lessonID: lessonID, destination: destination, state: .queued, detail: "手动加入投递队列"))
        }
        try commit(copy)
    }
    public func remove(ids: Set<UUID>) throws {
        guard !entries.contains(where: { ids.contains($0.id) && [.preparing, .submitting].contains($0.state) }) else { throw LedgerError.invalidTransition }
        let copy = entries.filter { !ids.contains($0.id) }
        try commit(copy)
    }
    public func resetQueue() throws {
        guard !entries.contains(where: { [.preparing, .submitting].contains($0.state) }) else { throw LedgerError.invalidTransition }
        let copy = entries.filter { $0.state == .sent }
        try commit(copy)
    }
    public func reassign(ids: Set<UUID>, lessonID: UUID) throws {
        guard !entries.contains(where: { ids.contains($0.id) && [.preparing, .submitting].contains($0.state) }) else { throw LedgerError.invalidTransition }
        var updated = entries
        for index in updated.indices where ids.contains(updated[index].id) { updated[index].lessonID = lessonID }
        try commit(updated)
    }
    public func transition(id: UUID, state: DeliveryState, detail: String) throws {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { throw LedgerError.unknown }
        let old = entries[i].state
        let allowed: [DeliveryState: [DeliveryState]] = [
            .queued: [.preparing], .preparing: [.submitting, .failed, .uncertain],
            .submitting: [.sent, .uncertain], .failed: [.queued], .uncertain: [.queued, .sent], .sent: []
        ]
        guard allowed[old, default: []].contains(state) else { throw LedgerError.invalidTransition }
        var copy = entries; copy[i].state = state; copy[i].detail = String(detail.prefix(500)); try commit(copy)
    }
    public enum LedgerError: Error { case unknown, invalidTransition }
}
