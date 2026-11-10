// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/tab_lifecycle/shaar_tab_lifecycle.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace shaar::tab_lifecycle {
namespace {

TabSleepSignals Audible() {
  TabSleepSignals signals;
  signals.audible = true;
  return signals;
}

TEST(TabLifecycleTest, FreezeBlocksVisibleAudibleCaptureAndFormEntry) {
  TabSleepSignals visible;
  visible.visible = true;
  EXPECT_STREQ("visible tab stays awake", TabSleepBlock(visible));

  EXPECT_STREQ("audible tab stays awake", TabSleepBlock(Audible()));

  TabSleepSignals capturing;
  capturing.capturing = true;
  EXPECT_STREQ("capturing tab stays awake", TabSleepBlock(capturing));

  TabSleepSignals form_entry;
  form_entry.form_entry = true;
  EXPECT_STREQ("a tab with unsaved form entry stays awake",
               TabSleepBlock(form_entry));

  EXPECT_EQ(nullptr, TabSleepBlock(TabSleepSignals()));
}

TEST(TabLifecycleTest, WakeTemporarilyHidesOnlyVisiblePages) {
  EXPECT_TRUE(NeedsTemporaryHideForWake(true));
  EXPECT_FALSE(NeedsTemporaryHideForWake(false));
}

TEST(TabLifecycleTest, DiscardAllowsOnlyProactiveAndUrgent) {
  const TabSleepSignals clear;
  EXPECT_EQ(nullptr, TabDiscardBlock(TabDiscardReason::kProactive, clear));
  EXPECT_EQ(nullptr, TabDiscardBlock(TabDiscardReason::kUrgent, clear));
  EXPECT_STREQ("discard reason is not available to the app",
               TabDiscardBlock(TabDiscardReason::kExternal, clear));
  EXPECT_STREQ("discard reason is not available to the app",
               TabDiscardBlock(TabDiscardReason::kSuggested, clear));
  EXPECT_STREQ(
      "discard reason is not available to the app",
      TabDiscardBlock(TabDiscardReason::kFrozenWithGrowingMemory, clear));
  EXPECT_STREQ("audible tab stays awake",
               TabDiscardBlock(TabDiscardReason::kUrgent, Audible()));

  TabSleepSignals visible;
  visible.visible = true;
  EXPECT_STREQ("visible tab stays awake",
               TabDiscardBlock(TabDiscardReason::kProactive, visible));
}

}  // namespace
}  // namespace shaar::tab_lifecycle
