// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include "base/apple/scoped_cftyperef.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/bind.h"
#include "base/run_loop.h"
#include "base/synchronization/waitable_event.h"
#include "base/task/thread_pool.h"
#include "base/test/scoped_command_line.h"
#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "components/os_crypt/async/browser/keychain_key_provider.h"
#include "components/os_crypt/common/keychain_password_mac.h"
#include "crypto/apple/keychain_v2.h"
#include "net/cookies/canonical_cookie.h"
#include "net/extras/sqlite/cookie_crypto_delegate.h"
#include "net/extras/sqlite/sqlite_persistent_cookie_store.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace os_crypt_async {
namespace {

class PendingKeychain final : public crypto::apple::KeychainV2 {
 public:
  base::expected<std::vector<uint8_t>, OSStatus> FindGenericPassword(
      std::string_view, std::string_view) override {
    entered.Signal();
    release.Wait();
    return base::unexpected(errSecAuthFailed);
  }
  base::WaitableEvent entered;
  base::WaitableEvent release;
};

// This adapter only selects a disposable on-disk macOS keychain. Its lookup
// executes the actual Security framework; no secret or OSStatus is mocked.
class IsolatedRealKeychain final : public crypto::apple::KeychainV2 {
 public:
  explicit IsolatedRealKeychain(SecKeychainRef keychain) : keychain_(keychain) {}
  base::expected<std::vector<uint8_t>, OSStatus> FindGenericPassword(
      std::string_view service, std::string_view account) override {
    @autoreleasepool {
      NSDictionary* query = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : @(std::string(service).c_str()),
        (__bridge id)kSecAttrAccount : @(std::string(account).c_str()),
        (__bridge id)kSecMatchSearchList : @[(__bridge id)keychain_],
        (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
        (__bridge id)kSecReturnData : @YES,
        (__bridge id)kSecUseAuthenticationUI : (__bridge id)kSecUseAuthenticationUIFail,
      };
      base::apple::ScopedCFTypeRef<CFTypeRef> result;
      last_status = SecItemCopyMatching((__bridge CFDictionaryRef)query,
                                       result.InitializeInto());
      if (last_status != errSecSuccess)
        return base::unexpected(last_status);
      CFDataRef data = static_cast<CFDataRef>(result.get());
      return std::vector<uint8_t>(CFDataGetBytePtr(data),
                                  CFDataGetBytePtr(data) + CFDataGetLength(data));
    }
  }
  OSStatus last_status = errSecSuccess;
 private:
  SecKeychainRef keychain_;
};

}  // namespace

class ShaarKeychainDeadlineTest : public testing::Test {
 protected:
  std::unique_ptr<KeyProvider> Provider(crypto::apple::KeychainV2* keychain) {
    return std::unique_ptr<KeyProvider>(new KeychainKeyProvider(keychain));
  }
  void SetUp() override {
    command_line_.GetProcessCommandLine()->AppendSwitch("shaar-embedder");
  }
  base::test::ScopedCommandLine command_line_;
  base::test::TaskEnvironment environment_{
      base::test::TaskEnvironment::MainThreadType::UI,
      base::test::TaskEnvironment::ThreadPoolExecutionMode::ASYNC};
};

