// swift-tools-version: 6.2

import PackageDescription
import Foundation

let useStaticTDLib = ProcessInfo.processInfo.environment["ASSISTANTCTL_STATIC_TDLIB"] == "1"
let environment = ProcessInfo.processInfo.environment
let quietTDLib = environment["ASSISTANTCTL_QUIET_TDLIB"] != nil
let quietGmail = environment["ASSISTANTCTL_QUIET_GMAIL"] != nil
let quietMicrosoft = environment["ASSISTANTCTL_QUIET_MICROSOFT"] != nil

let package = Package(
  name: "AssistantCtl",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "assistantctl", targets: ["AssistantCLI"]),
    .library(name: "AssistantMessages", targets: ["AssistantMessages"]),
    .library(name: "AssistantStorage", targets: ["AssistantStorage"]),
    .library(name: "AssistantSecurity", targets: ["AssistantSecurity"]),
    .library(name: "AssistantOAuth", targets: ["AssistantOAuth"]),
    .library(name: "AssistantIngestion", targets: ["AssistantIngestion"]),
    .library(name: "TelegramConnector", targets: ["TelegramConnector"]),
    .library(name: "EmailConnector", targets: ["EmailConnector"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-argument-parser",
      from: "1.8.2"
    ),
    .package(
      url: "https://github.com/groue/GRDB.swift.git",
      from: "7.10.0"
    ),
    .package(
      url: "https://github.com/modelcontextprotocol/swift-sdk.git",
      from: "0.12.1"
    ),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
  ],
  targets: [
    .systemLibrary(
      name: "CTDLib",
      pkgConfig: useStaticTDLib ? nil : "tdjson",
      providers: [.brew(["tdlib"])]
    ),
    .target(name: "AssistantJSON"),
    .target(name: "AssistantMessages"),
    .target(
      name: "AssistantStorage",
      dependencies: [
        "AssistantMessages",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .target(
      name: "AssistantSecurity",
      linkerSettings: [.linkedFramework("Security")]
    ),
    .target(
      name: "AssistantOAuth",
      dependencies: ["AssistantSecurity"],
      swiftSettings: (quietGmail ? [.define("ASSISTANTCTL_QUIET_GMAIL")] : [])
        + (quietMicrosoft ? [.define("ASSISTANTCTL_QUIET_MICROSOFT")] : []),
      linkerSettings: [.linkedFramework("AppKit")],
      plugins: ["OAuthConfigPlugin"]
    ),
    .target(
      name: "AssistantIngestion",
      dependencies: ["AssistantMessages", "AssistantStorage", "EmailConnector"]
    ),
    .target(
      name: "TelegramConnector",
      dependencies: ["AssistantJSON", "AssistantMessages", "CTDLib"],
      swiftSettings: quietTDLib ? [.define("ASSISTANTCTL_QUIET_TDLIB")] : [],
      plugins: ["TelegramConfigPlugin"]
    ),
    .target(
      name: "EmailConnector",
      dependencies: ["AssistantMessages", "AssistantOAuth"],
      swiftSettings: (quietGmail ? [.define("ASSISTANTCTL_QUIET_GMAIL")] : [])
        + (quietMicrosoft ? [.define("ASSISTANTCTL_QUIET_MICROSOFT")] : [])
    ),
    .executableTarget(
      name: "AssistantCLI",
      dependencies: [
        "AssistantMessages",
        "AssistantStorage",
        "AssistantSecurity",
        "AssistantOAuth",
        "AssistantIngestion",
        "TelegramConnector",
        "EmailConnector",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
      ],
      linkerSettings: [.linkedFramework("CoreImage")]
    ),
    .testTarget(
      name: "AssistantMessagesTests",
      dependencies: [
        "AssistantMessages",
        "AssistantStorage",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .testTarget(
      name: "TelegramConnectorTests",
      dependencies: [
        "AssistantJSON",
        "TelegramConnector",
      ]
    ),
    .testTarget(
      name: "EmailConnectorTests",
      dependencies: [
        "AssistantMessages",
        "AssistantOAuth",
        "EmailConnector",
      ]
    ),
    .testTarget(
      name: "AssistantOAuthTests",
      dependencies: [
        "AssistantOAuth",
      ]
    ),
    .testTarget(
      name: "AssistantIngestionTests",
      dependencies: [
        "AssistantIngestion",
        "AssistantMessages",
        "AssistantStorage",
        "EmailConnector",
      ]
    ),
    .testTarget(
      name: "AssistantCLITests",
      dependencies: ["AssistantCLI"],
      linkerSettings: [.linkedFramework("Vision")]
    ),
    .executableTarget(
      name: "OAuthConfigGenerator",
      path: "Tools/OAuthConfigGenerator"
    ),
    .plugin(
      name: "OAuthConfigPlugin",
      capability: .buildTool(),
      dependencies: ["OAuthConfigGenerator"]
    ),
    .executableTarget(
      name: "TelegramConfigGenerator",
      path: "Tools/TelegramConfigGenerator"
    ),
    .plugin(
      name: "TelegramConfigPlugin",
      capability: .buildTool(),
      dependencies: ["TelegramConfigGenerator"]
    ),
  ]
)
