// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/media/shaar_media.h"
#include "chrome/browser/shaar/media/shaar_media_permission.h"
#include "chrome/browser/shaar/media/shaar_desktop_capture.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/permissions/shaar_permission_prompt.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "content/public/browser/media_session.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "services/media_session/public/mojom/media_session.mojom.h"
#include "third_party/blink/public/mojom/frame/user_activation_notification_type.mojom.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace {

constexpr size_t kMaximumArgumentsBytes = 64 * 1024;
std::unordered_map<content::WebContents*, base::DictValue> element_states;

base::DictValue NoElementState() {
  base::DictValue state;
  state.Set("playbackState", "none");
  state.Set("supportedActions", base::ListValue());
  state.Set("canSeek", false);
  state.Set("hasVideo", false);
  state.Set("pageVolume", base::Value());
  state.Set("silent", base::Value());
  state.Set("pipVideoState", "none");
  state.Set("pipVideoIsLive", false);
  state.Set("videoWidth", base::Value());
  state.Set("videoHeight", base::Value());
  return state;
}

shaar_bytes Bytes(const std::string& value) {
  return {value.data(), value.size()};
}

base::DictValue OverlayElementState(content::WebContents* contents,
                                    base::DictValue state) {
  const auto found = element_states.find(contents);
  if (found == element_states.end())
    return state;
  for (auto item : found->second)
    state.Set(item.first, item.second.Clone());
  if (const auto playable = found->second.FindBool("elementPlayable")) {
    base::ListValue actions;
    const bool can_seek = found->second.FindBool("canSeek") == true;
    if (const auto* existing = state.FindList("supportedActions")) {
      for (const auto& action : *existing) {
        if (action.is_int() && !can_seek &&
            (action.GetInt() == SHAAR_MEDIA_SEEK_BACKWARD ||
             action.GetInt() == SHAAR_MEDIA_SEEK_FORWARD ||
             action.GetInt() == SHAAR_MEDIA_SEEK_TO))
          continue;
        actions.Append(action.Clone());
      }
    }
    auto append_action = [&actions](int action) {
      for (const auto& existing : actions)
        if (existing.is_int() && existing.GetInt() == action)
          return;
      actions.Append(action);
    };
    if (*playable) {
      append_action(SHAAR_MEDIA_PLAY);
      append_action(SHAAR_MEDIA_PAUSE);
    }
    if (can_seek) {
      append_action(SHAAR_MEDIA_SEEK_BACKWARD);
      append_action(SHAAR_MEDIA_SEEK_FORWARD);
    }
    state.Set("supportedActions", std::move(actions));
    state.Remove("elementPlayable");
  }
  return state;
}

struct ReplyContext {
  shaar_request_id request_id;
  shaar_reply_fn callback;
  void* context;
};

void DeliverReply(ReplyContext request,
                  shaar_error_code code,
                  std::string payload,
                  std::string message) {
  shaar_result result{};
  result.size = sizeof(result);
  result.request_id = request.request_id;
  result.error.size = sizeof(result.error);
  result.error.code = code;
  result.error.platform_code = 0;
  result.error.message = {message.data(), message.size()};
  result.payload_json = {payload.data(), payload.size()};
  request.callback(request.context, &result);
}

void Reply(const ReplyContext& request, base::DictValue payload) {
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(payload)), &json);
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&DeliverReply, request, SHAAR_OK,
                                std::move(json), std::string()));
}

