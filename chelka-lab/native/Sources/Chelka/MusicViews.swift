import AppKit
import SwiftUI
import ForelockMusic
import CryptoKit

private final class ArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(BridgeRules.artworkAllowed) == true ? request : nil)
    }
}

struct MusicArtwork: View {
    let snapshot: MusicSnapshot
    let size: CGFloat
    @State private var image: NSImage?
    private var key: String { snapshot.title + snapshot.artist + (snapshot.artworkURL?.absoluteString ?? "") + (snapshot.artworkData.map { SHA256.hash(data: $0).description } ?? "") }
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "music.note").font(.system(size: size * 0.35)).foregroundStyle(Color.chelkaMuted).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white.opacity(0.06)) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
            .task(id: key) {
                image = nil
                if let data = snapshot.artworkData { image = NSImage(data: data); return }
                guard let url = snapshot.artworkURL, BridgeRules.artworkAllowed(url) else { return }
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
                config.timeoutIntervalForRequest = 5
                let session = URLSession(configuration: config, delegate: ArtworkRedirectPolicy(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                do {
                    let (bytes, response) = try await session.bytes(from: url)
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                          response.mimeType?.hasPrefix("image/") == true, response.expectedContentLength <= 2_000_000 else { return }
                    var data = Data()
                    for try await byte in bytes { if data.count >= 2_000_000 || Task.isCancelled { return }; data.append(byte) }
                    if !Task.isCancelled { image = NSImage(data: data) }
                } catch { /* A missing cover never prevents music controls. */ }
            }
    }
}

struct MusicTransport: View {
    @ObservedObject var music: MusicCoordinator
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 0 : 14) {
            control(.previous, symbol: "backward.end.fill", label: "Предыдущий трек")
            control(music.selected?.state == .playing ? .pause : .play,
                    symbol: music.selected?.state == .playing ? "pause.fill" : "play.fill",
                    label: music.selected?.state == .playing ? "Пауза" : "Продолжить", prominent: true)
            control(.next, symbol: "forward.end.fill", label: "Следующий трек")
        }
    }
    private func control(_ command: MusicCommand, symbol: String, label: String, prominent: Bool = false) -> some View {
        let enabled = music.selected?.commands.contains(command) == true && !music.busy
        return Button { music.send(command) } label: {
            Image(systemName: symbol).font(.system(size: prominent ? 15 : 11, weight: .medium))
                .frame(width: compact ? 28 : 34, height: compact ? 28 : 32)
                .foregroundStyle(Color.white.opacity(enabled ? 0.95 : 0.22)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(label)
            .accessibilityIdentifier("Music-" + command.rawValue)
            .help(music.selected?.service == .yandexDesktop ? music.yandexControlNotice : (enabled ? label : "Команда недоступна у этого плеера"))
    }
}

struct MusicSourcePicker: View {
    @ObservedObject var music: MusicCoordinator
    var body: some View {
        HStack(spacing: 2) {
            Text(music.selected?.service.name ?? "Источник")
                .lineLimit(1).font(.system(size: 10)).foregroundStyle(Color.chelkaMuted)
            if music.selected?.service == .yandexDesktop {
                Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(Color.chelkaMuted)
                    .help(music.yandexControlNotice).accessibilityLabel("Экспериментальный системный плеер. " + music.yandexControlNotice)
            }
            Menu {
            Button(music.registry.manualID == nil ? "✓ Автоматически" : "Автоматически") { music.select(nil) }
            ForEach(music.sources) { source in
                Button((source.id == music.selected?.id ? "✓ " : "") + source.service.name + " — " + source.title) { music.select(source.id) }
            }
            if music.appleState == .permissionRequired {
                Divider()
                Button("Разрешить Apple Music") { music.authorizeAppleMusic() }.disabled(music.busy)
            }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8)).frame(width: 24, height: 24)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color.chelkaMuted).allowsHitTesting(false).accessibilityHidden(true)
                }
            .accessibilityLabel("Выбрать музыкальный источник")
        }
    }
}

struct MusicHoverView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfModel
    @ObservedObject var music: MusicCoordinator
    var body: some View {
        Group {
            if let snapshot = music.selected {
                VStack(spacing: 5) {
                    HStack(spacing: 9) {
                        MusicArtwork(snapshot: snapshot, size: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snapshot.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(snapshot.artist).font(.system(size: 11)).foregroundStyle(Color.chelkaMuted).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        MusicTransport(music: music, compact: true)
                    }
                    HStack { MusicSourcePicker(music: music); Spacer(minLength: 8)
                        Button { model.open(.shelf) } label: { Text("Полка · \(shelf.items.count)").font(.system(size: 11)).frame(minHeight: 28) }.buttonStyle(.plain)
                    }
                }.frame(height: 72)
            } else { HoverView(model: model, shelf: shelf) }
        }
    }
}

