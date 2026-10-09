import Foundation

public struct PhoneStageRecord: Codable, Equatable, Sendable {
    public var stage: String
    public var detail: String
    public var updatedAt: Date
    public init(stage: String, detail: String, updatedAt: Date = Date()) {
        self.stage = stage; self.detail = detail; self.updatedAt = updatedAt
    }
}

public struct PhonePhoto: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let createdAt: Date
    public let receivedByMac: Bool
    public let context: LessonContext?
    public var sendToAI: Bool
    public var stage: String?
    public var stageDetail: String?

    public init(id: UUID, url: URL, createdAt: Date, receivedByMac: Bool, context: LessonContext?,
                stage: String? = nil, stageDetail: String? = nil, sendToAI: Bool = true) {
        self.id = id; self.url = url; self.createdAt = createdAt
        self.receivedByMac = receivedByMac; self.context = context
        self.stage = stage; self.stageDetail = stageDetail; self.sendToAI = sendToAI
    }
}

public final class PhoneLibrary {
    public let directory: URL
    public private(set) var photos: [PhonePhoto] = []
    private var received = Set<UUID>()
    private var deliveryChoices: [String: Bool] = [:]
    private var choicesURL: URL { directory.appendingPathComponent("delivery-choices.json") }
    private var contexts: [String: LessonContext] = [:]
    private var stages: [String: PhoneStageRecord] = [:]
    private var contextURL: URL { directory.appendingPathComponent("contexts.json") }
    private var receiptURL: URL { directory.appendingPathComponent("received.json") }
    private var stageURL: URL { directory.appendingPathComponent("stages.json") }
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            received = Set(try JSONDecoder().decode([UUID].self, from: Data(contentsOf: receiptURL)))
        }
        if FileManager.default.fileExists(atPath: contextURL.path) {
            contexts = try JSONDecoder().decode([String: LessonContext].self, from: Data(contentsOf: contextURL))
        }
        if FileManager.default.fileExists(atPath: stageURL.path) {
            stages = (try? JSONDecoder().decode([String: PhoneStageRecord].self, from: Data(contentsOf: stageURL))) ?? [:]
        }
        if FileManager.default.fileExists(atPath: choicesURL.path) { deliveryChoices = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: choicesURL)) }
        try reload()
    }
    public func reload() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        photos = try files.compactMap { url in
            guard url.pathExtension.lowercased() == "jpg",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            let date = try url.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            let stageRec = stages[id.uuidString]
            return PhonePhoto(id: id, url: url, createdAt: date, receivedByMac: received.contains(id),
                              context: contexts[id.uuidString], stage: stageRec?.stage, stageDetail: stageRec?.detail, sendToAI: deliveryChoices[id.uuidString] ?? true)
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
    @discardableResult
    public func save(_ jpeg: Data, context: LessonContext? = nil, sendToAI: Bool = true) throws -> UUID {
        guard !jpeg.isEmpty, jpeg.count <= 40 * 1024 * 1024 else { throw LibraryError.invalidSize }
        let id = UUID()
        var choices = deliveryChoices; choices[id.uuidString] = sendToAI
        try JSONEncoder().encode(choices).write(to: choicesURL, options: .atomic); deliveryChoices = choices
        if let context {
            var updated = contexts; updated[id.uuidString] = context
            try JSONEncoder().encode(updated).write(to: contextURL, options: .atomic)
            contexts = updated
        }
        try jpeg.write(to: directory.appendingPathComponent("\(id.uuidString).jpg"), options: .atomic)
        let url = directory.appendingPathComponent("\(id.uuidString).jpg")
        let date = try url.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date()
        photos.append(PhonePhoto(id: id, url: url, createdAt: date, receivedByMac: false, context: context, sendToAI: sendToAI))
        return id
    }
    public func acknowledge(_ id: UUID) throws {
        guard photos.contains(where: { $0.id == id }) else { throw LibraryError.unknownPhoto }
        var updated = received; updated.insert(id)
        try JSONEncoder().encode(updated.sorted { $0.uuidString < $1.uuidString }).write(to: receiptURL, options: .atomic)
        received = updated
        if stages[id.uuidString] == nil {
            stages[id.uuidString] = PhoneStageRecord(stage: "received", detail: "Mac 已归档")
            try? JSONEncoder().encode(stages).write(to: stageURL, options: .atomic)
        }
        updatePhoto(id)
    }
    public func updateStage(id: UUID, stage: String, detail: String) throws {
        guard photos.contains(where: { $0.id == id }) else { throw LibraryError.unknownPhoto }
        guard stages[id.uuidString]?.stage != stage || stages[id.uuidString]?.detail != detail else { return }
        var updated = stages
        updated[id.uuidString] = PhoneStageRecord(stage: stage, detail: detail)
        try JSONEncoder().encode(updated).write(to: stageURL, options: .atomic)
        stages = updated
        updatePhoto(id)
    }
    public func requeue(_ id: UUID) throws {
        guard photos.contains(where: { $0.id == id }) else { throw LibraryError.unknownPhoto }
        var updated = received; updated.remove(id)
        try JSONEncoder().encode(updated.sorted { $0.uuidString < $1.uuidString }).write(to: receiptURL, options: .atomic)
        received = updated; updatePhoto(id)
    }
    public func updateCourseName(from context: LessonContext) throws {
        var updated = contexts
        for (key, old) in contexts where old.lesson.courseID == context.lesson.courseID {
            let sectionName = old.lesson.sectionID == context.lesson.sectionID ? context.sectionName : old.sectionName
            if old.courseName != context.courseName || old.sectionName != sectionName {
                updated[key] = LessonContext(lesson: old.lesson, courseName: context.courseName, sectionName: sectionName)
            }
        }
        guard updated != contexts else { return }
        try JSONEncoder().encode(updated).write(to: contextURL, options: .atomic)
        contexts = updated
        for id in photos.map(\.id) { updatePhoto(id) }
    }
    private func updatePhoto(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let old = photos[index], record = stages[id.uuidString]
        photos[index] = PhonePhoto(id: id, url: old.url, createdAt: old.createdAt, receivedByMac: received.contains(id), context: contexts[id.uuidString], stage: record?.stage, stageDetail: record?.detail, sendToAI: deliveryChoices[id.uuidString] ?? true)
    }
    public enum LibraryError: Error { case invalidSize, unknownPhoto }
}
