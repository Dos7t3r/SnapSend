import Foundation
@main struct Benchmark {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var ids: [UUID] = []
        for _ in 0..<500 { let id = UUID(); ids.append(id); try Data([1,2,3]).write(to: folder.appendingPathComponent("\(id.uuidString).jpg")) }
        let library = try PhoneLibrary(directory: folder)
        let start = Date()
        for id in ids.prefix(100) { try library.updateStage(id: id, stage: "sent", detail: "benchmark") }
        print("500-photo library, 100 status updates: \(Date().timeIntervalSince(start)) seconds")
        print("records: \(library.photos.count)")
    }
}
