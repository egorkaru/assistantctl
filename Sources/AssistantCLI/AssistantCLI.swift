import ArgumentParser
import AssistantIngestion
import AssistantMessages
import AssistantOAuth
import AssistantSecurity
import AssistantStorage
import EmailConnector
import Foundation
import TelegramConnector

@main
struct AssistantCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "assistantctl",
    abstract: "Read-only local message cache for Telegram, Gmail, and Microsoft Mail.",
    subcommands: [Sources.self, Messages.self, Telegram.self, Email.self, MCPCommands.self]
  )
}

struct MCPCommands: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp",
    abstract: "Manage local read-only MCP access.",
    subcommands: [Token.self, Stdio.self, Serve.self]
  )

  struct Token: ParsableCommand {
    @Flag(name: .long, help: "Replace the HTTP bearer token and print the new value.")
    var rotate = false

    func run() throws {
      let secrets = KeychainSecretStore()
      if rotate {
        try secrets.set(UUID().uuidString + UUID().uuidString, for: CredentialKey.mcpBearerToken)
      }
      print(try secrets.valueOrCreate(for: CredentialKey.mcpBearerToken))
    }
  }
}

struct Sources: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List supported read-only sources."
  )

  func run() throws {
    try printJSON([
      MessageSource(id: "telegram", kind: .telegram, displayName: "Telegram"),
      MessageSource(id: "gmail", kind: .gmail, displayName: "Gmail"),
      MessageSource(id: "microsoft", kind: .microsoft, displayName: "Microsoft Mail"),
    ])
  }
}

struct Messages: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Inspect the local read-only message cache.",
    subcommands: [List.self, Get.self, Search.self]
  )

  struct List: AsyncParsableCommand {
    @Option(name: .long) var source: String?
    @Option(name: .long) var conversation: String?
    @Option(name: .long) var limit = 50

    func run() async throws {
      let database = try openDatabase()
      try await printJSON(
        database.list(sourceID: source, conversationID: conversation, limit: limit)
      )
    }
  }

  struct Get: AsyncParsableCommand {
    @Argument var id: String

    func run() async throws {
      let database = try openDatabase()
      guard let message = try await database.message(id: id) else {
        throw ValidationError("Message not found: \(id)")
      }
      try printJSON(message)
    }
  }

  struct Search: AsyncParsableCommand {
    @Argument var query: String
    @Option(name: .long) var limit = 50

    func run() async throws {
      let database = try openDatabase()
      try await printJSON(database.search(query: query, limit: limit))
    }
  }
}

struct Telegram: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Authorize and ingest Telegram through TDLib's read-only policy.",
    subcommands: [Login.self, Chats.self, Sync.self, Backfill.self, Watch.self]
  )

  struct Login: AsyncParsableCommand {
    @Option(name: .long) var apiID: Int?
    @Option(name: .long) var apiHash: String?
    @Option(name: .long) var phone: String?
    @Flag(name: .long, help: "Log in by scanning a QR code from an authorized Telegram app.")
    var qr = false

    func run() async throws {
      if qr {
        guard phone == nil else { throw ValidationError("--qr and --phone cannot be used together") }
        let connector = try makeTelegramConnector(apiID: apiID, apiHash: apiHash)
        try await connector.authorizeWithQRCode(
          onLink: { link in
            writeStatus("Scan the current QR code in an authorized Telegram app:")
            writeStatus(try renderTelegramQRCode(link))
          },
          password: { try prompt("Telegram 2FA password: ") }
        )
        await connector.close()
        writeStatus("Telegram authorization is ready.")
        return
      }
      let connector = try await authorizedTelegram(
        apiID: apiID,
        apiHash: apiHash,
        phone: phone
      )
      await connector.close()
      writeStatus("Telegram authorization is ready.")
    }
  }

  struct Chats: AsyncParsableCommand {
    @Option(name: .long) var apiID: Int?
    @Option(name: .long) var apiHash: String?

    func run() async throws {
      let connector = try await connectedTelegram(apiID: apiID, apiHash: apiHash)
      try await printJSON(connector.conversations())
    }
  }

  struct Sync: AsyncParsableCommand {
    @Option(name: .long) var apiID: Int?
    @Option(name: .long) var apiHash: String?
    @Option(name: .long) var limit = 100

    func run() async throws {
      let connector = try await connectedTelegram(apiID: apiID, apiHash: apiHash)
      let result = try await MessageIngestionService(database: openDatabase()).sync(
        connector: connector,
        perConversationLimit: limit
      )
      try printJSON(result)
    }
  }

  struct Watch: AsyncParsableCommand {
    @Option(name: .long) var apiID: Int?
    @Option(name: .long) var apiHash: String?

    func run() async throws {
      let connector = try await connectedTelegram(apiID: apiID, apiHash: apiHash)
      writeStatus("Watching Telegram; press Control-C to stop.")
      try await MessageIngestionService(database: openDatabase()).watch(connector: connector)
    }
  }

  struct Backfill: AsyncParsableCommand {
    @Option(name: .long) var conversation: String
    @Option(name: .long) var limit: Int
    @Option(name: .long) var apiID: Int?
    @Option(name: .long) var apiHash: String?

    func run() async throws {
      let connector = try await connectedTelegram(apiID: apiID, apiHash: apiHash)
      let result = try await MessageIngestionService(database: openDatabase()).backfill(
        connector: connector, conversationID: conversation, limit: limit
      )
      try printJSON(result)
    }
  }
}

