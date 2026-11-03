// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/bookmarks/shaar_bookmarks.h"

#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace shaar {
namespace {

TEST(ShaarBookmarksModuleTest, RejectsPrivateScopeBeforeModelLookup) {
  shaar_engine engine;
  BookmarksModule module(nullptr, true, &engine, "regular-profile-id");

  EXPECT_EQ(module.Submit(SHAAR_OP_BOOKMARK_TREE, "{}", nullptr, nullptr),
            SHAAR_PRIVATE_DISALLOWED);
}

}  // namespace
}  // namespace shaar
