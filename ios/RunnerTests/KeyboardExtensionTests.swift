import Foundation
import UIKit
import XCTest

final class KeyboardExtensionTests: XCTestCase {
  func testSettingsRejectMalformedPayloads() {
    XCTAssertNil(KeyboardSettings(dictionary: [:]))
    XCTAssertNil(KeyboardSettings(dictionary: [
      "schemaVersion": 99,
      "locale": "en",
      "defaultAction": "rewrite",
      "requestTimeoutMilliseconds": 15_000,
    ]))
    XCTAssertNil(KeyboardSettings(dictionary: [
      "schemaVersion": 1,
      "locale": "unknown",
      "defaultAction": "rewrite",
      "requestTimeoutMilliseconds": 15_000,
    ]))
    XCTAssertNil(KeyboardSettings(dictionary: [
      "schemaVersion": 1,
      "locale": "en",
      "defaultAction": "unknown",
      "requestTimeoutMilliseconds": 15_000,
    ]))
    XCTAssertNil(KeyboardSettings(dictionary: [
      "schemaVersion": 1,
      "locale": "en",
      "defaultAction": "rewrite",
      "requestTimeoutMilliseconds": 999,
    ]))
  }

  func testSettingsRoundTripUsesOneEncodedValue() throws {
    let suite = "KeyboardExtensionTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = KeyboardSettingsStore(defaults: defaults)

    let saved = try store.save(dictionary: [
      "schemaVersion": 1,
      "locale": "ru",
      "defaultAction": "fix",
      "requestTimeoutMilliseconds": 3_000,
    ])

    XCTAssertEqual(saved, store.load())
  }

  func testSettingsStoreFailsClosedWithoutAnAppGroupContainer() {
    let store = KeyboardSettingsStore(defaults: nil)

    XCTAssertFalse(store.isAvailable)
    XCTAssertEqual(store.load(), .defaults)
    XCTAssertThrowsError(try store.save(dictionary: KeyboardSettings.defaults.dictionary)) {
      XCTAssertTrue($0 is KeyboardSettingsStoreError)
    }
  }

  func testCapturePreservesUnicodeAndEmbeddedNull() throws {
    let identifier = UUID()
    let text = "مرحبا 👩🏽‍💻\u{0}текст"

    let snapshot = try KeyboardTransactionGate.capture(
      selectedText: text,
      documentIdentifier: identifier,
      contextBeforeInput: "before",
      contextAfterInput: "after",
      documentGeneration: 4
    )

    XCTAssertEqual(snapshot.selectedText, text)
    XCTAssertEqual(snapshot.documentIdentifier, identifier)
  }

  func testKeyboardLayoutProvidesLettersNumbersAndSymbols() {
    XCTAssertEqual(
      KeyboardLayout.rows(language: "en", plane: .letters).first,
      ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
    )
    let russianLetters = KeyboardLayout.rows(language: "ru", plane: .letters).joined()
    XCTAssertEqual(russianLetters.count, 33)
    XCTAssertEqual(
      Set(russianLetters),
      Set("абвгдеёжзийклмнопрстуфхцчшщъыьэюя".map(String.init))
    )
    XCTAssertTrue(
      KeyboardLayout.rows(language: "en", plane: .numbers).joined().contains("$")
    )
    XCTAssertTrue(
      KeyboardLayout.rows(language: "ru", plane: .numbers).joined().contains("₽")
    )
    XCTAssertTrue(
      KeyboardLayout.rows(language: "en", plane: .symbols).joined().contains("€")
    )
  }