struct MusicModule: View {
    @ObservedObject var music: MusicCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let snapshot = music.selected {
                HStack(alignment: .center, spacing: 12) {
                    MusicArtwork(snapshot: snapshot, size: 50)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.title).font(.system(size: 17, weight: .medium)).lineLimit(1)
                        Text(snapshot.artist).font(.system(size: 12)).foregroundStyle(Color.chelkaMuted).lineLimit(1)
                        if !snapshot.album.isEmpty { Text(snapshot.album).font(.system(size: 10)).foregroundStyle(Color.chelkaMuted).lineLimit(1) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(minLength: 0); MusicTransport(music: music); Spacer(minLength: 0) }
                if let error = music.commandError {
                    Text(error).font(.system(size: 10)).foregroundStyle(Color.chelkaMuted).lineLimit(2)
                } else if let duration = snapshot.duration, duration > 0, snapshot.position != nil {
                    MusicProgress(music: music, snapshot: snapshot, duration: duration).id(snapshot.id + snapshot.title)
                }
                HStack { MusicSourcePicker(music: music); Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(snapshot.state == .playing ? "Играет" : "Пауза").font(.system(size: 10))
                        if snapshot.service == .yandexDesktop {
                            Text(music.yandexConflicts ? "Управление заблокировано" : "Возможна смена плеера").font(.system(size: 9)).help(music.yandexControlNotice)
                        }
                    }.foregroundStyle(Color.chelkaMuted)
                }
            } else {
                Text("Музыка").font(.system(size: 23, weight: .medium)).tracking(-0.5)
                if music.appleState == .permissionRequired {
                    Text("Разрешите Forelock управлять открытым Music.app.").font(.system(size: 12)).foregroundStyle(Color.chelkaMuted)
                    SurfaceButton("Разрешить Apple Music") { music.authorizeAppleMusic() }.disabled(music.busy)
                } else if music.appleState == .permissionDenied {
                    Text("Доступ к Music.app отклонён. Разрешение можно изменить в настройках macOS → Конфиденциальность → Автоматизация.").font(.system(size: 12)).foregroundStyle(Color.chelkaMuted)
                } else if music.yandexEnabled, music.updates["yandex-desktop"]?.state == .failed {
                    Text(music.updates["yandex-desktop"]?.detail ?? "MediaRemote недоступен").font(.system(size: 12)).foregroundStyle(Color.chelkaMuted).lineLimit(3)
                    Text("Эксперимент можно выключить и включить в настройках.").font(.system(size: 11)).foregroundStyle(Color.chelkaMuted)
                } else {
                    Text("Включите трек в Яндекс Музыке, Music.app или музыкальной вкладке Chrome.").font(.system(size: 12)).foregroundStyle(Color.chelkaMuted).lineSpacing(3)
                    Text("Для Chrome нужен Forelock Music Bridge.").font(.system(size: 11)).foregroundStyle(Color.chelkaMuted)
                }
                Spacer(minLength: 0)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MusicProgress: View {
    @ObservedObject var music: MusicCoordinator
    let snapshot: MusicSnapshot
    let duration: Double
    @State private var scrub: Double?
    @State private var editing = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = scrub ?? snapshot.position(at: context.date) ?? 0
            VStack(spacing: 1) {
                if snapshot.commands.contains(.seek) {
                    Slider(value: Binding(get: { position }, set: { value in
                        if editing { scrub = value } else { music.send(.seek, position: value) }
                    }), in: 0...duration, onEditingChanged: { editing in
                        self.editing = editing
                        if !editing, let scrub { music.send(.seek, position: scrub); self.scrub = nil }
                    }).controlSize(.mini).tint(.white).disabled(music.busy).accessibilityLabel("Позиция воспроизведения")
                } else { ProgressView(value: position, total: duration).tint(.white).accessibilityLabel("Прогресс воспроизведения") }
                HStack { Text(time(position)); Spacer(); Text(time(duration)) }.font(.system(size: 9).monospacedDigit()).foregroundStyle(Color.chelkaMuted)
            }
        }
    }
    private func time(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        if seconds >= 3600 { return "\(seconds / 3600):\(String(format: "%02d:%02d", seconds / 60 % 60, seconds % 60))" }
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

struct MusicShelfOverview: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfModel
    @ObservedObject var music: MusicCoordinator
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            MusicModule(music: music).frame(width: 320)
            SurfaceDivider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Полка").font(.system(size: 14, weight: .medium))
                    Text("\(shelf.items.count)").font(.system(size: 11)).foregroundStyle(Color.chelkaMuted)
                    Spacer()
                    Button("Открыть полку") { model.open(.shelf) }.font(.system(size: 11)).buttonStyle(.plain)
                }.frame(height: 25)
                if shelf.items.isEmpty {
                    Text("Перетащите файл из Finder к чёлке.\nСохранится отдельная копия.").font(.system(size: 12)).foregroundStyle(Color.chelkaMuted).lineSpacing(4)
                    Spacer(minLength: 0)
                    SurfaceButton("Добавить файлы", symbol: "plus") { model.chooseFiles() }.disabled(shelf.loading)
                } else {
                    HStack(spacing: 12) {
                        ForEach(shelf.items.prefix(3)) { item in
                            NativeFileTile(item: item, image: shelf.image(item), url: shelf.url(for: item), open: { model.open(.preview(item.id)) }, dragChanged: { model.draggingOut = $0 })
                                .frame(width: 112, height: 91)
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
