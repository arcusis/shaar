// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/history/shaar_history.h"

#include <algorithm>
#include <cmath>
#include <initializer_list>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "chrome/browser/history/history_service_factory.h"
#include "chrome/browser/history/history_utils.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/history/shaar_history_registry.h"
#include "components/history/core/browser/history_service.h"
#include "components/history/core/browser/history_service_observer.h"
#include "components/history/core/browser/history_types.h"
#include "components/history/core/browser/url_row.h"
#include "ui/base/page_transition_types.h"

namespace {

constexpr int kMaximumURLs = 5000;
constexpr int kMaximumVisitsPerURL = 50;
constexpr int kMaximumDeleteURLs = 500;
constexpr int kMaximumImportPages = 5000;
constexpr size_t kMaximumArgumentsBytes = 4 * 1024 * 1024;
constexpr int64_t kDuplicateToleranceMs = 1000;

using HistoryHandler = ShaarModuleRegistry::Handler;

struct ReplyContext {
  shaar_request_id request_id;
  shaar_reply_fn reply;
  void* context;
};

void Reply(const ReplyContext& request,
           shaar_error_code code,
           base::Value::Dict payload = {}) {
  std::string json;
  if (code == SHAAR_OK)
    base::JSONWriter::Write(base::Value(std::move(payload)), &json);
  shaar_result result{};
  result.size = sizeof(result);
  result.request_id = request.request_id;
  result.error.size = sizeof(result.error);
  result.error.code = code;
  result.payload_json = {json.data(), json.size()};
  if (request.reply)
    request.reply(request.context, &result);
}

void ReplyError(const ReplyContext& request,
                shaar_error_code code,
                const char* message) {
  std::string text(message);
  shaar_result result{};
  result.size = sizeof(result);
  result.request_id = request.request_id;
  result.error.size = sizeof(result.error);
  result.error.code = code;
  result.error.message = {text.data(), text.size()};
  if (request.reply)
    request.reply(request.context, &result);
}

bool HasOnlyKeys(const base::Value::Dict& dict,
                 std::initializer_list<std::string_view> allowed) {
  for (const auto item : dict) {
    if (std::find(allowed.begin(), allowed.end(), item.first) == allowed.end())
      return false;
  }
  return true;
}

std::optional<base::Value::Dict> ParseArguments(shaar_bytes bytes) {
  if (!bytes.data || bytes.size == 0 || bytes.size > kMaximumArgumentsBytes)
    return std::nullopt;
  auto parsed = base::JSONReader::Read(std::string_view(bytes.data, bytes.size));
  if (!parsed || !parsed->is_dict())
    return std::nullopt;
  return std::move(parsed->GetDict());
}

bool HasVersionOne(const base::Value::Dict& dict) {
  return dict.FindInt("schemaVersion") == 1;
}

bool IsWebURL(const GURL& url) {
  return url.is_valid() && (url.SchemeIsHTTPOrHTTPS());
}

bool RegularProfileScope(shaar_scope scope) {
  return scope.size >= sizeof(shaar_scope) && scope.profile &&
         !scope.private_session;
}

bool ValidateRegularScope(shaar_scope scope, const ReplyContext& request) {
  if (scope.private_session) {
    ReplyError(request, SHAAR_PRIVATE_DISALLOWED,
               "history is unavailable in private sessions");
    return false;
  }
  if (!RegularProfileScope(scope)) {
    ReplyError(request, SHAAR_INVALID_ARGUMENT, "invalid history scope");
    return false;
  }
  return true;
}

Profile* ResolveProfile(ShaarModuleRegistry* registry,
                        shaar_scope scope,
                        const ReplyContext& request) {
  if (scope.private_session) {
    ReplyError(request, SHAAR_PRIVATE_DISALLOWED,
               "history is unavailable in private sessions");
    return nullptr;
  }
  if (!RegularProfileScope(scope)) {
    ReplyError(request, SHAAR_INVALID_ARGUMENT, "invalid history scope");
    return nullptr;
  }
  Profile* profile = registry->ResolveRegularProfile(scope.profile);
  if (!profile) {
    ReplyError(request, SHAAR_NOT_FOUND, "profile is not available");
    return nullptr;
  }
  if (profile->IsOffTheRecord()) {
    ReplyError(request, SHAAR_PRIVATE_DISALLOWED,
               "history is unavailable in private profiles");
    return nullptr;
  }
  return profile;
}

history::HistoryService* ResolveHistory(ShaarModuleRegistry* registry,
                                        Profile* profile,
                                        const ReplyContext& request) {
  history::HistoryService* service =
      HistoryServiceFactory::GetForProfile(profile, ServiceAccessType::EXPLICIT_ACCESS);
  if (!service) {
    ReplyError(request, SHAAR_NOT_READY, "history service is not ready");
    return nullptr;
  }
  return service;
}

int64_t EpochMilliseconds(base::Time time) {
  return (time - base::Time::UnixEpoch()).InMilliseconds();
}

struct QueryRow {
  std::string url;
  std::string title;
  int visit_count = 0;
  std::vector<int64_t> visits;
};

void Query(ShaarModuleRegistry* registry,
           shaar_scope scope,
           shaar_bytes bytes,
           shaar_request_id request_id,
           shaar_reply_fn reply,
           void* context) {
  const ReplyContext request{request_id, reply, context};
  if (!ValidateRegularScope(scope, request))
    return;
  auto args = ParseArguments(bytes);
  if (!args || !HasVersionOne(*args) ||
      !HasOnlyKeys(*args, {"schemaVersion", "maxUrls", "maxVisitsPerUrl", "search"})) {
    ReplyError(request, SHAAR_INVALID_ARGUMENT, "invalid history query schema");
    return;
  }
  const int max_urls = args->FindInt("maxUrls").value_or(5000);
  const int max_visits = args->FindInt("maxVisitsPerUrl").value_or(50);
  const std::string* search = args->FindString("search");
  if (max_urls < 1 || max_urls > kMaximumURLs || max_visits < 1 ||
      max_visits > kMaximumVisitsPerURL || (search && search->size() > 4096)) {
    ReplyError(request, SHAAR_INVALID_ARGUMENT, "history query is out of range");
    return;
  }
  Profile* profile = ResolveProfile(registry, scope, request);
  if (!profile)
    return;
  history::HistoryService* service = ResolveHistory(registry, profile, request);
  if (!service)
    return;

  history::QueryOptions options;
  options.max_count = max_urls * max_visits;
  options.duplicate_policy = history::QueryOptions::KEEP_ALL_DUPLICATES;
  options.visit_order = history::QueryOptions::RECENT_FIRST;
  options.policy_for_404_visits = history::VisitQuery404sPolicy::kExclude404s;
  auto tracker = std::make_shared<base::CancelableTaskTracker>();
  const std::u16string text = search ? base::UTF8ToUTF16(*search) : std::u16string();
  service->QueryHistory(
      text, options,
      base::BindOnce(
          [request, tracker, max_urls, max_visits](history::QueryResults results) {
            if (results.size() >= static_cast<size_t>(max_urls * max_visits)) {
              ReplyError(request, SHAAR_POLICY_BLOCKED,
                         "history exceeds the bounded query; continuation is unavailable");
              return;
            }
            std::vector<QueryRow> rows;
            std::map<std::string, size_t> by_url;
            for (const history::URLResult& result : results) {
              const std::string url = result.url().spec();
              auto [found, inserted] = by_url.emplace(url, rows.size());
              if (inserted) {
                QueryRow row;
                row.url = url;
                row.title = base::UTF16ToUTF8(result.title());
                row.visit_count = result.visit_count();
                rows.push_back(std::move(row));
              }
              QueryRow& row = rows[found->second];
              if (row.visits.size() < static_cast<size_t>(max_visits))
                row.visits.push_back(EpochMilliseconds(result.visit_time()));
            }
            base::Value::List entries;
            for (const QueryRow& row : rows) {
              base::Value::List visits;
              for (int64_t visit : row.visits)
                visits.Append(visit);
              entries.Append(base::Value::Dict()
                                 .Set("url", row.url)
                                 .Set("title", row.title)
                                 .Set("visitCount", row.visit_count)
                                 .Set("visits", std::move(visits)));
            }
            Reply(request, SHAAR_OK,
                  base::Value::Dict().Set("schemaVersion", 1).Set("entries",
                                                                    std::move(entries)));
          }),
      tracker.get());
}

void Delete(ShaarModuleRegistry* registry,
            shaar_scope scope,
            shaar_bytes bytes,
            shaar_request_id request_id,
            shaar_reply_fn reply,
            void* context) {
  const ReplyContext request{request_id, reply, context};
  if (!ValidateRegularScope(scope, request))
    return;
  auto args = ParseArguments(bytes);
  if (!args || !HasVersionOne(*args) || !HasOnlyKeys(*args, {"schemaVersion", "urls"})) {
    ReplyError(request, SHAAR_INVALID_ARGUMENT, "invalid history delete schema");
    return;
  }
  const base::Value::List* values = args->FindList("urls");
  if (!values || values->empty() || values->size() > kMaximumDeleteURLs) {
    ReplyError(request, SHAAR_INVALID_ARGUMENT, "invalid history URL list");
    return;
  }
  std::vector<GURL> urls;
  std::map<std::string, bool> seen;
  for (const base::Value& value : *values) {
    if (!value.is_string()) {
      ReplyError(request, SHAAR_INVALID_ARGUMENT, "history URL must be a string");
      return;
    }
    GURL url(value.GetString());
    if (!IsWebURL(url) || !seen.emplace(url.spec(), true).second) {
      ReplyError(request, SHAAR_INVALID_ARGUMENT, "invalid or duplicate history URL");
      return;
    }
    urls.push_back(std::move(url));
  }
  Profile* profile = ResolveProfile(registry, scope, request);
  if (!profile)
    return;
  history::HistoryService* service = ResolveHistory(registry, profile, request);
  if (!service)
    return;
  auto tracker = std::make_shared<base::CancelableTaskTracker>();
  service->DeleteURLs(urls);
  service->QueryUrlIds(
      urls,
      base::BindOnce([request, tracker, count = urls.size()](
                         std::optional<std::vector<history::URLID>> ids) {
        if (!ids || ids->size() != count) {
          ReplyError(request, SHAAR_IO_ERROR, "history deletion could not be confirmed");
          return;
        }
        const int deleted = static_cast<int>(std::count(ids->begin(), ids->end(), 0));
        if (deleted != static_cast<int>(count)) {
          ReplyError(request, SHAAR_IO_ERROR, "history deletion is still pending");
          return;
        }
        Reply(request, SHAAR_OK,
              base::Value::Dict().Set("schemaVersion", 1).Set("deleted", deleted));
      }),
      tracker.get());
}

history::VisitSource ImportSource(const std::string& source) {
  if (source == "safari")
    return history::SOURCE_SAFARI_IMPORTED;
  if (source == "firefox")
    return history::SOURCE_FIREFOX_IMPORTED;
  return history::SOURCE_OS_MIGRATION_IMPORTED;
}

// Each row is first read through HistoryService, then new timestamps are sent
// through AddPage. The follow-up query is queued after those writes and provides
// the acknowledgement rather than treating AddPage's scheduling as success.
struct ImportState : public std::enable_shared_from_this<ImportState> {
  ReplyContext request;
  history::HistoryService* service = nullptr;
  std::shared_ptr<base::CancelableTaskTracker> tracker =
      std::make_shared<base::CancelableTaskTracker>();
  std::vector<GURL> urls;
  std::vector<std::u16string> titles;
  std::vector<std::vector<base::Time>> times;
  std::vector<std::string> rejection_codes;
  history::VisitSource source = history::SOURCE_OS_MIGRATION_IMPORTED;
  int accepted = 0;
  int inserted = 0;
  int duplicates = 0;
  size_t index = 0;

