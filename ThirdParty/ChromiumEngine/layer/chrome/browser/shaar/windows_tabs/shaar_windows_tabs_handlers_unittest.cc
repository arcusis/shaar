// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs_handlers.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"

#include <string>
#include <memory>
#include <unordered_map>
#include <vector>

#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace shaar::windows_tabs {
namespace {

struct CapturedWindowRequest {
  shaar_request_id request_id = 0;
  shaar_window* window = nullptr;
  bool accepted = false;
  bool called = false;
};

struct CapturedTabActivation {
  shaar_request_id request_id = 0;
  shaar_window* window = nullptr;
  shaar_tab* tab = nullptr;
  bool accepted = false;
  bool called = false;
};

using EngineHandle = std::unique_ptr<shaar_engine, decltype(&shaar_engine_release)>;

EngineHandle MakeEngineHandle() {
  static constexpr char kDataRoot[] = ".";
  shaar_config config = {};
  config.size = sizeof(config);
  config.requested_major = SHAAR_ENGINE_ABI_MAJOR;
  config.requested_minor = SHAAR_ENGINE_ABI_MINOR;
  config.data_root = {kDataRoot, sizeof(kDataRoot) - 1};
  config.on_event = [](void*, const shaar_event*) {};
  shaar_engine* engine = nullptr;
  shaar_error error = {.size = sizeof(shaar_error)};
  EXPECT_EQ(shaar_engine_create(&config, &engine, &error), SHAAR_OK);
  return EngineHandle(engine, shaar_engine_release);
}

shaar_error_code CaptureWindowRequest(void* context,
                                      shaar_request_id request_id,
                                      const shaar_scope* scope,
                                      shaar_window* window,
                                      bool accepted) {
  auto* captured = static_cast<CapturedWindowRequest*>(context);
  if (!scope || !scope->profile || scope->private_session)
    return SHAAR_WRONG_PROFILE;
  captured->request_id = request_id;
  captured->window = window;
  captured->accepted = accepted;
  captured->called = true;
  return SHAAR_OK;
}

shaar_error_code CaptureTabActivation(void* context,
                                      shaar_request_id request_id,
                                      const shaar_scope* scope,
                                      shaar_window* window,
                                      shaar_tab* tab,
                                      bool accepted) {
  auto* captured = static_cast<CapturedTabActivation*>(context);
  if (!scope || !scope->private_session || scope->profile)
    return SHAAR_WRONG_SESSION;
  captured->request_id = request_id;
  captured->window = window;
  captured->tab = tab;
  captured->accepted = accepted;
  captured->called = true;
  return SHAAR_OK;
}

TEST(ShaarWindowsTabsHandlersTest, PlacementRequiresExactUniqueMembership) {
  EXPECT_TRUE(ValidatePlacement({"a", "b", "c"}, {"c", "b", "a"},
                                {"a", "b"}));
  EXPECT_FALSE(ValidatePlacement({"a", "a"}, {"a", "b"}, {}));
  EXPECT_FALSE(ValidatePlacement({"a", "c"}, {"a", "b"}, {}));
}

TEST(ShaarWindowsTabsHandlersTest, PinnedTabsMustBeAnOrderedPrefix) {
  EXPECT_TRUE(ValidatePlacement({"a", "b", "c"}, {"a", "b", "c"},
                                {"a", "b"}));
  EXPECT_FALSE(ValidatePlacement({"a", "b", "c"}, {"a", "b", "c"},
                                 {"b"}));
  EXPECT_FALSE(ValidatePlacement({"a", "b"}, {"a", "b"}, {"outside"}));
}

TEST(ShaarWindowsTabsHandlersTest, PlaceHandlerRejectsWrongOperationBeforeMutation) {
  shaar::ModuleCall call = {};
  call.operation = SHAAR_OP_WINDOW_ACTIVATE_TAB;
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(HandleWindowPlaceTabs(&call, &error), SHAAR_INVALID_ARGUMENT);
}

TEST(ShaarWindowsTabsHandlersTest, RegistryResolvesBoundWindowAndTabIDs) {
  BrowserTabRegistryImpl registry;
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  auto* window = reinterpret_cast<shaar_window*>(2);
  auto* tab = reinterpret_cast<shaar_tab*>(3);
  auto* browser = reinterpret_cast<Browser*>(4);
  auto* contents = reinterpret_cast<content::WebContents*>(5);
  registry.BindWindow(engine, window, browser);
  auto* state = registry.EnsureWindowState(engine, window, browser, "profile-a");
  registry.BindTab(engine, window, tab, "tab-a", browser, contents);
  ASSERT_NE(state, nullptr);
  EXPECT_EQ(state->active_browser, browser);
  EXPECT_EQ(state->active_profile_id, "profile-a");
  EXPECT_EQ(state->browsers_by_profile.at("profile-a"), browser);
  EXPECT_EQ(registry.FindBrowser(engine, window), browser);
  EXPECT_EQ(registry.FindWebContents(engine, window, tab), contents);
  EXPECT_EQ(registry.FindWebContentsByID(engine, window, "tab-a"), contents);
  EXPECT_EQ(registry.TabID(engine, window, tab), "tab-a");
  EXPECT_EQ(registry.FindWindowOwner(window), engine);
  EXPECT_EQ(registry.FindTabWindow(tab), window);
  std::unordered_map<std::string, content::WebContents*> tabs;
  registry.GetTabs(engine, window, &tabs);
  EXPECT_EQ(tabs.at("tab-a"), contents);
  registry.UnbindWindow(engine, window);
  EXPECT_EQ(registry.FindBrowser(engine, window), nullptr);
  EXPECT_EQ(registry.FindWebContents(engine, window, tab), nullptr);
  EXPECT_EQ(registry.FindWindowOwner(window), nullptr);
  EXPECT_EQ(registry.FindTabWindow(tab), nullptr);
}

TEST(ShaarWindowsTabsHandlersTest, ReservedWindowBindsBrowserAndClosesCleanly) {
  BrowserTabRegistryImpl registry;
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  auto* window = reinterpret_cast<shaar_window*>(2);
  auto* browser = reinterpret_cast<Browser*>(3);
  ASSERT_TRUE(registry.ReserveWindow(engine, window, "window-a"));
  EXPECT_EQ(registry.FindWindowOwner(window), engine);
  EXPECT_EQ(registry.FindBrowser(engine, window), nullptr);
  EXPECT_EQ(registry.WindowID(engine, window), "window-a");
  EXPECT_FALSE(registry.ReserveWindow(engine, reinterpret_cast<shaar_window*>(4),
                                      "window-a"));
  registry.BindWindow(engine, window, browser);
  EXPECT_EQ(registry.FindBrowser(engine, window), browser);
  registry.UnbindBrowser(engine, window, browser);
  EXPECT_EQ(registry.FindBrowser(engine, window), nullptr);
  EXPECT_EQ(registry.FindWindowOwner(window), engine);
  registry.BindWindow(engine, window, browser);
  registry.UnbindWindow(engine, window);
  EXPECT_EQ(registry.FindWindowOwner(window), nullptr);
}

TEST(ShaarWindowsTabsHandlersTest, ClosedTabCannotResolveOrReuseItsPublicID) {
  BrowserTabRegistryImpl registry;
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  auto* window = reinterpret_cast<shaar_window*>(2);
  auto* tab = reinterpret_cast<shaar_tab*>(3);
  auto* contents = reinterpret_cast<content::WebContents*>(4);
  ASSERT_TRUE(registry.ReserveWindow(engine, window, "window-a"));
  ASSERT_TRUE(registry.ReserveTab(engine, window, tab, "tab-a"));
  EXPECT_FALSE(registry.ReserveTab(engine, window,
                                   reinterpret_cast<shaar_tab*>(5), "tab-a"));
  registry.BindTab(engine, window, tab, "tab-a",
                   reinterpret_cast<Browser*>(9), contents);
  EXPECT_EQ(registry.FindWebContents(engine, window, tab), contents);
  registry.UnbindTab(engine, window, tab);
  EXPECT_EQ(registry.FindTabWindow(tab), nullptr);
  EXPECT_EQ(registry.FindWebContentsByID(engine, window, "tab-a"), nullptr);
  EXPECT_TRUE(registry.ReserveTab(engine, window,
                                  reinterpret_cast<shaar_tab*>(5), "tab-a"));
  registry.UnbindWindow(engine, window);
}

TEST(ShaarWindowsTabsHandlersTest, ProfileTabsStayBoundToTheirOwnBrowser) {
  BrowserTabRegistryImpl registry;
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  auto* window = reinterpret_cast<shaar_window*>(2);
  auto* browser_a = reinterpret_cast<Browser*>(3);
  auto* browser_b = reinterpret_cast<Browser*>(4);
  auto* tab_a = reinterpret_cast<shaar_tab*>(5);
  auto* tab_b = reinterpret_cast<shaar_tab*>(6);
  auto* contents_a = reinterpret_cast<content::WebContents*>(7);
  auto* contents_b = reinterpret_cast<content::WebContents*>(8);
  ASSERT_TRUE(registry.ReserveWindow(engine, window, "window-a"));
  registry.EnsureWindowState(engine, window, browser_a, "profile-a");
  registry.EnsureWindowState(engine, window, browser_b, "profile-b");
  ASSERT_TRUE(registry.ReserveTab(engine, window, tab_a, "tab-a"));
  ASSERT_TRUE(registry.ReserveTab(engine, window, tab_b, "tab-b"));
  registry.BindTab(engine, window, tab_a, "tab-a", browser_a, contents_a);
  registry.BindTab(engine, window, tab_b, "tab-b", browser_b, contents_b);
  EXPECT_EQ(registry.FindBrowserForTab(engine, window, tab_a), browser_a);
  EXPECT_EQ(registry.FindBrowserForTab(engine, window, tab_b), browser_b);
  std::unordered_map<std::string, content::WebContents*> tabs;
  registry.GetTabsForBrowser(engine, window, browser_a, &tabs);
  EXPECT_EQ(tabs.size(), 1u);
  EXPECT_EQ(tabs.at("tab-a"), contents_a);
  registry.UnbindWindow(engine, window);
}

TEST(ShaarWindowsTabsHandlersTest, LastTabCloseDropsBrowserSoReopenBindsAFreshOne) {
  BrowserTabRegistryImpl registry;
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  auto* window = reinterpret_cast<shaar_window*>(2);
  auto* closing = reinterpret_cast<Browser*>(3);
  auto* fresh = reinterpret_cast<Browser*>(4);
  auto* other = reinterpret_cast<Browser*>(5);
  auto* tab = reinterpret_cast<shaar_tab*>(6);
  auto* other_tab = reinterpret_cast<shaar_tab*>(7);
  auto* contents = reinterpret_cast<content::WebContents*>(8);
  auto* other_contents = reinterpret_cast<content::WebContents*>(9);
  ASSERT_TRUE(registry.ReserveWindow(engine, window, "window-a"));
  ASSERT_NE(registry.EnsureWindowState(engine, window, closing, "profile-a"),
            nullptr);
  ASSERT_NE(registry.EnsureWindowState(engine, window, other, "profile-b"),
            nullptr);
  ASSERT_TRUE(registry.ReserveTab(engine, window, tab, "tab-a"));
  ASSERT_TRUE(registry.ReserveTab(engine, window, other_tab, "tab-b"));
  registry.BindTab(engine, window, tab, "tab-a", closing, contents);
  registry.BindTab(engine, window, other_tab, "tab-b", other, other_contents);

  registry.UnbindTab(engine, window, tab);
  EXPECT_FALSE(registry.BrowserHasBoundTabs(closing));
  EXPECT_TRUE(registry.BrowserHasBoundTabs(other));
  registry.RetireClosingBrowser(closing);

  auto* state = registry.FindWindowState(engine, window);
  ASSERT_NE(state, nullptr);
  EXPECT_TRUE(registry.IsClosingBrowser(closing));
  EXPECT_FALSE(registry.IsClosingBrowser(other));
  EXPECT_EQ(state->browsers_by_profile.find("profile-a"),
            state->browsers_by_profile.end());
  EXPECT_EQ(state->browsers_by_profile.at("profile-b"), other);
  EXPECT_NE(registry.FindBrowser(engine, window), closing);
  EXPECT_EQ(registry.FindBrowserForTab(engine, window, other_tab), other);

  EXPECT_EQ(registry.EnsureWindowState(engine, window, closing, "profile-a"),
            nullptr);
  EXPECT_EQ(state->browsers_by_profile.find("profile-a"),
            state->browsers_by_profile.end());
  EXPECT_FALSE(registry.BindWindow(engine, window, closing));

  auto* rebound =
      registry.EnsureWindowState(engine, window, fresh, "profile-a");
  ASSERT_NE(rebound, nullptr);
  EXPECT_EQ(rebound->browsers_by_profile.at("profile-a"), fresh);
  EXPECT_EQ(rebound->browsers_by_profile.at("profile-b"), other);
  EXPECT_NE(registry.FindBrowser(engine, window), closing);
  EXPECT_EQ(registry.EnsureWindowState(engine, window, closing, "profile-a"),
            nullptr);
  EXPECT_EQ(rebound->browsers_by_profile.at("profile-a"), fresh);

  // A later allocation may reuse the retired address. Clear that pointer
  // identity before associating the new live Browser.
  registry.MarkBrowserCreated(closing);
  auto* reused =
      registry.EnsureWindowState(engine, window, closing, "profile-c");
  ASSERT_NE(reused, nullptr);
  EXPECT_EQ(reused->browsers_by_profile.at("profile-c"), closing);
  registry.UnbindWindow(engine, window);
}

TEST(ShaarWindowsTabsHandlersTest, WindowCloseWaitsForEveryBrowser) {
  BrowserTabRegistryImpl registry;
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  auto* window = reinterpret_cast<shaar_window*>(2);
  auto* first = reinterpret_cast<Browser*>(3);
  auto* second = reinterpret_cast<Browser*>(4);
  ASSERT_TRUE(registry.ReserveWindow(engine, window, "window-a"));
  registry.EnsureWindowState(engine, window, first, "profile-a");
  registry.EnsureWindowState(engine, window, second, "profile-b");
  EXPECT_TRUE(registry.BeginWindowClose(engine, window));
  EXPECT_FALSE(registry.WindowCloseReady(engine, window));
  registry.UnbindBrowser(engine, window, first);
  EXPECT_FALSE(registry.WindowCloseReady(engine, window));
  registry.UnbindBrowser(engine, window, second);
  EXPECT_TRUE(registry.WindowCloseReady(engine, window));
  registry.UnbindWindow(engine, window);
}

TEST(ShaarWindowsTabsHandlersTest, WindowCloseWaitsForLiveTabCleanup) {
  BrowserTabRegistryImpl registry;
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  auto* window = reinterpret_cast<shaar_window*>(2);
  auto* browser = reinterpret_cast<Browser*>(3);
  auto* tab = reinterpret_cast<shaar_tab*>(4);
  ASSERT_TRUE(registry.ReserveWindow(engine, window, "private-window"));
  registry.EnsureWindowState(engine, window, browser, "private-profile");
  ASSERT_TRUE(registry.ReserveTab(engine, window, tab, "live-tab"));
  ASSERT_TRUE(registry.BeginWindowClose(engine, window));
  registry.UnbindBrowser(engine, window, browser);
  EXPECT_FALSE(registry.WindowCloseReady(engine, window));
  registry.UnbindTab(engine, window, tab);
  EXPECT_TRUE(registry.WindowCloseReady(engine, window));
  registry.UnbindWindow(engine, window);
}

TEST(ShaarWindowsTabsHandlersTest, MixedProfileWindowsCloseIndependently) {
  BrowserTabRegistryImpl registry;
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  auto* regular = reinterpret_cast<shaar_window*>(2);
  auto* private_window = reinterpret_cast<shaar_window*>(3);
  auto* regular_browser = reinterpret_cast<Browser*>(4);
  auto* private_browser = reinterpret_cast<Browser*>(5);
  auto* regular_tab = reinterpret_cast<shaar_tab*>(6);
  auto* private_tab = reinterpret_cast<shaar_tab*>(7);
  ASSERT_TRUE(registry.ReserveWindow(engine, regular, "regular-window"));
  ASSERT_TRUE(registry.ReserveWindow(engine, private_window, "private-window"));
  registry.EnsureWindowState(engine, regular, regular_browser, "profile-a");
  registry.EnsureWindowState(engine, private_window, private_browser,
                             "profile-a-private");
  ASSERT_TRUE(registry.ReserveTab(engine, regular, regular_tab, "regular-tab"));
  ASSERT_TRUE(registry.ReserveTab(engine, private_window, private_tab,
                                  "private-tab"));
  ASSERT_TRUE(registry.BeginWindowClose(engine, regular));
  ASSERT_TRUE(registry.BeginWindowClose(engine, private_window));
  registry.UnbindBrowser(engine, regular, regular_browser);
  registry.UnbindTab(engine, regular, regular_tab);
  EXPECT_TRUE(registry.WindowCloseReady(engine, regular));
  EXPECT_FALSE(registry.WindowCloseReady(engine, private_window));
  registry.UnbindBrowser(engine, private_window, private_browser);
  registry.UnbindTab(engine, private_window, private_tab);
  EXPECT_TRUE(registry.WindowCloseReady(engine, private_window));
  registry.UnbindWindow(engine, regular);
  registry.UnbindWindow(engine, private_window);
}

TEST(ShaarWindowsTabsHandlersTest, RegularWindowABIReservesAndClosesHandle) {
  EngineHandle engine_storage = MakeEngineHandle();
  auto* engine = engine_storage.get();
  ASSERT_NE(engine, nullptr);
  static constexpr char kID[] = "window-api";
  shaar_window* window = nullptr;
  shaar_error error = {.size = sizeof(shaar_error)};
  EXPECT_EQ(shaar_window_open(engine, SHAAR_WINDOW_REGULAR, nullptr,
                              {kID, sizeof(kID) - 1}, &window, &error), SHAAR_OK);
  ASSERT_NE(window, nullptr);
  EXPECT_EQ(Registry().FindWindowOwner(window), engine);
  EXPECT_EQ(Registry().WindowID(engine, window), "window-api");
  EXPECT_EQ(shaar_window_close(window, &error), SHAAR_OK);
  EXPECT_EQ(Registry().FindWindowOwner(window), nullptr);
  EXPECT_EQ(shaar_window_close(window, &error), SHAAR_NOT_FOUND);
}

TEST(ShaarWindowsTabsHandlersTest, ClosedWindowHandleCannotNameNewWindow) {
  EngineHandle engine_storage = MakeEngineHandle();
  auto* engine = engine_storage.get();
  ASSERT_NE(engine, nullptr);
  shaar_error error = {.size = sizeof(shaar_error)};
  shaar_window* stale = nullptr;
  static constexpr char kFirst[] = "retired-window";
  static constexpr char kSecond[] = "replacement-window";
  static constexpr char kTab[] = "late-tab";
  ASSERT_EQ(shaar_window_open(engine, SHAAR_WINDOW_REGULAR, nullptr,
                              {kFirst, sizeof(kFirst) - 1}, &stale, &error),
            SHAAR_OK);
  ASSERT_EQ(shaar_window_close(stale, &error), SHAAR_OK);
  shaar_window* replacement = nullptr;
  ASSERT_EQ(shaar_window_open(engine, SHAAR_WINDOW_REGULAR, nullptr,
                              {kSecond, sizeof(kSecond) - 1}, &replacement,
                              &error),
            SHAAR_OK);
  ASSERT_NE(stale, replacement);
  EXPECT_EQ(shaar_window_host_view(stale), nullptr);
  EXPECT_EQ(shaar_window_native_window(stale), nullptr);
  shaar_tab* tab = nullptr;
  shaar_scope scope = {.size = sizeof(shaar_scope)};
  EXPECT_EQ(shaar_tab_open(scope, stale, {kTab, sizeof(kTab) - 1}, {}, 1,
                           &tab, &error),
            SHAAR_NOT_FOUND);
  EXPECT_EQ(tab, nullptr);
  auto* poisoned = reinterpret_cast<shaar_window*>(0xefefefefefeff157ULL);
  EXPECT_EQ(shaar_tab_open(scope, poisoned, {kTab, sizeof(kTab) - 1}, {}, 1,
                           &tab, &error),
            SHAAR_NOT_FOUND);
  EXPECT_EQ(tab, nullptr);
  EXPECT_EQ(shaar_window_close(stale, &error), SHAAR_NOT_FOUND);
  EXPECT_EQ(shaar_window_close(replacement, &error), SHAAR_OK);
}

TEST(ShaarWindowsTabsHandlersTest, ReleasedEngineCannotOpenWindow) {
  EngineHandle engine_storage = MakeEngineHandle();
  shaar_engine* stale = engine_storage.get();
  ASSERT_NE(stale, nullptr);
  engine_storage.reset();
  static constexpr char kID[] = "late-window";
  shaar_window* window = nullptr;
  shaar_error error = {.size = sizeof(shaar_error)};
  EXPECT_EQ(shaar_window_open(stale, SHAAR_WINDOW_REGULAR, nullptr,
                              {kID, sizeof(kID) - 1}, &window, &error),
            SHAAR_NOT_FOUND);
  EXPECT_EQ(window, nullptr);
  EXPECT_EQ(error.code, SHAAR_NOT_FOUND);
}

TEST(ShaarWindowsTabsHandlersTest, DevToolsRouteRejectsUnownedAndUnsafeURLs) {
  auto* profile = reinterpret_cast<Profile*>(1);
  EXPECT_FALSE(RouteDevToolsOpenURL(
      nullptr, profile, GURL("https://example.com/learn-more")));
  EXPECT_FALSE(RouteDevToolsOpenURL(nullptr, profile,
                                   GURL("javascript:alert(1)")));
  EXPECT_FALSE(RouteDevToolsOpenURL(nullptr, profile,
                                   GURL("file:///private/document")));
  EXPECT_FALSE(RouteDevToolsOpenURL(
      nullptr, profile, GURL("devtools://devtools/bundled/other.html")));
  EXPECT_FALSE(RouteDevToolsOpenURL(
      nullptr, profile, GURL("https://example.com/" + std::string(8192, 'a'))));
}

TEST(ShaarWindowsTabsHandlersTest, QuitRejectsLateWindowAndTabOpen) {
  EngineHandle engine_storage = MakeEngineHandle();
  auto* engine = engine_storage.get();
  ASSERT_NE(engine, nullptr);
  static constexpr char kFirst[] = "quit-window";
  static constexpr char kSecond[] = "late-window";
  static constexpr char kTab[] = "late-tab";
  shaar_error error = {.size = sizeof(shaar_error)};
  shaar_window* window = nullptr;
  EXPECT_EQ(shaar_window_open(engine, SHAAR_WINDOW_REGULAR, nullptr,
                              {kFirst, sizeof(kFirst) - 1}, &window, &error),
            SHAAR_OK);
  if (!window)
    return;

  Registry().BeginEngineQuit(engine);
  shaar_window* late_window = nullptr;
  EXPECT_EQ(shaar_window_open(engine, SHAAR_WINDOW_REGULAR, nullptr,
                              {kSecond, sizeof(kSecond) - 1}, &late_window,
                              &error),
            SHAAR_SHUTTING_DOWN);
  EXPECT_EQ(late_window, nullptr);
  shaar_scope scope = {.size = sizeof(shaar_scope),
                       .profile = reinterpret_cast<shaar_profile*>(1)};
  shaar_tab* late_tab = nullptr;
  EXPECT_EQ(shaar_tab_open(scope, window, {kTab, sizeof(kTab) - 1}, {}, 1,
                           &late_tab, &error),
            SHAAR_SHUTTING_DOWN);
  EXPECT_EQ(late_tab, nullptr);

  Registry().CancelEngineQuit(engine);
  EXPECT_EQ(shaar_window_open(engine, SHAAR_WINDOW_REGULAR, nullptr,
                              {kSecond, sizeof(kSecond) - 1}, &late_window,
                              &error),
            SHAAR_OK);
  if (late_window)
    EXPECT_EQ(shaar_window_close(late_window, &error), SHAAR_OK);
  EXPECT_EQ(shaar_window_close(window, &error), SHAAR_OK);
}

// BEGIN find
TEST(ShaarWindowsTabsHandlersTest, WindowOpenBindsPublicIDForScopedEvents) {
  BrowserTabRegistryImpl registry;
  auto* const engine = reinterpret_cast<shaar_engine*>(1);
  auto* const window = reinterpret_cast<shaar_window*>(2);
  auto* const browser = reinterpret_cast<Browser*>(3);

  registry.OnWindowOpened(engine, window, browser, "window-public-id",
                          "profile-a");

  EXPECT_EQ(registry.FindBrowser(engine, window), browser);
  EXPECT_EQ(registry.WindowID(engine, window), "window-public-id");
  EXPECT_EQ(registry.WindowID(engine, reinterpret_cast<shaar_window*>(4)), "");
}
// END find

TEST(ShaarWindowsTabsHandlersTest, RegularProfileBindingIsExplicitAndStable) {
  shaar::ModuleCall call = {};
  Browser* const browser = reinterpret_cast<Browser*>(1);
  std::unordered_map<std::string, Browser*> browsers;
  call.engine = reinterpret_cast<shaar_engine*>(1);
  call.scope.size = sizeof(shaar_scope);
  call.scope.profile = reinterpret_cast<shaar_profile*>(1);
  call.window = reinterpret_cast<shaar_window*>(1);
  call.operation = SHAAR_OP_WINDOW_BIND_PROFILE;
  static constexpr char kArgs[] = R"({"schemaVersion":1,"profileID":"p"})";
  call.args_json = {kArgs, sizeof(kArgs) - 1};
  call.scope_profile_id = "p";
  call.scoped_browser = browser;
  call.browsers_by_profile = &browsers;
  shaar_error error = {};
  error.size = sizeof(error);

  EXPECT_EQ(HandleWindowBindProfile(&call, &error), SHAAR_OK);
  EXPECT_EQ(browsers.at("p"), browser);
  EXPECT_EQ(HandleWindowBindProfile(&call, &error), SHAAR_OK);
  EXPECT_EQ(browsers.size(), 1u);
}

TEST(ShaarWindowsTabsHandlersTest, ProfileBindingRejectsPrivateScope) {
  shaar::ModuleCall call = {};
  call.scope.private_session = reinterpret_cast<shaar_private_session*>(1);
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(HandleWindowBindProfile(&call, &error), SHAAR_WRONG_SESSION);
}

TEST(ShaarWindowsTabsHandlersTest, ProfileBindingRejectsUnexpectedFields) {
  shaar::ModuleCall call = {};
  call.engine = reinterpret_cast<shaar_engine*>(1);
  call.scope.size = sizeof(shaar_scope);
  call.scope.profile = reinterpret_cast<shaar_profile*>(1);
  call.window = reinterpret_cast<shaar_window*>(1);
  call.operation = SHAAR_OP_WINDOW_BIND_PROFILE;
  static constexpr char kArgs[] =
      R"({"schemaVersion":1,"profileID":"p","sessionID":"s"})";
  call.args_json = {kArgs, sizeof(kArgs) - 1};
  call.scope_profile_id = "p";
  call.scoped_browser = reinterpret_cast<Browser*>(1);
  std::unordered_map<std::string, Browser*> browsers;
  call.browsers_by_profile = &browsers;
  shaar_error error = {};
  error.size = sizeof(error);

  EXPECT_EQ(HandleWindowBindProfile(&call, &error), SHAAR_INVALID_ARGUMENT);
  EXPECT_TRUE(browsers.empty());
}

TEST(ShaarWindowsTabsHandlersTest, ProfileBindingRejectsConflictingBrowser) {
  shaar::ModuleCall call = {};
  call.engine = reinterpret_cast<shaar_engine*>(1);
  call.scope.size = sizeof(shaar_scope);
  call.scope.profile = reinterpret_cast<shaar_profile*>(1);
  call.window = reinterpret_cast<shaar_window*>(1);
  call.operation = SHAAR_OP_WINDOW_BIND_PROFILE;
  static constexpr char kArgs[] = R"({"schemaVersion":1,"profileID":"p"})";
  call.args_json = {kArgs, sizeof(kArgs) - 1};
  call.scope_profile_id = "p";
  call.scoped_browser = reinterpret_cast<Browser*>(2);
  std::unordered_map<std::string, Browser*> browsers = {
      {"p", reinterpret_cast<Browser*>(1)}};
  call.browsers_by_profile = &browsers;
  shaar_error error = {};
  error.size = sizeof(error);

  EXPECT_EQ(HandleWindowBindProfile(&call, &error), SHAAR_CONFLICT);
  EXPECT_EQ(browsers.at("p"), reinterpret_cast<Browser*>(1));
}

TEST(ShaarWindowsTabsHandlersTest, ActiveProfileMustAlreadyBeBound) {
  shaar::ModuleCall call = {};
  Browser* const browser = reinterpret_cast<Browser*>(1);
  Browser* active_browser = nullptr;
  std::string active_profile_id;
  std::unordered_map<std::string, Browser*> browsers = {{"p", browser}};
  call.engine = reinterpret_cast<shaar_engine*>(1);
  call.scope.size = sizeof(shaar_scope);
  call.scope.profile = reinterpret_cast<shaar_profile*>(1);
  call.window = reinterpret_cast<shaar_window*>(1);
  call.operation = SHAAR_OP_WINDOW_SET_ACTIVE_PROFILE;
  static constexpr char kArgs[] = R"({"schemaVersion":1,"profileID":"p"})";
  call.args_json = {kArgs, sizeof(kArgs) - 1};
  call.scope_profile_id = "p";
  call.active_browser = &active_browser;
  call.active_profile_id = &active_profile_id;
  call.browsers_by_profile = &browsers;
  shaar_error error = {};
  error.size = sizeof(error);

  EXPECT_EQ(HandleWindowSetActiveProfile(&call, &error), SHAAR_OK);
  EXPECT_EQ(active_browser, browser);
  EXPECT_EQ(active_profile_id, "p");
  static constexpr char kUnknown[] =
      R"({"schemaVersion":1,"profileID":"missing"})";
  call.args_json = {kUnknown, sizeof(kUnknown) - 1};
  EXPECT_EQ(HandleWindowSetActiveProfile(&call, &error), SHAAR_WRONG_PROFILE);
  static constexpr char kWrongScope[] =
      R"({"schemaVersion":1,"profileID":"p"})";
  call.scope_profile_id = "other-profile";
  call.args_json = {kWrongScope, sizeof(kWrongScope) - 1};
  EXPECT_EQ(HandleWindowSetActiveProfile(&call, &error), SHAAR_WRONG_PROFILE);
}

TEST(ShaarWindowsTabsHandlersTest, WindowRequestResolutionUsesLifecycleRegistry) {
  shaar::ModuleCall call = {};
  CapturedWindowRequest captured;
  shaar_window* const window = reinterpret_cast<shaar_window*>(1);
  call.engine = reinterpret_cast<shaar_engine*>(1);
  call.scope.size = sizeof(shaar_scope);
  call.scope.profile = reinterpret_cast<shaar_profile*>(1);
  call.operation = SHAAR_OP_WINDOW_REQUEST_RESOLVE;
  call.window = window;
  static constexpr char kArgs[] =
      R"({"schemaVersion":1,"requestID":"4294967298","accepted":true})";
  call.args_json = {kArgs, sizeof(kArgs) - 1};
  call.request_registry_context = &captured;
  call.resolve_window_request = CaptureWindowRequest;
  shaar_error error = {};
  error.size = sizeof(error);

  EXPECT_EQ(HandleWindowRequestResolve(&call, &error), SHAAR_OK);
  EXPECT_EQ(error.code, SHAAR_OK);
  EXPECT_TRUE(captured.called);
  EXPECT_EQ(captured.request_id, 4294967298ULL);
  EXPECT_EQ(captured.window, window);
  EXPECT_TRUE(captured.accepted);
}

TEST(ShaarWindowsTabsHandlersTest, WindowRequestResolutionRejectsMissingRegistry) {
  shaar::ModuleCall call = {};
  call.engine = reinterpret_cast<shaar_engine*>(1);
  call.scope.size = sizeof(shaar_scope);
  call.scope.profile = reinterpret_cast<shaar_profile*>(1);
  call.operation = SHAAR_OP_WINDOW_REQUEST_RESOLVE;
  static constexpr char kArgs[] =
      R"({"schemaVersion":1,"requestID":"7","accepted":false})";
  call.args_json = {kArgs, sizeof(kArgs) - 1};
  shaar_error error = {};
  error.size = sizeof(error);

  EXPECT_EQ(HandleWindowRequestResolve(&call, &error), SHAAR_NOT_READY);
  EXPECT_EQ(error.code, SHAAR_NOT_READY);
}

TEST(ShaarWindowsTabsHandlersTest, TabActivationResolutionUsesExactScope) {
  shaar::ModuleCall call = {};
  CapturedTabActivation captured;
  shaar_window* const window = reinterpret_cast<shaar_window*>(1);
  shaar_tab* const tab = reinterpret_cast<shaar_tab*>(2);
  call.engine = reinterpret_cast<shaar_engine*>(1);
  call.scope.size = sizeof(shaar_scope);
  call.scope.private_session = reinterpret_cast<shaar_private_session*>(1);
  call.window = window;
  call.tab = tab;
  call.operation = SHAAR_OP_TAB_ACTIVATION_RESOLVE;
  static constexpr char kArgs[] =
      R"({"schemaVersion":1,"requestID":"19","accepted":false})";
  call.args_json = {kArgs, sizeof(kArgs) - 1};
  call.request_registry_context = &captured;
  call.resolve_tab_activation = CaptureTabActivation;
  shaar_error error = {};
  error.size = sizeof(error);

  EXPECT_EQ(HandleTabActivationResolve(&call, &error), SHAAR_OK);
  EXPECT_TRUE(captured.called);
  EXPECT_EQ(captured.request_id, 19u);
  EXPECT_EQ(captured.window, window);
  EXPECT_EQ(captured.tab, tab);
  EXPECT_FALSE(captured.accepted);
}

TEST(ShaarWindowsTabsHandlersTest, ProbeStateRejectsUnregisteredHandles) {
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  auto* window = reinterpret_cast<shaar_window*>(2);
  auto* tab = reinterpret_cast<shaar_tab*>(3);
  shaar_error error = {};
  error.size = sizeof(error);
  shaar_tab_probe_state state = {};
  state.size = sizeof(state);
  shaar_scope scope = {.size = sizeof(shaar_scope),
                       .profile = reinterpret_cast<shaar_profile*>(4)};
  EXPECT_EQ(shaar_tab_get_probe_state(engine, scope, window, tab, &state, &error),
            SHAAR_NOT_FOUND);
  EXPECT_EQ(error.code, SHAAR_NOT_FOUND);
  EXPECT_EQ(state.live_web_contents, 0);
  EXPECT_EQ(state.selected_native_tab, 0);
  EXPECT_EQ(state.displayed_native_web_contents, 0);
  EXPECT_EQ(state.context_is_private, 0);
  EXPECT_EQ(state.scope_owns_tab, 0);
  state.size = sizeof(state) - 1;
  EXPECT_EQ(shaar_tab_get_probe_state(engine, scope, window, tab, &state, &error),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(error.code, SHAAR_INVALID_ARGUMENT);
}

TEST(ShaarWindowsTabsHandlersTest, FaviconBytesRejectUnregisteredAndAmbiguousScope) {
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  auto* window = reinterpret_cast<shaar_window*>(2);
  auto* tab = reinterpret_cast<shaar_tab*>(3);
  shaar_scope scope = {.size = sizeof(shaar_scope),
                       .profile = reinterpret_cast<shaar_profile*>(4)};
  shaar_bytes png = {"stale", 5};
  shaar_error error = {};
  error.size = sizeof(error);
  EXPECT_EQ(shaar_tab_favicon_png(engine, scope, window, tab, &png, &error),
            SHAAR_NOT_FOUND);
  EXPECT_EQ(error.code, SHAAR_NOT_FOUND);
  EXPECT_EQ(png.data, nullptr);
  EXPECT_EQ(png.size, 0u);

  scope.private_session = reinterpret_cast<shaar_private_session*>(5);
  EXPECT_EQ(shaar_tab_favicon_png(engine, scope, window, tab, &png, &error),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(error.code, SHAAR_INVALID_ARGUMENT);
}

}  // namespace
}  // namespace shaar::windows_tabs
