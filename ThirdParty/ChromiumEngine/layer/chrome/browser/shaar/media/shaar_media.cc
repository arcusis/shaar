// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/media/shaar_media.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <initializer_list>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/time/time.h"
#include "base/containers/flat_map.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "content/public/browser/media_session.h"
#include "content/public/browser/navigation_handle.h"
#include "content/browser/media/session/media_session_impl.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "services/media_session/public/mojom/media_session.mojom.h"
#include "services/media_session/public/cpp/media_image.h"
#include "third_party/blink/public/mojom/mediasession/media_session.mojom.h"
#include "url/gurl.h"

namespace {

constexpr size_t kMaximumArgumentsBytes = 64 * 1024;

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

void Reply(const ReplyContext& request, base::Value::Dict payload) {
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

std::optional<base::Value::Dict> ParseArguments(shaar_bytes bytes) {
  if (!bytes.data || bytes.size == 0 || bytes.size > kMaximumArgumentsBytes)
    return std::nullopt;
  auto parsed = base::JSONReader::Read(
      std::string_view(bytes.data, bytes.size));
  if (!parsed || !parsed->is_dict())
    return std::nullopt;
  return std::move(parsed->GetDict());
}

bool HasOnlyKeys(const base::Value::Dict& dict,
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

base::Value::Dict StateFor(content::WebContents* contents) {
  base::Value::Dict state;
  state.Set("schemaVersion", 1);
  state.Set("playbackState", "none");
  state.Set("title", "");
  state.Set("artist", "");
  state.Set("album", "");
  state.Set("artwork", base::Value());
  state.Set("supportedActions", base::Value::List());
  state.Set("canSeek", false);
  state.Set("hasVideo", false);
  state.Set("tabMuted", contents->IsAudioMuted());
  state.Set("pageVolume", base::Value());
  state.Set("silent", base::Value());
  state.Set("pipVideoState", base::Value());
  state.Set("videoWidth", base::Value());
  state.Set("videoHeight", base::Value());

  content::MediaSession* session = content::MediaSession::GetIfExists(contents);
  if (!session)
    return state;

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
  base::Value::List supported_actions;
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
  return state;
}

void EmitStateChanged(shaar::ShaarEngineContext* context,
                      shaar_engine* engine,
                      shaar_scope scope,
                      shaar_window* window,
                      shaar_tab* tab,
                      content::WebContents* contents) {
  if (!context || !context->profile_services || !context->browser_tabs ||
      !scope.profile || scope.private_session)
    return;
  const std::string_view profile_id =
      context->profile_services->ProfileID(engine, scope.profile);
  const std::string_view window_id =
      context->browser_tabs->WindowID(engine, window);
  const std::string_view tab_id =
      context->browser_tabs->TabID(engine, window, tab);
  if (profile_id.empty() || tab_id.empty())
    return;
  std::string state_json;
  base::JSONWriter::Write(base::Value(StateFor(contents)), &state_json);
  const std::string payload =
      shaar::media::SerializeStateChangedEvent(state_json);
  shaar::EmitEvent(engine, SHAAR_EVENT_MEDIA,
                   {profile_id.data(), profile_id.size()}, {nullptr, 0},
                   {window_id.data(), window_id.size()}, {tab_id.data(), tab_id.size()},
                   {payload.data(), payload.size()});
}

class MediaSessionEventObserver final
    : public content::WebContentsObserver,
      public media_session::mojom::MediaSessionObserver {
 public:
  MediaSessionEventObserver(content::WebContents* contents,
                            shaar_engine* engine,
                            std::string profile_id,
                            std::string window_id,
                            std::string tab_id)
      : content::WebContentsObserver(contents),
        engine_(engine),
        profile_id_(std::move(profile_id)),
        window_id_(std::move(window_id)),
        tab_id_(std::move(tab_id)) {}

  void Start(content::MediaSession* session) {
    mojo::PendingRemote<media_session::mojom::MediaSessionObserver> remote;
    receiver_.Bind(remote.InitWithNewPipeAndPassReceiver());
    session->AddObserver(std::move(remote));
  }

  bool Observes(content::WebContents* contents) const {
    return web_contents() == contents;
  }

  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (!navigation->HasCommitted() || !navigation->IsInPrimaryMainFrame())
      return;
    receiver_.reset();
    if (auto* session = content::MediaSession::GetIfExists(web_contents()))
      Start(session);
    Publish();
  }

  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override {
    receiver_.reset();
    Publish();
  }

  void WebContentsDestroyed() override { receiver_.reset(); }

  void MediaSessionInfoChanged(
      media_session::mojom::MediaSessionInfoPtr) override { Publish(); }
  void MediaSessionMetadataChanged(
      const std::optional<media_session::MediaMetadata>&) override { Publish(); }
  void MediaSessionActionsChanged(
      const std::vector<media_session::mojom::MediaSessionAction>&) override {
    Publish();
  }
  void MediaSessionImagesChanged(
      const base::flat_map<media_session::mojom::MediaSessionImageType,
                           std::vector<media_session::MediaImage>>&) override {
    Publish();
  }
  void MediaSessionPositionChanged(
      const std::optional<media_session::MediaPosition>&) override {
    Publish();
  }

 private:
  void Publish() {
    if (!web_contents())
      return;
    std::string state_json;
    base::JSONWriter::Write(base::Value(StateFor(web_contents())), &state_json);
    const std::string payload =
        shaar::media::SerializeStateChangedEvent(state_json);
    shaar::EmitEvent(engine_, SHAAR_EVENT_MEDIA,
                     {profile_id_.data(), profile_id_.size()}, {nullptr, 0},
                     {window_id_.data(), window_id_.size()},
                     {tab_id_.data(), tab_id_.size()},
                     {payload.data(), payload.size()});
  }

  shaar_engine* engine_;
  const std::string profile_id_;
  const std::string window_id_;
  const std::string tab_id_;
  mojo::Receiver<media_session::mojom::MediaSessionObserver> receiver_{this};
};

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
         context->media_services->OwnsPrivateTab(engine, context, scope, window,
                                                 tab, *contents);
}

class ShaarMediaRuntimeServices final : public shaar::MediaRuntimeServices {
 public:
  void ObserveMediaTab(shaar::ShaarEngineContext* context,
                  shaar_engine* engine,
                  shaar_scope scope,
                  shaar_window* window,
                  shaar_tab* tab,
                  content::WebContents* contents) override {
    std::erase_if(observers_, [](const auto& observer) {
      return !observer->web_contents();
    });
    if (!context || !context->profile_services || !context->browser_tabs ||
        !scope.profile || scope.private_session)
      return;
    const std::string_view profile_id =
        context->profile_services->ProfileID(engine, scope.profile);
    const std::string_view window_id =
        context->browser_tabs->WindowID(engine, window);
    const std::string_view tab_id =
        context->browser_tabs->TabID(engine, window, tab);
    content::MediaSession* session = content::MediaSession::GetIfExists(contents);
    if (profile_id.empty() || tab_id.empty() || !session ||
        std::any_of(observers_.begin(), observers_.end(),
                    [contents](const auto& observer) {
                      return observer->Observes(contents);
                    }))
      return;
    auto observer = std::make_unique<MediaSessionEventObserver>(
        contents, engine, std::string(profile_id), std::string(window_id),
        std::string(tab_id));
    observer->Start(session);
    observers_.push_back(std::move(observer));
  }

