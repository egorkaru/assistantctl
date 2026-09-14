import ArgumentParser
import AssistantIngestion
import AssistantMessages
import AssistantOAuth
import AssistantSecurity
import AssistantStorage
import EmailConnector
import Foundation
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix
import TelegramConnector

extension MCPCommands {
  struct Stdio: AsyncParsableCommand {
    func run() async throws {
      let server = await makeMCPServer()
      try await server.start(transport: StdioTransport())
      await server.waitUntilCompleted()
      await server.stop()
    }
  }

  struct Serve: AsyncParsableCommand {
    @Option(name: .long) var port: Int
    @Option(name: .long) var host = "127.0.0.1"

    func run() async throws {
      guard (1...65535).contains(port) else { throw ValidationError("Port must be 1...65535") }
      guard host != "0.0.0.0", host != "::" else {
        throw ValidationError("Specify a concrete interface address for --host")
      }
      let origin = OriginValidator(
        allowedHosts: ["\(host):\(port)"],
        allowedOrigins: ["http://\(host):\(port)"]
      )
      let pipeline = StandardValidationPipeline(validators: [
        origin, AcceptHeaderValidator(mode: .jsonOnly), ContentTypeValidator(),
        ProtocolVersionValidator(),
      ])
      let transport = StatelessHTTPServerTransport(validationPipeline: pipeline)
      let server = await makeMCPServer()
      try await server.start(transport: transport)
      let http = MCPHTTPServer(host: host, port: port, transport: transport)
      do {
        try await http.run()
      } catch {
        await server.stop()
        throw error
      }
      await server.stop()
    }
  }
}

private func makeMCPServer() async -> Server {
  let operations = MCPOperations()
  let server = Server(name: "assistantctl", version: "0.1.0", capabilities: .init(tools: .init()))
  await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: MCPOperations.tools)
  }
  await server.withMethodHandler(CallTool.self) { call in
    do {
      let result = try await operations.call(name: call.name, arguments: call.arguments ?? [:])
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let json = String(decoding: try encoder.encode(result), as: UTF8.self)
      let structured: Value? = result
      return CallTool.Result(
        content: [.text(text: json, annotations: nil, _meta: nil)],
        structuredContent: structured
      )
    } catch let error as MCPToolError {
      return CallTool.Result(
        content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
        isError: true
      )
    } catch {
      return CallTool.Result(
        content: [.text(text: "Operation failed; check server diagnostics", annotations: nil, _meta: nil)],
        isError: true
      )
    }
  }
  return server
}

private actor MCPOperations {
  private let logins = LoginCoordinator()

  static let tools: [Tool] = [
    tool("sources", "List supported providers", [:]),
    tool("connection_status", "Check provider connection without returning credentials",
         ["provider": stringField], required: ["provider"]),
    tool("conversations", "List provider chats or Inbox",
         ["provider": stringField], required: ["provider"]),
    tool("messages_list", "List cached messages",
         ["source": stringField, "conversation": stringField, "limit": integerField]),
    tool("messages_get", "Read a cached message",
         ["id": stringField], required: ["id"]),
    tool("messages_search", "Search cached messages",
         ["query": stringField, "limit": integerField], required: ["query"]),
    tool("sync", "Import all newly arrived provider messages",
         ["provider": stringField], required: ["provider"]),
    tool("backfill", "Import a bounded amount of older history",
         ["provider": stringField, "conversation": stringField, "limit": integerField],
         required: ["provider", "limit"]),
    tool("login_start", "Start human-assisted provider login",
         ["provider": stringField, "api_id": integerField, "api_hash": stringField,
          "phone": stringField, "oauth_config": stringField], required: ["provider"]),
    tool("login_complete", "Submit a requested Telegram code or password",
         ["session_id": stringField, "value": stringField], required: ["session_id", "value"]),
    tool("login_status", "Check a pending login",
         ["session_id": stringField], required: ["session_id"]),
  ]

  private static let stringField: Value = ["type": "string"]
  private static let integerField: Value = ["type": "integer"]

  private static func tool(
    _ name: String, _ description: String, _ properties: [String: Value],
    required: [String] = []
  ) -> Tool {
    Tool(name: name, description: description, inputSchema: [
      "type": "object", "properties": .object(properties),
      "required": .array(required.map(Value.string)), "additionalProperties": false,
    ])
  }

  func call(name: String, arguments: [String: Value]) async throws -> Value {
    switch name {
    case "sources":
      return ["items": try Value(sourceList)]
    case "connection_status":
      let provider = try providerID(arguments)
      if provider == "telegram" {
        do {
          _ = try await authorizedTelegram(apiID: nil, apiHash: nil, phone: nil,
                                           allowPrompts: false)
          return ["provider": .string(provider), "connected": true]
        } catch {
          return ["provider": .string(provider), "connected": false,
                  "nextAction": "Run login_start"]
        }
      }
      let session = try await KeychainOAuthSessionStore().session(
        for: provider == "gmail" ? .gmail : .microsoft
      )
      return ["provider": .string(provider), "connected": .bool(session != nil)]
    case "conversations":
      let connector = try await connector(for: providerID(arguments))
      return ["items": try Value(await connector.conversations())]
    case "messages_list":
      let database = try openDatabase()
      return ["items": try Value(await database.list(
        sourceID: arguments["source"]?.stringValue,
        conversationID: arguments["conversation"]?.stringValue,
        limit: arguments["limit"]?.intValue ?? 50
      ))]
    case "messages_get":
      let id = try requiredString("id", arguments)
      let database = try openDatabase()
      guard let message = try await database.message(id: id) else {
        throw MCPToolError.messageNotFound
      }
      return try Value(message)
    case "messages_search":
      let database = try openDatabase()
      return ["items": try Value(await database.search(
        query: requiredString("query", arguments),
        limit: arguments["limit"]?.intValue ?? 50
      ))]
    case "sync":
      let connector = try await connector(for: providerID(arguments))
      return try Value(await MessageIngestionService(database: openDatabase()).sync(
        connector: connector
      ))
    case "backfill":
      let provider = try providerID(arguments)
      guard let limit = arguments["limit"]?.intValue else { throw MCPToolError.missing("limit") }
      let conversation = provider == "telegram"
        ? try requiredString("conversation", arguments) : "\(provider):inbox"
      let source = try await connector(for: provider)
      return try Value(await MessageIngestionService(database: openDatabase()).backfill(
        connector: source, conversationID: conversation, limit: limit
      ))
    case "login_start":
      let provider = try providerID(arguments)
      return try await logins.start(provider: provider, arguments: arguments)
    case "login_complete":
      return try await logins.complete(
        id: requiredString("session_id", arguments),
        value: requiredString("value", arguments)
      )
    case "login_status":
      return try await logins.status(id: requiredString("session_id", arguments))
    default:
      throw MCPToolError.unknownTool
    }
  }

  private func connector(for provider: String) async throws -> any MessageConnector {
    switch provider {
    case "telegram":
      return try await authorizedTelegram(apiID: nil, apiHash: nil, phone: nil,
                                          allowPrompts: false)
    case "gmail": return gmailConnector(accessToken: nil)
    case "microsoft": return microsoftConnector(accessToken: nil)
    default: throw MCPToolError.invalidProvider
    }
  }
}

