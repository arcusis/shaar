import SwiftUI
import Testing

@testable import ArcusisBrowser

struct InspectorDetailsViewTests {
  @Test func selectedComponentRowExposesSelectedAccessibilityTrait() {
    #expect(InspectorComponentRowAccessibility.traits(isSelected: true).contains(.isSelected))
  }

  @Test func unselectedComponentRowDoesNotExposeSelectedAccessibilityTrait() {
    #expect(!InspectorComponentRowAccessibility.traits(isSelected: false).contains(.isSelected))
  }
}
