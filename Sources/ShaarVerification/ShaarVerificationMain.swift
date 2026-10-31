import Foundation

@main
enum ShaarVerificationMain {
  @MainActor static func main() {
    exit(EngineProbe.run(arguments: CommandLine.arguments))
  }
}
