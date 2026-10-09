import Foundation

public struct Course: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var archived: Bool? = nil
}
public struct Lesson: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let courseID: UUID
    public var title: String
    public let startedAt: Date
    public let timeZoneID: String
    public var sectionID: UUID? = nil
}
public struct LessonContext: Codable, Sendable, Equatable {
    public let lesson: Lesson
    public let courseName: String
    public init(lesson: Lesson, courseName: String) { self.lesson = lesson; self.courseName = courseName }
}
public struct CourseCatalog: Codable, Sendable {
    public var courses: [Course] = []
    public var lessons: [Lesson] = []
    public var activeLessonID: UUID?
    public var legacyLessonID: UUID?
    public var sections: [CourseSection]? = nil
    public var manualSectionID: UUID? = nil
    public var inboxLessonID: UUID? = nil
    public init() {}
    public func context(for id: UUID?) -> LessonContext? {
        guard let id, let lesson = lessons.first(where: { $0.id == id }),
              let course = courses.first(where: { $0.id == lesson.courseID }) else { return nil }
        return LessonContext(lesson: lesson, courseName: course.name)
    }
}

/// A persistent teaching group. Dates remain Lesson archives, not chat bindings.
public struct CourseSection: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID = UUID()
    public var courseID: UUID
    public var name: String
    public var chatURL: String?
    public var schedule: WeeklySchedule?
    public init(courseID: UUID, name: String, chatURL: String? = nil, schedule: WeeklySchedule? = nil) {
        self.courseID = courseID; self.name = name; self.chatURL = chatURL; self.schedule = schedule
    }
}

public struct WeeklySchedule: Codable, Sendable, Equatable {
    public var weekday: Int // Calendar weekday: Sunday = 1
    public var startMinute: Int
    public var endMinute: Int
    public init(weekday: Int, startMinute: Int, endMinute: Int) {
        self.weekday = weekday; self.startMinute = startMinute; self.endMinute = endMinute
    }
    public var isValid: Bool { (1...7).contains(weekday) && (0..<1440).contains(startMinute) && (1...1440).contains(endMinute) && startMinute < endMinute }
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return isValid && c.weekday == weekday && minute >= startMinute && minute < endMinute
    }
}

extension CourseCatalog {
    public func targetSection(at date: Date = Date(), calendar: Calendar = .current) -> CourseSection? {
        let available = (sections ?? []).filter { section in courses.contains { $0.id == section.courseID && $0.archived != true } }
        // Overlapping schedules retain the user's target if it is one of the active sections.
        let scheduled = available.filter { $0.schedule?.contains(date, calendar: calendar) == true }
        return scheduled.first(where: { $0.id == manualSectionID }) ?? scheduled.first ?? available.first(where: { $0.id == manualSectionID })
    }
    public func section(for lessonID: UUID?) -> CourseSection? {
        guard let lesson = lessons.first(where: { $0.id == lessonID }) else { return nil }
        return sections?.first { $0.id == lesson.sectionID }
    }
}
