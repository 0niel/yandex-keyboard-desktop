import Foundation

struct KeyboardSelectionSnapshot: Equatable {
  let documentIdentifier: UUID
  let selectedText: String
  let contextBeforeInput: String?
  let contextAfterInput: String?
  let documentGeneration: UInt64
}

enum KeyboardTransactionError: Error, Equatable {
  case noSelection
  case selectionTooLarge
  case targetChanged
}

enum KeyboardTransactionGate {
  static let maximumInputBytes = 64 * 1_024

  static func capture(
    selectedText: String?,
    documentIdentifier: UUID,
    contextBeforeInput: String?,
    contextAfterInput: String?,
    documentGeneration: UInt64
  ) throws -> KeyboardSelectionSnapshot {
    guard let selectedText, !selectedText.isEmpty else {
      throw KeyboardTransactionError.noSelection
    }
    guard selectedText.lengthOfBytes(using: .utf8) <= maximumInputBytes else {
      throw KeyboardTransactionError.selectionTooLarge
    }
    return KeyboardSelectionSnapshot(
      documentIdentifier: documentIdentifier,
      selectedText: selectedText,
      contextBeforeInput: contextBeforeInput,
      contextAfterInput: contextAfterInput,
      documentGeneration: documentGeneration
    )
  }

  static func canCommit(
    _ snapshot: KeyboardSelectionSnapshot,
    currentSelectedText: String?,
    currentDocumentIdentifier: UUID,
    currentContextBeforeInput: String?,
    currentContextAfterInput: String?,
    currentDocumentGeneration: UInt64
  ) -> Bool {
    snapshot.documentIdentifier == currentDocumentIdentifier
      && snapshot.selectedText == currentSelectedText
      && snapshot.contextBeforeInput == currentContextBeforeInput
      && snapshot.contextAfterInput == currentContextAfterInput
      && snapshot.documentGeneration == currentDocumentGeneration
  }
}

final class KeyboardOperationGate {
  private(set) var generation: UInt64 = 0

  @discardableResult
  func begin() -> UInt64 {
    invalidate()
    return generation
  }

  func isCurrent(_ token: UInt64) -> Bool { token == generation }

  func invalidate() {
    generation &+= 1
  }
}

final class KeyboardOperationCoordinator {
  private let gate = KeyboardOperationGate()
  private(set) var activeToken: UInt64?

  @discardableResult
  func begin() -> UInt64 {
    let token = gate.begin()
    activeToken = token
    return token
  }

  func isCurrent(_ token: UInt64) -> Bool {
    activeToken == token && gate.isCurrent(token)
  }

  @discardableResult
  func finish(_ token: UInt64) -> Bool {
    guard isCurrent(token) else { return false }
    activeToken = nil
    gate.invalidate()
    return true
  }

  func cancel() {
    activeToken = nil
    gate.invalidate()
  }
}