  func testKeyboardLayoutResolvesConfiguredAndAsciiLanguages() {
    XCTAssertEqual(
      KeyboardLayout.resolvedLanguage(
        configured: "system",
        systemLanguage: "ru",
        requiresAscii: false
      ),
      "ru"
    )
    XCTAssertEqual(
      KeyboardLayout.resolvedLanguage(
        configured: "ru",
        systemLanguage: "ru",
        requiresAscii: true
      ),
      "en"
    )
    XCTAssertEqual(
      KeyboardLayout.resolvedLanguage(
        configured: "unsupported",
        systemLanguage: nil,
        requiresAscii: false
      ),
      "en"
    )
    XCTAssertEqual(
      KeyboardLayout.resolvedPlane(
        requested: .letters,
        requiresAsciiNumberPad: true
      ),
      .asciiNumberPad
    )
    XCTAssertEqual(
      Array(KeyboardLayout.rows(language: "ru", plane: .asciiNumberPad).joined()),
      ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    )
  }

  func testTypingPresentationKeepsQwertyOrderAndInvalidatesForDynamicType() {
    let typingStack = UIStackView()
    KeyboardLayout.forceTypingOrderLeftToRight(typingStack)
    XCTAssertEqual(typingStack.semanticContentAttribute, .forceLeftToRight)
    XCTAssertEqual(
      UIView.userInterfaceLayoutDirection(for: typingStack.semanticContentAttribute),
      .leftToRight
    )
    let rows = KeyboardLayout.rows(language: "en", plane: .letters)
    XCTAssertEqual(rows.first, ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"])
    let standardKey = KeyboardLayout.presentationKey(
        language: "en",
        plane: .letters,
        contentSizeCategory: "UICTContentSizeCategoryL"
      )
    let accessibilityKey = KeyboardLayout.presentationKey(
        language: "en",
        plane: .letters,
        contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL"
      )
    XCTAssertTrue(
      KeyboardLayout.requiresPresentationRebuild(
        activeKey: standardKey,
        nextKey: accessibilityKey
      )
    )
  }

  func testKeyboardLayoutPolicyAdaptsAcrossPhoneLandscapeFloatingAndPadWidths() {
    let phonePortrait = layoutMetrics(
      width: 390,
      height: 844,
      horizontal: .compact,
      vertical: .regular,
      safeAreaBottom: 34
    )
    let phoneLandscape = layoutMetrics(
      width: 844,
      height: 390,
      horizontal: .compact,
      vertical: .compact,
      safeAreaBottom: 21
    )
    let floatingPad = layoutMetrics(
      width: 360,
      height: 420,
      horizontal: .compact,
      vertical: .regular
    )
    let fullWidthPad = layoutMetrics(
      width: 1_024,
      height: 420,
      horizontal: .regular,
      vertical: .regular
    )

    XCTAssertTrue(phoneLandscape.usesCompactActionContent)
    XCTAssertTrue(floatingPad.usesCompactActionContent)
    XCTAssertFalse(phonePortrait.usesCompactActionContent)
    XCTAssertFalse(fullWidthPad.usesCompactActionContent)
    XCTAssertLessThan(phoneLandscape.preferredHeight, phonePortrait.preferredHeight)
    XCTAssertLessThan(floatingPad.horizontalInset, fullWidthPad.horizontalInset)
    XCTAssertGreaterThan(fullWidthPad.actionSpacing, phoneLandscape.actionSpacing)
  }

  func testKeyboardLayoutPolicyExpandsForAccessibilityTextAndAsciiNumberPad() {
    let standard = layoutMetrics(
      width: 390,
      height: 844,
      horizontal: .compact,
      vertical: .regular,
      safeAreaBottom: 34
    )
    let accessibility = layoutMetrics(
      width: 390,
      height: 844,
      horizontal: .compact,
      vertical: .regular,
      textSize: .accessibility,
      safeAreaBottom: 34
    )
    let asciiNumberPad = layoutMetrics(
      width: 390,
      height: 844,
      horizontal: .compact,
      vertical: .regular,
      typingRowCount: 5,
      safeAreaBottom: 34
    )

    XCTAssertGreaterThan(accessibility.preferredHeight, standard.preferredHeight)
    XCTAssertGreaterThan(accessibility.statusLineCount, standard.statusLineCount)
    XCTAssertEqual(
      asciiNumberPad.preferredHeight - standard.preferredHeight,
      standard.keyHeight + standard.keyRowSpacing
    )
  }

  func testKeyboardLayoutPolicyMaintainsTouchTargetsAndNoOverflowInvariants() {
    let environments = [
      KeyboardLayoutEnvironment(
        availableWidth: 320,
        availableHeight: 568,
        horizontalSizeClass: .compact,
        verticalSizeClass: .regular,
        textSize: .standard,
        typingRowCount: 4,
        safeAreaTop: 0,
        safeAreaBottom: 0
      ),
      KeyboardLayoutEnvironment(
        availableWidth: 667,
        availableHeight: 375,
        horizontalSizeClass: .compact,
        verticalSizeClass: .compact,
        textSize: .accessibility,
        typingRowCount: 4,
        safeAreaTop: 0,
        safeAreaBottom: 21
      ),
      KeyboardLayoutEnvironment(
        availableWidth: 1_366,
        availableHeight: 420,
        horizontalSizeClass: .regular,
        verticalSizeClass: .regular,
        textSize: .accessibility,
        typingRowCount: 5,
        safeAreaTop: 8,
        safeAreaBottom: 24
      ),
    ]

    for environment in environments {
      let metrics = KeyboardLayoutPolicy.metrics(for: environment)
      let requiredHeight = metrics.estimatedContentHeight
        + max(0, environment.safeAreaTop)
        + max(0, environment.safeAreaBottom)
      let availableKeyWidth = environment.availableWidth
        - (2 * metrics.horizontalInset)
        - (9 * metrics.keySpacing)

      XCTAssertGreaterThanOrEqual(metrics.actionHeight, 44)
      XCTAssertGreaterThanOrEqual(metrics.keyHeight, 44)
      XCTAssertGreaterThanOrEqual(metrics.footerHeight, 44)
      XCTAssertGreaterThanOrEqual(metrics.preferredHeight, requiredHeight)
      if environment.availableHeight >= 380 {
        XCTAssertLessThanOrEqual(
          metrics.preferredHeight,
          environment.availableHeight
        )
      }
      XCTAssertGreaterThan(availableKeyWidth / 10, 0)
      XCTAssertGreaterThanOrEqual(metrics.horizontalInset, 0)
      XCTAssertGreaterThanOrEqual(metrics.topInset, 0)
      XCTAssertGreaterThanOrEqual(metrics.bottomInset, 0)
    }
  }

  func testKeyboardHeightBudgetEscapesLandscapeRequestedHeightInPortrait() {
    var budget = KeyboardHeightBudget()
    let landscape = KeyboardLayoutEnvironment(
      availableWidth: 844,
      availableHeight: 0,
      horizontalSizeClass: .compact,
      verticalSizeClass: .compact,
      textSize: .standard,
      typingRowCount: 4,
      safeAreaTop: 0,
      safeAreaBottom: 21
    )
    let landscapeAvailable = budget.availableHeight(
      observedHeight: 390,
      requestedHeight: 490,
      environment: landscape
    )
    let landscapeMetrics = KeyboardLayoutPolicy.metrics(
      for: KeyboardLayoutEnvironment(
        availableWidth: landscape.availableWidth,
        availableHeight: landscapeAvailable,
        horizontalSizeClass: landscape.horizontalSizeClass,
        verticalSizeClass: landscape.verticalSizeClass,
        textSize: landscape.textSize,
        typingRowCount: landscape.typingRowCount,
        safeAreaTop: landscape.safeAreaTop,
        safeAreaBottom: landscape.safeAreaBottom
      )
    )
    let portrait = KeyboardLayoutEnvironment(
      availableWidth: 390,
      availableHeight: 0,
      horizontalSizeClass: .compact,
      verticalSizeClass: .regular,
      textSize: .standard,
      typingRowCount: 4,
      safeAreaTop: 0,
      safeAreaBottom: 34
    )
    let portraitAvailable = budget.availableHeight(
      observedHeight: landscapeMetrics.preferredHeight,
      requestedHeight: landscapeMetrics.preferredHeight,
      environment: portrait
    )
    let portraitMetrics = KeyboardLayoutPolicy.metrics(
      for: KeyboardLayoutEnvironment(
        availableWidth: portrait.availableWidth,
        availableHeight: portraitAvailable,
        horizontalSizeClass: portrait.horizontalSizeClass,
        verticalSizeClass: portrait.verticalSizeClass,
        textSize: portrait.textSize,
        typingRowCount: portrait.typingRowCount,
        safeAreaTop: portrait.safeAreaTop,
        safeAreaBottom: portrait.safeAreaBottom
      )
    )

    XCTAssertEqual(portraitAvailable, 0)
    XCTAssertFalse(portraitMetrics.usesCompactActionContent)
    XCTAssertGreaterThan(portraitMetrics.preferredHeight, landscapeMetrics.preferredHeight)
  }

  func testKeyboardHeightBudgetRecoversWhenHostHeightGrowsWithoutTraitChange() {
    var budget = KeyboardHeightBudget()
    let environment = KeyboardLayoutEnvironment(
      availableWidth: 390,
      availableHeight: 0,
      horizontalSizeClass: .compact,
      verticalSizeClass: .regular,
      textSize: .standard,
      typingRowCount: 4,
      safeAreaTop: 0,
      safeAreaBottom: 34
    )

    XCTAssertEqual(
      budget.availableHeight(
        observedHeight: 420,
        requestedHeight: 520,
        environment: environment
      ),
      420
    )
    XCTAssertEqual(
      budget.availableHeight(
        observedHeight: 500,
        requestedHeight: 600,
        environment: environment
      ),
      500
    )
    XCTAssertEqual(
      budget.availableHeight(
        observedHeight: 600,
        requestedHeight: 600,
        environment: environment,
        isExplicitHostSize: true
      ),
      600
    )
    XCTAssertEqual(
      budget.availableHeight(
        observedHeight: 400,
        requestedHeight: 600,
        environment: environment,
        isExplicitHostSize: true
      ),
      400
    )
  }

  private func layoutMetrics(
    width: Double,
    height: Double,
    horizontal: KeyboardLayoutSizeClass,
    vertical: KeyboardLayoutSizeClass,
    textSize: KeyboardLayoutTextSize = .standard,
    typingRowCount: Int = 4,
    safeAreaBottom: Double = 0
  ) -> KeyboardLayoutMetrics {
    KeyboardLayoutPolicy.metrics(
      for: KeyboardLayoutEnvironment(
        availableWidth: width,
        availableHeight: height,
        horizontalSizeClass: horizontal,
        verticalSizeClass: vertical,
        textSize: textSize,
        typingRowCount: typingRowCount,
        safeAreaTop: 0,
        safeAreaBottom: safeAreaBottom
      )
    )
  }

  func testCaptureRejectsMissingAndOversizedSelection() {
    XCTAssertThrowsError(try KeyboardTransactionGate.capture(
      selectedText: nil,
      documentIdentifier: UUID(),
      contextBeforeInput: nil,
      contextAfterInput: nil,
      documentGeneration: 0
    ))
    XCTAssertThrowsError(try KeyboardTransactionGate.capture(
      selectedText: String(repeating: "x", count: KeyboardTransactionGate.maximumInputBytes + 1),
      documentIdentifier: UUID(),
      contextBeforeInput: nil,
      contextAfterInput: nil,
      documentGeneration: 0
    ))
  }

  func testCommitRequiresSameDocumentAndExactSelection() throws {
    let identifier = UUID()
    let snapshot = try KeyboardTransactionGate.capture(
      selectedText: "original",
      documentIdentifier: identifier,
      contextBeforeInput: "before",
      contextAfterInput: "after",
      documentGeneration: 10
    )

    XCTAssertTrue(KeyboardTransactionGate.canCommit(
      snapshot,
      currentSelectedText: "original",
      currentDocumentIdentifier: identifier,
      currentContextBeforeInput: "before",
      currentContextAfterInput: "after",
      currentDocumentGeneration: 10
    ))
    XCTAssertFalse(KeyboardTransactionGate.canCommit(
      snapshot,
      currentSelectedText: "changed",
      currentDocumentIdentifier: identifier,
      currentContextBeforeInput: "before",
      currentContextAfterInput: "after",
      currentDocumentGeneration: 10
    ))
    XCTAssertFalse(KeyboardTransactionGate.canCommit(
      snapshot,
      currentSelectedText: "original",
      currentDocumentIdentifier: UUID(),
      currentContextBeforeInput: "before",
      currentContextAfterInput: "after",
      currentDocumentGeneration: 10
    ))
    XCTAssertFalse(KeyboardTransactionGate.canCommit(
      snapshot,
      currentSelectedText: "original",
      currentDocumentIdentifier: identifier,
      currentContextBeforeInput: "before",
      currentContextAfterInput: "after",
      currentDocumentGeneration: 12
    ), "An equal-text ABA must be rejected by the document generation.")
    XCTAssertFalse(KeyboardTransactionGate.canCommit(
      snapshot,
      currentSelectedText: "original",
      currentDocumentIdentifier: identifier,
      currentContextBeforeInput: "changed-before",
      currentContextAfterInput: "after",
      currentDocumentGeneration: 10
    ))
    XCTAssertFalse(KeyboardTransactionGate.canCommit(
      snapshot,
      currentSelectedText: "original",
      currentDocumentIdentifier: identifier,
      currentContextBeforeInput: "before",
      currentContextAfterInput: "changed-after",
      currentDocumentGeneration: 10
    ))
  }

  func testOperationGateRejectsAnOlderOperationAfterANewerOneStarts() {
    let gate = KeyboardOperationGate()
    let first = gate.begin()

    XCTAssertTrue(gate.isCurrent(first))

    let second = gate.begin()

    XCTAssertFalse(gate.isCurrent(first))
    XCTAssertTrue(gate.isCurrent(second))
  }

  func testOperationGateRejectsCurrentOperationAfterLifecycleInvalidation() {
    let gate = KeyboardOperationGate()
    let operation = gate.begin()

    gate.invalidate()

    XCTAssertFalse(gate.isCurrent(operation))
  }

  func testOperationCoordinatorLetsOnlyTheOwnerFinish() {
    let coordinator = KeyboardOperationCoordinator()
    let first = coordinator.begin()
    let second = coordinator.begin()

    XCTAssertFalse(coordinator.finish(first))
    XCTAssertTrue(coordinator.finish(second))
    XCTAssertNil(coordinator.activeToken)
    XCTAssertFalse(coordinator.finish(second))
  }

  func testOperationCoordinatorCancelsLifecycleWorkBeforeLateCompletion() {
    let coordinator = KeyboardOperationCoordinator()
    let operation = coordinator.begin()

    coordinator.cancel()

    XCTAssertFalse(coordinator.isCurrent(operation))
    XCTAssertFalse(coordinator.finish(operation))
    XCTAssertNil(coordinator.activeToken)
  }

  func testTransformationReleaseDefaultIsFailClosed() async throws {
    let unavailable = KeyboardTransformationService(baseURL: nil)
    XCTAssertFalse(unavailable.isAvailable)
    XCTAssertFalse(KeyboardTransformationService(
      baseURL: URL(string: "http://example.test/gpt/")!
    ).isAvailable)
    XCTAssertTrue(KeyboardTransformationService(
      baseURL: URL(string: "https://example.test/gpt/")!
    ).isAvailable)
    XCTAssertNil(KeyboardTransformationService.configuredBaseURL(
      privacyReviewed: "NO",
      value: "https://example.test/gpt/"
    ))
    XCTAssertNil(KeyboardTransformationService.configuredBaseURL(
      privacyReviewed: "YES",
      value: "http://example.test/gpt/"
    ))
    XCTAssertEqual(
      KeyboardTransformationService.configuredBaseURL(
        privacyReviewed: "true",
        value: "https://example.test/gpt/"
      )?.absoluteString,
      "https://example.test/gpt/"
    )
    XCTAssertEqual(
      KeyboardTransformationService.configuredBaseURL(
        privacyReviewed: "YES",
        value: "https://example.test/gpt"
      )?.absoluteString,
      "https://example.test/gpt/"
    )

    do {
      _ = try await unavailable.transform(
        text: "private",
        action: .fix,
        timeout: 3
      )
      XCTFail("An unconfigured release service unexpectedly sent text.")
    } catch {
      XCTAssertEqual(
        error as? KeyboardTransformationError,
        .serviceUnavailable
      )
    }
  }

  func testTransformationUsesExactUtf8BodyAndEphemeralSession() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [KeyboardURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    let source = "مرحبا 👩🏽‍💻\u{0}текст"
    KeyboardURLProtocolStub.handler = { request in
      XCTAssertEqual(request.url?.absoluteString, "https://example.test/gpt/fix")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
      let body = try requestBody(request)
      let json = try XCTUnwrap(
        JSONSerialization.jsonObject(with: body) as? [String: String]
      )
      XCTAssertEqual(json, ["text": source])
      let response = try XCTUnwrap(HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      ))
      let data = try JSONSerialization.data(withJSONObject: [
        "response": "исправлено ✅",
      ])
      return (response, data)
    }
    defer {
      KeyboardURLProtocolStub.handler = nil
      session.invalidateAndCancel()
    }
    let service = KeyboardTransformationService(
      baseURL: URL(string: "https://example.test/gpt/")!,
      session: session
    )

    let transformed = try await service.transform(
      text: source,
      action: .fix,
      timeout: 3
    )

    XCTAssertEqual(transformed, "исправлено ✅")
  }