struct Email: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Ingest email using provider read-only OAuth scopes.",
    subcommands: [
      Gmail.self,
      Microsoft.self,
      GmailSync.self,
      MicrosoftSync.self,
      GmailWatch.self,
      MicrosoftWatch.self,
    ]
  )

  struct Gmail: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Authorize and ingest Gmail with gmail.readonly.",
      subcommands: [Login.self, Status.self, Sync.self, Backfill.self, Watch.self, Logout.self]
    )

    struct Login: AsyncParsableCommand {
      @Option(name: .long, help: "Override the embedded OAuth client JSON.")
      var oauthConfig: String?

      func run() async throws {
        try await loginEmail(provider: .gmail, oauthConfig: oauthConfig)
      }
    }

    struct Status: AsyncParsableCommand {
      func run() async throws { try await printEmailStatus(provider: .gmail) }
    }

    struct Sync: AsyncParsableCommand {
      @Option(name: .long, help: "Gmail access token; saved in Keychain.")
      var accessToken: String?
      @Option(name: .long) var limit = 100

      func run() async throws { try await syncGmail(accessToken: accessToken, limit: limit) }
    }

    struct Watch: AsyncParsableCommand {
      @Option(name: .long, help: "Gmail access token; saved in Keychain.")
      var accessToken: String?

      func run() async throws { try await watchGmail(accessToken: accessToken) }
    }

    struct Backfill: AsyncParsableCommand {
      @Option(name: .long) var limit: Int

      func run() async throws {
        let result = try await MessageIngestionService(database: openDatabase()).backfill(
          connector: gmailConnector(accessToken: nil),
          conversationID: "gmail:inbox", limit: limit
        )
        try printJSON(result)
      }
    }

    struct Logout: AsyncParsableCommand {
      func run() async throws { try await logoutEmail(provider: .gmail) }
    }
  }

  struct Microsoft: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Authorize and ingest Microsoft Mail with delegated Mail.Read.",
      subcommands: [Login.self, Status.self, Sync.self, Backfill.self, Watch.self, Logout.self]
    )

    struct Login: AsyncParsableCommand {
      @Option(name: .long, help: "Override the embedded OAuth client JSON.")
      var oauthConfig: String?

      func run() async throws {
        try await loginEmail(provider: .microsoft, oauthConfig: oauthConfig)
      }
    }

    struct Status: AsyncParsableCommand {
      func run() async throws { try await printEmailStatus(provider: .microsoft) }
    }

    struct Sync: AsyncParsableCommand {
      @Option(name: .long, help: "Microsoft access token; saved in Keychain.")
      var accessToken: String?
      @Option(name: .long) var limit = 100

      func run() async throws { try await syncMicrosoft(accessToken: accessToken, limit: limit) }
    }

    struct Watch: AsyncParsableCommand {
      @Option(name: .long, help: "Microsoft access token; saved in Keychain.")
      var accessToken: String?

      func run() async throws { try await watchMicrosoft(accessToken: accessToken) }
    }

    struct Backfill: AsyncParsableCommand {
      @Option(name: .long) var limit: Int

      func run() async throws {
        let result = try await MessageIngestionService(database: openDatabase()).backfill(
          connector: microsoftConnector(accessToken: nil),
          conversationID: "microsoft:inbox", limit: limit
        )
        try printJSON(result)
      }
    }

    struct Logout: AsyncParsableCommand {
      func run() async throws { try await logoutEmail(provider: .microsoft) }
    }
  }

  struct GmailSync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Deprecated alias for `gmail sync`."
    )

    @Option(name: .long, help: "Gmail access token; saved in Keychain.")
    var accessToken: String?
    @Option(name: .long) var limit = 100

    func run() async throws {
      writeStatus("Warning: `gmail-sync` is deprecated; use `gmail sync`.")
      try await syncGmail(accessToken: accessToken, limit: limit)
    }
  }

  struct MicrosoftSync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Deprecated alias for `microsoft sync`."
    )

    @Option(name: .long, help: "Microsoft access token; saved in Keychain.")
    var accessToken: String?
    @Option(name: .long) var limit = 100

    func run() async throws {
      writeStatus("Warning: `microsoft-sync` is deprecated; use `microsoft sync`.")
      try await syncMicrosoft(accessToken: accessToken, limit: limit)
    }
  }

  struct GmailWatch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Deprecated alias for `gmail watch`."
    )

    @Option(name: .long, help: "Gmail access token; saved in Keychain.")
    var accessToken: String?

    func run() async throws {
      writeStatus("Warning: `gmail-watch` is deprecated; use `gmail watch`.")
      try await watchGmail(accessToken: accessToken)
    }
  }

  struct MicrosoftWatch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Deprecated alias for `microsoft watch`."
    )

    @Option(name: .long, help: "Microsoft access token; saved in Keychain.")
    var accessToken: String?

    func run() async throws {
      writeStatus("Warning: `microsoft-watch` is deprecated; use `microsoft watch`.")
      try await watchMicrosoft(accessToken: accessToken)
    }
  }
}

