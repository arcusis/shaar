// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/engine/shaar_module_registry.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace {

shaar_error_code FakeProfileHandler(shaar_engine*,
                                    shaar_scope,
                                    shaar_window*,
                                    shaar_tab*,
                                    shaar_operation operation,
                                    shaar_bytes,
                                    shaar_request_id,
                                    shaar_reply_fn,
                                    void*,
                                    shaar_error*) {
  return operation == SHAAR_OP_PROFILE_GET_STATE ? SHAAR_OK
                                                  : SHAAR_INVALID_ARGUMENT;
}

shaar_error_code FakeCancelHandler(shaar_engine*,
                                   shaar_request_id,
                                   shaar_error*) {
  return SHAAR_OK;
}

TEST(ShaarModuleRegistryTest, DispatchesOperationsInsideRegisteredRange) {
  ShaarModuleRegistry registry;
  ASSERT_TRUE(registry.Register(SHAAR_OP_PROFILE_DELETE,
                                SHAAR_OP_PROFILE_SET_STATE,
                                &FakeProfileHandler));
  EXPECT_EQ(registry.Find(SHAAR_OP_PROFILE_GET_STATE), &FakeProfileHandler);
  EXPECT_EQ(registry.Find(SHAAR_OP_WINDOW_BIND_PROFILE), nullptr);

  auto handler = registry.Find(SHAAR_OP_PROFILE_GET_STATE);
  ASSERT_NE(handler, nullptr);
  EXPECT_EQ(handler(nullptr, {}, nullptr, nullptr, SHAAR_OP_PROFILE_GET_STATE,
                    {}, 1, nullptr, nullptr, nullptr),
            SHAAR_OK);
}

TEST(ShaarModuleRegistryTest, RejectsInvalidAndOverlappingRanges) {
  ShaarModuleRegistry registry;
  EXPECT_FALSE(registry.Register(0, 2, &FakeProfileHandler));
  EXPECT_FALSE(registry.Register(10, 9, &FakeProfileHandler));
  EXPECT_FALSE(registry.Register(10, 12, nullptr));
  ASSERT_TRUE(registry.Register(100, 102, &FakeProfileHandler));
  EXPECT_FALSE(registry.Register(101, 105, &FakeProfileHandler));
  EXPECT_FALSE(registry.Register(99, 100, &FakeProfileHandler));
  EXPECT_TRUE(registry.Register(200, 207, &FakeProfileHandler));
}

TEST(ShaarModuleRegistryTest, TracksRequestsForModuleOwnedCancellation) {
  ShaarModuleRegistry registry;
  ASSERT_TRUE(registry.Register(SHAAR_OP_PROFILE_DELETE,
                                SHAAR_OP_PROFILE_SET_STATE,
                                &FakeProfileHandler, &FakeCancelHandler));
  auto* engine = reinterpret_cast<shaar_engine*>(0x10);
  ASSERT_TRUE(registry.Reserve(engine, 42, registry.FindCancel(SHAAR_OP_PROFILE_DELETE)));
  EXPECT_FALSE(registry.Reserve(engine, 42, &FakeCancelHandler));
  EXPECT_TRUE(registry.IsPending(engine, 42));
  EXPECT_EQ(registry.PendingCancel(engine, 42), &FakeCancelHandler);
  EXPECT_TRUE(registry.BeginCompletion(42));
  EXPECT_FALSE(registry.IsPending(engine, 42));
  EXPECT_FALSE(registry.BeginCompletion(42));
  registry.FinishCompletion(42);
  EXPECT_FALSE(registry.IsPending(engine, 42));
}

}  // namespace
