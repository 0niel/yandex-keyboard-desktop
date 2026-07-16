import Foundation

enum KeyboardAction: String, Codable, CaseIterable {
  case emojify
  case rewrite
  case fix

  var endpointPath: String {
    switch self {
    case .emojify: return "emoji"
    case .rewrite: return "rewrite"
    case .fix: return "fix"
    }
  }
}

struct KeyboardSettings: Codable, Equatable {
  static let currentSchemaVersion = 1
  static let defaults = KeyboardSettings(
    schemaVersion: currentSchemaVersion,
    locale: "system",
    defaultAction: .rewrite,
    requestTimeoutMilliseconds: 15_000
  )

  let schemaVersion: Int
  let locale: String
  let defaultAction: KeyboardAction
  let requestTimeoutMilliseconds: Int

  init(
    schemaVersion: Int,
    locale: String,
    defaultAction: KeyboardAction,
    requestTimeoutMilliseconds: Int
  ) {
    self.schemaVersion = schemaVersion
    self.locale = locale
    self.defaultAction = defaultAction
    self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
  }

  init?(dictionary: [String: Any]) {
    guard
      let schemaVersion = dictionary["schemaVersion"] as? Int,
      schemaVersion == Self.currentSchemaVersion,
      let locale = dictionary["locale"] as? String,
      ["system", "en", "ru"].contains(locale),
      let rawAction = dictionary["defaultAction"] as? String,
      let defaultAction = KeyboardAction(rawValue: rawAction),
      let timeout = dictionary["requestTimeoutMilliseconds"] as? Int,
      (1_000...120_000).contains(timeout)
    else {
      return nil
    }

    self.init(
      schemaVersion: schemaVersion,
      locale: locale,
      defaultAction: defaultAction,
      requestTimeoutMilliseconds: timeout
    )
  }

  var dictionary: [String: Any] {
    [
      "schemaVersion": schemaVersion,
      "locale": locale,
      "defaultAction": defaultAction.rawValue,
      "requestTimeoutMilliseconds": requestTimeoutMilliseconds,
    ]
  }
}

enum KeyboardSettingsStoreError: Error {
  case appGroupUnavailable
  case invalidSettings
  case encodingFailed
}

final class KeyboardSettingsStore {
  static let appGroupIdentifier = "group.io.github.oniel.yandexKeyboardDesktop"
  static let shared = KeyboardSettingsStore()

  private static let settingsKey = "keyboard.settings.v1"
  private let defaults: UserDefaults?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)) {
    self.defaults = defaults
  }

  var isAvailable: Bool { defaults != nil }

  func load() -> KeyboardSettings {
    guard
      let data = defaults?.data(forKey: Self.settingsKey),
      let settings = try? decoder.decode(KeyboardSettings.self, from: data),
      settings.schemaVersion == KeyboardSettings.currentSchemaVersion,
      ["system", "en", "ru"].contains(settings.locale),
      (1_000...120_000).contains(settings.requestTimeoutMilliseconds)
    else {
      return .defaults
    }
    return settings
  }

  func save(dictionary: [String: Any]) throws -> KeyboardSettings {
    guard let defaults else {
      throw KeyboardSettingsStoreError.appGroupUnavailable
    }
    guard let settings = KeyboardSettings(dictionary: dictionary) else {
      throw KeyboardSettingsStoreError.invalidSettings
    }
    guard let data = try? encoder.encode(settings) else {
      throw KeyboardSettingsStoreError.encodingFailed
    }

    defaults.set(data, forKey: Self.settingsKey)
    return settings
  }
}