  bool OwnsPrivateTab(shaar_engine*,
                      shaar::ShaarEngineContext*,
                      shaar_scope,
                      shaar_window*,
                      shaar_tab*,
                      content::WebContents*) override {
    // The batch-2 private-session ABI has no resolver for its opaque handle.
    // Fail closed until lifecycle provides one; checking only IsOffTheRecord()
    // would let one private session address another session's tab.
    return false;
  }

  shaar_error_code SubmitSupplementalOperation(
      shaar::ShaarEngineContext* context,
      shaar_engine* engine,
      shaar_scope scope,
      shaar_window* window,
      shaar_tab* tab,
      shaar_operation operation,
      shaar_bytes args_json,
      shaar_request_id request_id,
      shaar_reply_fn reply,
      void* reply_context,
      shaar_error* immediate_error) override {
    if (!context || !context->browser_tabs || !engine || !window || !tab ||
        !reply || !request_id)
      return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                  "invalid supplemental media request");
    if (scope.private_session)
      return Fail(immediate_error, SHAAR_PRIVATE_DISALLOWED,
                  "media policy and capture are not available in private scope");
    if (!scope.profile || !context->profile_services)
      return Fail(immediate_error, SHAAR_WRONG_PROFILE,
                  "media operation requires a regular profile");
    Profile* profile =
        context->profile_services->ResolveProfile(engine, scope.profile);
    content::WebContents* contents =
        context->browser_tabs->FindWebContents(engine, window, tab);
    if (!profile || profile->IsOffTheRecord() || !contents ||
        Profile::FromBrowserContext(contents->GetBrowserContext()) != profile)
      return Fail(immediate_error, SHAAR_WRONG_PROFILE,
                  "media tab does not belong to the supplied profile");

