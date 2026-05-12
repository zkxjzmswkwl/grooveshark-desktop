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
    static let currentVersion = 6
    @MainActor
    static let fields: [UserSettingField] = [
        .dropdown(name: "libraryGrouping", label: "Group Library By", keyPath: \.libraryGrouping),
        .dropdown(name: "librarySortOption", label: "Sort Songs By", keyPath: \.librarySortOption),
        .slider(name: "volume", label: "Volume", keyPath: \.volume, display: .percent),
        .slider(name: "fontScale", label: "Font Scale", keyPath: \.fontScale, range: 0.8...1.8, display: .percent),
        .checkbox(name: "darkModeEnabled", label: "Enable dark mode", keyPath: \.darkModeEnabled),
        .checkbox(name: "showFidelityColumn", label: "Show fidelity column", keyPath: \.showFidelityColumn),
        .text(name: "username", label: "Your username", keyPath: \.username),
        .checkbox(name: "lastFMScrobblingEnabled", label: "Enable Last.fm scrobbling", keyPath: \.lastFMScrobblingEnabled),
        .text(name: "lastFMAPIKey", label: "Last.fm API key", keyPath: \.lastFMAPIKey),
        .text(name: "lastFMAPISecret", label: "Last.fm API shared secret", keyPath: \.lastFMAPISecret),
        .text(name: "lastFMSessionKey", label: "Last.fm session key", keyPath: \.lastFMSessionKey),
        .text(name: "librarySharingPort", label: "LAN sharing port", keyPath: \.librarySharingPort),
    ]

    var version: Int
    var volume: Float
    var fontScale: Float
    var darkModeEnabled: Bool
    var showFidelityColumn: Bool
    var username: String
    var libraryGrouping: LibraryGrouping
    var librarySortOption: LibrarySortOption
    var lastFMScrobblingEnabled: Bool
    var lastFMAPIKey: String
    var lastFMAPISecret: String
    var lastFMSessionKey: String
    var librarySharingPort: String

    static let `default` = UserSettings(
        version: currentVersion,
        volume: 0.9,
        fontScale: 1.0,
        darkModeEnabled: false,
        showFidelityColumn: false,
        username: NSUserName(),
        libraryGrouping: .artist,
        librarySortOption: .artist,
        lastFMScrobblingEnabled: false,
        lastFMAPIKey: "",
        lastFMAPISecret: "",
        lastFMSessionKey: "",
        librarySharingPort: "43821"
    )

    init(
        version: Int,
        volume: Float,
        fontScale: Float,
        darkModeEnabled: Bool,
        showFidelityColumn: Bool,
        username: String,
        libraryGrouping: LibraryGrouping,
        librarySortOption: LibrarySortOption,
        lastFMScrobblingEnabled: Bool,
        lastFMAPIKey: String,
        lastFMAPISecret: String,
        lastFMSessionKey: String,
        librarySharingPort: String
    ) {
        self.version = version
        self.volume = volume
        self.fontScale = fontScale
        self.darkModeEnabled = darkModeEnabled
        self.showFidelityColumn = showFidelityColumn
        self.username = username
        self.libraryGrouping = libraryGrouping
        self.librarySortOption = librarySortOption
        self.lastFMScrobblingEnabled = lastFMScrobblingEnabled
        self.lastFMAPIKey = lastFMAPIKey
        self.lastFMAPISecret = lastFMAPISecret
        self.lastFMSessionKey = lastFMSessionKey
        self.librarySharingPort = librarySharingPort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? Self.default.volume
        fontScale = try container.decodeIfPresent(Float.self, forKey: .fontScale) ?? Self.default.fontScale
        darkModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .darkModeEnabled) ?? Self.default.darkModeEnabled
        showFidelityColumn = try container.decodeIfPresent(Bool.self, forKey: .showFidelityColumn) ?? Self.default.showFidelityColumn
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? Self.default.username
        libraryGrouping = try container.decodeIfPresent(LibraryGrouping.self, forKey: .libraryGrouping) ?? Self.default.libraryGrouping
        librarySortOption = try container.decodeIfPresent(LibrarySortOption.self, forKey: .librarySortOption) ?? Self.default.librarySortOption
        lastFMScrobblingEnabled = try container.decodeIfPresent(Bool.self, forKey: .lastFMScrobblingEnabled) ?? Self.default.lastFMScrobblingEnabled
        lastFMAPIKey = try container.decodeIfPresent(String.self, forKey: .lastFMAPIKey) ?? Self.default.lastFMAPIKey
        lastFMAPISecret = try container.decodeIfPresent(String.self, forKey: .lastFMAPISecret) ?? Self.default.lastFMAPISecret
        lastFMSessionKey = try container.decodeIfPresent(String.self, forKey: .lastFMSessionKey) ?? Self.default.lastFMSessionKey
        librarySharingPort = try container.decodeIfPresent(String.self, forKey: .librarySharingPort) ?? Self.default.librarySharingPort
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
            .appendingPathComponent("GrooveShark", isDirectory: true)
            .appendingPathComponent("user-settings.json", isDirectory: false)
    }
}
