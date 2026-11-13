// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/save_prompts/shaar_save_prompts.h"

#include <algorithm>
#include <cstddef>
#include <cstring>
#include <initializer_list>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/web_contents.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace shaar::save_prompts {

GURL CleanPageURLForSavePrompt(const GURL& url) {
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS())
    return GURL();
  GURL::Replacements replacements;
  replacements.ClearUsername();
  replacements.ClearPassword();
  replacements.ClearQuery();
  replacements.ClearRef();
  return url.ReplaceComponents(replacements);
}

namespace {

constexpr size_t kMaximumArgumentsBytes = 1024;
constexpr size_t kMaximumPending = 8;
constexpr size_t kMaximumDecisionRequestIDBytes = 20;
constexpr size_t kMaximumDetailBytes = 120;
constexpr size_t kMaximumOriginBytes = 256;
constexpr size_t kMaximumPageBytes = 2048;

struct PendingPrompt {
  shaar_engine* engine = nullptr;
  content::WebContents* contents = nullptr;
  shaar_window* window = nullptr;
  shaar_tab* tab = nullptr;
  std::string profile_id;
  std::string window_id;
  std::string tab_id;
  std::string prompt;
  GURL page_url;
  bool update = false;
  base::OnceCallback<void(int)> decision;
};

using PendingMap = std::map<std::string, PendingPrompt>;

struct ReplyContext {
  shaar_request_id request_id;
  shaar_reply_fn callback;
  void* context;
};

PendingMap& Pending() {
  static base::NoDestructor<PendingMap> pending;
  return *pending;
}

uint64_t& NextRequestID() {
  static uint64_t next = 0;
  return next;
}

const char* DecisionName(int code) {
  if (code == kDecisionSave)
    return "save";
  if (code == kDecisionNever)
    return "never";
  return "dismiss";
}

bool KnownPrompt(const char* prompt) {
  return prompt && (std::strcmp(prompt, "password") == 0 ||
                    std::strcmp(prompt, "card") == 0 ||
                    std::strcmp(prompt, "address") == 0);
}

GURL OriginURL(const GURL& page) {
  if (!page.is_valid())
    return GURL();
  return url::Origin::Create(page).GetURL();
}

bool IsFormattingCharacter(std::string_view bytes) {
  if (bytes.size() == 2 &&
      (bytes == "\xC2\xAD" || bytes == "\xD8\x9C"))
    return true;
  if (bytes.size() == 3 && bytes[0] == '\xE2') {
    const unsigned char second = static_cast<unsigned char>(bytes[1]);
    const unsigned char third = static_cast<unsigned char>(bytes[2]);
    if (second == 0x80 &&
        (third == 0x8B || third == 0x8C || third == 0x8D ||
         third == 0x8E || third == 0x8F ||
         (third >= 0xAA && third <= 0xAE)))
      return true;
    if (second == 0x81 && third >= 0xA0 && third <= 0xAF)
      return true;
  }
  return bytes == "\xEF\xBB\xBF";
}

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
    if (size >= offsetof(shaar_error, platform_code) +
                    sizeof(error->platform_code))
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

void Finish(const std::string& request_id, int choice) {
  auto found = Pending().find(request_id);
  if (found == Pending().end())
    return;
  auto callback = std::move(found->second.decision);
  Pending().erase(found);
  if (callback)
    std::move(callback).Run(choice);
}

void EmitDismiss(const PendingPrompt& pending, const std::string& request_id) {
  if (!lifecycle::EngineIsReady(pending.engine))
    return;
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "savePromptDismissed");
  payload.Set("id", request_id);
  std::string json;
  if (!base::JSONWriter::Write(payload, &json))
    return;
  shaar::EmitEvent(pending.engine, SHAAR_EVENT_SAVE_PROMPT,
                   {pending.profile_id.data(), pending.profile_id.size()}, {},
                   {pending.window_id.data(), pending.window_id.size()},
                   {pending.tab_id.data(), pending.tab_id.size()},
                   {json.data(), json.size()});
}

void Expire(std::string request_id) {
  auto found = Pending().find(request_id);
  if (found == Pending().end())
    return;
  EmitDismiss(found->second, request_id);
  Finish(request_id, kDecisionDismiss);
}

void Supersede(content::WebContents* contents) {
  std::vector<std::string> ids;
  for (const auto& [id, pending] : Pending()) {
    if (pending.contents == contents)
      ids.push_back(id);
  }
  for (const auto& id : ids) {
    auto found = Pending().find(id);
    if (found == Pending().end())
      continue;
    EmitDismiss(found->second, id);
    Finish(id, kDecisionDismiss);
  }
}

bool IsCurrent(const PendingPrompt& pending) {
  if (!lifecycle::EngineIsReady(pending.engine) || !pending.contents)
    return false;
  auto identity = windows_tabs::Registry().FindSelectedRegularTab(
      pending.engine, pending.contents);
  if (!identity)
    return false;
  const bool same_tab = identity->window == pending.window &&
                        identity->tab == pending.tab &&
                        identity->profile_id == pending.profile_id &&
                        identity->window_id == pending.window_id &&
                        identity->tab_id == pending.tab_id;
  return same_tab &&
         CleanPageURLForSavePrompt(pending.contents->GetLastCommittedURL()) ==
             pending.page_url;
}