shaar_error_code Fail(shaar_error* error,
                      shaar_error_code code,
                      const char* message) {
  if (error) {
    const uint32_t size = error->size;
    if (size >= offsetof(shaar_error, code) + sizeof(error->code))
      error->code = code;
    if (size >= offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
      error->platform_code = 0;
    if (size >= offsetof(shaar_error, message) + sizeof(error->message))
      error->message = {message, std::strlen(message)};
  }
  return code;
}

std::optional<base::DictValue> ParseArguments(shaar_bytes bytes) {
  if (!bytes.data || bytes.size == 0 || bytes.size > kMaximumArgumentsBytes)
    return std::nullopt;
  auto parsed = base::JSONReader::Read(
      std::string_view(bytes.data, bytes.size), base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict())
    return std::nullopt;
  return std::move(parsed->GetDict());
}

bool HasOnlyKeys(const base::DictValue& dict,
                 std::initializer_list<std::string_view> allowed) {
  for (const auto item : dict) {
    if (std::find(allowed.begin(), allowed.end(), item.first) == allowed.end())
      return false;
  }
  return true;
}

const char* PlaybackStateName(
    media_session::mojom::MediaPlaybackState state) {
  switch (state) {
    case media_session::mojom::MediaPlaybackState::kPlaying:
      return "playing";
    case media_session::mojom::MediaPlaybackState::kPaused:
      return "paused";
  }
  return "none";
}

std::optional<uint32_t> AbiAction(
    media_session::mojom::MediaSessionAction action) {
  using media_session::mojom::MediaSessionAction;
  switch (action) {
    case MediaSessionAction::kPlay: return SHAAR_MEDIA_PLAY;
    case MediaSessionAction::kPause: return SHAAR_MEDIA_PAUSE;
    case MediaSessionAction::kPreviousTrack: return SHAAR_MEDIA_PREVIOUS_TRACK;
    case MediaSessionAction::kNextTrack: return SHAAR_MEDIA_NEXT_TRACK;
    case MediaSessionAction::kSeekBackward: return SHAAR_MEDIA_SEEK_BACKWARD;
    case MediaSessionAction::kSeekForward: return SHAAR_MEDIA_SEEK_FORWARD;
    case MediaSessionAction::kSeekTo: return SHAAR_MEDIA_SEEK_TO;
    case MediaSessionAction::kEnterPictureInPicture: return SHAAR_MEDIA_PIP_ENTER;
    case MediaSessionAction::kExitPictureInPicture: return SHAAR_MEDIA_PIP_EXIT;
    default: return std::nullopt;
  }
}

base::DictValue StateFor(content::WebContents* contents) {
  base::DictValue state;
  state.Set("schemaVersion", 1);
  state.Set("playbackState", "none");
  state.Set("title", "");
  state.Set("artist", "");
  state.Set("album", "");
  state.Set("artwork", base::Value());
  state.Set("supportedActions", base::ListValue());
  state.Set("canSeek", false);
  state.Set("hasVideo", false);
  state.Set("tabMuted", contents->IsAudioMuted());
  state.Set("pageVolume", base::Value());
  state.Set("silent", base::Value());
  state.Set("pipVideoState", base::Value());
  state.Set("pipVideoIsLive", base::Value());
  state.Set("videoWidth", base::Value());
  state.Set("videoHeight", base::Value());

  content::MediaSession* session = content::MediaSession::GetIfExists(contents);
  if (!session)
    return OverlayElementState(contents, std::move(state));

  const auto info = session->GetMediaSessionInfoSync();
  if (info) {
    state.Set("playbackState", PlaybackStateName(info->playback_state));
    using media_session::mojom::MediaAudioVideoState;
    const bool has_video =
        info->deprecated_audio_video_state == MediaAudioVideoState::kAudioVideo ||
        info->deprecated_audio_video_state == MediaAudioVideoState::kVideoOnly;
    state.Set("hasVideo", has_video);
    state.Set("pipVideoState",
              info->picture_in_picture_state ==
                      media_session::mojom::MediaPictureInPictureState::kInPictureInPicture
                  ? "inPictureInPicture"
                  : "none");
  }
  const auto& metadata = session->GetMediaSessionMetadata();
  state.Set("title", base::UTF16ToUTF8(metadata.title));
  state.Set("artist", base::UTF16ToUTF8(metadata.artist));
  state.Set("album", base::UTF16ToUTF8(metadata.album));
  const auto actions = session->GetMediaSessionActionsSync();
  base::ListValue supported_actions;
  for (auto action : actions) {
    if (const auto abi_action = AbiAction(action))
      supported_actions.Append(static_cast<int>(*abi_action));
  }
  state.Set("supportedActions", std::move(supported_actions));
  state.Set("canSeek",
            std::find(actions.begin(), actions.end(),
                      media_session::mojom::MediaSessionAction::kSeekTo) !=
                    actions.end() ||
                std::find(actions.begin(), actions.end(),
                          media_session::mojom::MediaSessionAction::kSeekBackward) !=
                    actions.end() ||
                std::find(actions.begin(), actions.end(),
                          media_session::mojom::MediaSessionAction::kSeekForward) !=
                    actions.end());
  return OverlayElementState(contents, std::move(state));
}

bool ValidScopeForTab(shaar::ShaarEngineContext* context,
                      shaar_engine* engine,
                      shaar_scope scope,
                      shaar_window* window,
                      shaar_tab* tab,
                      content::WebContents** contents) {
  if (!context || !context->browser_tabs || !window || !tab ||
      scope.size < sizeof(shaar_scope) ||
      ((scope.profile != nullptr) == (scope.private_session != nullptr))) {
    return false;
  }
  *contents = context->browser_tabs->FindWebContents(engine, window, tab);
  if (!*contents)
    return false;
  if (scope.profile) {
    if (!context->profile_services)
      return false;
    Profile* profile = context->profile_services->ResolveProfile(engine, scope.profile);
    return profile && !profile->IsOffTheRecord() &&
           profile == Profile::FromBrowserContext((*contents)->GetBrowserContext());
  }
  return (*contents)->GetBrowserContext()->IsOffTheRecord() &&
         context->media_services &&
         context->media_services->OwnsPrivateTab(engine, scope, window, tab,
                                                  *contents);
}

bool IsMarkedMediaProbe(shaar_engine* engine, content::WebContents* contents) {
  const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
  if (!testing || std::strcmp(testing, "1") != 0 || !engine || !contents)
    return false;
  const base::FilePath data_root = base::MakeAbsoluteFilePath(
      base::FilePath::FromUTF8Unsafe(engine->data_root));
  if (data_root.empty())
    return false;
  const base::FilePath root = data_root.DirName();
  if (data_root != root.Append("Chromium") ||
      root.BaseName().value().rfind("arcusis-engine-probe-", 0) != 0)
    return false;
  std::string marker;
  if (!base::ReadFileToString(root.Append(".arcusis-probe"), &marker) ||
      marker != "arcusis-engine-probe-v1\n")
    return false;
  const GURL& url = contents->GetLastCommittedURL();
  return url.SchemeIs("http") &&
         (url.host() == "127.0.0.1" || url.host() == "localhost" ||
          url.host() == "[::1]");
}

bool HasAction(content::MediaSession* session,
               media_session::mojom::MediaSessionAction action) {
  const auto actions = session->GetMediaSessionActionsSync();
  return std::find(actions.begin(), actions.end(), action) != actions.end();
}

class RuntimeServices final : public shaar::MediaRuntimeServices {
public:
  bool OwnsPrivateTab(shaar_engine *engine, shaar_scope scope,
                      shaar_window *window, shaar_tab *tab,
                      content::WebContents *contents) override {
    auto &context = shaar::EngineContext();
    if (!context.private_sessions || !context.browser_tabs || !engine ||
        !scope.private_session || scope.profile || !contents ||
        context.browser_tabs->FindWebContents(engine, window, tab) != contents)
      return false;
    Profile *parent = nullptr;
    Profile *otr = nullptr;
    std::string_view profile_id;
    std::string_view session_id;
    return context.private_sessions->Resolve(engine, scope.private_session,
                                             &parent, &otr, &profile_id,
                                             &session_id) &&
           parent && otr && !session_id.empty() &&
           contents->GetBrowserContext() == otr;
  }

  shaar_error_code SubmitSupplementalOperation(
      shaar_engine *engine, shaar_scope scope, shaar_window *window,
      shaar_tab *tab, shaar_operation operation, shaar_bytes args_json,
      shaar_request_id request_id, shaar_reply_fn reply, void *reply_context,
      shaar_error *error) override {
    if (operation == SHAAR_OP_MEDIA_CAPTURE_REPLY) {
      auto args = ParseArguments(args_json);
      const std::string *prompt_id =
          args ? args->FindString("promptID") : nullptr;
      const std::string *decision =
          args ? args->FindString("decision") : nullptr;
      const std::string *source_token =
          args ? args->FindString("sourceToken") : nullptr;
      if (!prompt_id || !decision || !source_token || !reply || !request_id)
        return Fail(error, SHAAR_INVALID_ARGUMENT,
                    "capture reply is missing required fields");
      const shaar_error_code result = shaar::desktop_capture::Resolve(
          engine, window, tab, *prompt_id, *decision, *source_token);
      if (result != SHAAR_OK)
        return Fail(error, result, "capture prompt is stale or invalid");
      Reply(ReplyContext{request_id, reply, reply_context},
            base::DictValue().Set("schemaVersion", 1));
      return SHAAR_OK;
    }
    if (operation != SHAAR_OP_MEDIA_SET_AUTO_PIP)
      return Fail(error, SHAAR_UNSUPPORTED_CAPABILITY,
                  "media capture controls are not connected");
    auto args = ParseArguments(args_json);
    if (!args || !args->FindBool("allowed").has_value() || !reply ||
        !request_id)
      return Fail(error, SHAAR_INVALID_ARGUMENT,
                  "automatic PiP requires an allowed boolean");
    auto &context = shaar::EngineContext();
    content::WebContents *contents =
        context.browser_tabs
            ? context.browser_tabs->FindWebContents(engine, window, tab)
            : nullptr;
    if (!contents)
      return Fail(error, SHAAR_NOT_FOUND, "media tab is unavailable");
    Profile *profile =
        Profile::FromBrowserContext(contents->GetBrowserContext());
    const GURL &url = contents->GetLastCommittedURL();
    if (!profile || !url.SchemeIsHTTPOrHTTPS())
      return Fail(error, SHAAR_INVALID_ARGUMENT,
                  "automatic PiP requires a web origin");
    HostContentSettingsMap *settings =
        HostContentSettingsMapFactory::GetForProfile(profile);
    if (!settings)
      return Fail(error, SHAAR_NOT_READY,
                  "automatic PiP content settings are unavailable");
    const GURL origin = url::Origin::Create(url).GetURL();
    settings->SetContentSettingDefaultScope(
        origin, origin, ContentSettingsType::AUTO_PICTURE_IN_PICTURE,
        *args->FindBool("allowed") ? CONTENT_SETTING_ALLOW
                                   : CONTENT_SETTING_BLOCK);
    Reply(ReplyContext{request_id, reply, reply_context},
          base::DictValue().Set("schemaVersion", 1));
    return SHAAR_OK;
  }
};

RuntimeServices g_runtime_services;

constexpr char16_t kElementStateScript[] = uR"JS((()=>{
  let best=null, score=-1;
  let artwork=null;
  try {
    const entry=navigator.mediaSession?.metadata?.artwork?.[0];
    if(entry?.src) {
      const url=new URL(entry.src,document.baseURI);
      if((url.protocol==='http:'||url.protocol==='https:') && url.href.length<4096)
        artwork=url.href;
    }
  } catch (_) {}
  for(const element of document.querySelectorAll('audio,video')) {
    if(element.ended || (!element.currentSrc && !element.srcObject)) continue;
    const playing=!element.paused;
    const video=element instanceof HTMLVideoElement;
    const decoded=video && element.readyState>=HTMLMediaElement.HAVE_CURRENT_DATA &&
        element.videoWidth>0 && element.videoHeight>0;
    const area=decoded ? element.videoWidth*element.videoHeight : 0;
    const candidate=(document.pictureInPictureElement===element?2e12:0)+
        (playing?1e12:0)+area;
    if(candidate<=score) continue;
    score=candidate;
    const duration=element.duration;
    const seekable=Number.isFinite(duration) && duration>0 && element.seekable.length>0;
    best={elementPlayable:true,playbackState:playing?'playing':'paused',
      pageVolume:element.volume,silent:element.muted || element.volume===0,
      hasVideo:decoded,canSeek:seekable,
      pipVideoState:document.pictureInPictureElement===element?'inPictureInPicture':'none',
      pipVideoIsLive:document.pictureInPictureElement===element && !seekable,
      videoWidth:decoded?element.videoWidth:null,
      videoHeight:decoded?element.videoHeight:null,artwork,score};
  }
  return best;
})())JS";

