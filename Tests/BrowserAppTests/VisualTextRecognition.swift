// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Vision OCR for component captures. CI windows render at 1x, where macOS 27 misreads
/// small text, so captures are upscaled before recognition. Bounding boxes stay normalized.
enum VisualTextRecognition {
  static func observations(in url: URL) throws -> [VNRecognizedTextObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: try upscaledImage(at: url)).perform([request])
    return request.results ?? []
  }

  static func lines(in url: URL) throws -> [String] {
    try observations(in: url).compactMap { $0.topCandidates(1).first?.string }
  }

  private static func upscaledImage(at url: URL) throws -> CGImage {
    let scale = 2
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let context = CGContext(
        data: nil, width: image.width * scale, height: image.height * scale,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw VisualTextRecognitionError.unreadableImage }
    context.interpolationQuality = .high
    context.draw(
      image, in: CGRect(x: 0, y: 0, width: image.width * scale, height: image.height * scale))
    guard let upscaled = context.makeImage() else {
      throw VisualTextRecognitionError.unreadableImage
    }
    return upscaled
  }
}

enum VisualTextRecognitionError: Error {
  case unreadableImage
}