  func testTransformationRejectsOversizedStream() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [KeyboardURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    KeyboardURLProtocolStub.handler = { request in
      let response = try XCTUnwrap(HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      ))
      return (
        response,
        Data(repeating: 0x61, count: KeyboardTransformationService.maximumResponseBytes + 1)
      )
    }
    defer {
      KeyboardURLProtocolStub.handler = nil
      session.invalidateAndCancel()
    }
    let service = KeyboardTransformationService(
      baseURL: URL(string: "https://example.test/gpt/")!,
      session: session
    )

    do {
      _ = try await service.transform(text: "text", action: .rewrite, timeout: 3)
      XCTFail("Oversized response unexpectedly succeeded.")
    } catch {
      XCTAssertEqual(error as? KeyboardTransformationError, .responseTooLarge)
    }
  }

  func testTransformationNeverFollowsRedirect() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [KeyboardURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    KeyboardURLProtocolStub.redirectTarget = URL(string: "https://attacker.invalid/collect")!
    defer {
      KeyboardURLProtocolStub.redirectTarget = nil
      session.invalidateAndCancel()
    }
    let service = KeyboardTransformationService(
      baseURL: URL(string: "https://example.test/gpt/")!,
      session: session
    )

    do {
      _ = try await service.transform(text: "private", action: .fix, timeout: 3)
      XCTFail("Redirect unexpectedly succeeded.")
    } catch {
      XCTAssertEqual(KeyboardURLProtocolStub.requestCount, 1)
    }
  }

  func testTransformationRejectsInvalidRequestsBeforeNetwork() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [KeyboardURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let service = KeyboardTransformationService(
      baseURL: URL(string: "https://example.test/gpt/")!,
      session: session
    )

    for source in [
      "",
      String(repeating: "x", count: KeyboardTransactionGate.maximumInputBytes + 1),
    ] {
      do {
        _ = try await service.transform(text: source, action: .fix, timeout: 3)
        XCTFail("Invalid source unexpectedly reached the network.")
      } catch {
        XCTAssertEqual(error as? KeyboardTransformationError, .invalidRequest)
      }
    }
  }

  func testTransformationNormalizesTransportFailures() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [KeyboardURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer {
      KeyboardURLProtocolStub.handler = nil
      session.invalidateAndCancel()
    }
    let service = KeyboardTransformationService(
      baseURL: URL(string: "https://example.test/gpt")!,
      session: session
    )

    for (source, expected) in [
      (URLError(.cancelled), KeyboardTransformationError.cancelled),
      (URLError(.timedOut), KeyboardTransformationError.timedOut),
      (URLError(.notConnectedToInternet), KeyboardTransformationError.transport),
    ] {
      KeyboardURLProtocolStub.handler = { _ in throw source }
      do {
        _ = try await service.transform(text: "private", action: .fix, timeout: 3)
        XCTFail("Transport failure unexpectedly succeeded.")
      } catch {
        XCTAssertEqual(error as? KeyboardTransformationError, expected)
      }
    }
  }

  func testTransformationRejectsHttpFailureAndInvalidJson() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [KeyboardURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer {
      KeyboardURLProtocolStub.handler = nil
      session.invalidateAndCancel()
    }
    let service = KeyboardTransformationService(
      baseURL: URL(string: "https://example.test/gpt/")!,
      session: session
    )

    KeyboardURLProtocolStub.handler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 503,
        httpVersion: "HTTP/1.1",
        headerFields: nil
      )!
      return (response, Data())
    }
    do {
      _ = try await service.transform(text: "private", action: .rewrite, timeout: 3)
      XCTFail("Rejected response unexpectedly succeeded.")
    } catch {
      XCTAssertEqual(
        error as? KeyboardTransformationError,
        .rejected(statusCode: 503)
      )
    }

    KeyboardURLProtocolStub.handler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data("{\"response\":\"  \"}".utf8))
    }
    do {
      _ = try await service.transform(text: "private", action: .rewrite, timeout: 3)
      XCTFail("Empty transformed text unexpectedly succeeded.")
    } catch {
      XCTAssertEqual(error as? KeyboardTransformationError, .invalidResponse)
    }
  }

  func testTransformationRejectsCrossOriginAndDeclaredOversize() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [KeyboardURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer {
      KeyboardURLProtocolStub.handler = nil
      session.invalidateAndCancel()
    }
    let service = KeyboardTransformationService(
      baseURL: URL(string: "https://example.test/gpt/")!,
      session: session
    )

    KeyboardURLProtocolStub.handler = { _ in
      let response = HTTPURLResponse(
        url: URL(string: "https://attacker.invalid/collect")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data("{\"response\":\"stolen\"}".utf8))
    }
    do {
      _ = try await service.transform(text: "private", action: .fix, timeout: 3)
      XCTFail("Cross-origin response unexpectedly succeeded.")
    } catch {
      XCTAssertEqual(error as? KeyboardTransformationError, .invalidResponse)
    }

    KeyboardURLProtocolStub.handler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Type": "application/json",
          "Content-Length": "\(KeyboardTransformationService.maximumResponseBytes + 1)",
        ]
      )!
      return (response, Data())
    }
    do {
      _ = try await service.transform(text: "private", action: .fix, timeout: 3)
      XCTFail("Declared oversized response unexpectedly succeeded.")
    } catch {
      XCTAssertEqual(error as? KeyboardTransformationError, .responseTooLarge)
    }
  }
}

private final class KeyboardURLProtocolStub: URLProtocol {
  static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
  static var redirectTarget: URL? {
    didSet { requestCount = 0 }
  }
  static private(set) var requestCount = 0

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Self.requestCount += 1
    if let redirectTarget = Self.redirectTarget {
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 307,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": redirectTarget.absoluteString]
      )!
      var redirected = request
      redirected.url = redirectTarget
      client?.urlProtocol(
        self,
        wasRedirectedTo: redirected,
        redirectResponse: response
      )
      return
    }
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(
        self,
        didReceive: response,
        cacheStoragePolicy: .notAllowed
      )
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private func requestBody(_ request: URLRequest) throws -> Data {
  if let body = request.httpBody { return body }
  let stream = try XCTUnwrap(request.httpBodyStream)
  stream.open()
  defer { stream.close() }
  var result = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
    if count == 0 { break }
    result.append(contentsOf: buffer.prefix(count))
  }
  return result
}
