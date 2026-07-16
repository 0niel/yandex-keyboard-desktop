import UIKit

enum KeyboardPlane: String, CaseIterable {
  case letters
  case numbers
  case symbols
  case asciiNumberPad
}

enum KeyboardLayoutSizeClass: String, Equatable {
  case unspecified
  case compact
  case regular
}

enum KeyboardLayoutTextSize: String, Equatable {
  case standard
  case accessibility
}

struct KeyboardLayoutEnvironment: Equatable {
  let availableWidth: Double
  let availableHeight: Double
  let horizontalSizeClass: KeyboardLayoutSizeClass
  let verticalSizeClass: KeyboardLayoutSizeClass
  let textSize: KeyboardLayoutTextSize
  let typingRowCount: Int
  let safeAreaTop: Double
  let safeAreaBottom: Double
}

struct KeyboardLayoutMetrics: Equatable {
  let preferredHeight: Double
  let horizontalInset: Double
  let topInset: Double
  let bottomInset: Double
  let rootSpacing: Double
  let actionSpacing: Double
  let actionHeight: Double
  let keyRowSpacing: Double
  let keySpacing: Double
  let keyHeight: Double
  let footerHeight: Double
  let usesCompactActionContent: Bool
  let statusLineCount: Int
  let typingRowCount: Int

  var estimatedContentHeight: Double {
    topInset
      + actionHeight
      + (Double(typingRowCount) * keyHeight)
      + (Double(max(0, typingRowCount - 1)) * keyRowSpacing)
      + footerHeight
      + (2 * rootSpacing)
      + bottomInset
  }
}

struct KeyboardHeightBudget {
  private struct Signature: Equatable {
    let availableWidth: Double
    let horizontalSizeClass: KeyboardLayoutSizeClass
    let verticalSizeClass: KeyboardLayoutSizeClass
    let textSize: KeyboardLayoutTextSize
    let typingRowCount: Int
    let safeAreaTop: Double
    let safeAreaBottom: Double
  }

  private var signature: Signature?
  private var constrainedHeight: Double?

  mutating func availableHeight(
    observedHeight: Double,
    requestedHeight: Double?,
    environment: KeyboardLayoutEnvironment,
    isExplicitHostSize: Bool = false
  ) -> Double {
    let nextSignature = Signature(
      availableWidth: environment.availableWidth,
      horizontalSizeClass: environment.horizontalSizeClass,
      verticalSizeClass: environment.verticalSizeClass,
      textSize: environment.textSize,
      typingRowCount: environment.typingRowCount,
      safeAreaTop: environment.safeAreaTop,
      safeAreaBottom: environment.safeAreaBottom
    )
    if signature != nextSignature {
      signature = nextSignature
      constrainedHeight = nil
      if let requestedHeight,
         abs(observedHeight - requestedHeight) <= 1 {
        return 0
      }
    }
    if let constrainedHeight {
      if isExplicitHostSize
        && observedHeight > 0
        && abs(observedHeight - constrainedHeight) > 1 {
        self.constrainedHeight = observedHeight
        return observedHeight
      }
      let isOwnRequestedHeight = requestedHeight.map {
        abs(observedHeight - $0) <= 1
      } ?? false
      if observedHeight > constrainedHeight + 1 && !isOwnRequestedHeight {
        self.constrainedHeight = observedHeight
        return observedHeight
      }
      return constrainedHeight
    }
    guard observedHeight > 0 else { return 0 }
    guard let requestedHeight else { return observedHeight }
    if observedHeight + 1 < requestedHeight {
      constrainedHeight = observedHeight
      return observedHeight
    }
    return 0
  }
}

