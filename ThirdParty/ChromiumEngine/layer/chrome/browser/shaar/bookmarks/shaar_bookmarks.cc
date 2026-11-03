// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/bookmarks/shaar_bookmarks.h"

#include <algorithm>
#include <cmath>
#include <initializer_list>
#include <memory>
#include <optional>
#include <string_view>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "chrome/browser/bookmarks/bookmark_model_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "components/bookmarks/browser/bookmark_model.h"
#include "components/bookmarks/browser/bookmark_node.h"
#include "components/bookmarks/browser/scoped_group_bookmark_actions.h"
#include "components/bookmarks/common/bookmark_metrics.h"
#include "url/gurl.h"

namespace shaar {
namespace {
constexpr size_t kMaxInputBytes = 1 << 20;
constexpr size_t kMaxNodes = 10000;
constexpr size_t kMaxDepth = 64;
constexpr size_t kMaxTitleBytes = 4096;
constexpr size_t kMaxURLBytes = 32768;
constexpr size_t kMaxSyncKeyBytes = 2048;
constexpr size_t kMaxOperations = 1000;
constexpr char kShaarSyncKey[] = "shaar_sync_key";

using Dict = base::Value::Dict;
using List = base::Value::List;
using Node = bookmarks::BookmarkNode;
using Model = bookmarks::BookmarkModel;

std::string Write(const base::Value &value) {
  std::string json;
  base::JSONWriter::Write(value, &json);
  return json;
}
std::optional<base::Value> Parse(std::string_view json) {
  if (json.empty() || json.size() > kMaxInputBytes)
    return std::nullopt;
  return base::JSONReader::Read(json);
}
std::string NodeID(const Node *node) {
  return node->uuid().AsLowercaseString();
}

bool SerializeNode(const Node *node, size_t depth, size_t *count,
                   Dict *output) {
  if (!node || depth > kMaxDepth || ++*count > kMaxNodes)
    return false;
  output->Set("id", NodeID(node));
  output->Set("t", base::UTF16ToUTF8(node->GetTitledUrlNodeTitle()));
  output->Set("a", node->date_added().InMillisecondsSinceUnixEpoch());
  std::string sync_key;
  if (node->GetMetaInfo(kShaarSyncKey, &sync_key) && !sync_key.empty())
    output->Set("key", sync_key);
  if (node->is_url()) {
    output->Set("k", "u");
    output->Set("u", node->url().possibly_invalid_spec());
    return node->url().is_valid();
  }
  output->Set("k", "f");
  List children;
  for (const auto &child : node->children()) {
    Dict value;
    if (!SerializeNode(child.get(), depth + 1, count, &value))
      return false;
    children.Append(std::move(value));
  }
  output->Set("c", std::move(children));
  return true;
}

const Node *Find(Model *model, std::string_view id) {
  if (id == "bar")
    return model->bookmark_bar_node();
  if (id == "other")
    return model->other_node();
  const base::Uuid uuid = base::Uuid::ParseLowercase(id);
  if (!uuid.is_valid())
    return nullptr;
  return model->GetNodeByUuid(
      uuid, Model::NodeTypeForUuidLookup::kLocalOrSyncableNodes);
}

const Node *ResolveParent(Model *model, std::string_view id) {
  const Node *node = Find(model, id);
  return node && node->is_folder() ? node : nullptr;
}

size_t IndexFor(const Dict &operation, const Node *parent) {
  const base::Value *value = operation.Find("index");
  if (!value)
    return parent->children().size();
  if (value->GetInt() < 0)
    return 0;
  return std::min(static_cast<size_t>(value->GetInt()),
                  parent->children().size());
}

bool ValidIndex(const Dict &operation) {
  const base::Value *value = operation.Find("index");
  return !value || value->is_int();
}

bool ValidFields(const Dict &op,
                 std::initializer_list<std::string_view> allowed) {
  for (const auto &[key, value] : op) {
    (void)value;
    if (std::find(allowed.begin(), allowed.end(), key) == allowed.end())
      return false;
  }
  return true;
}

std::optional<std::string> StringField(const Dict &op, std::string_view key,
                                       size_t max_size, bool required = false) {
  const base::Value *value = op.Find(key);
  if (!value)
    return required ? std::nullopt : std::optional<std::string>("");
  if (!value->is_string() || value->GetString().size() > max_size)
    return std::nullopt;
  return value->GetString();
}

bool ApplyOne(Model *model, const Dict &op, std::string *invalid_reason,
              bool *skipped) {
  const auto kind = StringField(op, "op", 16, true);
  const auto id = StringField(op, "id", 64, true);
  if (!kind || !id) {
    *invalid_reason = "invalid_fields";
    return false;
  }
  const Node *node = Find(model, *id);
  const auto parent_text = StringField(op, "parent", 64);
  if (!parent_text) {
    *invalid_reason = "invalid_parent";
    return false;
  }

  if (*kind == "add") {
    if (!ValidFields(op, {"op", "id", "parent", "index", "t", "k", "u", "a",
                          "key", "ifAbsent"})) {
      *invalid_reason = "unsupported_field";
      return false;
    }
    if (!ValidIndex(op)) {
      *invalid_reason = "invalid_index";
      return false;
    }
    const Node *parent = ResolveParent(model, *parent_text);
    const auto title = StringField(op, "t", kMaxTitleBytes, true);
    const auto node_kind = StringField(op, "k", 1, true);
    const auto key = StringField(op, "key", kMaxSyncKeyBytes);
    if (!parent || !title || !node_kind || !key ||
        !base::Uuid::ParseLowercase(*id).is_valid()) {
      *invalid_reason = "invalid_add";
      return false;
    }
    const base::Value *if_absent_value = op.Find("ifAbsent");
    if (if_absent_value && !if_absent_value->is_bool()) {
      *invalid_reason = "invalid_if_absent";
      return false;
    }
    const bool if_absent = if_absent_value && if_absent_value->GetBool();
    if (node && !if_absent) {
      *invalid_reason = "duplicate_id";
      return false;
    }
    std::optional<base::Uuid> uuid = base::Uuid::ParseLowercase(*id);
    std::optional<base::Time> date;
    if (const base::Value *added = op.Find("a")) {
      if (!added->is_double() && !added->is_int()) {
        *invalid_reason = "invalid_date";
        return false;
      }
      const double milliseconds =
          added->is_int() ? added->GetInt() : added->GetDouble();
      if (!std::isfinite(milliseconds) || milliseconds < 0 ||
          milliseconds > 253402300799000.0) {
        *invalid_reason = "invalid_date";
        return false;
      }
      date = base::Time::FromMillisecondsSinceUnixEpoch(milliseconds);
    }
    Node::MetaInfoMap metadata;
    if (!key->empty())
      metadata.emplace(kShaarSyncKey, *key);
    const Node::MetaInfoMap *metadata_ptr =
        metadata.empty() ? nullptr : &metadata;
    if (*node_kind == "f") {
      if (op.Find("u")) {
        *invalid_reason = "folder_url";
        return false;
      }
      if (node) {
        *skipped = true;
        return true;
      }
      model->AddFolder(parent, IndexFor(op, parent), base::UTF8ToUTF16(*title),
                       metadata_ptr, date, uuid);
      return true;
    }
    if (*node_kind != "u") {
      *invalid_reason = "invalid_kind";
      return false;
    }
    const auto url_text = StringField(op, "u", kMaxURLBytes, true);
    if (!url_text) {
      *invalid_reason = "invalid_url";
      return false;
    }
    GURL url(*url_text);
    if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || url.host().empty()) {
      *invalid_reason = "invalid_url";
      return false;
    }
    if (node) {
      *skipped = true;
      return true;
    }
    model->AddURL(parent, IndexFor(op, parent), base::UTF8ToUTF16(*title), url,
                  metadata_ptr, date, uuid, true);
    return true;
  }

