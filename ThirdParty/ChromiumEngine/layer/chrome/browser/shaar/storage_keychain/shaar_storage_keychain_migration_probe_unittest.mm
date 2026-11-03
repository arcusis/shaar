// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "components/os_crypt/common/keychain_password_mac.h"

#include <Security/Security.h>

#include <map>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/containers/span.h"
#include "crypto/apple/keychain_v2.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace {

// In-memory keychain fixture. This exercises Chromium's pinned OSCrypt
// migration code without touching the user's macOS Keychain.
class MigrationProbeKeychain final : public crypto::apple::KeychainV2 {
 public:
  using ItemKey = std::pair<std::string, std::string>;

  void Seed(std::string_view service,
            std::string_view account,
            std::string_view password) {
    items_[{std::string(service), std::string(account)}] =
        std::vector<uint8_t>(password.begin(), password.end());
  }

  base::expected<std::vector<uint8_t>, OSStatus> FindGenericPassword(
      std::string_view service,
      std::string_view account) override {
    if (service == kLegacyService)
      ++legacy_reads_;
    if (service == kLegacyService && legacy_read_error_ != noErr)
      return base::unexpected(legacy_read_error_);
    auto found = items_.find({std::string(service), std::string(account)});
    if (found == items_.end())
      return base::unexpected(errSecItemNotFound);
    return found->second;
  }

  OSStatus AddGenericPassword(std::string_view service,
                              std::string_view account,
                              base::span<const uint8_t> password) override {
    if (add_error_ != noErr)
      return add_error_;
    const bool inserted =
        items_
            .emplace(ItemKey(std::string(service), std::string(account)),
                     std::vector<uint8_t>(password.begin(), password.end()))
            .second;
    return inserted ? noErr : errSecDuplicateItem;
  }

  bool Has(std::string_view service, std::string_view account) const {
    return items_.contains({std::string(service), std::string(account)});
  }

  int legacy_reads() const { return legacy_reads_; }
  void set_legacy_read_error(OSStatus error) { legacy_read_error_ = error; }
  void set_add_error(OSStatus error) { add_error_ = error; }

 private:
  static constexpr char kLegacyService[] = "Ardia Safe Storage";
  std::map<ItemKey, std::vector<uint8_t>> items_;
  int legacy_reads_ = 0;
  OSStatus legacy_read_error_ = noErr;
  OSStatus add_error_ = noErr;
};

TEST(ShaarStorageKeychainMigrationProbe,
     CopiesExistingArdiaSecretAndKeepsRollbackItem) {
  MigrationProbeKeychain keychain;
  keychain.Seed("Ardia Safe Storage", "Ardia", "existing-cookie-key");
  KeychainPassword password(keychain);

  EXPECT_EQ(password.GetPassword(), "existing-cookie-key");
  EXPECT_EQ(password.GetPassword(), "existing-cookie-key");
  EXPECT_EQ(keychain.legacy_reads(), 1);
  EXPECT_TRUE(keychain.Has("Shaar Safe Storage", "Shaar"));
  EXPECT_TRUE(keychain.Has("Ardia Safe Storage", "Ardia"));
}

TEST(ShaarStorageKeychainMigrationProbe,
     ExistingShaarItemTakesPrecedenceOverLegacyItem) {
  MigrationProbeKeychain keychain;
  keychain.Seed("Ardia Safe Storage", "Ardia", "old-key");
  keychain.Seed("Shaar Safe Storage", "Shaar", "current-key");
  KeychainPassword password(keychain);

  EXPECT_EQ(password.GetPassword(), "current-key");
  EXPECT_EQ(keychain.legacy_reads(), 0);
}

TEST(ShaarStorageKeychainMigrationProbe,
     LegacyReadFailureDoesNotCreateReplacementKey) {
  MigrationProbeKeychain keychain;
  keychain.set_legacy_read_error(errSecAuthFailed);
  KeychainPassword password(keychain);

  EXPECT_TRUE(password.GetPassword().empty());
  EXPECT_FALSE(keychain.Has("Shaar Safe Storage", "Shaar"));
}

TEST(ShaarStorageKeychainMigrationProbe,
     EmptyLegacyItemDoesNotCreateReplacementKey) {
  MigrationProbeKeychain keychain;
  keychain.Seed("Ardia Safe Storage", "Ardia", "");
  KeychainPassword password(keychain);

  EXPECT_TRUE(password.GetPassword().empty());
  EXPECT_TRUE(keychain.Has("Ardia Safe Storage", "Ardia"));
  EXPECT_FALSE(keychain.Has("Shaar Safe Storage", "Shaar"));
}

TEST(ShaarStorageKeychainMigrationProbe,
     FailedCopyLeavesTheLegacyKeyAndDoesNotMintAnother) {
  MigrationProbeKeychain keychain;
  keychain.Seed("Ardia Safe Storage", "Ardia", "existing-cookie-key");
  keychain.set_add_error(errSecAuthFailed);
  KeychainPassword password(keychain);

  EXPECT_TRUE(password.GetPassword().empty());
  EXPECT_TRUE(keychain.Has("Ardia Safe Storage", "Ardia"));
  EXPECT_FALSE(keychain.Has("Shaar Safe Storage", "Shaar"));
}

TEST(ShaarStorageKeychainMigrationProbe, FreshInstallCreatesShaarIdentity) {
  MigrationProbeKeychain keychain;
  KeychainPassword password(keychain);

  EXPECT_FALSE(password.GetPassword().empty());
  EXPECT_TRUE(keychain.Has("Shaar Safe Storage", "Shaar"));
  EXPECT_FALSE(keychain.Has("Ardia Safe Storage", "Ardia"));
}

}  // namespace