struct VolumeRequest {
  explicit VolumeRequest(ReplyContext reply_context)
      : reply_context(reply_context) {}

  void Finish() {
    if (finished)
      return;
    finished = true;
    timer.Stop();
    if (changed_elements > 0) {
      Reply(reply_context, base::DictValue().Set("schemaVersion", 1));
    } else {
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE,
          base::BindOnce(
              &DeliverReply, reply_context, SHAAR_UNSUPPORTED_CAPABILITY,
              std::string(),
              std::string("no playing media element accepted volume")));
    }
  }

  void OnFrameResult(base::Value value) {
    if (finished)
      return;
    if (value.is_int() && value.GetInt() > 0)
      changed_elements += value.GetInt();
    else if (value.is_double() && value.GetDouble() > 0)
      ++changed_elements;
    else if (value.is_bool() && value.GetBool())
      ++changed_elements;
    if (--pending_frames == 0)
      Finish();
  }

  ReplyContext reply_context;
  int pending_frames = 0;
  int changed_elements = 0;
  bool finished = false;
  base::OneShotTimer timer;
};

struct ElementActionRequest {
  explicit ElementActionRequest(ReplyContext reply_context, bool probe,
                                bool probe_pip)
      : reply_context(reply_context), probe(probe), probe_pip(probe_pip) {}

