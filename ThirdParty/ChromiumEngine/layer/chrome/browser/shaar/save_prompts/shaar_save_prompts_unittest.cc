// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/save_prompts/shaar_save_prompts.h"

#include <string>

#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

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
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("a\xC2\x85" "b"), "ab");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("\xC2\x9F"), "");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("user\xC2\x85" "name"),
            "username");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("line\xE2\x80\xA8" "break"),
            "linebreak");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("para\xE2\x80\xA9" "graph"),
            "paragraph");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("user\xE2\x80\xAE" "admin"),
            "useradmin");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("user\xE2\x80\x8B" "name"),
            "username");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("user\xE2\x81\xA6" "name"),
            "username");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("\xEF\xBB\xBF" "user"),
            "user");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail(Repeat('a', 121)).size(), 120u);
  const std::string bounded =
      Repeat('a', 119) + "\xC3\xA9";
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail(bounded), Repeat('a', 119));
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("\xC3\xA9"), "\xC3\xA9");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail(""), "");
}

TEST(ShaarSavePromptTest, PageURLRemovesCredentialsQueryAndFragment) {
  const GURL input(
      "https://user:secret@example.com/login?next=%2Fhome#token");
  EXPECT_EQ(shaar::save_prompts::CleanPageURLForSavePrompt(input),
            GURL("https://example.com/login"));
}

TEST(ShaarSavePromptTest, PageURLRejectsNonWebSchemes) {
  EXPECT_FALSE(shaar::save_prompts::CleanPageURLForSavePrompt(
                   GURL("file:///tmp/page"))
                   .is_valid());
  EXPECT_FALSE(shaar::save_prompts::CleanPageURLForSavePrompt(
                   GURL("javascript:alert(1)"))
                   .is_valid());
}

TEST(ShaarSavePromptTest, DetailDropsUnicodeFormattingControls) {
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("user\xE2\x80\xAE" "admin"),
            "useradmin");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("left\xE2\x81\xA6" "right"),
            "leftright");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("עברית"), "עברית");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail(
                Repeat('a', 119) + "\xE2\x80\xAE" "b"),
            Repeat('a', 119) + "b");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("soft\xC2\xAD" "hyphen"),
            "softhyphen");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("bom\xEF\xBB\xBF" "text"),
            "bomtext");
}

TEST(ShaarSavePromptTest, DetailDropsMalformedUtf8Sequences) {
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("\xC0\xAF"), "");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("\xED\xA0\x80"), "");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("\xF4\x90\x80\x80"), "");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("\xC3("), "(");
  EXPECT_EQ(shaar::save_prompts::SanitizeDetail("\xF0\x9F\x8C\x8D"),
            "\xF0\x9F\x8C\x8D");
}

TEST(ShaarSavePromptTest, RegistersItsModuleAndOperationHandler) {
  ShaarModuleRegistry registry;
  shaar_save_prompts_register(&registry);
  EXPECT_NE(registry.FindModule(SHAAR_MODULE_SAVE_PROMPTS), nullptr);
  EXPECT_EQ(registry.Find(SHAAR_OP_SAVE_PROMPT_DECIDE),
            &HandleSavePromptOperation);
}