TEST_F(ShaarKeychainDeadlineTest, PendingPromptReleasesStartupAndLateDenialDoesNotReplyTwice) {
  PendingKeychain keychain;
  auto provider = Provider(&keychain);
  int replies = 0;
  base::RunLoop completion;
  provider->GetKey(base::BindOnce(
      [](int* replies, base::OnceClosure done, const std::string& tag,
         base::expected<Encryptor::Key, KeyProvider::KeyError> key) {
        ++*replies;
        std::move(done).Run();
        EXPECT_EQ(tag, "v10");
        ASSERT_FALSE(key.has_value());
        EXPECT_EQ(key.error(), KeyProvider::KeyError::kTemporarilyUnavailable);
      }, &replies, completion.QuitClosure()));
  keychain.entered.Wait();
  completion.Run();
  EXPECT_EQ(replies, 1);
  keychain.release.Signal();
  environment_.RunUntilIdle();
  EXPECT_EQ(replies, 1);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
TEST_F(ShaarKeychainDeadlineTest, RealLockedKeychainDenialPreservesStableItemAndSecret) {
  base::ScopedTempDir directory;
  ASSERT_TRUE(directory.CreateUniqueTempDir());
  auto path = directory.GetPath().AppendASCII("isolated.keychain");
  base::apple::ScopedCFTypeRef<SecKeychainRef> keychain;
  const char password[] = "isolated-test-keychain-password";
  ASSERT_EQ(SecKeychainCreate(path.value().c_str(), sizeof(password) - 1,
                             password, false, nullptr, keychain.InitializeInto()),
            errSecSuccess);
  const std::string service = KeychainPassword::GetServiceName();
  const std::string account = KeychainPassword::GetAccountName();
  EXPECT_EQ(service, "Shaar Safe Storage");
  EXPECT_EQ(account, "Shaar");
  const char secret[] = "isolated-test-cookie-secret";
  ASSERT_EQ(SecKeychainAddGenericPassword(keychain.get(), service.size(), service.data(),
                                        account.size(), account.data(), sizeof(secret) - 1,
                                        secret, nullptr), errSecSuccess);
  IsolatedRealKeychain real_keychain(keychain.get());
  auto before = real_keychain.FindGenericPassword(service, account);
  ASSERT_TRUE(before.has_value());
  ASSERT_EQ(SecKeychainLock(keychain.get()), errSecSuccess);
  auto provider = Provider(&real_keychain);
  base::test::TestFuture<const std::string&,
      base::expected<Encryptor::Key, KeyProvider::KeyError>> future;
  provider->GetKey(future.GetCallback());
  auto& [tag, key] = future.Get();
  environment_.RunUntilIdle();
  EXPECT_EQ(tag, "v10");
  ASSERT_FALSE(key.has_value());
  EXPECT_EQ(key.error(), KeyProvider::KeyError::kTemporarilyUnavailable);
  EXPECT_NE(real_keychain.last_status, errSecSuccess);
  ASSERT_EQ(SecKeychainUnlock(keychain.get(), sizeof(password) - 1, password, true),
            errSecSuccess);
  auto after = real_keychain.FindGenericPassword(service, account);
  ASSERT_TRUE(after.has_value());
  EXPECT_EQ(*before, *after);
  EXPECT_EQ(SecKeychainDelete(keychain.get()), errSecSuccess);
}
#pragma clang diagnostic pop

}  // namespace os_crypt_async

namespace {
class LockedCookieCrypto final : public net::CookieCryptoDelegate {
 public:
  void Init(base::OnceClosure callback) override { std::move(callback).Run(); }
  bool IsEncryptionAvailable() const override { return false; }
  bool EncryptString(const std::string&, std::string*) override {
    ADD_FAILURE() << "Locked persistent cookies must not be rewritten";
    return false;
  }
  bool DecryptString(const std::string&, std::string*) override {
    ADD_FAILURE() << "Locked persistent cookies must not be treated as corrupt";
    return false;
  }
};

TEST(ShaarKeychainCookieTest, UnavailableKeyLeavesPersistentDatabaseUnopened) {
  base::test::TaskEnvironment environment;
  base::ScopedTempDir directory;
  ASSERT_TRUE(directory.CreateUniqueTempDir());
  auto path = directory.GetPath().AppendASCII("Cookies");
  const std::string original = "saved encrypted cookie database must remain untouched";
  ASSERT_TRUE(base::WriteFile(path, original));
  auto store = base::MakeRefCounted<net::SQLitePersistentCookieStore>(
      path, base::SequencedTaskRunner::GetCurrentDefault(),
      base::ThreadPool::CreateSequencedTaskRunner({base::MayBlock()}),
      true, std::make_unique<LockedCookieCrypto>(), false);
  base::test::TestFuture<std::vector<std::unique_ptr<net::CanonicalCookie>>> loaded;
  store->Load(loaded.GetCallback(), net::NetLogWithSource());
  EXPECT_TRUE(loaded.Get().empty());
  base::test::TestFuture<void> flushed;
  store->Flush(flushed.GetCallback());
  ASSERT_TRUE(flushed.Wait());
  store.reset();
  environment.RunUntilIdle();
  std::string after;
  ASSERT_TRUE(base::ReadFileToString(path, &after));
  EXPECT_EQ(after, original);
}
}  // namespace