  void Finish() {
    if (finished)
      return;
    finished = true;
    timer.Stop();
    if (changed_elements > 0) {
      base::DictValue result;
      result.Set("schemaVersion", 1);
      if (probe)
        result.Set(probe_pip ? "opened" : "started", true);
      Reply(reply_context, std::move(result));
    } else {
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(&DeliverReply, reply_context,
                                    SHAAR_UNSUPPORTED_CAPABILITY,
                                    std::string(),
                                    std::string("no eligible media element")));
    }
  }

  void OnFrameResult(base::Value value) {
    if (finished)
      return;
    if (value.is_int() && value.GetInt() > 0)
      changed_elements += value.GetInt();
    else if (value.is_double() && value.GetDouble() > 0)
      ++changed_elements;
    else if (value.is_bool() && value.GetBool())
      ++changed_elements;
    if (--pending_frames == 0)
      Finish();
  }

  ReplyContext reply_context;
  int pending_frames = 0;
  int changed_elements = 0;
  bool finished = false;
  bool probe = false;
  bool probe_pip = false;
  base::OneShotTimer timer;
};

std::u16string ElementActionScript(uint32_t command, double value) {
  const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
  const bool debug = testing && std::strcmp(testing, "1") == 0;
  const std::string prefix =
      "(()=>{const command=" + std::to_string(command) +
      ",value=" + std::to_string(value) +
      ",debug=" + (debug ? "true" : "false") + ";";
  const std::string body = R"JS(
    let best=null, score=-1;
    const pip=document.pictureInPictureElement;
    for(const element of document.querySelectorAll('audio,video')) {
      if(element.ended || (!element.currentSrc && !element.srcObject)) continue;
      if((command===9 || command===10 || command===11) && element!==pip) continue;
      if(command===12 && (!(element instanceof HTMLVideoElement) ||
          element.paused || element.disablePictureInPicture)) continue;
      if(command===13 && element!==pip) continue;
      const playing=!element.paused;
      const area=element instanceof HTMLVideoElement ?
          element.videoWidth*element.videoHeight : 0;
      const candidate=(playing?1e12:0)+area;
      if(candidate>score){score=candidate;best=element;}
    }
    if(!best) return 0;
    if(command===0 || command===9){best.play().catch(()=>{});return 1;}
    if(command===1 || command===10){best.pause();return 1;}
    if(command===4 || command===5 || command===6 || command===11){
      if(!Number.isFinite(best.duration) || best.duration<=0 ||
          best.seekable.length===0) return 0;
      const destination=command===6?value:
          best.currentTime+(command===4?-value:
          command===5?value:value);
      best.currentTime=Math.max(0,Math.min(best.duration,destination));
      return 1;
    }
    if(command===8){best.volume=value;if(value>0)best.muted=false;return 1;}
    if(command===12){
      try {
        best.requestPictureInPicture().catch(e=>{
          if(debug)document.documentElement.setAttribute('data-shaar-pip-error',e.name+':'+e.message);
        });
        return 1;
      } catch(e) {
        if(debug)document.documentElement.setAttribute('data-shaar-pip-error',e.name+':'+e.message);
        return 0;
      }
    }
    if(command===13){document.exitPictureInPicture().catch(()=>{});return 1;}
    return 0;
  })())JS";
  return base::UTF8ToUTF16(prefix + body);
}

std::u16string VolumeScript(double value) {
  std::u16string script =
      u"(()=>{let changed=0;for(const element of "
      u"document.querySelectorAll('audio,video')){"
      u"if(!element.paused&&!element.ended){element.volume=";
  script += base::UTF8ToUTF16(std::to_string(value));
  script += u";if(element.volume>0)element.muted=false;changed++;}}return changed;})()";
  return script;
}

}  // namespace

