// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/devtools/shaar_devtools.h"

#include <string>

#include "testing/gtest/include/gtest/gtest.h"

namespace shaar::devtools {
namespace {

shaar_bytes Bytes(const std::string& value) {
  return {value.data(), value.size()};
}

TEST(ShaarDevToolsTest, CommandMapIsCapabilityScopedAndNeverExposesCookies) {
  EXPECT_STREQ("DOM.getDocument",
               ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR,
                              SHAAR_DEVTOOLS_DOM_GET_DOCUMENT));
  EXPECT_EQ(nullptr,
            ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER,
                           SHAAR_DEVTOOLS_DOM_GET_DOCUMENT));
  EXPECT_STREQ("Emulation.setLocaleOverride",
               ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER,
                              SHAAR_DEVTOOLS_EMULATION_SET_LOCALE_OVERRIDE));
  EXPECT_EQ(nullptr,
            ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR,
                           SHAAR_DEVTOOLS_NETWORK_GET_COOKIES));
  EXPECT_EQ(nullptr,
            ProtocolMethod(SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER,
                           SHAAR_DEVTOOLS_NETWORK_DELETE_COOKIES));
}

TEST(ShaarDevToolsTest, EncodesOnlyFixedMethodsWithNumericRequestIDs) {
  const std::string args =
      R"({"schemaVersion":1,"capability":1,"command":6,"params":{"depth":2}})";
  std::string output;
  std::string reason;
  EXPECT_EQ(SHAAR_OK,
            EncodeProtocolRequest(Bytes(args), 44, &output, &reason));
  EXPECT_NE(std::string::npos, output.find("DOM.getDocument"));
  EXPECT_NE(std::string::npos, output.find("\"id\":44"));
  EXPECT_EQ(std::string::npos, output.find("methodName"));
}

TEST(ShaarDevToolsTest, RejectsUnknownFieldsMalformedJSONAndForbiddenCommands) {
  for (const std::string args : {
           R"({"schemaVersion":1,"capability":1,"command":6,"params":{},"method":"Page.navigate"})",
           R"({bad json)",
           R"({"schemaVersion":1,"capability":1,"command":41,"params":{}})",
           R"({"schemaVersion":1,"capability":1,"command":6,"params":{"depth":2,"unreviewed":true}})",
           R"({"schemaVersion":1,"capability":3,"command":6,"params":{}})"}) {
    std::string output;
    std::string reason;
    EXPECT_NE(SHAAR_OK,
              EncodeProtocolRequest(Bytes(args), 7, &output, &reason));
    EXPECT_TRUE(output.empty());
  }
}

TEST(ShaarDevToolsTest, RejectsEmptyZeroAndOutOfRangeRequestIDs) {
  const std::string args =
      R"({"schemaVersion":1,"capability":2,"command":15,"params":{}})";
  std::string output;
  std::string reason;
  EXPECT_EQ(SHAAR_INVALID_ARGUMENT,
            EncodeProtocolRequest(Bytes(args), 0, &output, &reason));
  EXPECT_EQ(SHAAR_INVALID_ARGUMENT,
            EncodeProtocolRequest(Bytes(args), UINT64_MAX, &output, &reason));
}

TEST(ShaarDevToolsTest, LifecycleEntryRegistersOnlyItsOperationRange) {
  ShaarModuleRegistry registry;
  shaar_devtools_register(&registry);
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_DEVTOOLS_CALL));
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_DEVTOOLS_UI_SHOW));
  EXPECT_NE(nullptr, registry.Find(SHAAR_OP_DEVTOOLS_CONTROL_STATUS));
  EXPECT_EQ(nullptr, registry.Find(SHAAR_OP_MEDIA_GET_STATE));
  EXPECT_NE(nullptr, registry.FindModule(SHAAR_MODULE_DEVTOOLS));
}

}  // namespace
}  // namespace shaar::devtools
