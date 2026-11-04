// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/bookmarks/shaar_bookmarks.h"

#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/json/json_reader.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "chrome/browser/bookmarks/bookmark_model_factory.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/test/base/testing_profile.h"
#include "components/bookmarks/browser/bookmark_model.h"
#include "components/bookmarks/browser/bookmark_node.h"
#include "components/bookmarks/test/bookmark_test_helpers.h"
#include "content/public/test/browser_task_environment.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace shaar {
namespace {

TEST(ShaarBookmarksModuleTest, RejectsPrivateScopeBeforeModelLookup) {
  shaar_engine engine;
  BookmarksModule module(nullptr, true, &engine, "regular-profile-id");

  for (shaar_operation operation :
       {SHAAR_OP_BOOKMARK_TREE, SHAAR_OP_BOOKMARK_APPLY,
        SHAAR_OP_BOOKMARK_WATCH}) {
    EXPECT_EQ(module.Submit(operation, "{}", nullptr, nullptr),
              SHAAR_PRIVATE_DISALLOWED);
  }
}

TEST(ShaarBookmarksModuleTest, RegistersEachBookmarkOperation) {
  ShaarModuleRegistry registry;
  shaar_bookmarks_register(&registry);
  EXPECT_NE(registry.Find(SHAAR_OP_BOOKMARK_TREE), nullptr);
  EXPECT_NE(registry.Find(SHAAR_OP_BOOKMARK_APPLY), nullptr);
  EXPECT_NE(registry.Find(SHAAR_OP_BOOKMARK_WATCH), nullptr);
}

TEST(ShaarBookmarksModuleTest,
     RegisteredHandlerRejectsPrivateScopeBeforeLookup) {
  ShaarModuleRegistry registry;
  shaar_bookmarks_register(&registry);

  shaar_engine engine;
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.private_session = reinterpret_cast<shaar_private_session *>(1);
  for (shaar_operation operation : {SHAAR_OP_BOOKMARK_TREE,
                                    SHAAR_OP_BOOKMARK_APPLY,
                                    SHAAR_OP_BOOKMARK_WATCH}) {
    auto handler = registry.Find(operation);
    ASSERT_NE(handler, nullptr);
    shaar_error error{};
    error.size = sizeof(error);
    EXPECT_EQ(handler(nullptr, &engine, scope, nullptr, nullptr, operation,
                      {nullptr, 0}, 1, nullptr, nullptr, &error),
              SHAAR_PRIVATE_DISALLOWED)
        << operation;
    EXPECT_EQ(error.code, SHAAR_PRIVATE_DISALLOWED) << operation;
  }
}

struct ReplyState {
  bool called = false;
  shaar_error_code code = SHAAR_OK;
  std::string payload;
  std::vector<std::string> *order = nullptr;
};

void CaptureReply(void *context, shaar_error_code code,
                  const std::string &payload) {
  auto *state = static_cast<ReplyState *>(context);
  state->called = true;
  state->code = code;
  state->payload = payload;
  if (state->order)
    state->order->push_back("reply");
}

struct EventState {
  std::vector<std::string> order;
  std::vector<std::string> profile_ids;
  std::vector<std::string> session_ids;
  std::vector<std::string> payloads;
  std::vector<shaar_event_kind> kinds;
};

void CaptureEvent(void *context, const shaar_event *event) {
  auto *state = static_cast<EventState *>(context);
  state->order.push_back("event");
  state->kinds.push_back(event->kind);
  state->profile_ids.emplace_back(event->profile_id.data,
                                  event->profile_id.size);
  state->session_ids.emplace_back(
      event->session_id.data ? event->session_id.data : "",
      event->session_id.size);
  state->payloads.emplace_back(event->payload_json.data,
                               event->payload_json.size);
}

class ShaarBookmarksLoadedTest : public testing::Test {
public:
  ShaarBookmarksLoadedTest() = default;
  ShaarBookmarksLoadedTest(const ShaarBookmarksLoadedTest &) = delete;
  ShaarBookmarksLoadedTest &
  operator=(const ShaarBookmarksLoadedTest &) = delete;
  ~ShaarBookmarksLoadedTest() override = default;

  void SetUp() override {
    TestingProfile::Builder builder;
    builder.AddTestingFactory(BookmarkModelFactory::GetInstance(),
                              BookmarkModelFactory::GetDefaultFactory());
    profile_ = builder.Build();
    model_ = BookmarkModelFactory::GetForBrowserContext(profile_.get());
    ASSERT_NE(model_, nullptr);
    bookmarks::test::WaitForBookmarkModelToLoad(model_);
    engine_.on_event = &CaptureEvent;
    engine_.event_context = &events_;
    module_ = std::make_unique<BookmarksModule>(profile_.get(), false, &engine_,
                                                "profile-A");
  }

protected:
  ReplyState Submit(shaar_operation operation, const std::string &arguments) {
    ReplyState reply;
    EXPECT_EQ(module_->Submit(operation, arguments, &CaptureReply, &reply),
              SHAAR_OK);
    task_environment_.RunUntilIdle();
    return reply;
  }