  if (*kind == "update") {
    if (!ValidFields(op, {"op", "id", "t", "u", "key"}) || !node ||
        model->is_permanent_node(node)) {
      *invalid_reason = "invalid_update";
      return false;
    }
    const base::Value *title = op.Find("t");
    const base::Value *url_value = op.Find("u");
    const base::Value *key_value = op.Find("key");
    std::optional<GURL> replacement_url;
    if (title &&
        (!title->is_string() || title->GetString().size() > kMaxTitleBytes)) {
      *invalid_reason = "invalid_title";
      return false;
    }
    if (url_value) {
      if (!url_value->is_string() ||
          url_value->GetString().size() > kMaxURLBytes || !node->is_url()) {
        *invalid_reason = "invalid_url";
        return false;
      }
      replacement_url.emplace(url_value->GetString());
      if (!replacement_url->is_valid() ||
          !replacement_url->SchemeIsHTTPOrHTTPS() ||
          replacement_url->host().empty()) {
        *invalid_reason = "invalid_url";
        return false;
      }
    }
    if (key_value && (!key_value->is_string() ||
                      key_value->GetString().size() > kMaxSyncKeyBytes)) {
      *invalid_reason = "invalid_sync_key";
      return false;
    }
    if (title) {
      model->SetTitle(node, base::UTF8ToUTF16(title->GetString()),
                      metrics::BookmarkEditSource::kUser);
    }
    if (replacement_url)
      model->SetURL(node, *replacement_url, metrics::BookmarkEditSource::kUser);
    if (key_value) {
      if (key_value->GetString().empty())
        model->DeleteNodeMetaInfo(node, kShaarSyncKey);
      else
        model->SetNodeMetaInfo(node, kShaarSyncKey, key_value->GetString());
    }
    return true;
  }

