// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_EXTENSIONS_SHAAR_EXTENSION_INSTALL_H_
#define CHROME_BROWSER_SHAAR_EXTENSIONS_SHAAR_EXTENSION_INSTALL_H_

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "base/values.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/public/shaar_engine.h"

class Profile;
namespace extensions {
class Extension;
class PermissionSet;
}  // namespace extensions

namespace shaar::extensions_host {

enum class UnpackedFolderStatus {
  kOk,
  kInvalid,
};

// Absolute Manifest V3 directory. Parent references are rejected before the
// path is resolved. A directory link is followed to its real folder. The
// resolved manifest must stay inside that folder. `resolved` receives the
// real directory when inspection succeeds.
UnpackedFolderStatus InspectUnpackedFolder(const base::FilePath& path);
UnpackedFolderStatus InspectUnpackedFolder(const base::FilePath& path,
                                           base::FilePath* resolved);

// Prompt types the app can show. Anything else is declined.
std::optional<std::string_view> InstallPromptEventType(int prompt_type);

struct InstallConsentDetails {
  std::vector<std::string> permissions;
  std::vector<std::string> host_permissions;
};

std::optional<InstallConsentDetails> BuildInstallConsentDetails(
    const extensions::Extension& extension,
    const extensions::PermissionSet& permissions);

bool DeveloperModePayloadValid(const base::DictValue& input);
bool UnpackedPayloadValid(const base::DictValue& input);
bool SiteAccessPayloadValid(const base::DictValue& input);

shaar_error_code ApplyDeveloperMode(Profile* profile,
                                    bool enabled,
                                    shaar_reply_fn reply,
                                    void* reply_context,
                                    shaar_request_id request_id,
                                    shaar_error* error);

shaar_error_code BeginUnpackedLoad(ShaarEngineContext* context,
                                   shaar_engine* engine,
                                   shaar_window* window,
                                   shaar_tab* tab,
                                   Profile* profile,
                                   const base::DictValue& input,
                                   shaar_reply_fn reply,
                                   void* reply_context,
                                   shaar_request_id request_id,
                                   shaar_error* error);

shaar_error_code ApplySiteAccess(ShaarEngineContext* context,
                                 shaar_engine* engine,
                                 shaar_window* window,
                                 shaar_tab* tab,
                                 Profile* profile,
                                 const base::DictValue& input,
                                 shaar_reply_fn reply,
                                 void* reply_context,
                                 shaar_request_id request_id,
                                 shaar_error* error);

shaar_error_code ResolveInstallDecision(ShaarEngineContext* context,
                                        shaar_engine* engine,
                                        shaar_window* window,
                                        shaar_tab* tab,
                                        Profile* profile,
                                        std::string_view profile_id,
                                        std::string_view request_id,
                                        bool accepted,
                                        shaar_reply_fn reply,
                                        void* reply_context,
                                        shaar_request_id abi_request,
                                        shaar_error* error);

}  // namespace shaar::extensions_host

#endif  // CHROME_BROWSER_SHAAR_EXTENSIONS_SHAAR_EXTENSION_INSTALL_H_
