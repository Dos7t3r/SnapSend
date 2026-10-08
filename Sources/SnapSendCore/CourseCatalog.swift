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
    public init() {}
    public func context(for id: UUID?) -> LessonContext? {
        guard let id, let lesson = lessons.first(where: { $0.id == id }),
              let course = courses.first(where: { $0.id == lesson.courseID }) else { return nil }
        return LessonContext(lesson: lesson, courseName: course.name)
    }
}
