// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/media/shaar_media_permission.h"

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/memory/scoped_refptr.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/media/webrtc/media_capture_devices_dispatcher.h"
#include "chrome/browser/media/webrtc/media_stream_capture_indicator.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "content/public/browser/media_stream_request.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "third_party/blink/public/mojom/mediastream/media_stream.mojom.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace shaar::media {
namespace {

struct PendingPermission {
  shaar_engine* engine;
  content::WebContents* contents;
  shaar_window* window;
  shaar_tab* tab;
  std::string profile_id;
  std::string window_id;
  std::string tab_id;
  GURL page_url;
  GURL origin;
  int render_process_id;
  int render_frame_id;
  int64_t navigation_id;
  base::OnceCallback<void(bool)> decision;
};

using PendingMap = std::map<std::string, PendingPermission>;

PendingMap& Pending() {
  static base::NoDestructor<PendingMap> pending;
  return *pending;
}

uint64_t& NextRequestID() {
  static uint64_t next = 0;
  return next;
}

void Finish(std::string_view request_id, bool allowed) {
  auto found = Pending().find(std::string(request_id));
  if (found == Pending().end())
    return;
  auto callback = std::move(found->second.decision);
  Pending().erase(found);
  std::move(callback).Run(allowed);
}

void Expire(std::string request_id) {
  auto found = Pending().find(request_id);
  if (found == Pending().end())
    return;
  const PendingPermission& pending = found->second;
  if (!lifecycle::EngineIsReady(pending.engine)) {
    Finish(request_id, false);
    return;
  }
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "websiteMediaDismissed");
  payload.Set("id", request_id);
  std::string json;
  if (base::JSONWriter::Write(payload, &json)) {
    shaar::EmitEvent(
        pending.engine, SHAAR_EVENT_PERMISSION,
        {pending.profile_id.data(), pending.profile_id.size()}, {},
        {pending.window_id.data(), pending.window_id.size()},
        {pending.tab_id.data(), pending.tab_id.size()},
        {json.data(), json.size()});
  }
  Finish(request_id, false);
}

bool IsCurrentRequest(const PendingPermission& pending) {
  if (!lifecycle::EngineIsReady(pending.engine))
    return false;
  auto identity = windows_tabs::Registry().FindSelectedRegularTab(
      pending.engine, pending.contents);
  auto* frame = content::RenderFrameHost::FromID(
      pending.render_process_id, pending.render_frame_id);
  return identity && identity->window == pending.window &&
         identity->tab == pending.tab &&
         identity->profile_id == pending.profile_id &&
         identity->window_id == pending.window_id &&
         identity->tab_id == pending.tab_id &&
         pending.contents->GetLastCommittedURL() == pending.page_url &&
         frame && frame->IsActive() &&
         frame->GetNavigationId() == pending.navigation_id &&
         content::WebContents::FromRenderFrameHost(frame) ==
                      pending.contents &&
         frame->GetLastCommittedOrigin().GetURL() == pending.origin;
}

class CaptureObserver final : public MediaStreamCaptureIndicator::Observer {
 public:
  explicit CaptureObserver(shaar_engine* engine)
      : engine_(engine),
        indicator_(MediaCaptureDevicesDispatcher::GetInstance()
                       ->GetMediaStreamCaptureIndicator()) {
    indicator_->AddObserver(this);
  }

  ~CaptureObserver() override { indicator_->RemoveObserver(this); }

  void OnIsCapturingVideoChanged(content::WebContents* contents, bool) override {
    Publish(contents);
  }
  void OnIsCapturingAudioChanged(content::WebContents* contents, bool) override {
    Publish(contents);
  }
  void OnIsCapturingTabChanged(content::WebContents* contents, bool) override {
    Publish(contents);
  }
  void OnIsCapturingWindowChanged(content::WebContents* contents, bool) override {
    Publish(contents);
  }
  void OnIsCapturingDisplayChanged(content::WebContents* contents, bool) override {
    Publish(contents);
  }

