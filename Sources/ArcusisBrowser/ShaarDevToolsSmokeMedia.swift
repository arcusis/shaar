// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation

@MainActor enum ShaarDevToolsSmokeMedia {
  static func run(context: NativeBrowserContext, report: ShaarDevToolsSmokeReport) async {
    guard let tab = context.engine.siteControlTarget?.tabID else {
      report.fail("media-capture", "The fixture tab is missing")
      return
    }
    let started = await evaluate(
      context, tab: tab,
      script: """
        (()=>{window.arcusisMediaResult=null;
          navigator.mediaDevices.getUserMedia({audio:true,video:true}).then(stream=>{
            window.arcusisProbeStream=stream;window.arcusisMediaResult={allowed:true,
              audio:stream.getAudioTracks().length,video:stream.getVideoTracks().length};
          }).catch(error=>window.arcusisMediaResult={error:error.name});return {started:true};})()
        """)
    guard started?["started"] as? Bool == true else {
      report.fail("media-capture", "Could not request fake camera and microphone")
      return
    }
    let requested = await ShaarDevToolsSmoke.wait(attempts: 80) {
      context.store.websitePermissionRequests.contains { $0.tabID == tab }
    }
    guard requested,
      let request = context.store.websitePermissionRequests.first(where: { $0.tabID == tab })
    else {
      report.fail("media-capture", "Native website consent did not arrive")
      return
    }
    context.store.resolveWebsitePermission(request.id, accepted: true)
    context.store.sheetDidDismiss()
    let result = await mediaResult(context, tab: tab)
    guard result?["allowed"] as? Bool == true,
      result?["audio"] as? Int == 1, result?["video"] as? Int == 1
    else {
      report.fail("media-capture", "Fake media tracks did not start: \(result ?? [:])")
      return
    }
    let active = await ShaarDevToolsSmoke.wait(attempts: 80) {
      context.engine.mediaAccess[tab]?.camera == true
        && context.engine.mediaAccess[tab]?.microphone == true
    }
    let image = report.directory.appending(path: "panel-media-active.png")
    let captured = ShaarDevToolsSmokeAccess.capture(context.hosting, to: image)
    let indicator = captured && captureBadgePainted(at: image)
    if active && captured && indicator {
      report.pass("media-capture", "Fake tracks are live and the hidden toolbar shows In use")
    } else {
      report.fail(
        "media-capture", "Capture state active=\(active), image=\(captured), indicator=\(indicator)"
      )
    }
    _ = await evaluate(
      context, tab: tab,
      script:
        "(()=>{window.arcusisProbeStream?.getTracks().forEach(track=>track.stop());return {stopped:true};})()"
    )
    let stopped = await ShaarDevToolsSmoke.wait(attempts: 80) {
      context.engine.mediaAccess[tab]?.isCapturing != true
    }
    if stopped {
      report.pass("media-stop", "Stopping both tracks cleared the capture state")
    } else {
      report.fail("media-stop", "The capture state stayed active after both tracks stopped")
    }
  }

  private static func mediaResult(
    _ context: NativeBrowserContext, tab: UUID
  ) async -> [String: Any]? {
    for _ in 0..<80 {
      if let result = await evaluate(context, tab: tab, script: "window.arcusisMediaResult") {
        return result
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
  }

  private static func evaluate(
    _ context: NativeBrowserContext, tab: UUID, script: String
  ) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      context.engine.runtime.evaluate(inTabID: tab.uuidString, script: script) {
        continuation.resume(returning: $0)
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private static func captureBadgePainted(at image: URL) -> Bool {
    guard let data = try? Data(contentsOf: image), let bitmap = NSBitmapImageRep(data: data) else {
      return false
    }
    let left = Int(Double(bitmap.pixelsWide) * 0.78)
    let right = Int(Double(bitmap.pixelsWide) * 0.95)
    var redPixels = 0
    let bottom = Int(Double(bitmap.pixelsHigh) * 0.12)
    for y in 0..<bottom {
      for x in left..<right {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }
        if color.redComponent > 0.53 && color.greenComponent < 0.35
          && color.blueComponent < 0.35
          && color.redComponent > color.greenComponent * 1.8
        {
          redPixels += 1
          if redPixels >= 20 { return true }
        }
      }
    }
    return false
  }
}
