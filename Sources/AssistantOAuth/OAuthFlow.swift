import AppKit
import CryptoKit
import Darwin
import Foundation

public protocol OAuthBrowserOpening: Sendable {
  func open(_ url: URL) async throws
}

public struct SystemOAuthBrowser: OAuthBrowserOpening {
  public init() {}

  public func open(_ url: URL) async throws {
    let opened = await MainActor.run { NSWorkspace.shared.open(url) }
    guard opened else { throw OAuthError.browserOpenFailed }
  }
}

public struct OAuthCallback: Equatable, Sendable {
  public let code: String?
  public let state: String?
  public let error: String?
  public let errorDescription: String?

  public init(code: String?, state: String?, error: String?, errorDescription: String?) {
    self.code = code
    self.state = state
    self.error = error
    self.errorDescription = errorDescription
  }
}

public protocol OAuthCallbackServing: Sendable {
  var redirectURI: URL { get }
  func waitForCallback(timeout: Duration) async throws -> OAuthCallback
}

public protocol OAuthCallbackServerCreating: Sendable {
  func makeServer(for provider: OAuthProvider) throws -> any OAuthCallbackServing
}

public struct LoopbackOAuthCallbackServerFactory: OAuthCallbackServerCreating {
  public init() {}

  public func makeServer(for provider: OAuthProvider) throws -> any OAuthCallbackServing {
    try LoopbackOAuthCallbackServer(provider: provider)
  }
}

public struct OAuthAuthorizationRequest: Equatable, Sendable {
  public let url: URL
  public let verifier: String
  public let state: String
  public let redirectURI: URL

  public init(url: URL, verifier: String, state: String, redirectURI: URL) {
    self.url = url
    self.verifier = verifier
    self.state = state
    self.redirectURI = redirectURI
  }
}

public enum OAuthAuthorizationRequestBuilder {
  public static func make(
    provider: OAuthProvider,
    client: OAuthProviderClientConfiguration,
    redirectURI: URL,
    verifier: String = PKCE.generateVerifier(),
    state: String = PKCE.randomURLSafeString(byteCount: 32)
  ) -> OAuthAuthorizationRequest {
    let challenge = PKCE.challenge(for: verifier)
    var components = URLComponents(
      url: OAuthProviderMetadata.authorizationEndpoint(for: provider, client: client),
      resolvingAgainstBaseURL: false
    )!
    var queryItems = [
      URLQueryItem(name: "client_id", value: client.clientId),
      URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(
        name: "scope",
        value: OAuthProviderMetadata.scopes(for: provider).joined(separator: " ")
      ),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    switch provider {
    case .gmail:
      queryItems.append(URLQueryItem(name: "access_type", value: "offline"))
      queryItems.append(URLQueryItem(name: "prompt", value: "consent"))
    case .microsoft:
      queryItems.append(URLQueryItem(name: "response_mode", value: "query"))
    }
    components.queryItems = queryItems
    return OAuthAuthorizationRequest(
      url: components.url!,
      verifier: verifier,
      state: state,
      redirectURI: redirectURI
    )
  }
}

public struct OAuthLoginService: Sendable {
  private let sessionStore: any OAuthSessionStoring
  private let httpClient: any OAuthHTTPClient
  private let browser: any OAuthBrowserOpening
  private let serverFactory: any OAuthCallbackServerCreating
  private let now: @Sendable () -> Date

  public init(
    sessionStore: any OAuthSessionStoring,
    httpClient: any OAuthHTTPClient = OAuthURLSessionClient(),
    browser: any OAuthBrowserOpening = SystemOAuthBrowser(),
    serverFactory: any OAuthCallbackServerCreating = LoopbackOAuthCallbackServerFactory(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.sessionStore = sessionStore
    self.httpClient = httpClient
    self.browser = browser
    self.serverFactory = serverFactory
    self.now = now
  }

  @discardableResult
  public func login(
    provider: OAuthProvider,
    clientConfiguration: OAuthProviderClientConfiguration,
    configurationSource: OAuthConfigurationSource
  ) async throws -> OAuthTokenSet {
    let server = try serverFactory.makeServer(for: provider)
    let authorization = OAuthAuthorizationRequestBuilder.make(
      provider: provider,
      client: clientConfiguration,
      redirectURI: server.redirectURI
    )
    try await browser.open(authorization.url)
    let callback = try await server.waitForCallback(timeout: .seconds(300))
    if let error = callback.error {
      let detail = visibleProviderError(
        callback.errorDescription ?? error,
        provider: provider
      ) ?? "consent was not granted"
      throw OAuthError.authorizationDenied(detail)
    }
    guard callback.state == authorization.state else {
      throw OAuthError.callbackStateMismatch
    }
    guard let code = callback.code, !code.isEmpty else {
      throw OAuthError.invalidCallback
    }
    let response = try await OAuthTokenEndpoint.exchange(
      provider: provider,
      clientConfiguration: clientConfiguration,
      code: code,
      verifier: authorization.verifier,
      redirectURI: authorization.redirectURI,
      httpClient: httpClient
    )
    let session = OAuthTokenSet(
      provider: provider,
      accessToken: response.accessToken,
      refreshToken: response.refreshToken,
      expiresAt: now().addingTimeInterval(response.expiresIn),
      clientConfiguration: clientConfiguration,
      configurationSource: configurationSource
    )
    try await sessionStore.save(session)
    return session
  }
}

enum OAuthProviderMetadata {
  static func authorizationEndpoint(
    for provider: OAuthProvider,
    client: OAuthProviderClientConfiguration
  ) -> URL {
    switch provider {
    case .gmail:
      return URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    case .microsoft:
      let tenant = client.tenant ?? "common"
      return URL(
        string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize"
      )!
    }
  }