 private:
  void Publish(content::WebContents* contents) {
    if (!lifecycle::EngineIsReady(engine_))
      return;
    auto identity = windows_tabs::Registry().FindRegularTab(engine_, contents);
    if (!identity)
      return;
    base::DictValue payload;
    payload.Set("schemaVersion", 1);
    payload.Set("kind", "capture_changed");
    payload.Set("camera", indicator_->IsCapturingVideo(contents));
    payload.Set("microphone", indicator_->IsCapturingAudio(contents));
    payload.Set("screen", indicator_->IsCapturingTab(contents) ||
                              indicator_->IsCapturingWindow(contents) ||
                              indicator_->IsCapturingDisplay(contents));
    std::string json;
    if (!base::JSONWriter::Write(payload, &json))
      return;
    shaar::EmitEvent(
        engine_, SHAAR_EVENT_MEDIA,
        {identity->profile_id.data(), identity->profile_id.size()}, {},
        {identity->window_id.data(), identity->window_id.size()},
        {identity->tab_id.data(), identity->tab_id.size()},
        {json.data(), json.size()});
  }

  shaar_engine* engine_;
  scoped_refptr<MediaStreamCaptureIndicator> indicator_;
};

std::unique_ptr<CaptureObserver> g_capture_observer;

}  // namespace

void StartCaptureObserving(shaar_engine* engine) {
  if (engine && !g_capture_observer)
    g_capture_observer = std::make_unique<CaptureObserver>(engine);
}

void StopCaptureObserving() {
  g_capture_observer.reset();
}

void RequestWebsiteMediaPermission(
    content::WebContents* contents, const content::MediaStreamRequest& request,
    base::OnceCallback<void(bool)> decision) {
  shaar_engine* engine = lifecycle::ActiveEngine();
  auto identity = windows_tabs::Registry().FindSelectedRegularTab(engine, contents);
  auto* frame = content::RenderFrameHost::FromID(request.render_process_id,
                                                 request.render_frame_id);
  const bool audio = request.audio_type ==
                     blink::mojom::MediaStreamType::DEVICE_AUDIO_CAPTURE;
  const bool video = request.video_type ==
                     blink::mojom::MediaStreamType::DEVICE_VIDEO_CAPTURE;
  if (!lifecycle::EngineIsReady(engine) || !identity || !frame ||
      !frame->IsActive() ||
      content::WebContents::FromRenderFrameHost(frame) != contents ||
      frame->GetLastCommittedOrigin().GetURL() != request.security_origin ||
      (!audio && !video) || Pending().size() >= 32 ||
      identity->profile_id.empty() || identity->window_id.empty() ||
      identity->tab_id.empty()) {
    std::move(decision).Run(false);
    return;
  }

  const GURL page_url = contents->GetLastCommittedURL();
  const GURL origin = url::Origin::Create(request.security_origin).GetURL();
  if (!page_url.SchemeIsHTTPOrHTTPS() || !origin.SchemeIsHTTPOrHTTPS()) {
    std::move(decision).Run(false);
    return;
  }

  const std::string id = std::to_string(++NextRequestID());
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "websiteMediaRequested");
  payload.Set("id", id);
  payload.Set("pageURL", page_url.spec());
  payload.Set("origin", origin.spec());
  base::ListValue kinds;
  if (video)
    kinds.Append("camera");
  if (audio)
    kinds.Append("microphone");
  payload.Set("permissions", std::move(kinds));
  std::string json;
  if (!base::JSONWriter::Write(payload, &json)) {
    std::move(decision).Run(false);
    return;
  }

  Pending().emplace(
      id, PendingPermission{engine, contents, identity->window, identity->tab,
                            identity->profile_id, identity->window_id,
                            identity->tab_id, page_url, origin,
                            request.render_process_id, request.render_frame_id,
                            frame->GetNavigationId(),
                            std::move(decision)});
  base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE,
      base::BindOnce(&Expire, id),
      base::Minutes(2));
  const shaar_error_code emitted = shaar::EmitEvent(
      engine, SHAAR_EVENT_PERMISSION,
      {identity->profile_id.data(), identity->profile_id.size()}, {},
      {identity->window_id.data(), identity->window_id.size()},
      {identity->tab_id.data(), identity->tab_id.size()},
      {json.data(), json.size()});
  if (emitted != SHAAR_OK)
    Finish(id, false);
}

std::optional<bool> ResolveWebsiteMediaPermission(
    shaar_engine* engine, content::WebContents* contents,
    std::string_view request_id, bool accepted) {
  auto found = Pending().find(std::string(request_id));
  if (found == Pending().end())
    return std::nullopt;
  const bool allowed = accepted && found->second.engine == engine &&
                       found->second.contents == contents &&
                       IsCurrentRequest(found->second);
  Finish(request_id, allowed);
  return allowed;
}

}  // namespace shaar::media
