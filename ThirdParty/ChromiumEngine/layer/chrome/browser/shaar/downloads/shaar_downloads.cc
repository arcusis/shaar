// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/downloads/shaar_downloads.h"

#include <algorithm>
#include <initializer_list>
#include <memory>
#include <optional>
#include <string_view>
#include <utility>

#include "base/json/json_writer.h"
#include "base/json/json_reader.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/download/download_prefs.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/pref_names.h"
#include "components/download/public/common/download_interrupt_reasons.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_source.h"
#include "components/download/public/common/simple_download_manager.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/download_manager.h"
#include "extensions/browser/extension_util.h"

namespace shaar {
namespace {

bool IsVisible(const download::DownloadItem& item) {
  // Chromium marks ephemeral helper downloads transient. Extension API and
  // installer sources, plus CRX MIME downloads, are not user downloads.
  return !item.IsTransient() &&
         item.GetDownloadSource() !=
             download::DownloadSource::EXTENSION_INSTALLER &&
         item.GetDownloadSource() != download::DownloadSource::EXTENSION_API &&
         !extensions::util::IsExtensionDownload(item);
}

const char* StateName(download::DownloadItem::DownloadState state) {
  switch (state) {
    case download::DownloadItem::IN_PROGRESS:
      return "downloading";
    case download::DownloadItem::COMPLETE:
      return "finished";
    case download::DownloadItem::CANCELLED:
      return "cancelled";
    case download::DownloadItem::INTERRUPTED:
      return "failed";
  }
  return "failed";
}

std::string PathString(const base::FilePath& path) {
  return path.AsUTF8Unsafe();
}

}  // namespace

Downloads::Downloads(content::BrowserContext* browser_context,
                     std::string profile_id,
                     std::string session_id,
                     EventCallback event_callback,
                     void* event_context)
    : browser_context_(browser_context),
      profile_id_(std::move(profile_id)),
      session_id_(std::move(session_id)),
      event_callback_(event_callback),
      event_context_(event_context),
      manager_(browser_context ? browser_context->GetDownloadManager() : nullptr) {
  if (manager_)
    notifier_ = std::make_unique<download::AllDownloadItemNotifier>(manager_, this);
}

Downloads::~Downloads() = default;

bool Downloads::IsReady() const {
  return ready_ && manager_;
}

base::DictValue Downloads::Record(const download::DownloadItem& item) {
  base::DictValue record;
  const base::FilePath& target = item.GetTargetFilePath();
  const base::FilePath& full = item.GetFullPath();
  const base::FilePath& shown = target.empty() ? full : target;
  const int64_t total = item.GetTotalBytes();
  const base::Time start = item.GetStartTime();
  record.Set("id", item.GetGuid());
  record.Set("url", item.GetOriginalUrl().spec());
  record.Set("filename", item.GetFileNameToReportUser().AsUTF8Unsafe());
  record.Set("path", PathString(shown));
  record.Set("state", StateName(item.GetState()));
  record.Set("paused", item.IsPaused());
  record.Set("received", static_cast<double>(item.GetReceivedBytes()));
  record.Set("total", total < 0 ? -1.0 : static_cast<double>(total));
  record.Set("speed", static_cast<double>(item.CurrentSpeed()));
  record.Set("mimeType", item.GetMimeType());
  record.Set("dangerous", item.IsDangerous() || item.IsInsecure());
  if (item.GetLastReason() == download::DOWNLOAD_INTERRUPT_REASON_NONE) {
    record.Set("error", base::Value());
  } else {
    record.Set("error", download::DownloadInterruptReasonToString(item.GetLastReason()));
  }
  record.Set("startTime", start.is_null()
                               ? 0.0
                               : static_cast<double>(start.InMillisecondsSinceUnixEpoch()));
  return record;
}

base::DictValue Downloads::List() const {
  base::DictValue result;
  result.Set("schemaVersion", 1);
  base::ListValue items;
  if (IsReady()) {
    download::SimpleDownloadManager::DownloadVector downloads;
    manager_->GetAllDownloads(&downloads);
    std::vector<download::DownloadItem*> visible;
    visible.reserve(downloads.size());
    for (download::DownloadItem* item : downloads) {
      if (item && IsVisible(*item))
        visible.push_back(item);
    }
    std::sort(visible.begin(), visible.end(), [](const auto* left, const auto* right) {
      return left->GetStartTime() > right->GetStartTime();
    });
    for (const auto* item : visible)
      items.Append(Record(*item));
  }
  result.Set("downloads", std::move(items));
  return result;
}

bool Downloads::Control(const std::string& guid,
                        const std::string& action,
                        std::string* error_code) {
  if (!IsReady()) {
    *error_code = "SHAAR_NOT_READY";
    return false;
  }
  download::DownloadItem* item = manager_->GetDownloadByGuid(guid);
  if (!item || !IsVisible(*item)) {
    *error_code = "SHAAR_NOT_FOUND";
    return false;
  }
  return ControlItem(item, action, error_code);
}

bool Downloads::ControlItem(download::DownloadItem* item,
                            const std::string& action,
                            std::string* error_code) {
  if (!item || !error_code) {
    if (error_code)
      *error_code = "SHAAR_NOT_FOUND";
    return false;
  }
  if (action == "pause") {
    if (!item->IsPaused() && item->GetState() == download::DownloadItem::IN_PROGRESS)
      item->Pause();
    return true;  // Pause is idempotent for an already paused item.
  }
  if (action == "resume") {
    if (!item->CanResume()) {
      *error_code = "SHAAR_CONFLICT";
      return false;
    }
    item->Resume(true);
    return true;
  }
  if (action == "cancel") {
    if (item->GetState() == download::DownloadItem::IN_PROGRESS)
      item->Cancel(true);
    return true;  // A repeated cancel after terminal transition is harmless.
  }
  if (action == "remove") {
    if (!item->IsDone()) {
      *error_code = "SHAAR_CONFLICT";
      return false;
    }
    item->Remove();
    return true;
  }
  *error_code = "SHAAR_INVALID_ARGUMENT";
  return false;
}

bool Downloads::Directory(const std::string& action,
                          const std::string& requested_path,
                          std::string* effective_path,
                          std::string* error_code) const {
  if (!browser_context_ || !effective_path) {
    *error_code = "SHAAR_NOT_READY";
    return false;
  }
  Profile* profile = Profile::FromBrowserContext(browser_context_);
  if (!profile || profile->IsOffTheRecord()) {
    *error_code = "SHAAR_PRIVATE_DISALLOWED";
    return false;
  }
  DownloadPrefs* prefs = DownloadPrefs::FromBrowserContext(browser_context_);
  PrefService* pref_service = profile->GetPrefs();
  if (!prefs || !pref_service) {
    *error_code = "SHAAR_NOT_READY";
    return false;
  }
  if (action == "get") {
    *effective_path = PathString(prefs->DownloadPath());
    return true;
  }
  if (action != "set" && action != "useDefault") {
    *error_code = "SHAAR_INVALID_ARGUMENT";
    return false;
  }
  if (prefs->IsDownloadPathManaged() ||
      !pref_service->IsUserModifiablePreference(prefs::kDownloadDefaultDirectory) ||
      !pref_service->IsUserModifiablePreference(prefs::kSaveFileDefaultDirectory)) {
    *error_code = "SHAAR_POLICY_BLOCKED";
    return false;
  }

  base::FilePath requested = action == "useDefault"
                                 ? prefs->GetDefaultDownloadDirectoryForProfile()
                                 : base::FilePath::FromUTF8Unsafe(requested_path);
  base::FilePath normalized;
  if (!requested.IsAbsolute() || requested.ReferencesParent() ||
      !base::DirectoryExists(requested) || !base::NormalizeFilePath(requested, &normalized) ||
      !base::PathIsWritable(normalized)) {
    *error_code = "SHAAR_IO_ERROR";
    return false;
  }
  requested = normalized.StripTrailingSeparators();
  const base::FilePath previous_download = prefs->DownloadPath();
  const base::FilePath previous_save = prefs->SaveFilePath();
  prefs->SetDownloadPath(requested);
  const base::FilePath effective = prefs->DownloadPath();
  if (effective != requested || prefs->SaveFilePath() != requested) {
    prefs->SetDownloadPath(previous_download);
    prefs->SetSaveFilePath(previous_save);
    *error_code = "SHAAR_IO_ERROR";
    return false;
  }
  *effective_path = PathString(effective);
  return true;
}

bool Downloads::Handle(shaar_operation operation,
                       const std::string& arguments_json,
                       std::string* payload_json,
                       std::string* error_code) {
  if (!payload_json || !error_code) return false;
  *payload_json = "";
  std::optional<base::Value> parsed = base::JSONReader::Read(arguments_json, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict()) {
    *error_code = "SHAAR_INVALID_ARGUMENT";
    return false;
  }
  const base::DictValue& args = parsed->GetDict();
  const std::optional<int> version = args.FindInt("schemaVersion");
  if (!version || *version != 1) {
    *error_code = "SHAAR_INVALID_ARGUMENT";
    return false;
  }
  auto only_keys = [&args](std::initializer_list<std::string_view> keys) {
    if (args.size() != keys.size()) return false;
    for (std::string_view key : keys) {
      if (!args.contains(key)) return false;
    }
    return true;
  };
  if (operation == SHAAR_OP_DOWNLOAD_LIST) {
    if (!only_keys({"schemaVersion"})) {
      *error_code = "SHAAR_INVALID_ARGUMENT";
      return false;
    }
    if (!IsReady()) {
      *error_code = "SHAAR_NOT_READY";
      return false;
    }
    if (!base::JSONWriter::Write(List(), payload_json)) {
      *error_code = "SHAAR_CHROMIUM_ERROR";
      return false;
    }
    return true;
  }
  if (operation == SHAAR_OP_DOWNLOAD_CONTROL) {
    const std::string* id = args.FindString("downloadId");
    const std::string* action = args.FindString("action");
    if (!id || id->empty() || !action ||
        !only_keys({"schemaVersion", "downloadId", "action"})) {
      *error_code = "SHAAR_INVALID_ARGUMENT";
      return false;
    }
    return Control(*id, *action, error_code);
  }
  if (operation == SHAAR_OP_DOWNLOAD_DIRECTORY) {
    const std::string* action = args.FindString("action");
    if (!action) {
      *error_code = "SHAAR_INVALID_ARGUMENT";
      return false;
    }
    const std::string* path = args.FindString("directory");
    if ((*action == "set" && (!path || !only_keys({"schemaVersion", "action", "directory"}))) ||
        (*action != "set" && !only_keys({"schemaVersion", "action"}))) {
      *error_code = "SHAAR_INVALID_ARGUMENT";
      return false;
    }
    std::string effective_path;
    if (!Directory(*action, path ? *path : "", &effective_path, error_code))
      return false;
    base::DictValue result;
    result.Set("schemaVersion", 1);
    result.Set("directory", effective_path);
    if (!base::JSONWriter::Write(result, payload_json)) {
      *error_code = "SHAAR_CHROMIUM_ERROR";
      return false;
    }
    return true;
  }
  *error_code = "SHAAR_UNSUPPORTED_CAPABILITY";
  return false;
}

void Downloads::OnManagerInitialized(content::DownloadManager* manager) {
  if (manager == manager_)
    ready_ = true;
}

void Downloads::OnManagerGoingDown(content::DownloadManager* manager) {
  if (manager == manager_) {
    ready_ = false;
    manager_ = nullptr;
    progress_timer_.Stop();
    pending_progress_.clear();
    last_transition_.clear();
    weak_factory_.InvalidateWeakPtrs();
  }
}

void Downloads::OnDownloadCreated(content::DownloadManager* manager,
                                 download::DownloadItem* item) {
  if (manager == manager_ && item && IsVisible(*item)) {
    last_transition_[item->GetGuid()] = GetTransition(*item);
    EmitUpsert(item);
  }
}

void Downloads::OnDownloadUpdated(content::DownloadManager* manager,
                                  download::DownloadItem* item) {
  if (manager != manager_ || !item || !IsVisible(*item))
    return;
  const std::string guid = item->GetGuid();
  const Transition transition = GetTransition(*item);
  auto previous = last_transition_.find(guid);
  if (previous == last_transition_.end() || previous->second != transition) {
    last_transition_[guid] = transition;
    pending_progress_.erase(guid);
    EmitUpsert(item);
    return;
  }
  pending_progress_.insert(guid);
  if (!progress_timer_.IsRunning()) {
    progress_timer_.Start(
        FROM_HERE, base::Milliseconds(100), this, &Downloads::FlushProgress);
  }
}

void Downloads::OnDownloadRemoved(content::DownloadManager* manager,
                                  download::DownloadItem* item) {
  if (manager == manager_ && item && IsVisible(*item)) {
    last_transition_.erase(item->GetGuid());
    pending_progress_.erase(item->GetGuid());
    EmitRemove(item);
  }
}

Downloads::Transition Downloads::GetTransition(const download::DownloadItem& item) {
  return {item.GetState(), item.IsPaused(), item.IsDangerous(), item.IsInsecure()};
}

void Downloads::FlushProgress() {
  if (!manager_)
    return;
  std::set<std::string> pending;
  pending.swap(pending_progress_);
  for (const std::string& guid : pending) {
    download::DownloadItem* item = manager_->GetDownloadByGuid(guid);
    if (item && IsVisible(*item))
      EmitUpsert(item);
  }
}

void Downloads::EmitUpsert(download::DownloadItem* item) {
  if (!event_callback_)
    return;
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "downloads.changed");
  payload.Set("change", "upsert");
  payload.Set("download", Record(*item));
  PostEvent(std::move(payload));
}

void Downloads::EmitRemove(download::DownloadItem* item) {
  if (!event_callback_)
    return;
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "downloads.removed");
  payload.Set("change", "remove");
  payload.Set("downloadId", item->GetGuid());
  PostEvent(std::move(payload));
}

void Downloads::PostEvent(base::DictValue event) {
  if (!event_callback_)
    return;
  EventCallback callback = event_callback_;
  void* context = event_context_;
  std::string profile_id = profile_id_;
  std::string session_id = session_id_;
  base::WeakPtr<Downloads> weak_this = weak_factory_.GetWeakPtr();
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](base::WeakPtr<Downloads> owner, EventCallback callback, void* context,
             std::string profile_id, std::string session_id,
             base::DictValue event) {
            if (owner)
              callback(context, profile_id, session_id, event);
          },
          weak_this, callback, context, std::move(profile_id),
          std::move(session_id), std::move(event)));
}

}  // namespace shaar
