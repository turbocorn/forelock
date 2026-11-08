import Foundation

public struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let byteCount: Int64
    public let typeIdentifier: String
    public let importedAt: Date

    public init(id: UUID = UUID(), name: String, byteCount: Int64, typeIdentifier: String, importedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.byteCount = byteCount
        self.typeIdentifier = typeIdentifier
        self.importedAt = importedAt
    }
}

/// Owns copies, never the source URLs. All filesystem mutations are serialized.
public actor ShelfRepository {
    public nonisolated let root: URL
    private let manager = FileManager.default
    private struct Manifest: Codable { var version = 1; var items: [ShelfItem] }
    private var manifestURL: URL { root.appendingPathComponent("shelf.json") }

    public init(root: URL) { self.root = root }

    public nonisolated func fileURL(for item: ShelfItem) -> URL {
        root.appendingPathComponent("Files", isDirectory: true)
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
            .appendingPathComponent(item.name)
    }

    public func load() throws -> [ShelfItem] {
        try manager.createDirectory(at: root.appendingPathComponent("Files"), withIntermediateDirectories: true)
        guard manager.fileExists(atPath: manifestURL.path) else { return [] }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1 else { throw ShelfError.unsupportedManifest }
        // A missing copy is omitted; malformed paths are never followed.
        return manifest.items.filter { isSafeName($0.name) && manager.fileExists(atPath: fileURL(for: $0).path) }
    }

    public func importFile(at source: URL) throws -> ShelfItem {
        guard source.isFileURL else { throw ShelfError.notLocal }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let resolved = source.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        guard values.isRegularFile == true || values.isDirectory == true else { throw ShelfError.unsupportedFile }
        let name = source.lastPathComponent
        guard isSafeName(name) else { throw ShelfError.invalidName }
        // Fail before copying if the existing manifest is damaged; never overwrite it silently.
        var items = try load()
        let item = ShelfItem(name: name, byteCount: Int64(values.fileSize ?? 0), typeIdentifier: (try? resolved.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier) ?? "public.data")
        let destination = fileURL(for: item)
        let container = destination.deletingLastPathComponent()
        try manager.createDirectory(at: container, withIntermediateDirectories: true)
        do {
            try manager.copyItem(at: resolved, to: destination)
            items.insert(item, at: 0)
            try save(items)
        } catch {
            try? manager.removeItem(at: container)
            throw error
        }
        return item
    }

    public func remove(_ item: ShelfItem) throws {
        guard isSafeName(item.name) else { throw ShelfError.invalidName }
        var items = try load()
        items.removeAll { $0.id == item.id }
        // Commit the index first. Failure can leave an unreferenced copy, never a lost indexed file.
        try save(items)
        let container = fileURL(for: item).deletingLastPathComponent()
        if manager.fileExists(atPath: container.path) { try manager.removeItem(at: container) }
    }

    private func save(_ items: [ShelfItem]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Manifest(items: items)).write(to: manifestURL, options: .atomic)
    }

    private func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

public enum ShelfError: LocalizedError {
    case notLocal, invalidName, unsupportedFile, unsupportedManifest
    public var errorDescription: String? {
        switch self {
        case .notLocal: return "На полку можно добавить только локальные файлы."
        case .invalidName: return "Не удалось прочитать имя файла."
        case .unsupportedFile: return "Этот объект не является файлом или папкой."
        case .unsupportedManifest: return "Формат полки создан другой версией приложения. Копии файлов сохранены."
        }
    }
}