  if (*kind == "move") {
    if (!ValidFields(op, {"op", "id", "parent", "index"}) || !node ||
        model->is_permanent_node(node)) {
      *invalid_reason = "invalid_move";
      return false;
    }
    if (!ValidIndex(op)) {
      *invalid_reason = "invalid_index";
      return false;
    }
    const Node *parent = ResolveParent(model, *parent_text);
    if (!parent) {
      *invalid_reason = "invalid_parent";
      return false;
    }
    for (const Node *ancestor = parent; ancestor;
         ancestor = ancestor->parent()) {
      if (ancestor == node) {
        *invalid_reason = "cycle";
        return false;
      }
    }
    model->Move(node, parent, IndexFor(op, parent));
    return true;
  }

  if (*kind == "remove") {
    if (!ValidFields(op, {"op", "id"}) || !node ||
        model->is_permanent_node(node)) {
      *invalid_reason = "invalid_remove";
      return false;
    }
    model->Remove(node, metrics::BookmarkEditSource::kUser, FROM_HERE);
    return true;
  }
  *invalid_reason = "unsupported_operation";
  return false;
}

} // namespace

BookmarksModule::BookmarksModule(Profile *profile, bool private_scope,
                                 shaar_engine *engine, std::string profile_id)
    : profile_(profile), private_scope_(private_scope), engine_(engine),
      profile_id_(std::move(profile_id)) {
  DCHECK(profile_ || private_scope_);
  DCHECK(engine_);
  DCHECK(!profile_id_.empty());
  if (private_scope_)
    return;
  model_ = BookmarkModelFactory::GetForBrowserContext(profile_);
  if (model_) {
    observation_.Observe(model_);
    watching_ = true;
  }
}

BookmarksModule::~BookmarksModule() {
  StopWatching();
  for (auto &request : pending_requests_)
    ReplyLater(request.reply, request.context, SHAAR_SHUTTING_DOWN, "");
}

void BookmarksModule::StopWatching() {
  weak_factory_.InvalidateWeakPtrs();
  if (observation_.IsObserving() &&
      (!model_ || model_->loaded() || pending_requests_.empty()))
    observation_.Reset();
  watching_ = false;
}

base::WeakPtr<BookmarksModule> BookmarksModule::GetWeakPtr() {
  return weak_factory_.GetWeakPtr();
}

void BookmarksModule::ReplyLater(Reply reply, void *context,
                                 shaar_error_code code, std::string payload) {
  if (!reply)
    return;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(reply, context, code, std::move(payload)));
}

