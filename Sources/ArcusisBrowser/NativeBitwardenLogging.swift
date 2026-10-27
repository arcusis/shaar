#if canImport(ArcusisBitwardenSDK)
  import ArcusisBitwardenSDK
#endif

/// This must run before any owned SDK client is constructed in the process.
enum NativeBitwardenLogging {
  private static let initialized: Void = {
    #if canImport(ArcusisBitwardenSDK)
      initLogger(callback: nil, level: .error, platformLogger: false)
    #endif
  }()

  static func bootstrap() { _ = initialized }
}