int TakeDecision(shaar_engine* engine,
                 content::WebContents* contents,
                 const std::string& request_id,
                 const std::string& decision,
                 shaar_error_code* error) {
  auto found = Pending().find(request_id);
  if (found == Pending().end() || found->second.engine != engine ||
      found->second.contents != contents) {
    *error = SHAAR_NOT_FOUND;
    return 0;
  }
  const int code = DecisionCode(found->second.prompt.c_str(),
                                found->second.update, decision.c_str());
  if (code == 0) {
    *error = SHAAR_INVALID_ARGUMENT;
    return 0;
  }
  if (!IsCurrent(found->second)) {
    Finish(request_id, kDecisionDismiss);
    *error = SHAAR_NOT_FOUND;
    return 0;
  }
  Finish(request_id, code);
  *error = SHAAR_OK;
  return code;
}

bool ProfileOwnsContents(shaar::ShaarEngineContext* context,
                         shaar_engine* engine,
                         shaar_scope scope,
                         content::WebContents* contents) {
  if (!context->profile_services)
    return false;
  Profile* profile =
      context->profile_services->ResolveProfile(engine, scope.profile);
  return profile && !profile->IsOffTheRecord() &&
         profile == Profile::FromBrowserContext(contents->GetBrowserContext());
}

}  // namespace

void SupersedeSavePrompts(content::WebContents* contents) {
  if (contents)
    Supersede(contents);
}

void DismissSavePromptsForDestroyedContents(content::WebContents* contents) {
  SupersedeSavePrompts(contents);
}

int DecisionCode(const char* prompt, bool update, const char* decision) {
  if (!decision)
    return 0;
  if (std::strcmp(decision, "save") == 0)
    return kDecisionSave;
  if (std::strcmp(decision, "dismiss") == 0)
    return kDecisionDismiss;
  if (std::strcmp(decision, "never") != 0)
    return 0;
  if (prompt && std::strcmp(prompt, "password") == 0 && !update)
    return kDecisionNever;
  return kDecisionDismiss;
}

bool IsValidDecisionRequestID(std::string_view id) {
  if (id.empty() || id.size() > kMaximumDecisionRequestIDBytes)
    return false;
  // Save prompt IDs are generated by incrementing NextRequestID(). Keep the
  // decision envelope to that decimal representation.
  for (unsigned char c : id) {
    if (c < '0' || c > '9')
      return false;
  }
  return true;
}

bool SavePromptAllowedForContext(bool has_browser_context,
                                 bool off_the_record) {
  return has_browser_context && !off_the_record;
}

std::string SanitizeDetail(std::string_view raw) {
  std::string cleaned;
  size_t index = 0;
  while (index < raw.size() && cleaned.size() < kMaximumDetailBytes) {
    const auto lead = static_cast<unsigned char>(raw[index]);
    if (lead < 32 || lead == 127) {
      ++index;
      continue;
    }
    if (lead == 0xC2 && index + 1 < raw.size()) {
      const auto second = static_cast<unsigned char>(raw[index + 1]);
      if (second >= 0x80 && second <= 0x9F) {
        index += 2;
        continue;
      }
    }
    size_t length = 1;
    if (lead >= 0xC2 && lead <= 0xDF)
      length = 2;
    else if (lead >= 0xE0 && lead <= 0xEF)
      length = 3;
    else if (lead >= 0xF0 && lead <= 0xF4)
      length = 4;
    else if (lead >= 128) {
      ++index;
      continue;
    }
    if (index + length > raw.size())
      break;
    if (cleaned.size() + length > kMaximumDetailBytes)
      break;
    const std::string_view character = raw.substr(index, length);
    if (!IsFormattingCharacter(character))
      cleaned.append(character);
    index += length;
  }
  return cleaned;
}