  content::BrowserTaskEnvironment task_environment_;
  std::unique_ptr<TestingProfile> profile_;
  raw_ptr<bookmarks::BookmarkModel> model_ = nullptr;
  shaar_engine engine_;
  EventState events_;
  std::unique_ptr<BookmarksModule> module_;
};

TEST_F(ShaarBookmarksLoadedTest,
       TreePreservesOrderKindsEmptyTitlesIdsAndCreationDate) {
  const base::Time creation_date =
      base::Time::FromMillisecondsSinceUnixEpoch(123);
  const base::Uuid folder_id =
      base::Uuid::ParseLowercase("10000000-0000-4000-8000-000000000001");
  const base::Uuid url_id =
      base::Uuid::ParseLowercase("10000000-0000-4000-8000-000000000002");
  const bookmarks::BookmarkNode *folder = model_->AddFolder(
      model_->bookmark_bar_node(), 0, u"", nullptr, creation_date, folder_id);
  model_->AddURL(folder, 0, u"", GURL("https://example.test/"), nullptr,
                 creation_date, url_id);
  model_->AddURL(model_->bookmark_bar_node(), 1, u"second",
                 GURL("https://second.test/"), nullptr, creation_date);

  ReplyState reply = Submit(SHAAR_OP_BOOKMARK_TREE, R"({"schemaVersion":1})");
  ASSERT_TRUE(reply.called);
  ASSERT_EQ(reply.code, SHAAR_OK);
  std::optional<base::Value> payload = base::JSONReader::Read(reply.payload, base::JSON_PARSE_RFC);
  ASSERT_TRUE(payload);
  const base::DictValue &root = payload->GetDict();
  const base::DictValue *bar = root.FindDict("bar");
  ASSERT_NE(bar, nullptr);
  const base::ListValue *children = bar->FindList("c");
  ASSERT_NE(children, nullptr);
  ASSERT_EQ(children->size(), 2u);

  const base::DictValue &first = children->front().GetDict();
  ASSERT_NE(first.FindString("id"), nullptr);
  EXPECT_EQ(*first.FindString("id"), folder_id.AsLowercaseString());
  ASSERT_NE(first.FindString("t"), nullptr);
  EXPECT_TRUE(first.FindString("t")->empty());
  ASSERT_NE(first.FindString("k"), nullptr);
  EXPECT_EQ(*first.FindString("k"), "f");
  EXPECT_EQ(first.FindDouble("a"), 123.0);
  const base::ListValue *folder_children = first.FindList("c");
  ASSERT_NE(folder_children, nullptr);
  ASSERT_EQ(folder_children->size(), 1u);
  const base::DictValue &url = folder_children->front().GetDict();
  ASSERT_NE(url.FindString("id"), nullptr);
  EXPECT_EQ(*url.FindString("id"), url_id.AsLowercaseString());
  ASSERT_NE(url.FindString("t"), nullptr);
  EXPECT_TRUE(url.FindString("t")->empty());
  ASSERT_NE(url.FindString("k"), nullptr);
  EXPECT_EQ(*url.FindString("k"), "u");
  ASSERT_NE(url.FindString("u"), nullptr);
  EXPECT_EQ(*url.FindString("u"), "https://example.test/");
  ASSERT_NE(children->back().GetDict().FindString("t"), nullptr);
  EXPECT_EQ(*children->back().GetDict().FindString("t"), "second");
}

TEST_F(ShaarBookmarksLoadedTest,
       ApplySupportsMutationSequenceIdempotencyAndPartialResults) {
  constexpr char kAddedID[] = "20000000-0000-4000-8000-000000000001";
  constexpr char kFolderID[] = "20000000-0000-4000-8000-000000000002";
  const std::string add_url =
      R"({"op":"add","id":"20000000-0000-4000-8000-000000000001","parent":"bar","index":999,"t":"one","k":"u","u":"https://one.test/","ifAbsent":true})";
  ReplyState added =
      Submit(SHAAR_OP_BOOKMARK_APPLY,
             "{\"schemaVersion\":1,\"ops\":[" + add_url + "," + add_url + "]}");
  ASSERT_TRUE(added.called);
  ASSERT_EQ(added.code, SHAAR_OK);
  std::optional<base::Value> add_result = base::JSONReader::Read(added.payload, base::JSON_PARSE_RFC);
  ASSERT_TRUE(add_result);
  EXPECT_EQ(add_result->GetDict().FindInt("applied"), 1);
  EXPECT_EQ(add_result->GetDict().FindInt("skipped"), 1);
  ASSERT_TRUE(add_result->GetDict().FindList("invalid"));
  EXPECT_TRUE(add_result->GetDict().FindList("invalid")->empty());

  const std::string ops =
      R"({"schemaVersion":1,"ops":[)"
      R"({"op":"update","id":"20000000-0000-4000-8000-000000000001","t":"updated","u":"https://updated.test/","key":"sync"},)"
      R"({"op":"add","id":"20000000-0000-4000-8000-000000000002","parent":"bar","t":"folder","k":"f"},)"
      R"({"op":"move","id":"20000000-0000-4000-8000-000000000001","parent":"20000000-0000-4000-8000-000000000002","index":-1},)"
      R"({"op":"move","id":"20000000-0000-4000-8000-000000000002","parent":"20000000-0000-4000-8000-000000000002","index":0},)"
      R"({"op":"remove","id":"bar"}]})";
  ReplyState partial = Submit(SHAAR_OP_BOOKMARK_APPLY, ops);
  ASSERT_TRUE(partial.called);
  ASSERT_EQ(partial.code, SHAAR_OK);
  std::optional<base::Value> result = base::JSONReader::Read(partial.payload, base::JSON_PARSE_RFC);
  ASSERT_TRUE(result);
  EXPECT_EQ(result->GetDict().FindInt("applied"), 3);
  EXPECT_EQ(result->GetDict().FindInt("skipped"), 0);
  const base::ListValue *invalid = result->GetDict().FindList("invalid");
  ASSERT_NE(invalid, nullptr);
  ASSERT_EQ(invalid->size(), 2u);
  EXPECT_EQ(invalid->front().GetString(), "cycle");
  EXPECT_EQ(invalid->back().GetString(), "invalid_remove");

  ReplyState removed = Submit(
      SHAAR_OP_BOOKMARK_APPLY,
      R"({"schemaVersion":1,"ops":[{"op":"remove","id":"20000000-0000-4000-8000-000000000001"}]})");
  ASSERT_TRUE(removed.called);
  std::optional<base::Value> remove_result =
      base::JSONReader::Read(removed.payload, base::JSON_PARSE_RFC);
  ASSERT_TRUE(remove_result);
  EXPECT_EQ(remove_result->GetDict().FindInt("applied"), 1);
  EXPECT_EQ(
      model_->GetNodeByUuid(base::Uuid::ParseLowercase(kAddedID),
                            bookmarks::BookmarkModel::NodeTypeForUuidLookup::
                                kLocalOrSyncableNodes),
      nullptr);
  EXPECT_TRUE(model_->GetNodeByUuid(
      base::Uuid::ParseLowercase(kFolderID),
      bookmarks::BookmarkModel::NodeTypeForUuidLookup::kLocalOrSyncableNodes));
}

TEST_F(ShaarBookmarksLoadedTest, WatchCoalescesOwnChangesAndRepliesAfterEvent) {
  const base::Uuid id =
      base::Uuid::ParseLowercase("30000000-0000-4000-8000-000000000001");
  const bookmarks::BookmarkNode *node =
      model_->AddURL(model_->bookmark_bar_node(), 0, u"before",
                     GURL("https://before.test/"), nullptr, std::nullopt, id);

  ReplyState watch =
      Submit(SHAAR_OP_BOOKMARK_WATCH, R"({"schemaVersion":1,"enabled":true})");
  ASSERT_TRUE(watch.called);
  events_.order.clear();
  events_.kinds.clear();
  events_.profile_ids.clear();
  events_.session_ids.clear();
  events_.payloads.clear();

  ReplyState update;
  update.order = &events_.order;
  EXPECT_EQ(
      module_->Submit(
          SHAAR_OP_BOOKMARK_APPLY,
          R"({"schemaVersion":1,"ops":[{"op":"update","id":"30000000-0000-4000-8000-000000000001","t":"after","u":"https://after.test/","key":"changed"}]})",
          &CaptureReply, &update),
      SHAAR_OK);
  task_environment_.RunUntilIdle();

  ASSERT_TRUE(update.called);
  ASSERT_EQ(events_.kinds.size(), 1u);
  EXPECT_EQ(events_.kinds.front(), SHAAR_EVENT_BOOKMARK);
  ASSERT_EQ(events_.profile_ids.size(), 1u);
  EXPECT_EQ(events_.profile_ids.front(), "profile-A");
  ASSERT_EQ(events_.session_ids.size(), 1u);
  EXPECT_TRUE(events_.session_ids.front().empty());
  ASSERT_EQ(events_.payloads.size(), 1u);
  EXPECT_NE(events_.payloads.front().find("\"change\":\"invalidated\""),
            std::string::npos);
  ASSERT_EQ(events_.order.size(), 2u);
  EXPECT_EQ(events_.order[0], "event");
  EXPECT_EQ(events_.order[1], "reply");
  EXPECT_EQ(node->GetTitledUrlNodeTitle(), u"after");
}

} // namespace
} // namespace shaar
