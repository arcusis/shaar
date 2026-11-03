// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/bookmarks/shaar_bookmarks.h"

#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "testing/gtest/include/gtest/gtest.h"

#include <vector>

namespace shaar {
namespace {

TEST(ShaarBookmarksModuleTest, RejectsPrivateScopeBeforeModelLookup) {
  shaar_engine engine;
  BookmarksModule module(nullptr, true, &engine, "regular-profile-id");

  EXPECT_EQ(module.Submit(SHAAR_OP_BOOKMARK_TREE, "{}", nullptr, nullptr),
            SHAAR_PRIVATE_DISALLOWED);
}

struct Registration {
  shaar_operation operation;
  ShaarModuleRegistry::Handler handler;
  void *context;
};

void CaptureHandler(void *context, shaar_operation operation,
                    ShaarModuleRegistry::Handler handler,
                    void *handler_context) {
  static_cast<std::vector<Registration> *>(context)->push_back(
      {operation, handler, handler_context});
}

BookmarksModule *ResolveModule(void *, shaar_engine *, shaar_profile *,
                               shaar_error_code *) {
  ADD_FAILURE() << "private scope must be rejected before profile resolution";
  return nullptr;
}

TEST(ShaarBookmarksModuleTest, RegistersEachBookmarkOperation) {
  std::vector<Registration> registrations;
  ShaarModuleRegistry registry;
  registry.context = &registrations;
  registry.register_handler = &CaptureHandler;
  registry.resolve_bookmarks_module = &ResolveModule;

  shaar_bookmarks_register(&registry);

  ASSERT_EQ(registrations.size(), 3u);
  EXPECT_EQ(registrations[0].operation, SHAAR_OP_BOOKMARK_TREE);
  EXPECT_EQ(registrations[1].operation, SHAAR_OP_BOOKMARK_APPLY);
  EXPECT_EQ(registrations[2].operation, SHAAR_OP_BOOKMARK_WATCH);
  for (const Registration &registration : registrations)
    EXPECT_NE(registration.handler, nullptr);
}

TEST(ShaarBookmarksModuleTest,
     RegisteredHandlerRejectsPrivateScopeBeforeLookup) {
  std::vector<Registration> registrations;
  ShaarModuleRegistry registry;
  registry.context = &registrations;
  registry.register_handler = &CaptureHandler;
  registry.resolve_bookmarks_module = &ResolveModule;
  shaar_bookmarks_register(&registry);

  shaar_engine engine;
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.private_session = reinterpret_cast<shaar_private_session *>(1);
  EXPECT_EQ(registrations[0].handler(registrations[0].context, &engine, scope,
                                     SHAAR_OP_BOOKMARK_TREE, {nullptr, 0}, 1,
                                     nullptr, nullptr),
            SHAAR_PRIVATE_DISALLOWED);
}

} // namespace
} // namespace shaar