private let sourceList = [
  MessageSource(id: "telegram", kind: .telegram, displayName: "Telegram"),
  MessageSource(id: "gmail", kind: .gmail, displayName: "Gmail"),
  MessageSource(id: "microsoft", kind: .microsoft, displayName: "Microsoft Mail"),
]

private func providerID(_ arguments: [String: Value]) throws -> String {
  let provider = try requiredString("provider", arguments)
  guard ["telegram", "gmail", "microsoft"].contains(provider) else {
    throw MCPToolError.invalidProvider
  }
  return provider
}

private func requiredString(_ name: String, _ arguments: [String: Value]) throws -> String {
  guard let value = arguments[name]?.stringValue, !value.isEmpty else {
    throw MCPToolError.missing(name)
  }
  return value
}

private enum MCPToolError: Error, LocalizedError {
  case invalidProvider
  case missing(String)
  case messageNotFound
  case unknownTool
  case unknownLogin
  case loginNotWaiting

  var errorDescription: String? {
    switch self {
    case .invalidProvider: "Provider must be telegram, gmail, or microsoft"
    case .missing(let name): "Missing or invalid \(name)"
    case .messageNotFound: "Message not found"
    case .unknownTool: "Unknown tool"
    case .unknownLogin: "Login session not found or expired"
    case .loginNotWaiting: "Login is not waiting for a code or password"
    }
  }
}