func openDatabase() throws -> MessageDatabase {
  let paths = ApplicationPaths.standard
  try paths.prepare()
  return try MessageDatabase(path: paths.messagesDatabase.path)
}

func authorizedTelegram(
  apiID: Int?,
  apiHash: String?,
  phone: String?
) async throws -> TelegramMessageConnector {
  let connector = try makeTelegramConnector(apiID: apiID, apiHash: apiHash)
  let resolvedPhone = try resolveOptional(
    supplied: phone, environment: "ASSISTANTCTL_TELEGRAM_PHONE",
    key: CredentialKey.telegramPhone, store: KeychainSecretStore()
  ) ?? ""
  try await connector.authorize(
    using: TelegramAuthentication(
      phoneNumber: resolvedPhone,
      onCodeDelivery: { delivery in
        writeStatus("Telegram code delivery: \(delivery.method).")
        if let next = delivery.nextMethod {
          writeStatus("Next delivery: \(next). Enter /resend if no code arrives; Telegram requires up to \(delivery.timeout) seconds before resending.")
        } else {
          writeStatus("Telegram has not offered another delivery method.")
        }
      },
      code: { try prompt("Telegram code: ") },
      password: { try prompt("Telegram 2FA password: ") }
    )
  )
  return connector
}

func connectedTelegram(apiID: Int?, apiHash: String?) async throws -> TelegramMessageConnector {
  let connector = try makeTelegramConnector(apiID: apiID, apiHash: apiHash)
  try await connector.requireAuthorization()
  return connector
}

func makeTelegramConnector(apiID: Int?, apiHash: String?) throws -> TelegramMessageConnector {
  let secrets = KeychainSecretStore()
  let externalAPIID = try resolveOptional(
    supplied: apiID.map(String.init),
    environment: "ASSISTANTCTL_TELEGRAM_API_ID",
    key: CredentialKey.telegramAPIID,
    store: secrets
  )
  let externalAPIHash = try resolveOptional(
    supplied: apiHash,
    environment: "ASSISTANTCTL_TELEGRAM_API_HASH",
    key: CredentialKey.telegramAPIHash,
    store: secrets
  )
  let app = try TelegramAppConfigurationLoader().resolve(
    externalAPIID: externalAPIID,
    externalAPIHash: externalAPIHash
  )
  let paths = ApplicationPaths.standard
  try paths.prepare()
  return TelegramMessageConnector(
    configuration: TelegramConfiguration(
      apiID: app.apiID,
      apiHash: app.apiHash,
      databaseDirectory: paths.telegramDatabase,
      filesDirectory: paths.telegramFiles,
      databaseEncryptionKey: try secrets.valueOrCreate(for: CredentialKey.telegramDatabaseKey)
    )
  )
}

private func loginEmail(provider: OAuthProvider, oauthConfig: String?) async throws {
  let (configuration, source) = try OAuthConfigurationLoader().loadProvider(
    provider,
    explicitPath: oauthConfig
  )
  writeStatus("Opening the system browser for \(provider.displayName) authorization...")
  _ = try await OAuthLoginService(sessionStore: KeychainOAuthSessionStore()).login(
    provider: provider,
    clientConfiguration: configuration,
    configurationSource: source
  )
  try KeychainSecretStore().deleteValue(for: emailAccessTokenKey(for: provider))
  writeStatus("\(provider.displayName) authorization is ready.")
}

private func printEmailStatus(provider: OAuthProvider) async throws {
  let session = try await KeychainOAuthSessionStore().session(for: provider)
  let hasStoredToken = try KeychainSecretStore().value(for: emailAccessTokenKey(for: provider)) != nil
  try printJSON(OAuthConnectionStatus(
    provider: provider, session: session, hasStoredAccessToken: hasStoredToken
  ))
}