    const ReplyContext request{request_id, reply, reply_context};
    if (operation == SHAAR_OP_MEDIA_SET_AUTO_PIP) {
      auto args = ParseArguments(args_json);
      if (!args || args->FindInt("schemaVersion") != 1 ||
          !HasOnlyKeys(*args, {"schemaVersion", "allowed"}) ||
          !args->FindBool("allowed"))
        return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                    "setAutoPiP requires an allowed boolean");
      const GURL url = contents->GetLastCommittedURL();
      if (!shaar::media::IsAllowedAutoPiPURL(url.spec()))
        return Fail(immediate_error, SHAAR_POLICY_BLOCKED,
                    "auto PiP policy requires a committed HTTP or HTTPS page");
      auto* settings = HostContentSettingsMapFactory::GetForProfile(profile);
      if (!settings)
        return Fail(immediate_error, SHAAR_NOT_READY,
                    "profile content settings are not ready");
      settings->SetContentSettingDefaultScope(
          url, GURL(), ContentSettingsType::AUTO_PICTURE_IN_PICTURE,
          *args->FindBool("allowed") ? CONTENT_SETTING_ALLOW
                                      : CONTENT_SETTING_BLOCK);
      Reply(request, base::Value::Dict().Set("schemaVersion", 1));
      return SHAAR_OK;
    }
    if (operation == SHAAR_OP_MEDIA_LIST_CAPTURE_SOURCES)
      return Fail(immediate_error, SHAAR_UNSUPPORTED_CAPABILITY,
                  "native capture source enumeration is not connected");
    if (operation == SHAAR_OP_MEDIA_CAPTURE_REPLY)
      return Fail(immediate_error, SHAAR_PERMISSION_DENIED,
                  "capture reply has no matching engine-issued source grant");
    return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                "unknown supplemental media operation");
  }

 private:
  std::vector<std::unique_ptr<MediaSessionEventObserver>> observers_;
};

ShaarMediaRuntimeServices g_media_runtime_services;

bool HasAction(content::MediaSession* session,
               media_session::mojom::MediaSessionAction action) {
  const auto actions = session->GetMediaSessionActionsSync();
  return std::find(actions.begin(), actions.end(), action) != actions.end();
}

}  // namespace

