// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/find/shaar_find.h"
#include "chrome/browser/shaar/find/shaar_page_zoom.h"

#include "components/zoom/page_zoom.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace {

void IgnoreReply(void *, const shaar_result *) {}

TEST(ShaarPageZoomTest, RejectsUnknownZoomAction) {
  shaar::ShaarEngineContext context;
  shaar_engine *engine = reinterpret_cast<shaar_engine *>(0x1);
  shaar_window *window = reinterpret_cast<shaar_window *>(0x2);
  shaar_tab *tab = reinterpret_cast<shaar_tab *>(0x3);
  constexpr char kInvalid[] = "{\"schemaVersion\":1,\"action\":\"page\"}";
  EXPECT_EQ(HandlePageZoomOperation(&context, engine, {}, window, tab,
                                    SHAAR_OP_TAB_ZOOM,
                                    {kInvalid, sizeof(kInvalid) - 1}, 1,
                                    &IgnoreReply, nullptr, nullptr),
            SHAAR_INVALID_ARGUMENT);
}

TEST(ShaarPageZoomTest, RegistersDedicatedTabZoomOperation) {
  ShaarModuleRegistry registry;
  shaar_find_register(&registry);
  EXPECT_NE(registry.Find(SHAAR_OP_TAB_ZOOM), nullptr);
  EXPECT_EQ(registry.Find(SHAAR_OP_TAB_ZOOM + 1), nullptr);
}

TEST(ShaarPageZoomTest, StepsThroughChromiumPresetZoomLevels) {
  const auto levels = zoom::PageZoom::PresetZoomLevels(0.0);
  ASSERT_GT(levels.size(), 2u);
  EXPECT_GT(shaar::page_zoom::NextPresetZoomLevel(0.0, 1), 0.0);
  EXPECT_LT(shaar::page_zoom::NextPresetZoomLevel(0.0, -1), 0.0);
  EXPECT_DOUBLE_EQ(shaar::page_zoom::NextPresetZoomLevel(levels.front(), -1),
                   levels.front());
  EXPECT_DOUBLE_EQ(shaar::page_zoom::NextPresetZoomLevel(levels.back(), 1),
                   levels.back());
}

} // namespace
