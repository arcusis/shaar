// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/storage_keychain/shaar_storage_keychain.h"

#include <stdint.h>

#include <string>
#include <string_view>

#include "base/json/json_reader.h"
#include "base/test/task_environment.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace {

class FakeProfileServices final : public shaar::ProfileServices {
 public:
  Profile* ResolveProfile(shaar_engine*, shaar_profile* handle) override {
    ++resolve_calls;
    return available && handle == expected_handle
               ? reinterpret_cast<Profile*>(1)
               : nullptr;
  }

  std::string_view ProfileID(shaar_engine*, shaar_profile* handle) override {
    return available && handle == expected_handle ? "profile-1" : "";
  }

  KeyedService* GetKeyedService(shaar_engine*, shaar_profile*,
                                KeyedServiceLookup) override {
    return nullptr;
  }

  shaar_profile* expected_handle = reinterpret_cast<shaar_profile*>(2);
  bool available = true;
  int resolve_calls = 0;
};

struct CapturedReply {
  bool called = false;
  shaar_error_code code = SHAAR_OK;
  std::string payload;
};

void Capture(void* context, const shaar_result* result) {
  auto* captured = static_cast<CapturedReply*>(context);
  captured->called = true;
  captured->code = result->error.code;
  captured->payload.assign(result->payload_json.data,
                           result->payload_json.size);
}

shaar_bytes Bytes(const std::string& value) {
  return {value.data(), value.size()};
}

TEST(ShaarStorageKeychainTest, UsesStableShaarIdentityWithoutReadingKeychain) {
  const auto identity = shaar::storage_keychain::CurrentSafeStorageIdentity();
  EXPECT_EQ(identity.service_name, "Shaar Safe Storage");
  EXPECT_EQ(identity.account_name, "Shaar");
}

TEST(ShaarStorageKeychainTest, RegistersOnlyItsIdentityOperationAndModuleID) {
  ShaarModuleRegistry registry;
  shaar_storage_keychain_register(&registry);
  EXPECT_EQ(registry.Find(SHAAR_OP_STORAGE_KEYCHAIN_IDENTITY),
            &shaar::storage_keychain::HandleIdentityStatus);
  const auto* handlers = static_cast<const shaar::storage_keychain::
                             StorageKeychainModuleHandlers*>(
      registry.FindModule(SHAAR_MODULE_STORAGE_KEYCHAIN));
  ASSERT_NE(handlers, nullptr);
  EXPECT_EQ(handlers->identity,
            &shaar::storage_keychain::CurrentSafeStorageIdentity);
  EXPECT_EQ(registry.Find(SHAAR_OP_PROFILE_GET_STATE), nullptr);
}

TEST(ShaarStorageKeychainTest, ReturnsOnlyNonSecretIdentityStatusForLiveProfile) {
  base::test::TaskEnvironment task_environment;
  FakeProfileServices profiles;
  shaar::ShaarEngineContext context{&profiles, nullptr};
  auto* engine = reinterpret_cast<shaar_engine*>(3);
  shaar_scope scope{sizeof(shaar_scope), profiles.expected_handle, nullptr};
  const std::string args = R"({"schemaVersion":1})";
  CapturedReply reply;
  shaar_error error{};
  error.size = sizeof(error);

  EXPECT_EQ(shaar::storage_keychain::HandleIdentityStatus(
                &context, engine, scope, nullptr, nullptr,
                SHAAR_OP_STORAGE_KEYCHAIN_IDENTITY, Bytes(args), 99, &Capture,
                &reply, &error),
            SHAAR_OK);
  EXPECT_FALSE(reply.called);
  task_environment.RunUntilIdle();

  ASSERT_TRUE(reply.called);
  EXPECT_EQ(reply.code, SHAAR_OK);
  EXPECT_EQ(profiles.resolve_calls, 2);
  auto payload = base::JSONReader::ReadDict(reply.payload);
  ASSERT_TRUE(payload);
  EXPECT_EQ(payload->size(), 2u);
  EXPECT_EQ(payload->FindInt("schemaVersion"), 1);
  ASSERT_NE(payload->FindString("identity"), nullptr);
  EXPECT_EQ(*payload->FindString("identity"), "shaar");
  EXPECT_FALSE(payload->Find("serviceName"));
  EXPECT_FALSE(payload->Find("accountName"));
  EXPECT_FALSE(payload->Find("secret"));
  EXPECT_EQ(error.code, SHAAR_OK);
}

TEST(ShaarStorageKeychainTest, RejectsPrivateScopeAndUnknownFieldsBeforeLookup) {
  FakeProfileServices profiles;
  shaar::ShaarEngineContext context{&profiles, nullptr};
  auto* engine = reinterpret_cast<shaar_engine*>(3);
  shaar_error error{};
  error.size = sizeof(error);
  CapturedReply reply;
  const std::string valid_args = R"({"schemaVersion":1})";
  shaar_scope private_scope{
      sizeof(shaar_scope), nullptr,
      reinterpret_cast<shaar_private_session*>(4)};

  EXPECT_EQ(shaar::storage_keychain::HandleIdentityStatus(
                &context, engine, private_scope, nullptr, nullptr,
                SHAAR_OP_STORAGE_KEYCHAIN_IDENTITY, Bytes(valid_args), 1,
                &Capture, &reply, &error),
            SHAAR_PRIVATE_DISALLOWED);
  EXPECT_EQ(error.code, SHAAR_PRIVATE_DISALLOWED);
  EXPECT_FALSE(reply.called);

  const std::string unknown_args =
      R"({"schemaVersion":1,"includeKeychainValue":true})";
  shaar_scope regular_scope{sizeof(shaar_scope), profiles.expected_handle,
                            nullptr};
  error.code = SHAAR_OK;
  EXPECT_EQ(shaar::storage_keychain::HandleIdentityStatus(
                &context, engine, regular_scope, nullptr, nullptr,
                SHAAR_OP_STORAGE_KEYCHAIN_IDENTITY, Bytes(unknown_args), 2,
                &Capture, &reply, &error),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(error.code, SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(profiles.resolve_calls, 0);
  EXPECT_FALSE(reply.called);
}

TEST(ShaarStorageKeychainTest, RevalidatesProfileBeforeDeferredCompletion) {
  base::test::TaskEnvironment task_environment;
  FakeProfileServices profiles;
  shaar::ShaarEngineContext context{&profiles, nullptr};
  auto* engine = reinterpret_cast<shaar_engine*>(3);
  shaar_scope scope{sizeof(shaar_scope), profiles.expected_handle, nullptr};
  const std::string args = R"({"schemaVersion":1})";
  CapturedReply reply;
  shaar_error error{};
  error.size = sizeof(error);

  ASSERT_EQ(shaar::storage_keychain::HandleIdentityStatus(
                &context, engine, scope, nullptr, nullptr,
                SHAAR_OP_STORAGE_KEYCHAIN_IDENTITY, Bytes(args), 100, &Capture,
                &reply, &error),
            SHAAR_OK);
  profiles.available = false;
  task_environment.RunUntilIdle();

  ASSERT_TRUE(reply.called);
  EXPECT_EQ(reply.code, SHAAR_NOT_FOUND);
  EXPECT_TRUE(reply.payload.empty());
}

}  // namespace