  void Next() {
    if (index == urls.size()) {
      base::Value::List rejected;
      for (size_t row = 0; row < rejection_codes.size(); ++row) {
        if (!rejection_codes[row].empty())
          rejected.Append(base::Value::Dict().Set("index", static_cast<int>(row))
                              .Set("code", rejection_codes[row]));
      }
      if (accepted == 0 && rejected.size() == urls.size()) {
        ReplyError(request, SHAAR_INVALID_ARGUMENT, "history import has no valid rows");
        return;
      }
      Reply(request, SHAAR_OK,
            base::Value::Dict()
                .Set("schemaVersion", 1)
                .Set("accepted", accepted)
                .Set("insertedVisits", inserted)
                .Set("duplicateVisits", duplicates)
                .Set("rejected", std::move(rejected)));
      return;
    }
    const size_t row = index++;
    if (!rejection_codes[row].empty()) {
      Next();
      return;
    }
    auto self = shared_from_this();
    service->QueryURLAndVisits(
        urls[row], history::VisitQuery404sPolicy::kExclude404s,
        base::BindOnce([self, row](history::QueryURLAndVisitsResult found) {
          std::vector<base::Time> additions;
          std::vector<base::Time> known;
          if (found.success) {
            for (const auto& visit : found.visits)
              known.push_back(visit.visit_time);
          }
          for (base::Time requested : self->times[row]) {
            const bool duplicate = std::any_of(known.begin(), known.end(), [requested](base::Time time) {
              return std::abs((time - requested).InMilliseconds()) <= kDuplicateToleranceMs;
            });
            if (duplicate) {
              ++self->duplicates;
            } else {
              additions.push_back(requested);
              known.push_back(requested);
            }
          }
          if (additions.empty()) {
            ++self->accepted;
            self->Next();
            return;
          }
          for (base::Time time : additions) {
            history::HistoryAddPageArgs add;
            add.url = self->urls[row];
            add.time = time;
            add.transition = ui::PAGE_TRANSITION_LINK;
            add.visit_source = self->source;
            add.response_code_category = history::VisitResponseCodeCategory::kNot404;
            add.title = self->titles[row];
            add.consider_for_ntp_most_visited = false;
            self->service->AddPage(std::move(add));
          }
          self->service->QueryURLAndVisits(
              self->urls[row], history::VisitQuery404sPolicy::kExclude404s,
              base::BindOnce([self, row, count = additions.size()](
                                 history::QueryURLAndVisitsResult verified) {
                if (!verified.success) {
                  ReplyError(self->request, SHAAR_IO_ERROR,
                             "history import write could not be confirmed");
                  return;
                }
                size_t observed = 0;
                for (base::Time time : self->times[row]) {
                  const size_t matches = std::count_if(
                      verified.visits.begin(), verified.visits.end(), [time](const auto& visit) {
                        return std::abs((visit.visit_time - time).InMilliseconds()) <=
                               kDuplicateToleranceMs;
                      });
                  if (matches)
                    ++observed;
                }
                if (observed < self->times[row].size()) {
                  ReplyError(self->request, SHAAR_IO_ERROR,
                             "history import write could not be confirmed");
                  return;
                }
                ++self->accepted;
                self->inserted += static_cast<int>(count);
                self->Next();
              }), self->tracker.get());
        }), tracker.get());
  }
};

void Insert(ShaarModuleRegistry* registry,
            shaar_scope scope,
            shaar_bytes bytes,
            shaar_request_id request_id,
            shaar_reply_fn reply,
            void* context) {
  const ReplyContext request{request_id, reply, context};
  if (!ValidateRegularScope(scope, request))
    return;
  auto args = ParseArguments(bytes);
  if (!args || !HasVersionOne(*args) ||
      !HasOnlyKeys(*args, {"schemaVersion", "source", "pages"})) {
    ReplyError(request, SHAAR_INVALID_ARGUMENT, "invalid history import schema");
    return;
  }
  const std::string* source = args->FindString("source");
  const base::Value::List* pages = args->FindList("pages");
  if (!source || (*source != "safari" && *source != "chrome" && *source != "arc" &&
                  *source != "firefox") ||
      !pages || pages->empty() || pages->size() > kMaximumImportPages) {
    ReplyError(request, SHAAR_INVALID_ARGUMENT, "invalid history import batch");
    return;
  }
  Profile* profile = ResolveProfile(registry, scope, request);
  if (!profile)
    return;
  history::HistoryService* service = ResolveHistory(registry, profile, request);
  if (!service)
    return;

  auto state = std::make_shared<ImportState>();
  state->request = request;
  state->service = service;
  state->source = ImportSource(*source);
  state->rejection_codes.resize(pages->size());
  for (size_t page_index = 0; page_index < pages->size(); ++page_index) {
    const base::Value& page = (*pages)[page_index];
    auto reject_row = [&](const char* code) {
      state->rejection_codes[page_index] = code;
      state->urls.emplace_back();
      state->titles.emplace_back();
      state->times.emplace_back();
    };
    if (!page.is_dict() || !HasOnlyKeys(page.GetDict(), {"url", "title", "visits"})) {
      reject_row("invalid_page");
      continue;
    }
    const std::string* raw_url = page.GetDict().FindString("url");
    const std::string* raw_title = page.GetDict().FindString("title");
    const base::Value::List* raw_visits = page.GetDict().FindList("visits");
    GURL url(raw_url ? *raw_url : std::string());
    if (!raw_url || raw_url->size() > 16 * 1024 || !IsWebURL(url) ||
        !CanAddURLToHistory(url)) {
      reject_row("invalid_url");
      continue;
    }
    if ((raw_title && raw_title->size() > 8192) || !raw_visits ||
        raw_visits->empty() || raw_visits->size() > 1000) {
      reject_row("invalid_visits");
      continue;
    }
    std::vector<base::Time> visits;
    bool invalid_timestamp = false;
    for (const base::Value& raw_time : *raw_visits) {
      if (!raw_time.is_int() && !raw_time.is_double()) {
        invalid_timestamp = true;
        break;
      }
      const double raw_millis = raw_time.is_int() ? raw_time.GetInt() : raw_time.GetDouble();
      if (!std::isfinite(raw_millis) || std::floor(raw_millis) != raw_millis ||
          raw_millis < 0 || raw_millis > 4102444800000.0) {
        invalid_timestamp = true;
        break;
      }
      const int64_t millis = static_cast<int64_t>(raw_millis);
      visits.push_back(base::Time::UnixEpoch() + base::Milliseconds(millis));
    }
    if (invalid_timestamp) {
      reject_row("invalid_timestamp");
      continue;
    }
    state->urls.push_back(std::move(url));
    state->titles.push_back(base::UTF8ToUTF16(raw_title ? *raw_title : std::string()));
    state->times.push_back(std::move(visits));
  }
  state->Next();
}

struct WatchState;

class HistoryObserver final : public history::HistoryServiceObserver {
 public:
  HistoryObserver(history::HistoryService* service,
                  std::string profile_id,
                  ShaarModuleRegistry::HistoryEvent sink,
                  base::OnceCallback<void(history::HistoryService*)> on_deleted)
      : service_(service), service_key_(service), profile_id_(std::move(profile_id)),
        sink_(std::move(sink)), on_deleted_(std::move(on_deleted)) {
    service_->AddObserver(this);
  }
  ~HistoryObserver() override {
    timer_.Stop();
    if (service_)
      service_->RemoveObserver(this);
  }
  void OnURLVisited(history::HistoryService*,
                    const history::VisitedURLInfo&) override { Changed(); }
  void OnURLsModified(history::HistoryService*, const history::URLRows&) override { Changed(); }
  void OnHistoryDeletions(history::HistoryService*,
                          const history::DeletionInfo&) override { Changed(); }
  void HistoryServiceBeingDeleted(history::HistoryService*) override {
    timer_.Stop();
    service_ = nullptr;
    if (on_deleted_)
      std::move(on_deleted_).Run(service_key_);
  }