namespace shaar::media {

class MediaTracker final : public content::WebContentsObserver {
 public:
  MediaTracker(shaar_engine* engine, content::WebContents* contents,
               std::string profile_id, std::string session_id,
               std::string window_id, std::string tab_id)
      : content::WebContentsObserver(contents),
        engine_(engine), contents_(contents), profile_id_(std::move(profile_id)),
        session_id_(std::move(session_id)), window_id_(std::move(window_id)),
        tab_id_(std::move(tab_id)) {}

  ~MediaTracker() override {
    timer_.Stop();
    element_states.erase(contents_);
  }

  void MediaStartedPlaying(const MediaPlayerInfo&,
                           const content::MediaPlayerId&) override {
    if (!timer_.IsRunning()) {
      timer_.Start(FROM_HERE, base::Milliseconds(500), this,
                   &MediaTracker::Refresh);
    }
    Refresh();
  }

  void MediaStoppedPlaying(const MediaPlayerInfo&, const content::MediaPlayerId&,
                           MediaStoppedReason) override {
    Refresh();
  }

  void MediaMetadataChanged(const MediaPlayerInfo&,
                            const content::MediaPlayerId&) override {
    Refresh();
  }

  void MediaPictureInPictureChanged(bool) override { Refresh(); }
  void OnAudioStateChanged(bool) override { Refresh(); }

  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (!navigation->HasCommitted() || !navigation->IsInPrimaryMainFrame() ||
        navigation->IsSameDocument())
      return;
    element_states[contents_] = NoElementState();
    EmitChangedState();
  }

  void AboutToBeDiscarded(content::WebContents* new_contents) override {
    if (!new_contents || new_contents == contents_)
      return;
    const auto state = element_states.find(contents_);
    if (state != element_states.end()) {
      element_states.emplace(new_contents, std::move(state->second));
      element_states.erase(state);
    }
    contents_ = new_contents;
    Observe(new_contents);
  }

  void WebContentsDestroyed() override {
    timer_.Stop();
    element_states.erase(contents_);
    contents_ = nullptr;
    weak_factory_.InvalidateWeakPtrs();
  }

 private:
  void Refresh() {
    if (!contents_ || pending_)
      return;
    content::RenderFrameHost* primary = contents_->GetPrimaryMainFrame();
    if (!primary || !primary->IsRenderFrameLive()) {
      EmitChangedState();
      return;
    }
    std::vector<content::RenderFrameHost*> frames;
    primary->ForEachRenderFrameHost([&](content::RenderFrameHost* frame) {
      if (frame->IsRenderFrameLive())
        frames.push_back(frame);
    });
    if (frames.empty()) {
      EmitChangedState();
      return;
    }
    pending_ = static_cast<int>(frames.size());
    best_score_ = -1;
    best_state_.clear();
    for (content::RenderFrameHost* frame : frames) {
      frame->ExecuteJavaScriptInIsolatedWorld(
          kElementStateScript,
          base::BindOnce(&MediaTracker::OnFrameState,
                         weak_factory_.GetWeakPtr()),
          ISOLATED_WORLD_ID_CHROME_INTERNAL);
    }
  }

  void OnFrameState(base::Value value) {
    if (!contents_ || pending_ <= 0)
      return;
    if (value.is_dict()) {
      base::DictValue candidate = std::move(value.GetDict());
      double score = -1;
      if (const base::Value* score_item = candidate.Find("score")) {
        if (score_item->is_double())
          score = score_item->GetDouble();
        else if (score_item->is_int())
          score = score_item->GetInt();
      }
      if (score > best_score_) {
        best_score_ = score;
        candidate.Remove("score");
        best_state_ = std::move(candidate);
      }
    }
    if (--pending_ != 0)
      return;
    if (best_score_ < 0) {
      element_states[contents_] = NoElementState();
      timer_.Stop();
    } else {
      element_states[contents_] = std::move(best_state_);
    }
    EmitChangedState();
  }

  void EmitChangedState() {
    if (!contents_)
      return;
    base::DictValue state = StateFor(contents_);
    std::string state_json;
    base::JSONWriter::Write(base::Value(state.Clone()), &state_json);
    if (state_json == previous_state_)
      return;
    const std::string* pip = state.FindString("pipVideoState");
    const std::string pip_state = pip ? *pip : "none";
    base::DictValue payload;
    payload.Set("schemaVersion", 1);
    payload.Set("kind", "state_changed");
    payload.Set("state", std::move(state));
    std::string json;
    base::JSONWriter::Write(base::Value(std::move(payload)), &json);
    shaar::EmitEvent(engine_, SHAAR_EVENT_MEDIA, Bytes(profile_id_),
                     Bytes(session_id_), Bytes(window_id_), Bytes(tab_id_),
                     Bytes(json));
    if (pip_state != previous_pip_) {
      base::DictValue pip_event;
      pip_event.Set("schemaVersion", 1);
      pip_event.Set("kind", "pip_changed");
      pip_event.Set("state", pip_state);
      base::JSONWriter::Write(base::Value(std::move(pip_event)), &json);
      shaar::EmitEvent(engine_, SHAAR_EVENT_MEDIA, Bytes(profile_id_),
                       Bytes(session_id_), Bytes(window_id_), Bytes(tab_id_),
                       Bytes(json));
      previous_pip_ = pip_state;
    }
    previous_state_ = std::move(state_json);
  }

  shaar_engine* engine_;
  content::WebContents* contents_;
  std::string profile_id_, session_id_, window_id_, tab_id_;
  base::RepeatingTimer timer_;
  int pending_ = 0;
  double best_score_ = -1;
  base::DictValue best_state_;
  std::string previous_state_, previous_pip_ = "none";
  base::WeakPtrFactory<MediaTracker> weak_factory_{this};
};

