// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/downloads/shaar_downloads.h"

#include "base/time/time.h"
#include "components/download/public/common/mock_download_item.h"
#include "testing/gmock/include/gmock/gmock.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace shaar {
namespace {

using ::testing::NiceMock;
using ::testing::Return;
using ::testing::ReturnRefOfCopy;

void SetRecordDefaults(NiceMock<download::MockDownloadItem>& item,
                       download::DownloadItem::DownloadState state) {
  ON_CALL(item, GetGuid()).WillByDefault(ReturnRefOfCopy(std::string("guid-1")));
  ON_CALL(item, GetOriginalUrl())
      .WillByDefault(ReturnRefOfCopy(GURL("https://example.test/file.bin")));
  ON_CALL(item, GetFileNameToReportUser())
      .WillByDefault(Return(base::FilePath::FromUTF8Unsafe("file.bin")));
  ON_CALL(item, GetTargetFilePath())
      .WillByDefault(ReturnRefOfCopy(base::FilePath::FromUTF8Unsafe("/downloads/file.bin")));
  ON_CALL(item, GetFullPath())
      .WillByDefault(ReturnRefOfCopy(base::FilePath::FromUTF8Unsafe("/temporary/file.bin")));
  ON_CALL(item, GetState()).WillByDefault(Return(state));
  ON_CALL(item, IsPaused()).WillByDefault(Return(false));
  ON_CALL(item, GetTotalBytes()).WillByDefault(Return(-1));
  ON_CALL(item, GetReceivedBytes()).WillByDefault(Return(17));
  ON_CALL(item, CurrentSpeed()).WillByDefault(Return(3));
  ON_CALL(item, GetMimeType()).WillByDefault(Return("application/octet-stream"));
  ON_CALL(item, IsDangerous()).WillByDefault(Return(false));
  ON_CALL(item, IsInsecure()).WillByDefault(Return(false));
  ON_CALL(item, GetLastReason())
      .WillByDefault(Return(download::DOWNLOAD_INTERRUPT_REASON_NONE));
  ON_CALL(item, GetStartTime())
      .WillByDefault(Return(base::Time::FromMillisecondsSinceUnixEpoch(1234)));
}

TEST(ShaarDownloadsRecordTest, MapsAllStatesAndKeepsUnknownSize) {
  const std::pair<download::DownloadItem::DownloadState, const char*> cases[] = {
      {download::DownloadItem::IN_PROGRESS, "downloading"},
      {download::DownloadItem::COMPLETE, "finished"},
      {download::DownloadItem::CANCELLED, "cancelled"},
      {download::DownloadItem::INTERRUPTED, "failed"},
  };

  for (const auto& [state, expected] : cases) {
    NiceMock<download::MockDownloadItem> item;
    SetRecordDefaults(item, state);
    const base::Value::Dict record = Downloads::Record(item);
    ASSERT_NE(record.FindString("state"), nullptr);
    EXPECT_EQ(*record.FindString("state"), expected);
    EXPECT_EQ(record.FindDouble("total"), -1.0);
    EXPECT_EQ(record.FindDouble("received"), 17.0);
    ASSERT_NE(record.FindString("path"), nullptr);
    EXPECT_EQ(*record.FindString("path"), "/downloads/file.bin");
    ASSERT_NE(record.FindString("filename"), nullptr);
    EXPECT_EQ(*record.FindString("filename"), "file.bin");
    EXPECT_EQ(record.FindDouble("startTime"), 1234.0);
    EXPECT_TRUE(record.Find("error")->is_none());
  }
}

TEST(ShaarDownloadsRecordTest, UsesFullPathWhenTargetPathIsEmpty) {
  NiceMock<download::MockDownloadItem> item;
  SetRecordDefaults(item, download::DownloadItem::IN_PROGRESS);
  ON_CALL(item, GetTargetFilePath())
      .WillByDefault(ReturnRefOfCopy(base::FilePath()));

  const base::Value::Dict record = Downloads::Record(item);
  ASSERT_NE(record.FindString("path"), nullptr);
  EXPECT_EQ(*record.FindString("path"), "/temporary/file.bin");
}

TEST(ShaarDownloadsHandlerTest, RejectsMalformedArgumentsAndUnknownOperation) {
  Downloads downloads(nullptr, "profile-id", "", nullptr, nullptr);
  std::string payload;
  std::string error;

  EXPECT_FALSE(downloads.Handle(SHAAR_OP_DOWNLOAD_LIST, "{", &payload, &error));
  EXPECT_EQ(error, "SHAAR_INVALID_ARGUMENT");

  EXPECT_FALSE(downloads.Handle(static_cast<shaar_operation>(999),
                                R"({"schemaVersion":1})", &payload, &error));
  EXPECT_EQ(error, "SHAAR_UNSUPPORTED_CAPABILITY");
}

}  // namespace
}  // namespace shaar
