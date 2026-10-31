import ArcusisBrowser

@main
enum ShaarMain {
  @MainActor static func main() {
    BrowserLaunch.run()
  }
}
