// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/site_data/shaar_site_data.h"

#include "testing/gtest/include/gtest/gtest.h"

TEST(ShaarSiteDataTest, AcceptsExactHttpOrigins) {
  EXPECT_TRUE(IsValidSiteDataOriginForTesting("https://example.com"));
  EXPECT_TRUE(IsValidSiteDataOriginForTesting("http://localhost:8080/"));
}

TEST(ShaarSiteDataTest, RejectsNonOriginAndUnsafeSchemes) {
  EXPECT_FALSE(IsValidSiteDataOriginForTesting("https://example.com/path"));
  EXPECT_FALSE(IsValidSiteDataOriginForTesting("https://example.com?q=1"));
  EXPECT_FALSE(IsValidSiteDataOriginForTesting("file:///tmp/page"));
  EXPECT_FALSE(IsValidSiteDataOriginForTesting("https://user@example.com"));
  EXPECT_FALSE(IsValidSiteDataOriginForTesting(""));
}

TEST(ShaarSiteDataTest, RegistersItsOperationRangeAndModuleID) {
  ShaarModuleRegistry registry;
  shaar_site_data_register(&registry);
  EXPECT_EQ(registry.Find(SHAAR_OP_SITE_SETTINGS_GET), &HandleSiteDataOperation);
  EXPECT_EQ(registry.Find(SHAAR_OP_THIRD_PARTY_COOKIES_SET),
            &HandleSiteDataOperation);
  EXPECT_NE(registry.FindModule(SHAAR_MODULE_SITE_DATA), nullptr);
}

TEST(ShaarSiteDataTest, SecurityInfoRequiresSelectedRegularTabScope) {
  shaar_scope scope{};
  scope.size = sizeof(scope);
  shaar_bytes output{};
  shaar_error error{};
  error.size = sizeof(error);
  EXPECT_EQ(shaar_site_security_info(nullptr, scope, nullptr, nullptr,
                                     &output, &error), SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(error.code, SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(output.size, 0u);
}

TEST(ShaarSiteDataTest, SecurityLevelRejectsCertificateErrorsAndNonWebPages) {
  EXPECT_EQ(SiteSecurityLevelForTesting("https://example.com", false), "secure");
  EXPECT_EQ(SiteSecurityLevelForTesting("https://example.com", true), "certificateError");
  EXPECT_EQ(SiteSecurityLevelForTesting("http://example.com", false), "insecure");
  EXPECT_EQ(SiteSecurityLevelForTesting("file:///tmp/page", false), "unavailable");
}
