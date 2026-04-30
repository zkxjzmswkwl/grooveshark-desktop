import Foundation

struct UserSettingField: Identifiable {
    let id: String
    let label: String
    let control: UserSettingControl

    static func dropdown<Option>(
        name: String,
        label: String,
        keyPath: WritableKeyPath<UserSettings, Option>
    ) -> UserSettingField where Option: CaseIterable & RawRepresentable, Option.RawValue == String {
        UserSettingField(
            id: name,
            label: label,
            control: .dropdown(
                value: UserSettingValue<String>(
                    get: { $0[keyPath: keyPath].rawValue },
                    set: { settings, rawValue in
                        guard let option = Option(rawValue: rawValue) else { return }
                        settings[keyPath: keyPath] = option
                    }
                ),
                options: Option.allCases.map { UserSettingDropdownOption(rawValue: $0.rawValue, label: $0.rawValue) }
            )
        )
    }

    static func text(
        name: String,
        label: String,
        keyPath: WritableKeyPath<UserSettings, String>
    ) -> UserSettingField {
        UserSettingField(
            id: name,
            label: label,
            control: .text(
                UserSettingValue<String>(
                    get: { $0[keyPath: keyPath] },
                    set: { $0[keyPath: keyPath] = $1 }
                )
            )
        )
    }

    static func slider(
        name: String,
        label: String,
        keyPath: WritableKeyPath<UserSettings, Float>,
        range: ClosedRange<Double> = 0...1,
        display: UserSettingValueDisplay = .plain
    ) -> UserSettingField {
        UserSettingField(
            id: name,
            label: label,
            control: .slider(
                value: UserSettingValue<Double>(
                    get: { Double($0[keyPath: keyPath]) },
                    set: { $0[keyPath: keyPath] = Float($1) }
                ),
                range: range,
                display: display
            )
        )
    }

    static func checkbox(
        name: String,
        label: String,
        keyPath: WritableKeyPath<UserSettings, Bool>
    ) -> UserSettingField {
        UserSettingField(
            id: name,
            label: label,
            control: .checkbox(
                UserSettingValue<Bool>(
                    get: { $0[keyPath: keyPath] },
                    set: { $0[keyPath: keyPath] = $1 }
                )
            )
        )
    }
}

enum UserSettingControl {
    case dropdown(value: UserSettingValue<String>, options: [UserSettingDropdownOption])
    case text(UserSettingValue<String>)
    case slider(value: UserSettingValue<Double>, range: ClosedRange<Double>, display: UserSettingValueDisplay)
    case checkbox(UserSettingValue<Bool>)
}

struct UserSettingValue<Value> {
    let get: (UserSettings) -> Value
    let set: (inout UserSettings, Value) -> Void
}

enum UserSettingValueDisplay {
    case plain
    case percent

    func format(_ value: Double) -> String {
        switch self {
        case .plain:
            return String(format: "%.2f", value)
        case .percent:
            return "\(Int(value * 100))%"
        }
    }
}

struct UserSettingDropdownOption: Identifiable, Hashable {
    let rawValue: String
    let label: String

    var id: String { rawValue }
}

struct UserSettings: Codable, Equatable {
    static let currentVersion = 1
    @MainActor
    static let fields: [UserSettingField] = [
        .dropdown(name: "libraryGrouping", label: "Group Library By", keyPath: \.libraryGrouping),
        .dropdown(name: "librarySortOption", label: "Sort Songs By", keyPath: \.librarySortOption),
        .slider(name: "volume", label: "Volume", keyPath: \.volume, display: .percent),
        .text(name: "username", label: "Your username", keyPath: \.username),
    ]

    var version: Int
    var volume: Float
    var username: String
    var libraryGrouping: LibraryGrouping
    var librarySortOption: LibrarySortOption

    static let `default` = UserSettings(
        version: currentVersion,
        volume: 0.9,
        username: NSUserName(),
        libraryGrouping: .artist,
        librarySortOption: .artist
    )

    init(
        version: Int,
        volume: Float,
        username: String,
        libraryGrouping: LibraryGrouping,
        librarySortOption: LibrarySortOption
    ) {
        self.version = version
        self.volume = volume
        self.username = username
        self.libraryGrouping = libraryGrouping
        self.librarySortOption = librarySortOption
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? Self.default.volume
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? Self.default.username
        libraryGrouping = try container.decodeIfPresent(LibraryGrouping.self, forKey: .libraryGrouping) ?? Self.default.libraryGrouping
        librarySortOption = try container.decodeIfPresent(LibrarySortOption.self, forKey: .librarySortOption) ?? Self.default.librarySortOption
    }

    mutating func migrateIfNeeded() {
        version = Self.currentVersion
    }
}

final class UserSettingsStore {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let decoder = JSONDecoder()

    func load() -> UserSettings {
        guard let url = settingsURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var decoded = try? decoder.decode(UserSettings.self, from: data)
        else {
            return .default
        }
        decoded.migrateIfNeeded()
        return decoded
    }

    func save(_ settings: UserSettings) {
        guard let url = settingsURL() else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func settingsURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("LiquidFLACPlayer", isDirectory: true)
            .appendingPathComponent("user-settings.json", isDirectory: false)
    }
}