MediaTrackerPtr CreateMediaTracker(shaar_engine* engine,
                                   content::WebContents* contents,
                                   std::string profile_id,
                                   std::string session_id,
                                   std::string window_id,
                                   std::string tab_id) {
  return MediaTrackerPtr(
      new MediaTracker(engine, contents, std::move(profile_id),
                       std::move(session_id), std::move(window_id),
                       std::move(tab_id)),
      [](MediaTracker* tracker) { delete tracker; });
}

void BindRuntimeServices() {
  shaar::SetMediaRuntimeServices(&g_runtime_services);
}

std::u16string VolumeScriptForTesting(double value) {
  return VolumeScript(value);
}

std::u16string ElementActionScriptForTesting(uint32_t command, double value) {
  return ElementActionScript(command, value);
}

shaar_error_code ApplyElementVolume(content::WebContents *contents,
                                    double value, ReplyContext reply_context,
                                    shaar_error *error) {
  content::RenderFrameHost *primary = contents->GetPrimaryMainFrame();
  if (!primary)
    return Fail(error, SHAAR_NOT_READY, "media page has no primary frame");
  std::vector<content::RenderFrameHost *> frames;
  primary->ForEachRenderFrameHost([&frames](content::RenderFrameHost *frame) {
    if (frame->IsRenderFrameLive())
      frames.push_back(frame);
  });
  if (frames.empty())
    return Fail(error, SHAAR_NOT_READY, "media page has no live frame");
  auto request = std::make_shared<VolumeRequest>(reply_context);
  request->pending_frames = static_cast<int>(frames.size());
  request->timer.Start(
      FROM_HERE, base::Seconds(2),
      base::BindOnce(
          [](std::shared_ptr<VolumeRequest> pending) { pending->Finish(); },
          request));
  const std::u16string script = VolumeScript(value);
  for (content::RenderFrameHost *frame : frames) {
    frame->ExecuteJavaScriptInIsolatedWorld(
        script,
        base::BindOnce(
            [](std::shared_ptr<VolumeRequest> pending, base::Value result) {
              pending->OnFrameResult(std::move(result));
            },
            request),
        ISOLATED_WORLD_ID_CHROME_INTERNAL);
  }
  return SHAAR_OK;
}

shaar_error_code ApplyElementAction(content::WebContents* contents,
                                    uint32_t command, double value,
                                    ReplyContext reply_context,
                                    shaar_error* error,
                                    bool probe = false,
                                    bool probe_pip = false) {
  content::RenderFrameHost* primary = contents->GetPrimaryMainFrame();
  if (!primary)
    return Fail(error, SHAAR_NOT_READY, "media page has no primary frame");
  std::vector<content::RenderFrameHost*> frames;
  primary->ForEachRenderFrameHost([&](content::RenderFrameHost* frame) {
    if (frame->IsRenderFrameLive())
      frames.push_back(frame);
  });
  if (frames.empty())
    return Fail(error, SHAAR_NOT_READY, "media page has no live frame");
  auto request =
      std::make_shared<ElementActionRequest>(reply_context, probe, probe_pip);
  request->pending_frames = static_cast<int>(frames.size());
  request->timer.Start(FROM_HERE, base::Seconds(2),
                       base::BindOnce(
                           [](std::shared_ptr<ElementActionRequest> pending) {
                             pending->Finish();
                           }, request));
  const std::u16string script = probe_pip
      ? u"(()=>{const clip=document.getElementById('clip');"
        u"if(!clip)return 0;clip.currentTime=5;"
        u"clip.play().then(()=>clip.requestPictureInPicture()).catch(()=>{});"
        u"return 1;})()"
      : probe
          ? u"(()=>{const video=document.getElementById('video');"
            u"if(!video)return 0;video.play().catch(()=>{});return 1;})()"
          : ElementActionScript(command, value);
  for (content::RenderFrameHost* frame : frames) {
    if (command == SHAAR_MEDIA_PIP_ENTER || probe) {
      frame->NotifyUserActivation(
          blink::mojom::UserActivationNotificationType::kInteraction);
    }
    frame->ExecuteJavaScriptInIsolatedWorld(
        script,
        base::BindOnce(
            [](std::shared_ptr<ElementActionRequest> pending,
               base::Value result) {
              pending->OnFrameResult(std::move(result));
            }, request),
        ISOLATED_WORLD_ID_CHROME_INTERNAL);
  }
  return SHAAR_OK;
}

bool IsValidControl(uint32_t command, double value, bool has_value) {
  if (command > SHAAR_MEDIA_PIP_EXIT)
    return false;
  if (command == SHAAR_MEDIA_SET_TAB_MUTED)
    return has_value && (value == 0 || value == 1);
  if (command == SHAAR_MEDIA_SET_ELEMENT_VOLUME ||
      command == SHAAR_MEDIA_SEEK_TO) {
    return has_value && std::isfinite(value) && value >= 0 && value <= 86400 &&
           (command != SHAAR_MEDIA_SET_ELEMENT_VOLUME || value <= 1);
  }
  if (command == SHAAR_MEDIA_PIP_SKIP)
    return has_value && std::isfinite(value) && value != 0 && value >= -86400 &&
           value <= 86400;
  if (command == SHAAR_MEDIA_SEEK_BACKWARD ||
      command == SHAAR_MEDIA_SEEK_FORWARD)
    return !has_value || (std::isfinite(value) && value > 0 && value <= 86400);
  return !has_value;
}

