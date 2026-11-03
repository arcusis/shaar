// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/storage_keychain/shaar_storage_keychain.h"

#include <algorithm>
#include <stddef.h>
#include <string.h>

#include <initializer_list>
#include <string_view>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/task/sequenced_task_runner.h"
#include "components/os_crypt/common/keychain_password_mac.h"

namespace shaar::storage_keychain {
namespace {

constexpr char kServiceName[] = "Shaar Safe Storage";
constexpr char kAccountName[] = "Shaar";

shaar_error_code Fail(shaar_error* error,
                      shaar_error_code code,
                      const char* message) {
  if (!error)
    return code;
  const uint32_t supplied_size = error->size;
  if (supplied_size >= offsetof(shaar_error, code) + sizeof(error->code))
    error->code = code;
  if (supplied_size >=
      offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
    error->platform_code = 0;
  if (supplied_size >= offsetof(shaar_error, message) + sizeof(error->message))
    error->message = {message, strlen(message)};
  return code;
}

bool HasOnlyKeys(const base::Value::Dict& dict,
                 std::initializer_list<std::string_view> allowed) {
  for (const auto item : dict) {
    if (std::find(allowed.begin(), allowed.end(), item.first) == allowed.end())
      return false;
  }
  return true;
}

void DeliverIdentityStatus(shaar::ProfileServices* profile_services,
                           shaar_engine* engine,
                           shaar_profile* profile,
                           shaar_reply_fn callback,
                           void* callback_context,
                           shaar_request_id request_id,
                           std::string payload) {
  shaar_result result = {};
  result.size = sizeof(result);
  result.request_id = request_id;
  result.error.size = sizeof(result.error);
  result.error.code = profile_services->ResolveProfile(engine, profile) &&
                              !profile_services->ProfileID(engine, profile).empty()
                          ? SHAAR_OK
                          : SHAAR_NOT_FOUND;
  if (result.error.code != SHAAR_OK)
    return callback(callback_context, &result);
  result.payload_json = {payload.data(), payload.size()};
  callback(callback_context, &result);
}

}  // namespace

SafeStorageIdentity CurrentSafeStorageIdentity() {
  return {KeychainPassword::GetServiceName(),
          KeychainPassword::GetAccountName()};
}

shaar_error_code HandleIdentityStatus(
    ShaarEngineContext* engine_context,
    shaar_engine* engine,
    shaar_scope scope,
    shaar_window*,
    shaar_tab*,
    shaar_operation operation,
    shaar_bytes args,
    shaar_request_id request_id,
    shaar_reply_fn reply,
    void* reply_context,
    shaar_error* error) {
  if (scope.size < sizeof(shaar_scope))
    return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid storage identity scope");
  if (scope.profile && scope.private_session)
    return Fail(error, SHAAR_INVALID_ARGUMENT, "ambiguous storage identity scope");
  if (!scope.profile && !scope.private_session)
    return Fail(error, SHAAR_INVALID_ARGUMENT, "missing storage identity scope");
  if (scope.private_session)
    return Fail(error, SHAAR_PRIVATE_DISALLOWED,
                "storage identity is unavailable in private scope");
  if (operation != SHAAR_OP_STORAGE_KEYCHAIN_IDENTITY || !engine || !reply ||
      !engine_context || !engine_context->profile_services || !scope.profile ||
      ((args.size > 0) && !args.data)) {
    return Fail(error, SHAAR_INVALID_ARGUMENT,
                "invalid storage identity request");
  }

  const auto arguments = base::JSONReader::ReadDict(
      std::string_view(args.data ? args.data : "", args.size));
  if (!arguments || !HasOnlyKeys(*arguments, {"schemaVersion"}) ||
      arguments->FindInt("schemaVersion") != 1) {
    return Fail(error, SHAAR_INVALID_ARGUMENT,
                "invalid storage identity arguments");
  }

  // Resolve through the engine-owned profile registry. The module never
  // searches for a default profile or reaches into a global profile manager.
  if (!engine_context->profile_services->ResolveProfile(engine, scope.profile) ||
      engine_context->profile_services->ProfileID(engine, scope.profile).empty()) {
    return Fail(error, SHAAR_NOT_FOUND, "profile is unavailable");
  }

  const SafeStorageIdentity identity = CurrentSafeStorageIdentity();
  if (identity.service_name != kServiceName ||
      identity.account_name != kAccountName) {
    return Fail(error, SHAAR_UNSUPPORTED_CAPABILITY,
                "engine Safe Storage identity is not Shaar");
  }

  base::Value::Dict result;
  result.Set("schemaVersion", 1);
  result.Set("identity", "shaar");
  std::string payload;
  if (!base::JSONWriter::Write(result, &payload)) {
    return Fail(error, SHAAR_CHROMIUM_ERROR,
                "could not encode storage identity response");
  }
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(&DeliverIdentityStatus,
                     engine_context->profile_services, engine, scope.profile,
                     reply, reply_context, request_id, std::move(payload)));
  return SHAAR_OK;
}

}  // namespace shaar::storage_keychain
