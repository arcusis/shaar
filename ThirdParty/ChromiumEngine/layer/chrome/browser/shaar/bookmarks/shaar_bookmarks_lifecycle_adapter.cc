// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/bookmarks/shaar_bookmarks.h"

#include <map>
#include <memory>
#include <string>

#include "base/supports_user_data.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"

namespace {

const int kBookmarksUserDataKey = 0;

class PerEngineBookmarks final : public base::SupportsUserData::Data {
 public:
  shaar::BookmarksModule* Get(Profile* profile,
                              shaar_engine* engine,
                              std::string profile_id) {
    auto& module = instances_[engine];
    if (!module) {
      module = std::make_unique<shaar::BookmarksModule>(
          profile, false, engine, std::move(profile_id));
    }
    return module.get();
  }

 private:
  std::map<shaar_engine*, std::unique_ptr<shaar::BookmarksModule>> instances_;
};

PerEngineBookmarks* GetBookmarksData(Profile* profile) {
  auto* data = static_cast<PerEngineBookmarks*>(
      profile->GetUserData(&kBookmarksUserDataKey));
  if (!data) {
    auto owned = std::make_unique<PerEngineBookmarks>();
    data = owned.get();
    profile->SetUserData(&kBookmarksUserDataKey, std::move(owned));
  }
  return data;
}

struct AbiReplyContext {
  shaar_request_id request_id;
  shaar_reply_fn reply;
  void* context;
};

void ReplyThroughABI(void* raw_context,
                     shaar_error_code code,
                     const std::string& payload) {
  std::unique_ptr<AbiReplyContext> state(
      static_cast<AbiReplyContext*>(raw_context));
  if (!state || !state->reply)
    return;
  shaar_result result = {};
  result.size = sizeof(result);
  result.request_id = state->request_id;
  result.error.size = sizeof(result.error);
  result.error.code = code;
  result.error.platform_code = 0;
  result.payload_json = {payload.data(), payload.size()};
  state->reply(state->context, &result);
}

shaar_error_code HandleLifecycleBookmark(
    shaar::ShaarEngineContext* context,
    shaar_engine* engine,
    shaar_scope scope,
    shaar_window*,
    shaar_tab*,
    shaar_operation operation,
    shaar_bytes args,
    shaar_request_id request_id,
    shaar_reply_fn reply,
    void* reply_context,
    shaar_error*) {
  if (scope.profile && scope.private_session)
    return SHAAR_INVALID_ARGUMENT;
  if (scope.private_session)
    return SHAAR_PRIVATE_DISALLOWED;
  if (!context || !context->profile_services || !engine || !scope.profile ||
      !reply || (args.size && !args.data))
    return SHAAR_INVALID_ARGUMENT;
  Profile* profile =
      context->profile_services->ResolveProfile(engine, scope.profile);
  const std::string_view profile_id =
      context->profile_services->ProfileID(engine, scope.profile);
  if (!profile || profile_id.empty())
    return SHAAR_NOT_FOUND;
  auto* module = GetBookmarksData(profile)->Get(
      profile, engine, std::string(profile_id));
  auto reply_state = std::make_unique<AbiReplyContext>(
      AbiReplyContext{request_id, reply, reply_context});
  const std::string arguments(args.data ? args.data : "", args.size);
  const shaar_error_code status = module->Submit(
      operation, arguments, &ReplyThroughABI, reply_state.get());
  if (status != SHAAR_OK)
    return status;
  reply_state.release();
  return SHAAR_OK;
}

}  // namespace

extern "C" void shaar_bookmarks_register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  registry->Register(SHAAR_OP_BOOKMARK_TREE, SHAAR_OP_BOOKMARK_TREE,
                     &HandleLifecycleBookmark);
  registry->Register(SHAAR_OP_BOOKMARK_APPLY, SHAAR_OP_BOOKMARK_APPLY,
                     &HandleLifecycleBookmark);
  registry->Register(SHAAR_OP_BOOKMARK_WATCH, SHAAR_OP_BOOKMARK_WATCH,
                     &HandleLifecycleBookmark);
}
