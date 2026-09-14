import Foundation

private struct TelegramAppFile: Decodable {
  let version: Int
  let apiId: Int
  let apiHash: String

  private enum CodingKeys: String, CodingKey {
    case version, apiId, apiHash
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard let version = try? values.decode(Int.self, forKey: .version) else {
      throw GeneratorError.invalid("invalid version")
    }
    guard let apiId = try? values.decode(Int.self, forKey: .apiId) else {
      throw GeneratorError.invalid("invalid apiId")
    }
    guard let apiHash = try? values.decode(String.self, forKey: .apiHash) else {
      throw GeneratorError.invalid("invalid apiHash")
    }
    self.version = version
    self.apiId = apiId
    self.apiHash = apiHash
  }
}

private func validate(_ data: Data) throws {
  let configuration: TelegramAppFile
  do {
    configuration = try JSONDecoder().decode(TelegramAppFile.self, from: data)
  } catch let error as GeneratorError {
    throw error
  } catch {
    throw GeneratorError.invalid("malformed JSON")
  }

  guard configuration.version == 1 else {
    throw GeneratorError.invalid("unsupported version; expected 1")
  }
  guard configuration.apiId > 0 else {
    throw GeneratorError.invalid("apiId must be a positive integer")
  }
  guard !configuration.apiHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw GeneratorError.invalid("apiHash must not be empty")
  }
}

private enum GeneratorError: Error, LocalizedError {
  case invalid(String)

  var errorDescription: String? {
    switch self {
    case .invalid(let detail): "Invalid Telegram app configuration: \(detail)"
    }
  }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
  FileHandle.standardError.write(Data("usage: TelegramConfigGenerator INPUT OUTPUT_DIRECTORY\n".utf8))
  exit(64)
}

let inputURL = URL(fileURLWithPath: arguments[1])
let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
let outputURL = outputDirectory.appending(path: "EmbeddedTelegramAppConfiguration.swift")
let fileManager = FileManager.default
try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let base64: String?
if fileManager.fileExists(atPath: inputURL.path) {
  let data = try Data(contentsOf: inputURL)
  try validate(data)
  base64 = data.base64EncodedString()
} else {
  base64 = nil
}

let value = base64.map { "\"\($0)\"" } ?? "nil"
let source = """
  import Foundation

  public enum EmbeddedTelegramAppConfiguration {
    public static let jsonBase64: String? = \(value)
  }

  """
try Data(source.utf8).write(to: outputURL, options: .atomic)