bool MapSessionAction(uint32_t command,
                      media_session::mojom::MediaSessionAction* action) {
  if (!action)
    return false;
  using media_session::mojom::MediaSessionAction;
  switch (command) {
    case SHAAR_MEDIA_PLAY: *action = MediaSessionAction::kPlay; return true;
    case SHAAR_MEDIA_PAUSE: *action = MediaSessionAction::kPause; return true;
    case SHAAR_MEDIA_PREVIOUS_TRACK: *action = MediaSessionAction::kPreviousTrack; return true;
    case SHAAR_MEDIA_NEXT_TRACK: *action = MediaSessionAction::kNextTrack; return true;
    case SHAAR_MEDIA_SEEK_BACKWARD: *action = MediaSessionAction::kSeekBackward; return true;
    case SHAAR_MEDIA_SEEK_FORWARD: *action = MediaSessionAction::kSeekForward; return true;
    case SHAAR_MEDIA_SEEK_TO: *action = MediaSessionAction::kSeekTo; return true;
    case SHAAR_MEDIA_PIP_PLAY: *action = MediaSessionAction::kPlay; return true;
    case SHAAR_MEDIA_PIP_PAUSE: *action = MediaSessionAction::kPause; return true;
    case SHAAR_MEDIA_PIP_ENTER: *action = MediaSessionAction::kEnterPictureInPicture; return true;
    case SHAAR_MEDIA_PIP_EXIT: *action = MediaSessionAction::kExitPictureInPicture; return true;
    default: return false;
  }
}

}  // namespace shaar::media

