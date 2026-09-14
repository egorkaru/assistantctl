import Foundation
import PackagePlugin

@main
struct OAuthConfigPlugin: BuildToolPlugin {
  func createBuildCommands(
    context: PluginContext,
    target: any Target
  ) async throws -> [Command] {
    let generator = try context.tool(named: "OAuthConfigGenerator")
    let privateConfiguration = context.package.directoryURL
      .appending(path: ".assistantctl-private/oauth-clients.json")
    let outputDirectory = context.pluginWorkDirectoryURL
    let outputFile = outputDirectory.appending(
      path: "EmbeddedOAuthClientConfiguration.swift"
    )

    return [
      .buildCommand(
        displayName: "Generate embedded OAuth client configuration",
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
