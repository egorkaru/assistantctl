import CoreGraphics
import Foundation
@testable import AssistantCLI
import Testing
import Vision

@Test("Terminal QR code is scannable")
func terminalQRCodeIsScannable() throws {
  let link = "tg://login?token=dGVzdC1sb2dpbi10b2tlbg"
  let output = try renderTelegramQRCode(link)
  let lines = output.split(separator: "\n")
  let prefix = "\u{001B}[30;47m"
  let suffix = "\u{001B}[0m"
  let width = try #require(lines.first?.count).advanced(by: -(prefix.count + suffix.count))
  let height = lines.count * 2
  var pixels = [UInt8](repeating: 255, count: width * height)

  for (lineIndex, line) in lines.enumerated() {
    let text = String(line)
    #expect(text.hasPrefix(prefix) && text.hasSuffix(suffix))
    let modules = text.dropFirst(prefix.count).dropLast(suffix.count)
    for (column, module) in modules.enumerated() {
      let topDark = module == "█" || module == "▀"
      let bottomDark = module == "█" || module == "▄"
      pixels[(lineIndex * 2) * width + column] = topDark ? 0 : 255
      pixels[(lineIndex * 2 + 1) * width + column] = bottomDark ? 0 : 255
    }
  }

  let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
  let image = try #require(CGImage(
    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
  ))
  let request = VNDetectBarcodesRequest()
  request.symbologies = [.qr]
  try VNImageRequestHandler(cgImage: image).perform([request])

  #expect(request.results?.first?.payloadStringValue == link)
}