 private:
  void Changed() {
    if (timer_.IsRunning())
      return;
    timer_.Start(FROM_HERE, base::Milliseconds(20), this,
                 &HistoryObserver::EmitChange);
  }
  void EmitChange() {
    if (sink_)
      sink_(profile_id_, "{\"kind\":\"changed\",\"schemaVersion\":1}");
  }
  raw_ptr<history::HistoryService> service_;
  history::HistoryService* service_key_;
  std::string profile_id_;
  ShaarModuleRegistry::HistoryEvent sink_;
  base::OnceCallback<void(history::HistoryService*)> on_deleted_;
  base::OneShotTimer timer_;
};

struct WatchState {
  std::map<history::HistoryService*, std::unique_ptr<HistoryObserver>> observers;
  std::map<std::string, history::HistoryService*> subscriptions;
  uint64_t next_id = 1;
};

void Watch(ShaarModuleRegistry* registry,
           const std::shared_ptr<WatchState>& state,
           shaar_scope scope,
           shaar_bytes bytes,
           shaar_request_id request_id,
           shaar_reply_fn reply,
           void* context) {
  const ReplyContext request{request_id, reply, context};
  if (!ValidateRegularScope(scope, request))
    return;
  auto args = ParseArguments(bytes);
  if (!args || !HasVersionOne(*args) || !HasOnlyKeys(*args, {"schemaVersion"})) {
    ReplyError(request, SHAAR_INVALID_ARGUMENT, "invalid history watch schema");
    return;
  }
  Profile* profile = ResolveProfile(registry, scope, request);
  if (!profile)
    return;
  history::HistoryService* service = ResolveHistory(registry, profile, request);
  if (!service)
    return;
  if (!state->observers.contains(service)) {
    std::weak_ptr<WatchState> weak_state = state;
    state->observers.emplace(
        service, std::make_unique<HistoryObserver>(service, registry->ProfileID(scope.profile),
                                                   registry->HistoryEventSink(),
                                                   base::BindOnce([](std::weak_ptr<WatchState> weak,
                                                                     history::HistoryService* key) {
        base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
            FROM_HERE, base::BindOnce([](std::weak_ptr<WatchState> posted,
                                         history::HistoryService* deleted) {
              if (auto live = posted.lock()) {
                live->observers.erase(deleted);
                for (auto it = live->subscriptions.begin(); it != live->subscriptions.end();) {
                  if (it->second == deleted)
                    it = live->subscriptions.erase(it);
                  else
                    ++it;
                }
              }
            }, weak, key));
      }, weak_state)));
  }
  const std::string token = "history-" + std::to_string(state->next_id++);
  state->subscriptions.emplace(token, service);
  Reply(request, SHAAR_OK,
        base::Value::Dict().Set("schemaVersion", 1).Set("subscriptionId", token));
}

