// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Test func siteCertificateChainParsesCertificatesAndBoundsNames() throws {
  let details = try #require(
    SiteCertificateChain.read([
      "certificate": [
        "derChain": [testCertificate],
        "subjectAltNames": ["example.com", "", String(repeating: "x", count: 256), "other.test"],
      ] as [String: Any]
    ]))

  #expect(details.certificates.count == 1)
  #expect(details.subjectAltNames == ["example.com", "other.test"])
}

@Test func siteCertificateChainRejectsMalformedOrOversizedChains() {
  #expect(SiteCertificateChain.read(nil) == nil)
  #expect(SiteCertificateChain.read(["certificate": ["derChain": ["not base64"]]]) == nil)
  #expect(SiteCertificateChain.read(["certificate": ["derChain": [testCertificate, "!"]]]) == nil)
  #expect(
    SiteCertificateChain.read([
      "certificate": ["derChain": Array(repeating: testCertificate, count: 17)]
    ]) == nil)
}

private let testCertificate =
  "MIICtjCCAZ4CCQD1Hcawu4ftfTANBgkqhkiG9w0BAQsFADAdMRswGQYDVQQDDBJjaGFpbi10ZXN0LmV4YW1wbGUwHhcNMjYxMTEzMTc1MDI2WhcNMjYxMTE0MTc1MDI2WjAdMRswGQYDVQQDDBJjaGFpbi10ZXN0LmV4YW1wbGUwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDhVNT6es/7MVJuMD+RkLhwi3L0WCth5KfcqNddk4ss0Kh93H+XDUHpWzKs2QFpfwJ6dw2cl4E52Q879YfoaMj1u2xeNHcsI7tiydoTkCk5oAYiftZSE5RkhvBg3BlM6re9gXSkXjMF4jBR0wxLxo8m/G3rMkTylPH1zNiaZ0uASQsAa/C9vgW/fDQ9f6cr82TWf8yNDyhg9mjooX40js652dDHaDIeW+usyESYpwoR8+nPY4j2wJw2uYIEibeMCGfn+phxNh+Tm6vf0z+jNvWXdCIf1o0sdB/AoVqKHVSYdFHzdpBCCOrjkMoRx/LW87pltY5yV7/z5W5AXRodUrg5AgMBAAEwDQYJKoZIhvcNAQELBQADggEBABKIwwbuI6scPuif9Uu3EF5DsW3RiNnnGizLTjdLmJILDZqI4w0wxARwk3b5WTVv06u3iN4Jw5uAaELCBeDoTwbwkEmQxQAfXFbeYuN/j7QRVj6lWK2kkDBG2iVLYkQt4ExL5OlP0QOhODgi7DvorslfwHd1XELn+ICax5adcZe4wx7qZKuX7rdowVdPvNd8mt6HhyvYBkkV7FUAltvC4vYh7aO8EOZ92TBy3xgK24UGRGn34neYK1rNqA5jthu2jQ4O8WI+ZiWVLEKJqVbfUpuc/GqLq/NV9DNVmh33mAfJyqNrhjjyHp+AV/PjMS7gk+ZULy/enMV6fNRxSZ/KVgk="
