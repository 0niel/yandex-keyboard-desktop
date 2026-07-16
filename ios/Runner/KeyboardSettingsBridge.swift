import Flutter
import Foundation

final class KeyboardSettingsBridge {
  private static var channel: FlutterMethodChannel?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "io.github.oniel.ykd/keyboard_settings",
      binaryMessenger: messenger
    )
    self.channel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "read":
        result(KeyboardSettingsStore.shared.load().dictionary)
      case "write":
        guard let arguments = call.arguments as? [String: Any] else {
          result(FlutterError(
            code: "invalid_settings",
            message: "Keyboard settings payload is invalid.",
            details: nil
          ))
          return
        }
        do {
          let settings = try KeyboardSettingsStore.shared.save(dictionary: arguments)
          result(settings.dictionary)
        } catch KeyboardSettingsStoreError.appGroupUnavailable {
          result(FlutterError(
            code: "app_group_unavailable",
            message: "The shared keyboard container is unavailable.",
            details: nil
          ))
        } catch {
          result(FlutterError(
            code: "invalid_settings",
            message: "Keyboard settings payload is invalid.",
            details: nil
          ))
        }
      case "capabilities":
        result([
          "appGroupAvailable": KeyboardSettingsStore.shared.isAvailable,
          "globalShortcuts": false,
          "selectionViaDocumentProxy": true,
          "clipboardMutation": false,
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
