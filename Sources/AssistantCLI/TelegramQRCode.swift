import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TelegramConnector

func renderTelegramQRCode(_ link: String) throws -> String {
  let filter = CIFilter.qrCodeGenerator()
  filter.message = Data(link.utf8)
  filter.correctionLevel = "M"
  guard let image = filter.outputImage else {
    throw TelegramConnectorError.invalidResponse("Could not generate a Telegram QR code")
  }

  let width = Int(image.extent.width)
  let height = Int(image.extent.height)
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  pixels.withUnsafeMutableBytes { buffer in
    CIContext().render(
      image,
      toBitmap: buffer.baseAddress!,
      rowBytes: width * 4,
      bounds: image.extent,
      format: .RGBA8,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )
  }

  let margin = 4
  let columns = width + margin * 2
  let rows = height + margin * 2
  func isDark(_ column: Int, _ row: Int) -> Bool {
    guard (margin..<(margin + width)).contains(column),
          (margin..<(margin + height)).contains(row)
    else { return false }
    let x = column - margin
    let y = height - 1 - (row - margin)
    return pixels[(y * width + x) * 4] < 128
  }

  var lines: [String] = []
  for row in stride(from: 0, to: rows, by: 2) {
    var line = "\u{001B}[30;47m"
    for column in 0..<columns {
      switch (isDark(column, row), isDark(column, row + 1)) {
      case (true, true): line.append("█")
      case (true, false): line.append("▀")
      case (false, true): line.append("▄")
      case (false, false): line.append(" ")
      }
    }
    line += "\u{001B}[0m"
    lines.append(line)
  }
  return lines.joined(separator: "\n")
}
