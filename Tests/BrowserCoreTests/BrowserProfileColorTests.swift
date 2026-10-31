import BrowserCore
import Foundation
import Testing

struct BrowserProfileColorTests {
  @Test func olderProfilesDecodeWithoutColor() throws {
    let id = UUID()
    let data = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Personal\"}".utf8)
    let profile = try JSONDecoder().decode(BrowserProfile.self, from: data)

    #expect(profile.id == id)
    #expect(profile.name == "Personal")
    #expect(profile.tint == nil)
    #expect(profile.customRGB == nil)
  }

  @Test func profilePresetAndCustomColorsRoundTrip() throws {
    let profile = BrowserProfile(
      name: "Work", tint: .ocean, customRGB: SpaceRGBColor(red: 18, green: 52, blue: 86))
    let data = try JSONEncoder().encode(profile)

    #expect(try JSONDecoder().decode(BrowserProfile.self, from: data) == profile)
  }
}