private func logoutEmail(provider: OAuthProvider) async throws {
  try await KeychainOAuthSessionStore().deleteSession(for: provider)
  try KeychainSecretStore().deleteValue(for: emailAccessTokenKey(for: provider))
  writeStatus("Removed the local \(provider.displayName) credentials.")
}

private func syncGmail(accessToken: String?, limit: Int) async throws {
  let result = try await MessageIngestionService(database: openDatabase()).sync(
    connector: gmailConnector(accessToken: accessToken),
    perConversationLimit: limit
  )
  try printJSON(result)
}

private func syncMicrosoft(accessToken: String?, limit: Int) async throws {
  let result = try await MessageIngestionService(database: openDatabase()).sync(
    connector: microsoftConnector(accessToken: accessToken),
    perConversationLimit: limit
  )
  try printJSON(result)
}

private func watchGmail(accessToken: String?) async throws {
  writeStatus("Watching Gmail; press Control-C to stop.")
  try await MessageIngestionService(database: openDatabase()).watch(
    connector: gmailConnector(accessToken: accessToken)
  )
}

private func watchMicrosoft(accessToken: String?) async throws {
  writeStatus("Watching Microsoft Mail; press Control-C to stop.")
  try await MessageIngestionService(database: openDatabase()).watch(
    connector: microsoftConnector(accessToken: accessToken)
  )
}

func gmailConnector(accessToken: String?) -> GmailMessageConnector {
  GmailMessageConnector(
    accessTokenProvider: emailTokenProvider(provider: .gmail, supplied: accessToken)
  )
}

func microsoftConnector(accessToken: String?) -> MicrosoftMailConnector {
  MicrosoftMailConnector(
    accessTokenProvider: emailTokenProvider(provider: .microsoft, supplied: accessToken)
  )
}

private func emailTokenProvider(
  provider: OAuthProvider,
  supplied: String?
) -> any AccessTokenProviding {
  let environmentName: String
  switch provider {
  case .gmail:
    environmentName = "ASSISTANTCTL_GMAIL_ACCESS_TOKEN"
  case .microsoft:
    environmentName = "ASSISTANTCTL_MICROSOFT_ACCESS_TOKEN"
  }
  return EmailAccessTokenProvider(
    supplied: supplied,
    environmentToken: ProcessInfo.processInfo.environment[environmentName],
    key: emailAccessTokenKey(for: provider),
    oauth: OAuthAccessTokenProvider(
      provider: provider,
      sessionStore: KeychainOAuthSessionStore()
    )
  )
}

private func emailAccessTokenKey(for provider: OAuthProvider) -> String {
  switch provider {
  case .gmail: CredentialKey.gmailAccessToken
  case .microsoft: CredentialKey.microsoftAccessToken
  }
}

private struct EmailAccessTokenProvider: AccessTokenProviding {
  let supplied: String?
  let environmentToken: String?
  let key: String
  let oauth: OAuthAccessTokenProvider
  let secrets = KeychainSecretStore()

  func accessToken(forceRefresh: Bool) async throws -> String {
    if let supplied, !supplied.isEmpty {
      try secrets.set(supplied, for: key)
      return supplied
    }
    if let environmentToken, !environmentToken.isEmpty {
      try secrets.set(environmentToken, for: key)
      return environmentToken
    }
    if let stored = try secrets.value(for: key), !stored.isEmpty {
      return stored
    }
    return try await oauth.accessToken(forceRefresh: forceRefresh)
  }
}

private func resolve(
  supplied: String?,
  environment: String,
  key: String,
  store: KeychainSecretStore
) throws -> String {
  guard let value = try resolveOptional(
    supplied: supplied, environment: environment, key: key, store: store
  ) else {
    throw ValidationError("Missing credential. Pass it as an option or set \(environment).")
  }
  return value
}

private func resolveOptional(
  supplied: String?,
  environment: String,
  key: String,
  store: KeychainSecretStore
) throws -> String? {
  if let supplied, !supplied.isEmpty {
    try store.set(supplied, for: key)
    return supplied
  }
  if let value = ProcessInfo.processInfo.environment[environment], !value.isEmpty {
    try store.set(value, for: key)
    return value
  }
  if let value = try store.value(for: key), !value.isEmpty {
    return value
  }
  return nil
}

private func prompt(_ label: String) throws -> String {
  writeStatus(label, newline: false)
  guard let value = readLine(), !value.isEmpty else {
    throw ValidationError("A value is required")
  }
  return value
}

private func printJSON<Value: Encodable>(_ value: Value) throws {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

private func writeStatus(_ message: String, newline: Bool = true) {
  FileHandle.standardError.write(Data((message + (newline ? "\n" : "")).utf8))
}
