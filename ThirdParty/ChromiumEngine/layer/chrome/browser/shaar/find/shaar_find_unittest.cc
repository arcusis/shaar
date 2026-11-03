// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/find/shaar_find.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace {

void IgnoreReply(void*, const shaar_result*) {}

TEST(ShaarFindTest, RejectsUnknownFieldsAndMalformedOperations) {
  shaar::ShaarEngineContext context;
  shaar_engine* engine = reinterpret_cast<shaar_engine*>(0x1);
  shaar_window* window = reinterpret_cast<shaar_window*>(0x2);
  shaar_tab* tab = reinterpret_cast<shaar_tab*>(0x3);
  constexpr char kUnknownField[] =
      "{\"schemaVersion\":1,\"query\":\"hello\",\"forward\":true,"
      "\"path\":\"private\"}";
  const shaar_bytes args = {kUnknownField, sizeof(kUnknownField) - 1};
  EXPECT_EQ(HandleFindOperation(
                &context, engine, {}, window, tab, SHAAR_OP_TAB_FIND, args, 1,
                &IgnoreReply, nullptr, nullptr),
            SHAAR_INVALID_ARGUMENT);
}

TEST(ShaarFindTest, RequiresNonzeroCallerRequestID) {
  shaar::ShaarEngineContext context;
  shaar_engine* engine = reinterpret_cast<shaar_engine*>(0x1);
  shaar_window* window = reinterpret_cast<shaar_window*>(0x2);
  shaar_tab* tab = reinterpret_cast<shaar_tab*>(0x3);
  constexpr char kValid[] =
      "{\"schemaVersion\":1,\"query\":\"hello\",\"forward\":true}";
  const shaar_bytes args = {kValid, sizeof(kValid) - 1};
  EXPECT_EQ(HandleFindOperation(
                &context, engine, {}, window, tab, SHAAR_OP_TAB_FIND, args, 0,
                &IgnoreReply, nullptr, nullptr),
            SHAAR_INVALID_ARGUMENT);
}

TEST(ShaarFindTest, RegisterExposesOnlyFindOperationRange) {
  ShaarModuleRegistry registry;
  shaar_find_register(&registry);
  EXPECT_NE(registry.Find(SHAAR_OP_TAB_FIND), nullptr);
  EXPECT_NE(registry.Find(SHAAR_OP_TAB_STOP_FIND), nullptr);
  EXPECT_EQ(registry.Find(SHAAR_OP_TAB_NAVIGATE), nullptr);
}

}  // namespace