private actor LoginCoordinator {
  private struct Session {
    let provider: String
    var state: String
    var action: String
    var continuation: CheckedContinuation<String, any Error>?
    var task: Task<Void, Never>?
  }

  private var sessions: [String: Session] = [:]

  func start(provider: String, arguments: [String: Value]) throws -> Value {
    let id = UUID().uuidString
    sessions[id] = Session(provider: provider, state: "pending", action: "starting")
    let task = Task {
      do {
        if provider == "telegram" {
          let connector = try makeTelegramConnector(
            apiID: arguments["api_id"]?.intValue,
            apiHash: arguments["api_hash"]?.stringValue,
            phone: arguments["phone"]?.stringValue
          )
          let phone = try telegramPhone(arguments)
          try await connector.authorize(using: TelegramAuthentication(
            phoneNumber: phone,
            code: { try await self.waitForInput(id: id, action: "telegram_code") },
            password: { try await self.waitForInput(id: id, action: "telegram_password") }
          ))
        } else {
          let oauthProvider: OAuthProvider = provider == "gmail" ? .gmail : .microsoft
          let (configuration, source) = try OAuthConfigurationLoader().loadProvider(
            oauthProvider, explicitPath: arguments["oauth_config"]?.stringValue
          )
          self.setAction(id: id, action: "Complete browser consent on this Mac")
          _ = try await OAuthLoginService(sessionStore: KeychainOAuthSessionStore()).login(
            provider: oauthProvider, clientConfiguration: configuration,
            configurationSource: source
          )
        }
        self.finish(id: id, state: "connected")
      } catch {
        self.finish(id: id, state: "failed")
      }
    }
    sessions[id]?.task = task
    Task {
      try? await Task.sleep(for: .seconds(300))
      self.expire(id: id)
      try? await Task.sleep(for: .seconds(60))
      self.sessions.removeValue(forKey: id)
    }
    let action = provider == "telegram"
      ? "Check login_status for Telegram prompt"
      : "Complete browser consent on this Mac; check login_status"
    return ["sessionID": .string(id), "state": "pending", "action": .string(action)]
  }

  func complete(id: String, value: String) throws -> Value {
    guard var session = sessions[id] else { throw MCPToolError.unknownLogin }
    guard let continuation = session.continuation else { throw MCPToolError.loginNotWaiting }
    session.continuation = nil
    session.action = "processing"
    sessions[id] = session
    continuation.resume(returning: value)
    return ["sessionID": .string(id), "state": "pending", "action": "Check login_status"]
  }

  func status(id: String) throws -> Value {
    guard let session = sessions[id] else { throw MCPToolError.unknownLogin }
    return ["sessionID": .string(id), "provider": .string(session.provider),
            "state": .string(session.state), "action": .string(session.action)]
  }

  private func waitForInput(id: String, action: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      guard var session = sessions[id] else {
        continuation.resume(throwing: MCPToolError.unknownLogin)
        return
      }
      session.action = action
      session.continuation = continuation
      sessions[id] = session
    }
  }

  private func setAction(id: String, action: String) {
    sessions[id]?.action = action
  }

  private func finish(id: String, state: String) {
    guard sessions[id]?.state == "pending" else { return }
    sessions[id]?.state = state
    sessions[id]?.action = state
    sessions[id]?.continuation = nil
    sessions[id]?.task = nil
  }

  private func expire(id: String) {
    guard var session = sessions[id], session.state == "pending" else { return }
    session.continuation?.resume(throwing: MCPToolError.unknownLogin)
    session.task?.cancel()
    session.task = nil
    session.continuation = nil
    session.state = "expired"
    session.action = "Start login again"
    sessions[id] = session
  }

  private func telegramPhone(_ arguments: [String: Value]) throws -> String {
    if let phone = arguments["phone"]?.stringValue, !phone.isEmpty { return phone }
    if let phone = ProcessInfo.processInfo.environment["ASSISTANTCTL_TELEGRAM_PHONE"] { return phone }
    if let phone = try KeychainSecretStore().value(for: CredentialKey.telegramPhone) { return phone }
    throw MCPToolError.missing("phone")
  }
}

private struct MCPHTTPServer: Sendable {
  let host: String
  let port: Int
  let transport: StatelessHTTPServerTransport

  func run() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 128)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
          channel.pipeline.addHandler(MCPHTTPHandler(transport: transport))
        }
      }
    do {
      let channel = try await bootstrap.bind(host: host, port: port).get()
      try await channel.closeFuture.get()
      try await group.shutdownGracefully()
    } catch {
      try? await group.shutdownGracefully()
      throw error
    }
  }
}

private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let transport: StatelessHTTPServerTransport
  private var head: HTTPRequestHead?
  private var body: ByteBuffer?

  init(transport: StatelessHTTPServerTransport) { self.transport = transport }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let request):
      head = request
      body = context.channel.allocator.buffer(capacity: 0)
    case .body(var chunk): body?.writeBuffer(&chunk)
    case .end:
      guard let head else { return }
      let bodyData = body.flatMap { buffer -> Data? in
        guard let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes) else { return nil }
        return Data(bytes)
      }
      self.head = nil
      body = nil
      var headers: [String: String] = [:]
      for (name, value) in head.headers { headers[name] = value }
      let request = HTTPRequest(method: head.method.rawValue, headers: headers,
                                body: bodyData, path: String(head.uri.split(separator: "?")[0]))
      nonisolated(unsafe) let ctx = context
      Task { @MainActor in
        let response: HTTPResponse
        if request.path != "/mcp" {
          response = .error(statusCode: 404, .invalidRequest("Not Found"))
        } else if !validToken(request.header("Authorization")) {
          response = .error(statusCode: 401, .invalidRequest("Unauthorized"))
        } else {
          response = await transport.handleRequest(request)
        }
        ctx.eventLoop.execute {
          var responseHead = HTTPResponseHead(
            version: head.version, status: HTTPResponseStatus(statusCode: response.statusCode)
          )
          for (name, value) in response.headers { responseHead.headers.add(name: name, value: value) }
          let bytes = response.bodyData ?? Data()
          responseHead.headers.replaceOrAdd(name: "Content-Length", value: String(bytes.count))
          ctx.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
          if !bytes.isEmpty {
            var buffer = ctx.channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
          }
          ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
      }
    }
  }

  private func validToken(_ header: String?) -> Bool {
    guard let header, header.hasPrefix("Bearer ") else { return false }
    guard let current = try? KeychainSecretStore().valueOrCreate(for: CredentialKey.mcpBearerToken) else {
      return false
    }
    return header.dropFirst(7) == current
  }
}
