// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/engine/shaar_module_registry.h"

#include "testing/gtest/include/gtest/gtest.h"

extern "C" void shaar_login_register(ShaarModuleRegistry* registry);

TEST(ShaarLoginTest, RegistersOnlyTheCredentialsReplyOperation) {
  ShaarModuleRegistry registry;
  shaar_login_register(&registry);
  EXPECT_NE(registry.Find(SHAAR_OP_HTTP_AUTH_CREDENTIALS_REPLY), nullptr);
  EXPECT_EQ(registry.Find(static_cast<shaar_operation>(1602)), nullptr);
}