  static func tokenEndpoint(
    for provider: OAuthProvider,
    client: OAuthProviderClientConfiguration
  ) -> URL {
    switch provider {
    case .gmail:
      URL(string: "https://oauth2.googleapis.com/token")!
    case .microsoft:
      URL(
        string: "https://login.microsoftonline.com/\(client.tenant ?? "common")/oauth2/v2.0/token"
      )!
    }
  }

  static func scopes(for provider: OAuthProvider) -> [String] {
    switch provider {
    case .gmail:
      ["https://www.googleapis.com/auth/gmail.readonly"]
    case .microsoft:
      ["offline_access", "Mail.Read"]
    }
  }
}

public enum PKCE {
  public static func generateVerifier() -> String {
    randomURLSafeString(byteCount: 64)
  }

  public static func challenge(for verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return Data(digest).base64URLEncodedString()
  }

  public static func randomURLSafeString(byteCount: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return Data(bytes).base64URLEncodedString()
  }
}

private final class LoopbackOAuthCallbackServer: OAuthCallbackServing, @unchecked Sendable {
  let redirectURI: URL

  private let socketDescriptor: Int32
  private let lock = NSLock()
  private var closed = false
  private var timedOut = false

  init(provider: OAuthProvider) throws {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw OAuthError.invalidCallback }
    socketDescriptor = descriptor

    var reuseAddress: Int32 = 1
    guard
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_REUSEADDR,
        &reuseAddress,
        socklen_t(MemoryLayout.size(ofValue: reuseAddress))
      ) == 0
    else {
      Darwin.close(descriptor)
      throw OAuthError.invalidCallback
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
      Darwin.close(descriptor)
      throw OAuthError.invalidCallback
    }

    var boundAddress = sockaddr_in()
    var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &boundLength)
      }
    }
    guard nameResult == 0 else {
      Darwin.close(descriptor)
      throw OAuthError.invalidCallback
    }
    let host = provider == .gmail ? "127.0.0.1" : "localhost"
    redirectURI = URL(string: "http://\(host):\(UInt16(bigEndian: boundAddress.sin_port))")!
  }

  deinit {
    closeSocket()
  }

  func waitForCallback(timeout: Duration) async throws -> OAuthCallback {
    defer { closeSocket() }
    return try await withThrowingTaskGroup(of: OAuthCallback.self) { group in
      group.addTask { try self.acceptCallback() }
      group.addTask {
        try await Task.sleep(for: timeout)
        self.closeSocket(timedOut: true)
        throw OAuthError.callbackTimeout
      }
      guard let callback = try await group.next() else {
        throw OAuthError.invalidCallback
      }
      group.cancelAll()
      return callback
    }
  }

  private func acceptCallback() throws -> OAuthCallback {
    let connection = Darwin.accept(socketDescriptor, nil, nil)
    guard connection >= 0 else {
      throw isTimedOut ? OAuthError.callbackTimeout : OAuthError.invalidCallback
    }
    defer { Darwin.close(connection) }

    var buffer = [UInt8](repeating: 0, count: 16_384)
    let count = Darwin.read(connection, &buffer, buffer.count)
    guard count > 0 else { throw OAuthError.invalidCallback }
    let request = String(decoding: buffer.prefix(count), as: UTF8.self)
    guard
      let firstLine = request.split(separator: "\r\n", maxSplits: 1).first,
      firstLine.hasPrefix("GET "),
      let target = firstLine.split(separator: " ").dropFirst().first,
      let callbackURL = URL(string: redirectURI.absoluteString + String(target)),
      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
    else {
      throw OAuthError.invalidCallback
    }

    var values: [String: String] = [:]
    for item in components.queryItems ?? [] {
      values[item.name] = item.value ?? ""
    }
    let body = "<!doctype html><title>assistantctl</title><p>Authorization complete. You can close this tab.</p>"
    let response = "HTTP/1.1 200 OK\r\n"
      + "Content-Type: text/html; charset=utf-8\r\n"
      + "Connection: close\r\n"
      + "Content-Length: \(body.utf8.count)\r\n\r\n"
      + body
    _ = response.withCString { Darwin.write(connection, $0, strlen($0)) }
    return OAuthCallback(
      code: values["code"],
      state: values["state"],
      error: values["error"],
      errorDescription: values["error_description"]
    )
  }

  private var isTimedOut: Bool {
    lock.withLock { timedOut }
  }

  private func closeSocket(timedOut: Bool = false) {
    lock.lock()
    defer { lock.unlock() }
    self.timedOut = self.timedOut || timedOut
    guard !closed else { return }
    closed = true
    Darwin.shutdown(socketDescriptor, SHUT_RDWR)
    Darwin.close(socketDescriptor)
  }
}

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
