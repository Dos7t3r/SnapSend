import XCTest
@testable import SnapSendCore

final class SectionRoutingTests: XCTestCase {
    func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func testReceiveWithoutCourseUsesDurableInbox() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PhotoStore(directory: dir)
        let inbox = try store.routeLesson()
        let photo = try store.save(Data([1,2,3]), sessionID: inbox)
        XCTAssertNil(store.catalog.activeLessonID)
        XCTAssertNil(store.catalog.targetSection())
        XCTAssertEqual(try PhotoStore(directory: dir).records.first?.id, photo.id)
        XCTAssertEqual(try store.routeLesson(), inbox)
        XCTAssertEqual(store.catalog.lessons.count, 1)
    }
    func testSectionBindingSurvivesDailyArchivesAndRestart() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PhotoStore(directory: dir)
        let first = try store.createCourse(name: "STA256")
        var section = try XCTUnwrap(store.catalog.section(for: first.id))
        section.chatURL = "https://chatgpt.com/g/g-p-sta256/c/chat-id"
        try store.updateSection(section)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let next = try store.routeLesson(now: nextDay)
        XCTAssertNotEqual(next, first.id)
        XCTAssertEqual(store.catalog.section(for: next)?.chatURL, section.chatURL)
        let restored = try PhotoStore(directory: dir)
        XCTAssertEqual(restored.catalog.targetSection()?.id, section.id)
        XCTAssertEqual(restored.catalog.section(for: first.id)?.chatURL, section.chatURL)
    }
    func testSchedulePriorityAndBoundaryAndArchivedExclusion() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PhotoStore(directory: dir)
        let a = try store.createCourse(name: "A"), b = try store.createCourse(name: "B")
        let manual = try XCTUnwrap(store.catalog.section(for: a.id))
        var scheduled = try XCTUnwrap(store.catalog.section(for: b.id))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 13))!
        scheduled.schedule = WeeklySchedule(weekday: 4, startMinute: 780, endMinute: 840)
        try store.updateSection(scheduled); try store.selectSection(manual.id)
        XCTAssertEqual(store.catalog.targetSection(at: date, calendar: cal)?.id, scheduled.id)
        XCTAssertEqual(store.catalog.targetSection(at: date.addingTimeInterval(-1), calendar: cal)?.id, manual.id)
        XCTAssertEqual(store.catalog.targetSection(at: date.addingTimeInterval(3600), calendar: cal)?.id, manual.id)
        try store.archiveCourse(b.courseID, archived: true)
        XCTAssertEqual(store.catalog.targetSection(at: date, calendar: cal)?.id, manual.id)
    }
    func testLegacyCatalogMigrationIsIdempotentAndKeepsFiles() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PhotoStore(directory: dir), lesson = try store.createCourse(name: "Old")
        let photo = try store.save(Data([8,9]), sessionID: lesson.id)
        var old = store.catalog; old.sections = nil; old.manualSectionID = nil
        try JSONEncoder().encode(old).write(to: dir.appendingPathComponent("courses.json"), options: .atomic)
        let migrated = try PhotoStore(directory: dir)
        XCTAssertEqual(migrated.catalog.sections?.count, 1)
        XCTAssertEqual(migrated.records.first?.filename, photo.filename)
        XCTAssertEqual(try Data(contentsOf: migrated.url(for: photo)), Data([8,9]))
        XCTAssertEqual(try PhotoStore(directory: dir).catalog.sections, migrated.catalog.sections)
    }
    func testInvalidBindingOrScheduleCannotOverwriteSection() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PhotoStore(directory: dir), lesson = try store.createCourse(name: "A")
        var section = try XCTUnwrap(store.catalog.section(for: lesson.id))
        section.chatURL = "https://example.com/c/id"
        XCTAssertThrowsError(try store.updateSection(section))
        section.chatURL = nil; section.schedule = WeeklySchedule(weekday: 2, startMinute: 600, endMinute: 500)
        XCTAssertThrowsError(try store.updateSection(section))
        XCTAssertNil(store.catalog.section(for: lesson.id)?.schedule)
    }
    func testSectionContextIsBackwardCompatibleAndShowsTargetName() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PhotoStore(directory: dir), lesson = try store.createCourse(name: "STA256")
        var section = try XCTUnwrap(store.catalog.section(for: lesson.id)); section.name = "LEC0101"
        try store.updateSection(section)
        let context = try XCTUnwrap(store.catalog.context(for: lesson.id))
        XCTAssertEqual(context.displayName, "STA256 · LEC0101")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any])
        legacy.removeValue(forKey: "sectionName")
        let decoded = try JSONDecoder().decode(LessonContext.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.sectionName); XCTAssertEqual(decoded.courseName, "STA256")
    }
    func testPhoneContextRenameKeepsOtherSectionNames() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let library = try PhoneLibrary(directory: dir), course = UUID()
        let a = Lesson(id: UUID(), courseID: course, title: "", startedAt: Date(), timeZoneID: "UTC", sectionID: UUID())
        let b = Lesson(id: UUID(), courseID: course, title: "", startedAt: Date(), timeZoneID: "UTC", sectionID: UUID())
        let idA = try library.save(Data([1]), context: LessonContext(lesson: a, courseName: "Old", sectionName: "LEC"))
        let idB = try library.save(Data([2]), context: LessonContext(lesson: b, courseName: "Old", sectionName: "TUT"))
        try library.updateCourseName(from: LessonContext(lesson: a, courseName: "New", sectionName: "LEC0101"))
        XCTAssertEqual(library.photos.first { $0.id == idA }?.context?.displayName, "New · LEC0101")
        XCTAssertEqual(library.photos.first { $0.id == idB }?.context?.displayName, "New · TUT")
    }

}