shaar_error_code HandleMediaOperation(
    shaar::ShaarEngineContext* context,
    shaar_engine* engine,
    shaar_scope scope,
    shaar_window* window,
    shaar_tab* tab,
    shaar_operation operation,
    shaar_bytes bytes,
    shaar_request_id request_id,
    shaar_reply_fn reply,
    void* reply_context,
    shaar_error* immediate_error) {
  content::WebContents* contents = nullptr;
  if (scope.size < sizeof(shaar_scope) ||
      ((scope.profile != nullptr) == (scope.private_session != nullptr)))
    return Fail(immediate_error, SHAAR_INVALID_ARGUMENT, "invalid media scope");
  if (scope.private_session && (!context || !context->media_services))
    return Fail(immediate_error, SHAAR_UNSUPPORTED_CAPABILITY,
                "private media scope validation is not connected");
  if (!ValidScopeForTab(context, engine, scope, window, tab, &contents))
    return Fail(immediate_error,
                scope.private_session ? SHAAR_WRONG_SESSION : SHAAR_WRONG_PROFILE,
                "media tab does not belong to the supplied scope");
  auto args = ParseArguments(bytes);
  if (!args || args->FindInt("schemaVersion") != 1 || !reply || !request_id)
    return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                "invalid media request envelope");

  const ReplyContext request{request_id, reply, reply_context};
  if (operation == SHAAR_OP_MEDIA_PERMISSION_DECISION) {
    const std::string* permission_id = args->FindString("id");
    const auto accepted = args->FindBool("accepted");
    if (!HasOnlyKeys(*args, {"schemaVersion", "id", "accepted"}) ||
        !permission_id || permission_id->empty() || permission_id->size() > 128 ||
        !accepted)
      return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                  "invalid website media decision");
    std::optional<bool> allowed = shaar::media::ResolveWebsiteMediaPermission(
        engine, contents, *permission_id, *accepted);
    if (!allowed) {
      allowed = shaar::permissions::ResolveWebsitePermission(
          engine, contents, *permission_id, *accepted);
    }
    if (!allowed)
      return Fail(immediate_error, SHAAR_NOT_FOUND,
                  "website media request is unavailable");
    base::DictValue result;
    result.Set("schemaVersion", 1);
    result.Set("accepted", *allowed);
    Reply(request, std::move(result));
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_PROBE_MEDIA_GESTURE) {
    if (!IsMarkedMediaProbe(engine, contents))
      return Fail(immediate_error, SHAAR_POLICY_BLOCKED,
                  "media gesture requires an owned loopback probe");
    const std::string* action = args->FindString("action");
    const std::string* element_id = args->FindString("elementID");
    const bool start_video = action && element_id &&
                             *action == "play" && *element_id == "video";
    const bool open_clip = action && element_id &&
                           *action == "playPiP" && *element_id == "clip";
    if (!HasOnlyKeys(*args, {"schemaVersion", "action", "elementID"}) ||
        (!start_video && !open_clip))
      return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                  "probe supports only authored media gestures");
    return shaar::media::ApplyElementAction(contents, SHAAR_MEDIA_PLAY, 0,
                                           request, immediate_error, true,
                                           open_clip);
  }
  if (operation == SHAAR_OP_MEDIA_GET_STATE) {
    if (!HasOnlyKeys(*args, {"schemaVersion"}))
      return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                  "getState accepts no additional fields");
    Reply(request, StateFor(contents));
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_MEDIA_CONTROL) {
    if (!HasOnlyKeys(*args, {"schemaVersion", "command", "value"}))
      return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                  "invalid media control fields");
    const auto command = args->FindInt("command");
    const base::Value* value_item = args->Find("value");
    const bool has_value = value_item != nullptr;
    double value = 0;
    if (value_item && value_item->is_double())
      value = value_item->GetDouble();
    else if (value_item && value_item->is_int())
      value = value_item->GetInt();
    else if (value_item && value_item->is_bool())
      value = value_item->GetBool() ? 1 : 0;
    if (!command || !shaar::media::IsValidControl(*command, value, has_value))
      return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                  "media control value is invalid");
    if (*command == SHAAR_MEDIA_SET_TAB_MUTED) {
      if (!value_item || !value_item->is_bool())
        return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                    "tab mute requires a boolean value");
      contents->SetAudioMuted(value != 0);
      Reply(request, base::DictValue().Set("schemaVersion", 1));
      return SHAAR_OK;
    }
    if (*command == SHAAR_MEDIA_SET_ELEMENT_VOLUME)
    {
      if (value > 0)
        contents->SetAudioMuted(false);
      return shaar::media::ApplyElementVolume(contents, value, request,
                                              immediate_error);
    }
    content::MediaSession* session = content::MediaSession::GetIfExists(contents);
    media_session::mojom::MediaSessionAction action;
    const bool action_mapped =
        shaar::media::MapSessionAction(*command, &action);
    if (action_mapped && session && HasAction(session, action) &&
        *command != SHAAR_MEDIA_SEEK_BACKWARD &&
        *command != SHAAR_MEDIA_SEEK_FORWARD &&
        *command != SHAAR_MEDIA_SEEK_TO &&
        *command != SHAAR_MEDIA_PIP_PLAY &&
        *command != SHAAR_MEDIA_PIP_PAUSE) {
      session->DidReceiveAction(action);
      Reply(request, base::DictValue().Set("schemaVersion", 1));
      return SHAAR_OK;
    }
    if (*command == SHAAR_MEDIA_PIP_SKIP ||
        *command == SHAAR_MEDIA_SEEK_BACKWARD ||
        *command == SHAAR_MEDIA_SEEK_FORWARD ||
        *command == SHAAR_MEDIA_SEEK_TO ||
        *command == SHAAR_MEDIA_PIP_PLAY ||
        *command == SHAAR_MEDIA_PIP_PAUSE ||
        *command == SHAAR_MEDIA_PLAY || *command == SHAAR_MEDIA_PAUSE) {
      if ((*command == SHAAR_MEDIA_SEEK_BACKWARD ||
           *command == SHAAR_MEDIA_SEEK_FORWARD) && !has_value)
        value = 10;
      return shaar::media::ApplyElementAction(contents, *command, value,
                                             request, immediate_error);
    }
    if (!session || !action_mapped || !HasAction(session, action))
      return Fail(immediate_error, SHAAR_UNSUPPORTED_CAPABILITY,
                  "media session does not advertise this action");
    session->DidReceiveAction(action);
    Reply(request, base::DictValue().Set("schemaVersion", 1));
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_MEDIA_ENTER_PIP ||
      operation == SHAAR_OP_MEDIA_EXIT_PIP) {
    if (!HasOnlyKeys(*args, {"schemaVersion"}))
      return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                  "PiP operation accepts no additional fields");
    return shaar::media::ApplyElementAction(
        contents, operation == SHAAR_OP_MEDIA_ENTER_PIP
                      ? SHAAR_MEDIA_PIP_ENTER : SHAAR_MEDIA_PIP_EXIT,
        0, request, immediate_error);
  }
  if (operation == SHAAR_OP_MEDIA_SET_AUTO_PIP) {
    if (!HasOnlyKeys(*args, {"schemaVersion", "allowed"}) ||
        !args->FindBool("allowed"))
      return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                  "setAutoPiP requires an allowed boolean");
  }
  if (operation == SHAAR_OP_MEDIA_LIST_CAPTURE_SOURCES ||
      operation == SHAAR_OP_MEDIA_CAPTURE_REPLY) {
    if (operation == SHAAR_OP_MEDIA_LIST_CAPTURE_SOURCES &&
        !HasOnlyKeys(*args, {"schemaVersion"}))
      return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                  "listCaptureSources accepts no additional fields");
    if (operation == SHAAR_OP_MEDIA_CAPTURE_REPLY &&
        !HasOnlyKeys(*args, {"schemaVersion", "promptID", "decision", "sourceToken"}))
      return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                  "captureReply has invalid fields");
    if (operation == SHAAR_OP_MEDIA_CAPTURE_REPLY) {
      const std::string* prompt_id = args->FindString("promptID");
      const std::string* decision = args->FindString("decision");
      const std::string* source_token = args->FindString("sourceToken");
      if (!prompt_id || prompt_id->empty() || !decision ||
          (*decision != "approve" && *decision != "cancel") ||
          ((*decision == "approve") != (source_token && !source_token->empty())))
        return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                    "captureReply requires a prompt and matching decision token");
    }
  }
  if (operation == SHAAR_OP_MEDIA_SET_AUTO_PIP ||
      operation == SHAAR_OP_MEDIA_LIST_CAPTURE_SOURCES ||
      operation == SHAAR_OP_MEDIA_CAPTURE_REPLY) {
    if (!context->media_services)
      return Fail(immediate_error, SHAAR_UNSUPPORTED_CAPABILITY,
                  "media runtime services are not connected");
    return context->media_services->SubmitSupplementalOperation(
        engine, scope, window, tab, operation, bytes, request_id, reply,
        reply_context, immediate_error);
  }
  return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
              "unknown media operation");
}