shaar_error_code BookmarksModule::Submit(shaar_operation operation,
                                         const std::string &args_json,
                                         Reply reply, void *reply_context) {
  if (private_scope_)
    return SHAAR_PRIVATE_DISALLOWED;
  if (profile_id_.empty())
    return SHAAR_INVALID_ARGUMENT;
  if (!profile_ || !model_ || !engine_)
    return SHAAR_NOT_READY;
  const auto parsed = Parse(args_json);
  if (!parsed || !parsed->is_dict())
    return SHAAR_INVALID_ARGUMENT;
  const Dict &args = parsed->GetDict();
  const auto version = args.FindInt("schemaVersion");
  if (!version || *version != 1)
    return SHAAR_INVALID_ARGUMENT;

  if (operation == SHAAR_OP_BOOKMARK_WATCH) {
    if (!ValidFields(args, {"schemaVersion", "enabled"}))
      return SHAAR_INVALID_ARGUMENT;
    const auto enabled = args.FindBool("enabled");
    if (!enabled)
      return SHAAR_INVALID_ARGUMENT;
    if (*enabled && !watching_) {
      observation_.Observe(model_);
      watching_ = true;
    } else if (!*enabled) {
      StopWatching();
    }
    Dict result;
    result.Set("schemaVersion", 1);
    result.Set("watching", watching_);
    ReplyLater(reply, reply_context, SHAAR_OK,
               Write(base::Value(std::move(result))));
    return SHAAR_OK;
  }

  if (operation == SHAAR_OP_BOOKMARK_TREE) {
    if (!ValidFields(args, {"schemaVersion"}))
      return SHAAR_INVALID_ARGUMENT;
  } else if (operation == SHAAR_OP_BOOKMARK_APPLY) {
    if (!ValidFields(args, {"schemaVersion", "ops"}))
      return SHAAR_INVALID_ARGUMENT;
    const base::Value::List *operations = args.FindList("ops");
    if (!operations || operations->size() > kMaxOperations)
      return SHAAR_INVALID_ARGUMENT;
  } else {
    return SHAAR_UNSUPPORTED_CAPABILITY;
  }

  if (!model_->loaded()) {
    pending_requests_.push_back({operation, args_json, reply, reply_context});
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_BOOKMARK_TREE) {
    size_t count = 0;
    Dict result;
    result.Set("schemaVersion", 1);
    Dict bar, other;
    if (!SerializeNode(model_->bookmark_bar_node(), 0, &count, &bar) ||
        !SerializeNode(model_->other_node(), 0, &count, &other))
      return SHAAR_CHROMIUM_ERROR;
    result.Set("bar", std::move(bar));
    result.Set("other", std::move(other));
    std::string payload = Write(base::Value(std::move(result)));
    if (payload.size() > kMaxInputBytes)
      return SHAAR_CHROMIUM_ERROR;
    ReplyLater(reply, reply_context, SHAAR_OK, std::move(payload));
    return SHAAR_OK;
  }

  const base::Value::List *operations = args.FindList("ops");
  bookmarks::ScopedGroupBookmarkActions grouped(model_);
  int applied = 0;
  int skipped = 0;
  List invalid;
  for (const base::Value &value : *operations) {
    if (!value.is_dict()) {
      invalid.Append("invalid_operation");
      continue;
    }
    std::string reason;
    bool was_skipped = false;
    if (ApplyOne(model_, value.GetDict(), &reason, &was_skipped)) {
      if (was_skipped)
        ++skipped;
      else
        ++applied;
    } else
      invalid.Append(std::move(reason));
  }
  Dict result;
  result.Set("schemaVersion", 1);
  result.Set("applied", applied);
  result.Set("skipped", skipped);
  result.Set("invalid", std::move(invalid));
  ReplyLater(reply, reply_context, SHAAR_OK,
             Write(base::Value(std::move(result))));
  return SHAAR_OK;
}

void BookmarksModule::QueueInvalidation() {
  if (!watching_ || invalidation_queued_)
    return;
  invalidation_queued_ = true;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&BookmarksModule::EmitInvalidation,
                                weak_factory_.GetWeakPtr()));
}

void BookmarksModule::EmitInvalidation() {
  invalidation_queued_ = false;
  if (!watching_ || !model_ || !engine_)
    return;
  constexpr char kPayload[] =
      "{\"kind\":\"bookmark\",\"schemaVersion\":1,\"change\":\"invalidated\"}";
  shaar::EmitEvent(engine_, SHAAR_EVENT_BOOKMARK,
                   {profile_id_.data(), profile_id_.size()}, {nullptr, 0},
                   {nullptr, 0}, {nullptr, 0},
                   {kPayload, sizeof(kPayload) - 1});
}

