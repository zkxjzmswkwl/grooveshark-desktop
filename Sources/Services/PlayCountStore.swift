import Foundation

struct PlayCountStore {
    static let secondsRequiredForOnePlay: TimeInterval = 30

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let decoder = JSONDecoder()

    func load() -> [String: Int] {
        guard let url = storageURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode([String: Int].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    func save(_ counts: [String: Int]) {
        guard let url = storageURL() else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(counts) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func storageURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("LiquidFLACPlayer", isDirectory: true)
            .appendingPathComponent("play-counts.json", isDirectory: false)
    }
}
