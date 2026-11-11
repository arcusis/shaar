// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_LIFECYCLE_SHAAR_LIFECYCLE_H_
#define CHROME_BROWSER_SHAAR_LIFECYCLE_SHAAR_LIFECYCLE_H_

#include <memory>
#include <string>
#include <vector>

#include "chrome/browser/shaar/public/shaar_engine.h"

class ChromeContentBrowserClient;
class ScopedKeepAlive;

namespace shaar::lifecycle {

// Hook called from Chromium's browser close manager after an unload abort.
void EngineQuitCancelled();
std::unique_ptr<ScopedKeepAlive> CreateHostKeepAlive();
void EngineReady(shaar_engine* engine);
void SafeStorageUnavailable();
void EngineWillShutDown(shaar_engine* engine);
shaar_engine* ActiveEngine();
bool EngineIsRunning(shaar_engine* engine);
bool EngineIsReady(shaar_engine* engine);
bool EngineIsShuttingDown(shaar_engine* engine);
// Uses the same marked disposable data-root check as lifecycle probes.
bool HasOwnedProbeRoot(const shaar_engine* engine);
std::unique_ptr<ChromeContentBrowserClient> CreateContentBrowserClient();
std::vector<std::string> ChromeMainArguments(
    const std::string& executable_path, const std::string& data_root,
    const std::string& locale, bool testing);

}  // namespace shaar::lifecycle

#endif  // CHROME_BROWSER_SHAAR_LIFECYCLE_SHAAR_LIFECYCLE_H_
