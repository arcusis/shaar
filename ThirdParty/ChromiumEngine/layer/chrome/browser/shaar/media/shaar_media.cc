// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/media/shaar_media.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <initializer_list>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "content/public/browser/media_session.h"
#include "content/public/browser/web_contents.h"
#include "services/media_session/public/mojom/media_session.mojom.h"

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
  return state;
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

bool HasAction(content::MediaSession* session,
               media_session::mojom::MediaSessionAction action) {
  const auto actions = session->GetMediaSessionActionsSync();
  return std::find(actions.begin(), actions.end(), action) != actions.end();
}

}  // namespace

namespace shaar::media {

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
    if (!session || !action_mapped || !HasAction(session, action)) {
      return Fail(immediate_error, SHAAR_UNSUPPORTED_CAPABILITY,
                  "media session does not advertise this action");
    }
    session->DidReceiveAction(action);
    Reply(request, base::DictValue().Set("schemaVersion", 1));
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
    session->DidReceiveAction(action);
    Reply(request, base::DictValue().Set("schemaVersion", 1));
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
        engine, scope, window, tab, operation, bytes, request_id, reply,
        reply_context, immediate_error);
  }
  return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
              "unknown media operation");
}
