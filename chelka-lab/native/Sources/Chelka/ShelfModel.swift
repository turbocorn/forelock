import AppKit
import ChelkaCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

@MainActor final class ShelfModel: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var loading = false
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    @Published var error: String?
    let repository: ShelfRepository

    init(root: URL) { repository = ShelfRepository(root: root) }
    func load() async {
        do { items = try await repository.load(); refreshThumbnails() }
        catch { self.error = "Не удалось открыть полку: \(error.localizedDescription)" }
    }
    func url(for item: ShelfItem) -> URL { repository.fileURL(for: item) }
    func importFiles(_ urls: [URL]) async {
        guard !loading else { return }
        loading = true
        error = nil
        var failures: [String] = []
        for source in urls {
            do { let item = try await repository.importFile(at: source); items.insert(item, at: 0); makeThumbnail(item) }
            catch { failures.append("\(source.lastPathComponent): \(error.localizedDescription)") }
        }
        loading = false
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }
    func remove(_ item: ShelfItem) {
        Task {
            do { try await repository.remove(item); items.removeAll { $0.id == item.id }; thumbnails[item.id] = nil }
            catch { self.error = "Не удалось убрать файл: \(error.localizedDescription)" }
        }
    }
    func typeName(_ item: ShelfItem) -> String {
        UTType(item.typeIdentifier)?.localizedDescription ?? URL(fileURLWithPath: item.name).pathExtension.uppercased()
    }
    func image(_ item: ShelfItem) -> NSImage { thumbnails[item.id] ?? NSWorkspace.shared.icon(forFile: url(for: item).path) }
    private func refreshThumbnails() { items.forEach(makeThumbnail) }
    private func makeThumbnail(_ item: ShelfItem) {
        let request = QLThumbnailGenerator.Request(fileAt: url(for: item), size: CGSize(width: 120, height: 100), scale: 2, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            Task { @MainActor in self?.thumbnails[item.id] = image }
        }
    }
}
