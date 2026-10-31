import ChromiumBridge
import Testing

@Test func webStoreKeepsFullZoomWhenThePageCardFits() {
  #expect(ARCWebStoreFitZoom(1280, 1280) == 1)
  #expect(ARCWebStoreFitZoom(1600, 1249) == 1)
  #expect(ARCWebStoreFitZoom(900, 0) == 1)
}

@Test func webStoreZoomsOutJustEnoughToFitItsMinimumWidth() {
  #expect(ARCWebStoreFitZoom(1000, 1280) == 0.781)
  #expect(ARCWebStoreFitZoom(1100, 1249) == 0.88)
  #expect(ARCWebStoreFitZoom(1000, 1280) * 1280 <= 1000)
}

@Test func webStoreFitZoomStopsAtTheReadableMinimum() {
  #expect(ARCWebStoreFitZoom(600, 1280) == 0.67)
  #expect(ARCWebStoreFitZoom(1, 1280) == 0.67)
}

@Test func webStoreFitZoomIgnoresUnmeasurableViewports() {
  #expect(ARCWebStoreFitZoom(0, 1280) == 1)
  #expect(ARCWebStoreFitZoom(-50, 1280) == 1)
  #expect(ARCWebStoreFitZoom(.nan, 1280) == 1)
  #expect(ARCWebStoreFitZoom(1000, .infinity) == 1)
}
