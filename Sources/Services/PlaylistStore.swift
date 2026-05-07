import Foundation

struct PlaylistStore {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let decoder = JSONDecoder()

    func load() -> [SavedPlaylist] {
        guard let url = storageURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var decoded = try? decoder.decode(PlaylistLibrary.self, from: data)
        else {
            return []
        }
        decoded.migrateIfNeeded()
        return decoded.playlists
    }

    func save(_ playlists: [SavedPlaylist]) {
        guard let url = storageURL() else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = PlaylistLibrary(playlists: playlists)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func storageURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("GrooveShark", isDirectory: true)
            .appendingPathComponent("playlists.json", isDirectory: false)
    }
}