void BookmarksModule::BookmarkModelLoaded(bool) {
  QueueInvalidation();
  auto pending = std::move(pending_requests_);
  pending_requests_.clear();
  for (auto &request : pending)
    Submit(request.operation, request.arguments, request.reply,
           request.context);
  if (!watching_ && pending_requests_.empty() && observation_.IsObserving())
    observation_.Reset();
}
void BookmarksModule::BookmarkModelBeingDeleted() {
  StopWatching();
  model_ = nullptr;
  auto pending = std::move(pending_requests_);
  pending_requests_.clear();
  for (auto &request : pending)
    ReplyLater(request.reply, request.context, SHAAR_SHUTTING_DOWN, "");
}
void BookmarksModule::BookmarkNodeMoved(const Node *, size_t, const Node *,
                                        size_t) {
  QueueInvalidation();
}
void BookmarksModule::BookmarkNodeAdded(const Node *, size_t, bool) {
  QueueInvalidation();
}
void BookmarksModule::BookmarkNodeRemoved(const Node *, size_t, const Node *,
                                          const std::set<GURL> &,
                                          const base::Location &) {
  QueueInvalidation();
}
void BookmarksModule::BookmarkNodeChanged(const Node *) { QueueInvalidation(); }
void BookmarksModule::BookmarkMetaInfoChanged(const Node *) {
  QueueInvalidation();
}
void BookmarksModule::BookmarkNodeFaviconChanged(const Node *) {}
void BookmarksModule::BookmarkNodeChildrenReordered(const Node *) {
  QueueInvalidation();
}
void BookmarksModule::BookmarkAllUserNodesRemoved(const std::set<GURL> &,
                                                  const base::Location &) {
  QueueInvalidation();
}

namespace {

struct AbiReplyContext {
  shaar_request_id request_id;
  shaar_reply_fn reply;
  void *context;
};

void ReplyThroughABI(void *raw_context, shaar_error_code code,
                     const std::string &payload) {
  std::unique_ptr<AbiReplyContext> state(
      static_cast<AbiReplyContext *>(raw_context));
  if (!state || !state->reply)
    return;
  static constexpr char kDiagnostic[] = "bookmark operation failed";
  shaar_result result = {};
  result.size = sizeof(result);
  result.request_id = state->request_id;
  result.error.size = sizeof(result.error);
  result.error.code = code;
  result.error.platform_code = 0;
  if (code == SHAAR_OK) {
    result.payload_json = {payload.data(), payload.size()};
  } else {
    result.error.message = {kDiagnostic, sizeof(kDiagnostic) - 1};
  }
  state->reply(state->context, &result);
}

shaar_error_code
HandleBookmarkOperation(void *raw_registry, shaar_engine *engine,
                        shaar_scope scope, shaar_operation operation,
                        shaar_bytes args, shaar_request_id request_id,
                        shaar_reply_fn reply, void *reply_context) {
  auto *registry = static_cast<ShaarModuleRegistry *>(raw_registry);
  if (scope.profile && scope.private_session)
    return SHAAR_INVALID_ARGUMENT;
  if (scope.private_session)
    return SHAAR_PRIVATE_DISALLOWED;
  if (!scope.profile || !registry || !registry->resolve_bookmarks_module ||
      !reply || (args.size && !args.data))
    return SHAAR_INVALID_ARGUMENT;

  shaar_error_code resolution = SHAAR_OK;
  BookmarksModule *module = registry->resolve_bookmarks_module(
      registry->context, engine, scope.profile, &resolution);
  if (!module)
    return resolution == SHAAR_OK ? SHAAR_NOT_FOUND : resolution;

  auto state = std::make_unique<AbiReplyContext>(
      AbiReplyContext{request_id, reply, reply_context});
  const shaar_error_code accepted = module->Submit(
      operation, std::string(args.data ? args.data : "", args.size),
      &ReplyThroughABI, state.get());
  if (accepted != SHAAR_OK)
    return accepted;
  state.release();
  return SHAAR_OK;
}

} // namespace

void shaar_bookmarks_register(ShaarModuleRegistry *registry) {
  if (!registry || !registry->register_handler)
    return;
  registry->register_handler(registry->context, SHAAR_OP_BOOKMARK_TREE,
                             &HandleBookmarkOperation, registry);
  registry->register_handler(registry->context, SHAAR_OP_BOOKMARK_APPLY,
                             &HandleBookmarkOperation, registry);
  registry->register_handler(registry->context, SHAAR_OP_BOOKMARK_WATCH,
                             &HandleBookmarkOperation, registry);
}

} // namespace shaar
