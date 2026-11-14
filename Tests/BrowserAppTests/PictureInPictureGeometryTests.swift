// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import XCTest

@testable import ArcusisBrowser

final class PictureInPictureGeometryTests: XCTestCase {
  private typealias Geometry = PictureInPictureGeometry

  func testVerticalEdgesResizeWhileHoldingTheOppositeEdge() {
    let frame = CGRect(x: 100, y: 100, width: 320, height: 180)
    let minimum = CGSize(width: 200, height: 100)
    let maximum = CGSize(width: 1000, height: 600)

    let top = Geometry.resized(
      frame, edges: .top, by: CGSize(width: 0, height: 45), minimum: minimum, maximum: maximum)
    XCTAssertEqual(top.height, 225, accuracy: 0.001)
    XCTAssertEqual(top.minY, frame.minY)
    XCTAssertEqual(top.minX, frame.minX)

    let bottom = Geometry.resized(
      frame, edges: .bottom, by: CGSize(width: 0, height: 45), minimum: minimum,
      maximum: maximum)
    XCTAssertEqual(bottom.height, 135, accuracy: 0.001)
    XCTAssertEqual(bottom.maxY, frame.maxY, accuracy: 0.001)
  }

  func testCornerResizeUsesVerticalGrowthWhenItDominates() {
    let frame = CGRect(x: 100, y: 100, width: 320, height: 180)
    let resized = Geometry.resized(
      frame, edges: [.right, .top], by: CGSize(width: 10, height: 60),
      minimum: CGSize(width: 200, height: 100), maximum: CGSize(width: 1000, height: 600))

    XCTAssertEqual(resized.width, 426.6667, accuracy: 0.001)
    XCTAssertEqual(resized.height, 240, accuracy: 0.001)
    XCTAssertEqual(resized.minX, frame.minX)
    XCTAssertEqual(resized.minY, frame.minY)
  }

  func testResizeWithoutUsableFrameOrEdgesIsANoop() {
    let frame = CGRect(x: 10, y: 20, width: 0, height: 180)
    let size = CGSize(width: 100, height: 100)
    let limits = CGSize(width: 800, height: 600)

    XCTAssertEqual(
      Geometry.resized(
        frame, edges: .left, by: CGSize(width: 20, height: 0), minimum: size,
        maximum: limits), frame)

    let normalFrame = CGRect(x: 10, y: 20, width: 320, height: 180)
    XCTAssertEqual(
      Geometry.resized(
        normalFrame, edges: [], by: CGSize(width: 20, height: 0), minimum: size,
        maximum: limits), normalFrame)
  }
}
