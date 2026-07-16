import Foundation

enum KeyboardTransformationError: Error, Equatable {
  case serviceUnavailable
  case invalidRequest
  case cancelled
  case timedOut
  case transport
  case rejected(statusCode: Int)
  case invalidResponse
  case responseTooLarge
}

protocol KeyboardTransforming {
  var isAvailable: Bool { get }

  func transform(
    text: String,
    action: KeyboardAction,
    timeout: TimeInterval
  ) async throws -> String
}

final class KeyboardTransformationService: KeyboardTransforming {
  static let maximumResponseBytes = 128 * 1_024

  private let baseURL: URL?
  private let session: URLSession
  private let redirectDelegate = RejectingRedirectDelegate()

  init(
    baseURL: URL? = KeyboardTransformationService.releaseBaseURL(),
    session: URLSession? = nil
  ) {
    self.baseURL = Self.validatedBaseURL(baseURL)
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.waitsForConnectivity = false
      self.session = URLSession(configuration: configuration)
    }
  }

  var isAvailable: Bool { baseURL != nil }

  func transform(
    text: String,
    action: KeyboardAction,
    timeout: TimeInterval
  ) async throws -> String {
    guard let baseURL else {
      throw KeyboardTransformationError.serviceUnavailable
    }
    guard
      !text.isEmpty,
      text.lengthOfBytes(using: .utf8) <= KeyboardTransactionGate.maximumInputBytes,
      let url = URL(string: action.endpointPath, relativeTo: baseURL)
    else {
      throw KeyboardTransformationError.invalidRequest
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = max(1, min(timeout, 120))
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let body = try? JSONSerialization.data(withJSONObject: ["text": text]) else {
      throw KeyboardTransformationError.invalidRequest
    }
    request.httpBody = body

    do {
      let (bytes, response) = try await session.bytes(
        for: request,
        delegate: redirectDelegate
      )
      guard let httpResponse = response as? HTTPURLResponse else {
        throw KeyboardTransformationError.invalidResponse
      }
      guard
        let responseURL = httpResponse.url,
        sameOrigin(responseURL, baseURL)
      else {
        throw KeyboardTransformationError.invalidResponse
      }
      guard httpResponse.statusCode == 200 else {
        throw KeyboardTransformationError.rejected(statusCode: httpResponse.statusCode)
      }
      guard
        httpResponse.expectedContentLength < 0
          || httpResponse.expectedContentLength <= Int64(Self.maximumResponseBytes)
      else {
        throw KeyboardTransformationError.responseTooLarge
      }
      var data = Data()
      data.reserveCapacity(min(
        max(0, Int(httpResponse.expectedContentLength)),
        Self.maximumResponseBytes
      ))
      for try await byte in bytes {
        guard data.count < Self.maximumResponseBytes else {
          throw KeyboardTransformationError.responseTooLarge
        }
        data.append(byte)
      }
      guard
        let object = try? JSONSerialization.jsonObject(with: data),
        let json = object as? [String: Any],
        let transformed = json["response"] as? String,
        !transformed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw KeyboardTransformationError.invalidResponse
      }
      return transformed
    } catch let error as KeyboardTransformationError {
      throw error
    } catch is CancellationError {
      throw KeyboardTransformationError.cancelled
    } catch let error as URLError {
      switch error.code {
      case .cancelled:
        throw KeyboardTransformationError.cancelled
      case .timedOut:
        throw KeyboardTransformationError.timedOut
      default:
        throw KeyboardTransformationError.transport
      }
    } catch {
      throw KeyboardTransformationError.transport
    }
  }

  static func releaseBaseURL(bundle: Bundle = .main) -> URL? {
    configuredBaseURL(
      privacyReviewed: bundle.object(
        forInfoDictionaryKey: "YKDTransformationServicePrivacyReviewed"
      ) as? String,
      value: bundle.object(
        forInfoDictionaryKey: "YKDTransformationServiceBaseURL"
      ) as? String
    )
  }

  static func configuredBaseURL(
    privacyReviewed: String?,
    value: String?
  ) -> URL? {
    let reviewed = ["1", "true", "yes"].contains(
      privacyReviewed?.lowercased() ?? ""
    )
    guard
      reviewed,
      let value
    else { return nil }
    return validatedBaseURL(URL(string: value))
  }

  private static func validatedBaseURL(_ url: URL?) -> URL? {
    guard
      let url,
      url.scheme?.lowercased() == "https",
      url.host?.isEmpty == false,
      url.user == nil,
      url.password == nil,
      url.query == nil,
      url.fragment == nil
    else { return nil }
    guard var components = URLComponents(
      url: url,
      resolvingAgainstBaseURL: false
    ) else { return nil }
    if !components.path.hasSuffix("/") {
      components.path += "/"
    }
    return components.url
  }

  private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
      && lhs.host?.lowercased() == rhs.host?.lowercased()
      && effectivePort(lhs) == effectivePort(rhs)
  }

  private func effectivePort(_ url: URL) -> Int? {
    if let port = url.port { return port }
    switch url.scheme?.lowercased() {
    case "https": return 443
    case "http": return 80
    default: return nil
    }
  }
}

private final class RejectingRedirectDelegate:
  NSObject,
  URLSessionTaskDelegate,
  @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
