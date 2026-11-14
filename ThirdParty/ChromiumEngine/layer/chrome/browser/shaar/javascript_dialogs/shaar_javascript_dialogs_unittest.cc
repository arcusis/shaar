// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/javascript_dialogs/shaar_javascript_dialogs.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace shaar::javascript_dialogs {

TEST(ShaarJavaScriptDialogTest, SuppressesBackgroundAndPrivateTabs) {
  EXPECT_FALSE(DialogMayBePresented(false, true));
  EXPECT_FALSE(DialogMayBePresented(true, false));
  EXPECT_TRUE(DialogMayBePresented(true, true));
}

TEST(ShaarJavaScriptDialogTest, SuppressedDialogsUseSafeDefaults) {
  EXPECT_TRUE(SuppressedDialogAccepted(content::JAVASCRIPT_DIALOG_TYPE_ALERT));
  EXPECT_FALSE(SuppressedDialogAccepted(content::JAVASCRIPT_DIALOG_TYPE_CONFIRM));
  EXPECT_FALSE(SuppressedDialogAccepted(content::JAVASCRIPT_DIALOG_TYPE_PROMPT));
}

TEST(ShaarJavaScriptDialogTest, RegistersTheTypedReplyOperation) {
  ShaarModuleRegistry registry;
  Register(&registry);
  EXPECT_NE(registry.Find(SHAAR_OP_JAVASCRIPT_DIALOG_REPLY), nullptr);
}

}  // namespace shaar::javascript_dialogs
