import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
  FileHandle.standardError.write(
    Data("usage: OAuthConfigGenerator INPUT OUTPUT_DIRECTORY\n".utf8)
  )
  exit(64)
}

let inputURL = URL(fileURLWithPath: arguments[1])
let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
let outputURL = outputDirectory.appending(path: "EmbeddedOAuthClientConfiguration.swift")
let fileManager = FileManager.default
try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let base64: String?
if fileManager.fileExists(atPath: inputURL.path) {
  let data = try Data(contentsOf: inputURL)
  _ = try JSONSerialization.jsonObject(with: data)
  base64 = data.base64EncodedString()
} else {
  base64 = nil
}

let value = base64.map { "\"\($0)\"" } ?? "nil"
let source = """
  import Foundation

  public enum EmbeddedOAuthClientConfiguration {
    public static let jsonBase64: String? = \(value)
  }

  """
try Data(source.utf8).write(to: outputURL, options: .atomic)
