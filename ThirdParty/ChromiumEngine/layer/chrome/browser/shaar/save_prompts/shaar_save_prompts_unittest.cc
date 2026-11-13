// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/save_prompts/shaar_save_prompts.h"

#include <string>

#include "testing/gtest/include/gtest/gtest.h"

namespace {

std::string Repeat(char value, size_t count) {
  return std::string(count, value);
}

}  // namespace

TEST(ShaarSavePromptTest, PrivateContextsDoNotReceiveOffers) {
  EXPECT_FALSE(shaar::save_prompts::SavePromptAllowedForContext(false, false));
  EXPECT_FALSE(shaar::save_prompts::SavePromptAllowedForContext(true, true));
  EXPECT_TRUE(shaar::save_prompts::SavePromptAllowedForContext(true, false));
}

TEST(ShaarSavePromptTest, NeverAppliesOnlyToANewPassword) {
  EXPECT_EQ(shaar::save_prompts::DecisionCode("password", false, "save"),
            shaar::save_prompts::kDecisionSave);
  EXPECT_EQ(shaar::save_prompts::DecisionCode("password", false, "dismiss"),
            shaar::save_prompts::kDecisionDismiss);
  EXPECT_EQ(shaar::save_prompts::DecisionCode("password", false, "never"),
            shaar::save_prompts::kDecisionNever);
  EXPECT_EQ(shaar::save_prompts::DecisionCode("password", true, "never"),
            shaar::save_prompts::kDecisionDismiss);
  EXPECT_EQ(shaar::save_prompts::DecisionCode("card", false, "never"),
            shaar::save_prompts::kDecisionDismiss);
  EXPECT_EQ(shaar::save_prompts::DecisionCode("address", false, "save"),
            shaar::save_prompts::kDecisionSave);
  EXPECT_EQ(shaar::save_prompts::DecisionCode("password", false, "later"), 0);
  EXPECT_EQ(shaar::save_prompts::DecisionCode("password", false, nullptr), 0);
}

TEST(ShaarSavePromptTest, DecisionRequestIDsUseBoundedDecimalForm) {
  EXPECT_FALSE(shaar::save_prompts::IsValidDecisionRequestID(""));
  EXPECT_TRUE(shaar::save_prompts::IsValidDecisionRequestID("1"));
  EXPECT_TRUE(shaar::save_prompts::IsValidDecisionRequestID(Repeat('9', 20)));
  EXPECT_FALSE(shaar::save_prompts::IsValidDecisionRequestID(Repeat('9', 21)));
  EXPECT_FALSE(shaar::save_prompts::IsValidDecisionRequestID("12x"));
  EXPECT_FALSE(shaar::save_prompts::IsValidDecisionRequestID("12\xC2\xA0"));
}

TEST(ShaarSavePromptTest, DetailDropsControlsAndKeepsUtf8Boundaries) {
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("a\nb\x7f" "c"), "abc");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail(Repeat('a', 121)).size(), 120u);
  const std::string bounded =
      Repeat('a', 119) + "\xC3\xA9";
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail(bounded), Repeat('a', 119));
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("\xC3\xA9"), "\xC3\xA9");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail(""), "");
}

TEST(ShaarSavePromptTest, RegistersItsModuleAndOperationHandler) {
  ShaarModuleRegistry registry;
  shaar_save_prompts_register(&registry);
  EXPECT_NE(registry.FindModule(SHAAR_MODULE_SAVE_PROMPTS), nullptr);
  EXPECT_EQ(registry.Find(SHAAR_OP_SAVE_PROMPT_DECIDE),
            &HandleSavePromptOperation);
}
