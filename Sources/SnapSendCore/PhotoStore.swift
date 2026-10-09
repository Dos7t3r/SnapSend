import Foundation
import CryptoKit

public struct PhotoRecord: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let receivedAt: Date
    public let filename: String
    public let sha256: String
    public let byteCount: Int
    public var status: String
    public var sessionID: UUID?
    public var capturedAt: Date?
}

public final class PhotoStore {
    public let directory: URL
    public private(set) var records: [PhotoRecord]
    public private(set) var catalog: CourseCatalog
    private var manifest: URL { directory.appendingPathComponent("photos.json") }
    private var catalogURL: URL { directory.appendingPathComponent("courses.json") }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("photos.json")
        records = FileManager.default.fileExists(atPath: manifest.path)
            ? try JSONDecoder().decode([PhotoRecord].self, from: Data(contentsOf: manifest)) : []
        let catalogFile = directory.appendingPathComponent("courses.json")
        catalog = FileManager.default.fileExists(atPath: catalogFile.path)
            ? try JSONDecoder().decode(CourseCatalog.self, from: Data(contentsOf: catalogFile)) : CourseCatalog()
        // Optional fields keep old catalogs decodable. Migration never moves originals.
        if catalog.sections == nil {
            var updated = catalog; updated.sections = []
            for course in updated.courses {
                let section = CourseSection(courseID: course.id, name: "默认 Section")
                updated.sections?.append(section)
                for index in updated.lessons.indices where updated.lessons[index].courseID == course.id { updated.lessons[index].sectionID = section.id }
            }
            updated.manualSectionID = updated.section(for: updated.activeLessonID)?.id
            try commit(updated)
        }
        // Existing flat archives stay where they are; migration only annotates their class.
        if records.contains(where: { $0.sessionID == nil }) {
            let legacy = try ensureLegacyLesson()
            let updated = records.map { record in
                var record = record
                if record.sessionID == nil { record.sessionID = legacy }
                return record
            }
            try JSONEncoder().encode(updated).write(to: self.manifest, options: .atomic)
            records = updated
        }
    }
    public func url(for record: PhotoRecord) -> URL { directory.appendingPathComponent(record.filename) }
    public func context(for id: UUID?) -> LessonContext? { catalog.context(for: id) }
    private func commit(_ updated: CourseCatalog) throws {
        try JSONEncoder().encode(updated).write(to: catalogURL, options: .atomic)
        catalog = updated
    }
    @discardableResult
    public func createCourse(name: String, now: Date = Date()) throws -> Lesson {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw StoreError.invalidName }
        var updated = catalog
        let course = Course(id: UUID(), name: name, createdAt: now)
        let section = CourseSection(courseID: course.id, name: "LEC0101")
        let lesson = Lesson(id: UUID(), courseID: course.id, title: "", startedAt: now, timeZoneID: TimeZone.current.identifier, sectionID: section.id)
        updated.sections = (updated.sections ?? []) + [section]; updated.manualSectionID = section.id
        updated.courses.append(course); updated.lessons.append(lesson); updated.activeLessonID = lesson.id
        try commit(updated)
        return lesson
    }
    @discardableResult
    public func startLesson(courseID: UUID, title: String = "", now: Date = Date()) throws -> Lesson {
        guard catalog.courses.contains(where: { $0.id == courseID && $0.archived != true }), title.count <= 80 else { throw StoreError.unknownLesson }
        var updated = catalog
        let lesson = Lesson(id: UUID(), courseID: courseID, title: title, startedAt: now, timeZoneID: TimeZone.current.identifier)
        updated.lessons.append(lesson); updated.activeLessonID = lesson.id
        try commit(updated)
        return lesson
    }
    public func updateSection(_ section: CourseSection) throws {
        guard !section.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, section.name.count <= 80,
              section.schedule == nil || section.schedule!.isValid,
              section.chatURL == nil || ChatURL.isConversation(section.chatURL!),
              catalog.courses.contains(where: { $0.id == section.courseID && $0.archived != true }) else { throw StoreError.invalidName }
        var updated = catalog
        var sections = updated.sections ?? []
        if let index = sections.firstIndex(where: { $0.id == section.id }) { sections[index] = section } else { sections.append(section) }
        updated.sections = sections; try commit(updated)
    }
    public func selectSection(_ id: UUID?) throws {
        if let id {
            guard let section = catalog.sections?.first(where: { $0.id == id }), catalog.courses.contains(where: { $0.id == section.courseID && $0.archived != true }) else { throw StoreError.unknownLesson }
        }
        var updated = catalog; updated.manualSectionID = id; try commit(updated)
    }
    /// Route at Mac receipt time; reuse a date archive without changing the Section binding.
    public func routeLesson(now: Date = Date(), calendar: Calendar = .current, activate: Bool = true) throws -> UUID {
        if let section = catalog.targetSection(at: now, calendar: calendar) {
            if let lesson = catalog.lessons.last(where: { $0.sectionID == section.id && calendar.isDate($0.startedAt, inSameDayAs: now) }) {
                if activate, catalog.activeLessonID != lesson.id { try activateLesson(lesson.id) }
                return lesson.id
            }
            var updated = catalog
            let lesson = Lesson(id: UUID(), courseID: section.courseID, title: "", startedAt: now, timeZoneID: calendar.timeZone.identifier, sectionID: section.id)
            updated.lessons.append(lesson); if activate { updated.activeLessonID = lesson.id }; try commit(updated); return lesson.id
        }
        if let inbox = catalog.inboxLessonID { if activate, catalog.activeLessonID != nil { try activateLesson(nil) }; return inbox }
        var updated = catalog
        let course = Course(id: UUID(), name: "收件箱", createdAt: now)
        let lesson = Lesson(id: UUID(), courseID: course.id, title: "未分配照片", startedAt: now, timeZoneID: calendar.timeZone.identifier)
        updated.courses.append(course); updated.lessons.append(lesson); updated.inboxLessonID = lesson.id; if activate { updated.activeLessonID = nil }
        try commit(updated); return lesson.id
    }
    public func renameCourse(_ id: UUID, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, let index = catalog.courses.firstIndex(where: { $0.id == id }) else { throw StoreError.invalidName }
        var updated = catalog; updated.courses[index].name = name; try commit(updated)
    }
    public func archiveCourse(_ id: UUID, archived: Bool) throws {
        guard let index = catalog.courses.firstIndex(where: { $0.id == id }) else { throw StoreError.unknownLesson }
        var updated = catalog
        updated.courses[index].archived = archived
        if archived, let active = updated.context(for: updated.activeLessonID), active.lesson.courseID == id { updated.activeLessonID = nil }
        try commit(updated)
    }
    public func renameLesson(_ id: UUID, title: String) throws {
        guard title.count <= 80, let index = catalog.lessons.firstIndex(where: { $0.id == id }) else { throw StoreError.invalidName }
        var updated = catalog; updated.lessons[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try commit(updated)
    }
    public func movePhotos(ids: Set<UUID>, to lessonID: UUID) throws {
        guard let context = catalog.context(for: lessonID), catalog.courses.first(where: { $0.id == context.lesson.courseID })?.archived != true else { throw StoreError.unknownLesson }
        guard ids.isSubset(of: Set(records.map(\.id))) else { throw StoreError.unknownLesson }
        var updated = records, created: [URL] = [], oldURLs: [URL] = []
        do {
            for index in updated.indices where ids.contains(updated[index].id) && updated[index].sessionID != lessonID {
                let old = updated[index]
                let relative = "Courses/\(context.lesson.courseID.uuidString)/\(lessonID.uuidString)/\(old.id.uuidString).\(URL(fileURLWithPath: old.filename).pathExtension)"
                let target = directory.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url(for: old), to: target)
                created.append(target); oldURLs.append(url(for: old))
                updated[index] = PhotoRecord(id: old.id, receivedAt: old.receivedAt, filename: relative, sha256: old.sha256, byteCount: old.byteCount, status: old.status, sessionID: lessonID, capturedAt: old.capturedAt)
            }
            try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
            records = updated
        } catch {
            for file in created { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        // Catalog is durable. Failure cleaning an old copy cannot lose the new original.
        for file in oldURLs { try? FileManager.default.removeItem(at: file) }
    }
    public func activateLesson(_ id: UUID?) throws {
        if let id {
            guard let context = catalog.context(for: id), catalog.courses.first(where: { $0.id == context.lesson.courseID })?.archived != true else { throw StoreError.unknownLesson }
        }
        var updated = catalog; updated.activeLessonID = id; try commit(updated)
    }
    @discardableResult
    private func ensureLegacyLesson() throws -> UUID {
        if let id = catalog.legacyLessonID { return id }
        var updated = catalog
        let date = records.map(\.receivedAt).min() ?? Date()
        let course = Course(id: UUID(), name: "历史照片", createdAt: date)
        let lesson = Lesson(id: UUID(), courseID: course.id, title: "旧版未分课程照片", startedAt: date, timeZoneID: TimeZone.current.identifier)
        updated.courses.append(course); updated.lessons.append(lesson); updated.legacyLessonID = lesson.id
        try commit(updated)
        return lesson.id
    }

    @discardableResult
    public func save(_ data: Data, id: UUID = UUID(), expectedHash: String? = nil,
                     sessionID: UUID? = nil, capturedAt: Date? = nil, fileExtension: String = "jpg") throws -> PhotoRecord {
        guard ["jpg", "png"].contains(fileExtension), !data.isEmpty, data.count <= 40 * 1024 * 1024 else { throw StoreError.invalidSize }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let expectedHash, expectedHash != hash { throw StoreError.hashMismatch }
        if let old = records.first(where: { $0.id == id }) {
            guard old.sha256 == hash else { throw StoreError.idConflict }
            try data.write(to: url(for: old), options: .atomic)
            return old
        }
        let destination: UUID
        if let sessionID {
            guard catalog.context(for: sessionID) != nil else { throw StoreError.unknownLesson }
            destination = sessionID
        } else { destination = try ensureLegacyLesson() }
        guard let context = catalog.context(for: destination) else { throw StoreError.unknownLesson }
        let relative = "Courses/\(context.lesson.courseID.uuidString)/\(destination.uuidString)/\(id.uuidString).\(fileExtension)"
        let record = PhotoRecord(id: id, receivedAt: Date(), filename: relative, sha256: hash,
                                 byteCount: data.count, status: "Mac 已保存 · 尚未发送给 AI",
                                 sessionID: destination, capturedAt: capturedAt)
        try FileManager.default.createDirectory(at: url(for: record).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url(for: record), options: .atomic)
        let updated = records + [record]
        try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
        records = updated
        return record
    }

    public func delete(ids: Set<UUID>) throws {
        let removed = records.filter { ids.contains($0.id) }
        let updated = records.filter { !ids.contains($0.id) }
        // Persist the catalog before removing originals. A failed write must preserve photos.
        try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
        records = updated
        for record in removed {
            try FileManager.default.removeItem(at: url(for: record))
        }
    }

    public func calculateStorageBytes() -> Int64 {
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        while let fileURL = enumerator?.nextObject() as? URL {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    public func cleanTemporaryCache() throws -> Int64 {
        var freedBytes: Int64 = 0
        let tempDir = FileManager.default.temporaryDirectory
        // Remove old SnapSend temporary images in temporaryDirectory
        if let items = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for item in items where item.lastPathComponent.hasPrefix("SnapSend") {
                if let size = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    freedBytes += Int64(size)
                }
                try? FileManager.default.removeItem(at: item)
            }
        }
        return freedBytes
    }

    public enum StoreError: Error { case invalidSize, hashMismatch, idConflict, invalidName, unknownLesson }
}
