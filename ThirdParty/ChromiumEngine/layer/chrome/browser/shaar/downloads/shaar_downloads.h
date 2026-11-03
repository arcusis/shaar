// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_DOWNLOADS_SHAAR_DOWNLOADS_H_
#define CHROME_BROWSER_SHAAR_DOWNLOADS_SHAAR_DOWNLOADS_H_

#include <string>
#include <map>
#include <set>
#include <vector>

#include "base/timer/timer.h"
#include "base/values.h"
#include "base/memory/weak_ptr.h"
#include "components/download/content/public/all_download_item_notifier.h"
#include "components/download/public/common/download_item.h"
#include "chrome/browser/shaar/public/shaar_engine.h"
#include "chrome/browser/shaar/downloads/shaar_module_registry.h"

namespace content {
class BrowserContext;
class DownloadManager;
}  // namespace content

namespace shaar {

// Profile-owned downloads view. The caller must resolve the exact regular or
// private BrowserContext from the supplied shaar_scope before constructing it.
// It never searches other managers and does not own the BrowserContext.
class Downloads final : private download::AllDownloadItemNotifier::Observer {
 public:
  using EventCallback = void (*)(void* context,
                                 const std::string& profile_id,
                                 const std::string& session_id,
                                 const base::Value::Dict& event);

  Downloads(content::BrowserContext* browser_context,
            std::string profile_id,
            std::string session_id,
            EventCallback event_callback,
            void* event_context);
  Downloads(const Downloads&) = delete;
  Downloads& operator=(const Downloads&) = delete;
  ~Downloads() override;

  // Returns false until Chromium has initialized history for this manager.
  bool IsReady() const;
  base::Value::Dict List() const;
  bool Control(const std::string& guid,
               const std::string& action,
               std::string* error_code);
  bool Directory(const std::string& action,
                 const std::string& requested_path,
                 std::string* effective_path,
                 std::string* error_code) const;
  bool Handle(shaar_operation operation,
              const std::string& arguments_json,
              std::string* payload_json,
              std::string* error_code);

  static base::Value::Dict Record(const download::DownloadItem& item);

 private:
  struct Transition {
    download::DownloadItem::DownloadState state;
    bool paused;
    bool dangerous;
    bool insecure;
    bool operator==(const Transition&) const = default;
  };

  void OnManagerInitialized(content::DownloadManager* manager) override;
  void OnManagerGoingDown(content::DownloadManager* manager) override;
  void OnDownloadCreated(content::DownloadManager* manager,
                         download::DownloadItem* item) override;
  void OnDownloadUpdated(content::DownloadManager* manager,
                         download::DownloadItem* item) override;
  void OnDownloadRemoved(content::DownloadManager* manager,
                         download::DownloadItem* item) override;

  void EmitUpsert(download::DownloadItem* item);
  void EmitRemove(download::DownloadItem* item);
  void PostEvent(base::Value::Dict event);
  void FlushProgress();
  static Transition GetTransition(const download::DownloadItem& item);

  content::BrowserContext* browser_context_;
  std::string profile_id_;
  std::string session_id_;
  EventCallback event_callback_;
  void* event_context_;
  content::DownloadManager* manager_;
  bool ready_ = false;
  std::unique_ptr<download::AllDownloadItemNotifier> notifier_;
  std::map<std::string, Transition> last_transition_;
  std::set<std::string> pending_progress_;
  base::OneShotTimer progress_timer_;
  base::WeakPtrFactory<Downloads> weak_factory_{this};
};

}  // namespace shaar

void shaar_downloads_register(shaar::ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_DOWNLOADS_SHAAR_DOWNLOADS_H_