namespace shaar::media {

bool IsAllowedAutoPiPURL(std::string_view raw_url) {
  const GURL url(raw_url);
  return url.is_valid() && url.SchemeIsHTTPOrHTTPS() && url.has_host();
}

std::string SerializeStateChangedEvent(std::string_view state_json) {
  return "{\"kind\":\"state_changed\",\"schemaVersion\":1,\"state\":" +
         std::string(state_json) + "}";
}

void InstallRuntimeServices(shaar::ShaarEngineContext* context) {
  shaar::SetMediaRuntimeServices(&g_media_runtime_services);
  if (context)
    context->media_services = &g_media_runtime_services;
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

std::optional<double> SeekTarget(uint32_t command,
                                 double value,
                                 bool has_value,
                                 double current_position) {
  if (!std::isfinite(current_position))
    return std::nullopt;
  if (command == SHAAR_MEDIA_SEEK_TO)
    return has_value && std::isfinite(value) && value >= 0 && value <= 86400
               ? std::optional<double>(value)
               : std::nullopt;
  const bool backward = command == SHAAR_MEDIA_SEEK_BACKWARD ||
                        (command == SHAAR_MEDIA_PIP_SKIP && value < 0);
  const bool forward = command == SHAAR_MEDIA_SEEK_FORWARD ||
                       (command == SHAAR_MEDIA_PIP_SKIP && value > 0);
  const double offset = command == SHAAR_MEDIA_PIP_SKIP ? std::abs(value) : value;
  if (!has_value || (!backward && !forward) || !std::isfinite(offset) ||
      offset <= 0 || offset > 86400)
    return std::nullopt;
  return std::clamp(current_position + (backward ? -offset : offset), 0.0,
                    86400.0);
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
  if (!context->media_services)
    return Fail(immediate_error, SHAAR_UNSUPPORTED_CAPABILITY,
                "media runtime services are not connected");
  auto args = ParseArguments(bytes);
  if (!args || args->FindInt("schemaVersion") != 1 || !reply || !request_id)
    return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                "invalid media request envelope");

  const ReplyContext request{request_id, reply, reply_context};
  if (operation == SHAAR_OP_MEDIA_GET_STATE) {
    if (!HasOnlyKeys(*args, {"schemaVersion"}))
      return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                  "getState accepts no additional fields");
    context->media_services->ObserveMediaTab(context, engine, scope, window,
                                              tab, contents);
    EmitStateChanged(context, engine, scope, window, tab, contents);
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
    if (command && *command != SHAAR_MEDIA_SET_TAB_MUTED && value_item &&
        !value_item->is_double() && !value_item->is_int())
      return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                  "numeric media controls require a numeric value");
    if (!command || !shaar::media::IsValidControl(*command, value, has_value))
      return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                  "media control value is invalid");
    if (*command == SHAAR_MEDIA_SET_TAB_MUTED) {
      if (!value_item || !value_item->is_bool())
        return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                    "tab mute requires a boolean value");
      context->media_services->ObserveMediaTab(context, engine, scope, window,
                                                tab, contents);
      contents->SetAudioMuted(value != 0);
      EmitStateChanged(context, engine, scope, window, tab, contents);
      Reply(request, base::Value::Dict().Set("schemaVersion", 1));
      return SHAAR_OK;
    }
    if (*command == SHAAR_MEDIA_SET_ELEMENT_VOLUME)
      return Fail(immediate_error, SHAAR_UNSUPPORTED_CAPABILITY,
                  "page-element volume requires a frame-owned media service");
    content::MediaSession* session = content::MediaSession::GetIfExists(contents);
    media_session::mojom::MediaSessionAction action;
    bool action_mapped = false;
    if (*command == SHAAR_MEDIA_PIP_SKIP) {
      action = value < 0
                   ? media_session::mojom::MediaSessionAction::kPreviousTrack
                   : media_session::mojom::MediaSessionAction::kNextTrack;
      action_mapped = true;
    } else {
      action_mapped = shaar::media::MapSessionAction(*command, &action);
    }
    blink::mojom::MediaSessionActionDetailsPtr action_details;
    const bool detailed_seek =
        *command == SHAAR_MEDIA_SEEK_TO ||
        ((*command == SHAAR_MEDIA_SEEK_BACKWARD ||
          *command == SHAAR_MEDIA_SEEK_FORWARD ||
          *command == SHAAR_MEDIA_PIP_SKIP) && has_value);
    if (session && detailed_seek) {
      const auto position = session->GetMediaSessionPosition();
      if (*command != SHAAR_MEDIA_SEEK_TO && !position)
        return Fail(immediate_error, SHAAR_NOT_READY,
                    "relative seek requires a current media position");
      const double current_position =
          position ? position->position.InSecondsF() : 0.0;
      const auto target = shaar::media::SeekTarget(
          *command, value, has_value, current_position);
      if (!target)
        return Fail(immediate_error, SHAAR_UNSUPPORTED_CAPABILITY,
                    "relative seek requires a current media position");
      action = media_session::mojom::MediaSessionAction::kSeekTo;
      action_mapped = true;
      action_details = blink::mojom::MediaSessionActionDetails::NewSeekTo(
          blink::mojom::MediaSessionSeekToDetails::New(base::Seconds(*target),
                                                       false));
    }
    if (!session || !action_mapped || !HasAction(session, action)) {
      return Fail(immediate_error, SHAAR_UNSUPPORTED_CAPABILITY,
                  "media session does not advertise this action");
    }
    context->media_services->ObserveMediaTab(context, engine, scope, window,
                                              tab, contents);
    if (detailed_seek) {
      static_cast<content::MediaSessionImpl*>(session)->DidReceiveAction(
          action, std::move(action_details));
    } else {
      session->DidReceiveAction(action);
    }
    EmitStateChanged(context, engine, scope, window, tab, contents);
    Reply(request, base::Value::Dict().Set("schemaVersion", 1));
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_MEDIA_ENTER_PIP ||
      operation == SHAAR_OP_MEDIA_EXIT_PIP) {
    if (!HasOnlyKeys(*args, {"schemaVersion"}))
      return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                  "PiP operation accepts no additional fields");
    content::MediaSession* session = content::MediaSession::GetIfExists(contents);
    const auto action = operation == SHAAR_OP_MEDIA_ENTER_PIP
                            ? media_session::mojom::MediaSessionAction::kEnterPictureInPicture
                            : media_session::mojom::MediaSessionAction::kExitPictureInPicture;
    if (!session || !HasAction(session, action))
      return Fail(immediate_error, SHAAR_UNSUPPORTED_CAPABILITY,
                  "tab media session does not advertise the PiP action");
    context->media_services->ObserveMediaTab(context, engine, scope, window,
                                              tab, contents);
    session->DidReceiveAction(action);
    EmitStateChanged(context, engine, scope, window, tab, contents);
    Reply(request, base::Value::Dict().Set("schemaVersion", 1));
    return SHAAR_OK;
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
        context, engine, scope, window, tab, operation, bytes, request_id,
        reply, reply_context, immediate_error);
  }
  return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
              "unknown media operation");
}