enum KeyboardLayoutPolicy {
  static func metrics(for environment: KeyboardLayoutEnvironment) -> KeyboardLayoutMetrics {
    let compactLandscape = environment.verticalSizeClass == .compact
    let narrow = environment.availableWidth > 0 && environment.availableWidth < 375
    let wide = environment.horizontalSizeClass == .regular
      && environment.availableWidth >= 700
    let accessibility = environment.textSize == .accessibility

    var values: (
      horizontalInset: Double,
      topInset: Double,
      bottomInset: Double,
      rootSpacing: Double,
      actionSpacing: Double,
      actionHeight: Double,
      keyRowSpacing: Double,
      keySpacing: Double,
      keyHeight: Double,
      footerHeight: Double,
      compactActions: Bool,
      statusLines: Int
    )

    if compactLandscape {
      values = (
        6, 6, 6, 6, 4, accessibility ? 52 : 48, 3, 3,
        44, accessibility ? 52 : 44, true, 2
      )
    } else if narrow {
      values = (
        6, 8, 8, 8, 4, accessibility ? 68 : 56, 4, 3,
        accessibility ? 48 : 44, accessibility ? 72 : 44, true,
        accessibility ? 3 : 2
      )
    } else if wide {
      values = (
        16, 12, 10, 12, 8, accessibility ? 84 : 72, 4, 5,
        accessibility ? 48 : 44, accessibility ? 72 : 44,
        accessibility, accessibility ? 3 : 2
      )
    } else {
      values = (
        10, 10, 8, 10, 6, accessibility ? 76 : 64, 4, 4,
        accessibility ? 48 : 44, accessibility ? 72 : 44,
        accessibility, accessibility ? 3 : 2
      )
    }

    let safeAreaHeight = max(0, environment.safeAreaTop)
      + max(0, environment.safeAreaBottom)
    let selectedHeight = values.topInset
      + values.actionHeight
      + (Double(max(1, environment.typingRowCount)) * values.keyHeight)
      + (Double(max(0, environment.typingRowCount - 1)) * values.keyRowSpacing)
      + values.footerHeight
      + (2 * values.rootSpacing)
      + values.bottomInset
      + safeAreaHeight
    if environment.availableHeight > 0
      && selectedHeight > environment.availableHeight {
      values = (6, 6, 6, 6, 4, 48, 3, 3, 44, 44, true, 1)
    }

    let provisional = KeyboardLayoutMetrics(
      preferredHeight: 0,
      horizontalInset: values.horizontalInset,
      topInset: values.topInset,
      bottomInset: values.bottomInset,
      rootSpacing: values.rootSpacing,
      actionSpacing: values.actionSpacing,
      actionHeight: values.actionHeight,
      keyRowSpacing: values.keyRowSpacing,
      keySpacing: values.keySpacing,
      keyHeight: values.keyHeight,
      footerHeight: values.footerHeight,
      usesCompactActionContent: values.compactActions,
      statusLineCount: values.statusLines,
      typingRowCount: max(1, environment.typingRowCount)
    )
    return KeyboardLayoutMetrics(
      preferredHeight: ceil(
        provisional.estimatedContentHeight
          + safeAreaHeight
      ),
      horizontalInset: provisional.horizontalInset,
      topInset: provisional.topInset,
      bottomInset: provisional.bottomInset,
      rootSpacing: provisional.rootSpacing,
      actionSpacing: provisional.actionSpacing,
      actionHeight: provisional.actionHeight,
      keyRowSpacing: provisional.keyRowSpacing,
      keySpacing: provisional.keySpacing,
      keyHeight: provisional.keyHeight,
      footerHeight: provisional.footerHeight,
      usesCompactActionContent: provisional.usesCompactActionContent,
      statusLineCount: provisional.statusLineCount,
      typingRowCount: provisional.typingRowCount
    )
  }
}

enum KeyboardLayout {
  static func forceTypingOrderLeftToRight(_ stack: UIStackView) {
    stack.semanticContentAttribute = .forceLeftToRight
  }

  static func presentationKey(
    language: String,
    plane: KeyboardPlane,
    contentSizeCategory: String
  ) -> String {
    "\(language):\(plane.rawValue):\(contentSizeCategory)"
  }

  static func requiresPresentationRebuild(
    activeKey: String?,
    nextKey: String
  ) -> Bool {
    activeKey != nextKey
  }

  static func resolvedLanguage(
    configured: String,
    systemLanguage: String?,
    requiresAscii: Bool
  ) -> String {
    if requiresAscii { return "en" }
    let requested = configured == "system" ? systemLanguage : configured
    return requested == "ru" ? "ru" : "en"
  }

  static func resolvedPlane(
    requested: KeyboardPlane,
    requiresAsciiNumberPad: Bool
  ) -> KeyboardPlane {
    requiresAsciiNumberPad ? .asciiNumberPad : requested
  }

  static func rows(language: String, plane: KeyboardPlane) -> [[String]] {
    switch plane {
    case .letters:
      return (language == "ru"
        ? ["йцукенгшщзхъ", "фывапролджэ", "ячсмитьбюё"]
        : ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
      ).map { $0.map(String.init) }
    case .numbers:
      return [
        "1234567890".map(String.init),
        ["-", "/", ":", ";", "(", ")", language == "ru" ? "₽" : "$", "&", "@", "\""],
        [".", ",", "?", "!", "'"],
      ]
    case .symbols:
      return [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
        [".", ",", "?", "!", "'"],
      ]
    case .asciiNumberPad:
      return [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["0"],
      ]
    }
  }
}
