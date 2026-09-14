import Foundation
import PackagePlugin

@main
struct TelegramConfigPlugin: BuildToolPlugin {
  func createBuildCommands(
    context: PluginContext,
    target: any Target
  ) async throws -> [Command] {
    let generator = try context.tool(named: "TelegramConfigGenerator")
    let privateConfiguration = context.package.directoryURL
      .appending(path: ".assistantctl-private/telegram-app.json")
    let outputDirectory = context.pluginWorkDirectoryURL
    let outputFile = outputDirectory.appending(path: "EmbeddedTelegramAppConfiguration.swift")

    return [
      .buildCommand(
        displayName: "Generate embedded Telegram app configuration",
        executable: generator.url,
        arguments: [privateConfiguration.path, outputDirectory.path],
        inputFiles: FileManager.default.fileExists(atPath: privateConfiguration.path)
          ? [privateConfiguration]
          : [],
        outputFiles: [outputFile]
      )
    ]
  }
}