void Unwatch(ShaarModuleRegistry* registry,
             const std::shared_ptr<WatchState>& state,
             shaar_scope scope,
             shaar_bytes bytes,
             shaar_request_id request_id,
             shaar_reply_fn reply,
             void* context) {
  const ReplyContext request{request_id, reply, context};
  if (!ValidateRegularScope(scope, request))
    return;
  auto args = ParseArguments(bytes);
  if (!args || !HasVersionOne(*args) ||
      !HasOnlyKeys(*args, {"schemaVersion", "subscriptionId"})) {
    ReplyError(request, SHAAR_INVALID_ARGUMENT, "invalid history unwatch schema");
    return;
  }
  const std::string* token = args->FindString("subscriptionId");
  if (!token || token->empty()) {
    ReplyError(request, SHAAR_INVALID_ARGUMENT, "missing history subscription ID");
    return;
  }
  Profile* profile = ResolveProfile(registry, scope, request);
  if (!profile)
    return;
  auto subscription = state->subscriptions.find(*token);
  if (subscription == state->subscriptions.end()) {
    Reply(request, SHAAR_OK, base::Value::Dict().Set("schemaVersion", 1));
    return;
  }
  history::HistoryService* service =
      HistoryServiceFactory::GetForProfile(profile, ServiceAccessType::EXPLICIT_ACCESS);
  if (subscription->second != service) {
    ReplyError(request, SHAAR_WRONG_PROFILE, "history subscription belongs to another profile");
    return;
  }
  state->subscriptions.erase(subscription);
  const bool still_used = std::any_of(state->subscriptions.begin(), state->subscriptions.end(),
                                      [service](const auto& item) {
                                        return item.second == service;
                                      });
  if (!still_used)
    state->observers.erase(service);
  Reply(request, SHAAR_OK, base::Value::Dict().Set("schemaVersion", 1));
}

}  // namespace

void shaar_history_register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  auto watches = std::make_shared<WatchState>();
  registry->RegisterHandler(SHAAR_OP_HISTORY_QUERY,
                            [registry](auto scope, auto args, auto id, auto reply, auto context) {
                              Query(registry, scope, args, id, reply, context);
                            });
  registry->RegisterHandler(SHAAR_OP_HISTORY_INSERT,
                            [registry](auto scope, auto args, auto id, auto reply, auto context) {
                              Insert(registry, scope, args, id, reply, context);
                            });
  registry->RegisterHandler(SHAAR_OP_HISTORY_DELETE,
                            [registry](auto scope, auto args, auto id, auto reply, auto context) {
                              Delete(registry, scope, args, id, reply, context);
                            });
  registry->RegisterHandler(SHAAR_OP_HISTORY_WATCH,
                            [registry, watches](auto scope, auto args, auto id, auto reply,
                                               auto context) {
                              Watch(registry, watches, scope, args, id, reply, context);
                            });
  registry->RegisterHandler(SHAAR_OP_HISTORY_UNWATCH,
                            [registry, watches](auto scope, auto args, auto id, auto reply,
                                               auto context) {
                              Unwatch(registry, watches, scope, args, id, reply, context);
                            });
}
