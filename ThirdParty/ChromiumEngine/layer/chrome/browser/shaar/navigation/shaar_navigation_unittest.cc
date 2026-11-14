// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/navigation/shaar_navigation.h"

#include <string>

#include "testing/gtest/include/gtest/gtest.h"

namespace shaar::navigation {
namespace {

class FakeBackend final : public Backend {
 public:
  shaar_error_code Navigate(const std::string& url,
                            bool user_initiated) override {
    navigated_url = url;
    was_user_initiated = user_initiated;
    return SHAAR_OK;
  }
  shaar_error_code Go(bool forward) override {
    went_forward = forward;
    return history_available ? SHAAR_OK : SHAAR_CONFLICT;
  }
  shaar_error_code Reload(bool bypass_cache) override {
    did_bypass_cache = bypass_cache;
    return SHAAR_OK;
  }
  shaar_error_code Stop() override {
    did_stop = true;
    return SHAAR_OK;
  }

  std::string navigated_url;
  bool was_user_initiated = false;
  bool went_forward = false;
  bool history_available = true;
  bool did_bypass_cache = false;
  bool did_stop = false;
};

shaar_bytes Bytes(const std::string& value) {
  return {value.data(), value.size()};
}

TEST(ShaarNavigationHandlerTest,
     NavigatePreservesGestureAndRedactsCredentials) {
  FakeBackend backend;
  const std::string args =
      R"({"schemaVersion":1,"url":"https://user:secret@example.test/path","userInitiated":true})";
  std::string reason;

  EXPECT_EQ(
      HandleCommand(&backend, SHAAR_OP_TAB_NAVIGATE, Bytes(args), &reason),
      SHAAR_OK);
  EXPECT_EQ(backend.navigated_url, "https://example.test/path");
  EXPECT_TRUE(backend.was_user_initiated);
  EXPECT_TRUE(reason.empty());
}

TEST(ShaarNavigationHandlerTest,
     RejectsBlockedSchemesUnknownFieldsAndBadTypes) {
  FakeBackend backend;
  std::string reason;
  const std::string blocked =
      R"json({"schemaVersion":1,"url":"javascript:alert(1)","userInitiated":true})json";
  EXPECT_EQ(
      HandleCommand(&backend, SHAAR_OP_TAB_NAVIGATE, Bytes(blocked), &reason),
      SHAAR_POLICY_BLOCKED);
  EXPECT_EQ(reason, "scheme_blocked");

  const std::string extra =
      R"({"schemaVersion":1,"direction":"back","unexpected":false})";
  EXPECT_EQ(HandleCommand(&backend, SHAAR_OP_TAB_GO, Bytes(extra), &reason),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(reason, "unknown_argument_field");

  const std::string wrong_type =
      R"({"schemaVersion":1,"direction":"sideways"})";
  EXPECT_EQ(
      HandleCommand(&backend, SHAAR_OP_TAB_GO, Bytes(wrong_type), &reason),
      SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(reason, "invalid_history_direction");
}

TEST(ShaarNavigationHandlerTest,
     URLPolicyRejectsEmptyControlAndMalformedHostPort) {
  std::string canonical;
  EXPECT_EQ(ValidateURL("", &canonical), SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(ValidateURL("https://example.test/a\n", &canonical),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(ValidateURL("https://example.test:99999/", &canonical),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(ValidateURL("data:text/html,blocked", &canonical),
            SHAAR_POLICY_BLOCKED);
  EXPECT_EQ(ValidateURL("file:///etc/passwd", &canonical),
            SHAAR_POLICY_BLOCKED);
  EXPECT_EQ(ValidateURL("https://example.test/", &canonical), SHAAR_OK);
  EXPECT_EQ(canonical, "https://example.test/");
}

TEST(ShaarNavigationHandlerTest, ReportsHistoryBoundaryAndMapsReloadModes) {
  FakeBackend backend;
  std::string reason;
  const std::string back = R"({"schemaVersion":1,"direction":"back"})";
  backend.history_available = false;
  EXPECT_EQ(HandleCommand(&backend, SHAAR_OP_TAB_GO, Bytes(back), &reason),
            SHAAR_CONFLICT);
  EXPECT_EQ(reason, "no_back_entry");

  const std::string reload = R"({"schemaVersion":1,"mode":"bypass_cache"})";
  EXPECT_EQ(
      HandleCommand(&backend, SHAAR_OP_TAB_RELOAD, Bytes(reload), &reason),
      SHAAR_OK);
  EXPECT_TRUE(backend.did_bypass_cache);

  const std::string normal = R"({"schemaVersion":1,"mode":"normal"})";
  EXPECT_EQ(
      HandleCommand(&backend, SHAAR_OP_TAB_RELOAD, Bytes(normal), &reason),
      SHAAR_OK);
  EXPECT_FALSE(backend.did_bypass_cache);
}

TEST(ShaarNavigationHandlerTest, ReloadDuringNavigationKeepsPendingDestination) {
  const GURL committed("https://example.test/previous");
  const GURL pending("https://example.test/slow");
  EXPECT_EQ(ReloadTargetURL(pending, committed), pending);
  EXPECT_EQ(ReloadTargetURL(GURL(), committed), committed);
}

TEST(ShaarNavigationHandlerTest, StopIsDispatchedAndNullBackendIsNotFound) {
  FakeBackend backend;
  std::string reason;
  const std::string stop = R"({"schemaVersion":1})";
  EXPECT_EQ(HandleCommand(&backend, SHAAR_OP_TAB_STOP, Bytes(stop), &reason),
            SHAAR_OK);
  EXPECT_TRUE(backend.did_stop);
  EXPECT_EQ(HandleCommand(nullptr, SHAAR_OP_TAB_STOP, Bytes(stop), &reason),
            SHAAR_NOT_FOUND);
  EXPECT_EQ(reason, "tab_not_found");
}

}  // namespace
}  // namespace shaar::navigation
