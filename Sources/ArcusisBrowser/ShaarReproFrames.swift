// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import CoreVideo
import Foundation
import ImageIO

struct ShaarReproJPEGFrame: Sendable {
  let jpeg: Data
  let receivedAt: Date
}

private enum ShaarReproJPEG {
  static func image(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
}

@MainActor final class ShaarReproFrames {
  private let maxAge: TimeInterval = 30
  private let maxCount = 150
  private let maxBytes = 48 * 1024 * 1024
  private let maxFrameBytes = 256 * 1024
  private var target: SiteControlTarget?
  private var frames: [ShaarReproJPEGFrame] = []
  private var bytes = 0

  var isActive: Bool { target != nil }

  func start(for target: SiteControlTarget) {
    stop()
    self.target = target
  }

  func stop() {
    target = nil
    frames.removeAll()
    bytes = 0
  }

  func record(_ jpeg: Data, for target: SiteControlTarget, at now: Date = Date()) {
    guard self.target == target, jpeg.count <= maxFrameBytes,
      jpeg.starts(with: [0xff, 0xd8]), jpeg.suffix(2).elementsEqual([0xff, 0xd9]),
      let image = ShaarReproJPEG.image(jpeg), image.width > 0, image.height > 0,
      image.width <= 1280, image.height <= 720,
      frames.last.map({ now.timeIntervalSince($0.receivedAt) >= 0.2 }) ?? true
    else { return }
    frames.append(ShaarReproJPEGFrame(jpeg: jpeg, receivedAt: now))
    bytes += jpeg.count
    prune(at: now)
  }

  func snapshot(at now: Date = Date()) -> [ShaarReproJPEGFrame] {
    prune(at: now)
    return frames
  }

  func encode(at now: Date = Date()) async throws -> Data {
    let recent = snapshot(at: now)
    guard !recent.isEmpty else { throw ShaarReproFrameError.unavailable }
    return try await ShaarReproVideoEncoder.encode(recent)
  }

  private func prune(at now: Date) {
    while let first = frames.first,
      first.receivedAt < now.addingTimeInterval(-maxAge)
        || frames.count > maxCount || bytes > maxBytes
    {
      bytes -= first.jpeg.count
      frames.removeFirst()
    }
  }

}

private enum ShaarReproFrameError: Error {
  case unavailable
  case encoding
}

@MainActor private enum ShaarReproVideoEncoder {
  static func encode(_ frames: [ShaarReproJPEGFrame]) async throws -> Data {
    guard let first = ShaarReproJPEG.image(frames[0].jpeg)
    else { throw ShaarReproFrameError.encoding }
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "page.mp4")
    let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: first.width,
        AVVideoHeightKey: first.height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000],
      ])
    input.expectsMediaDataInRealTime = false
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
      kCVPixelBufferWidthKey as String: first.width,
      kCVPixelBufferHeightKey as String: first.height,
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input, sourcePixelBufferAttributes: attributes)
    guard writer.canAdd(input) else { throw ShaarReproFrameError.encoding }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? ShaarReproFrameError.encoding }
    writer.startSession(atSourceTime: .zero)
    let start = frames[0].receivedAt
    for frame in frames {
      guard let current = ShaarReproJPEG.image(frame.jpeg)
      else { throw ShaarReproFrameError.encoding }
      let deadline = Date().addingTimeInterval(5)
      while !input.isReadyForMoreMediaData {
        guard writer.status == .writing, Date() < deadline
        else { throw writer.error ?? ShaarReproFrameError.encoding }
        try await Task.sleep(for: .milliseconds(10))
      }
      let buffer = try pixelBuffer(current)
      let time = CMTime(seconds: max(0, frame.receivedAt.timeIntervalSince(start)), preferredTimescale: 600)
      guard adaptor.append(buffer, withPresentationTime: time) else {
        throw writer.error ?? ShaarReproFrameError.encoding
      }
    }
    input.markAsFinished()
    await withCheckedContinuation { continuation in
      writer.finishWriting { continuation.resume() }
    }
    guard writer.status == .completed else { throw writer.error ?? ShaarReproFrameError.encoding }
    let result = try Data(contentsOf: file)
    guard result.count <= 48 * 1024 * 1024 else { throw ShaarReproFrameError.encoding }
    return result
  }

  private static func pixelBuffer(_ image: CGImage) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32ARGB,
      [kCVPixelBufferCGImageCompatibilityKey: true,
       kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw ShaarReproFrameError.encoding }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
    else { throw ShaarReproFrameError.encoding }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return buffer
  }
}