bool OfferSavePrompt(content::WebContents* contents,
                     const char* prompt,
                     const char* detail,
                     bool update,
                     base::OnceCallback<void(int)> decision) {
  if (!decision)
    return false;
  auto decline = [&decision]() {
    std::move(decision).Run(kDecisionDismiss);
    return false;
  };
  const bool password = prompt && std::strcmp(prompt, "password") == 0;
  if (!contents || !KnownPrompt(prompt) || (update && !password))
    return decline();
  content::BrowserContext* browser_context = contents->GetBrowserContext();
  const bool off_the_record =
      browser_context && browser_context->IsOffTheRecord();
  if (!SavePromptAllowedForContext(browser_context != nullptr, off_the_record))
    return decline();

  shaar_engine* engine = lifecycle::ActiveEngine();
  auto identity =
      windows_tabs::Registry().FindSelectedRegularTab(engine, contents);
  if (!lifecycle::EngineIsReady(engine) || !identity ||
      identity->profile_id.empty() || identity->window_id.empty() ||
      identity->tab_id.empty())
    return decline();

  const GURL page = CleanPageURLForSavePrompt(contents->GetLastCommittedURL());
  const GURL origin = OriginURL(page);
  if (!page.is_valid() || !origin.is_valid() ||
      page.spec().size() > kMaximumPageBytes ||
      origin.spec().size() > kMaximumOriginBytes)
    return decline();

  const std::string safe_detail = SanitizeDetail(detail ? detail : "");
  const std::string id = std::to_string(++NextRequestID());
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "savePromptRequested");
  payload.Set("id", id);
  payload.Set("prompt", prompt);
  payload.Set("origin", origin.spec());
  payload.Set("pageURL", origin.spec());
  payload.Set("detail", safe_detail);
  payload.Set("update", update);
  std::string json;
  if (!base::JSONWriter::Write(payload, &json))
    return decline();

  const std::string profile_id = identity->profile_id;
  const std::string window_id = identity->window_id;
  const std::string tab_id = identity->tab_id;
  shaar_window* const window = identity->window;
  shaar_tab* const tab = identity->tab;
  Supersede(contents);
  if (Pending().size() >= kMaximumPending)
    return decline();

  Pending().emplace(id, PendingPrompt{engine, contents, window, tab, profile_id,
                                      window_id, tab_id, prompt, page, update,
                                      std::move(decision)});
  const bool expiry_scheduled =
      base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
          FROM_HERE, base::BindOnce(&Expire, id), base::Minutes(2));
  if (!expiry_scheduled) {
    Finish(id, kDecisionDismiss);
    return false;
  }
  const shaar_error_code emitted = shaar::EmitEvent(
      engine, SHAAR_EVENT_SAVE_PROMPT, {profile_id.data(), profile_id.size()},
      {}, {window_id.data(), window_id.size()}, {tab_id.data(), tab_id.size()},
      {json.data(), json.size()});
  if (emitted != SHAAR_OK)
    Finish(id, kDecisionDismiss);
  return emitted == SHAAR_OK && Pending().find(id) != Pending().end();
}

shaar_error_code CompleteDecision(shaar::ShaarEngineContext* context,
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
  if (operation != SHAAR_OP_SAVE_PROMPT_DECIDE)
    return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                "unknown save prompt operation");
  if (scope.size < sizeof(shaar_scope) ||
      ((scope.profile != nullptr) == (scope.private_session != nullptr)))
    return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                "invalid save prompt scope");
  if (scope.private_session)
    return Fail(immediate_error, SHAAR_PRIVATE_DISALLOWED,
                "save prompts are not offered in a private window");
  if (!context || !context->browser_tabs || !window || !tab || !reply ||
      !request_id)
    return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                "save prompt tab is missing");
  if (!context->profile_services)
    return Fail(immediate_error, SHAAR_NOT_READY,
                "save prompt profile ownership is unavailable");
  content::WebContents* contents =
      context->browser_tabs->FindWebContents(engine, window, tab);
  if (!contents)
    return Fail(immediate_error, SHAAR_NOT_FOUND,
                "save prompt tab is unavailable");
  if (!ProfileOwnsContents(context, engine, scope, contents))
    return Fail(immediate_error, SHAAR_WRONG_PROFILE,
                "save prompt tab does not belong to the supplied profile");
  auto args = ParseArguments(bytes);
  if (!args || args->FindInt("schemaVersion") != 1)
    return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                "invalid save prompt envelope");
  const std::string* id = args->FindString("id");
  const std::string* decision = args->FindString("decision");
  if (!HasOnlyKeys(*args, {"schemaVersion", "id", "decision"}) || !id ||
      !decision || !IsValidDecisionRequestID(*id))
    return Fail(immediate_error, SHAAR_INVALID_ARGUMENT,
                "invalid save prompt decision");

  shaar_error_code resolved = SHAAR_OK;
  const int code = TakeDecision(engine, contents, *id, *decision, &resolved);
  if (resolved != SHAAR_OK) {
    const char* message = resolved == SHAAR_INVALID_ARGUMENT
                              ? "invalid save prompt decision"
                              : "save prompt request is unavailable";
    return Fail(immediate_error, resolved, message);
  }
  base::DictValue result;
  result.Set("schemaVersion", 1);
  result.Set("decision", DecisionName(code));
  Reply({request_id, reply, reply_context}, std::move(result));
  return SHAAR_OK;
}

}  // namespace shaar::save_prompts

shaar_error_code HandleSavePromptOperation(
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
  return shaar::save_prompts::CompleteDecision(
      context, engine, scope, window, tab, operation, bytes, request_id, reply,
      reply_context, immediate_error);
}

extern "C" void shaar_save_prompts_register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  registry->Register(SHAAR_OP_SAVE_PROMPT_DECIDE, SHAAR_OP_SAVE_PROMPT_DECIDE,
                     &HandleSavePromptOperation);
  static const ShaarModuleRegistry::Handler handlers =
      &HandleSavePromptOperation;
  registry->RegisterModule(SHAAR_MODULE_SAVE_PROMPTS, &handlers);
}
