// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_BOOKMARKS_SHAAR_BOOKMARKS_H_
#define CHROME_BROWSER_SHAAR_BOOKMARKS_SHAAR_BOOKMARKS_H_

#include <memory>
#include <set>
#include <string>
#include <vector>

#include "base/check.h"
#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/shaar/public/shaar_engine.h"
#include "components/bookmarks/browser/bookmark_model_observer.h"
#include "url/gurl.h"

class Profile;
namespace bookmarks {
class BookmarkModel;
}

namespace shaar {

// One instance is owned by the regular profile's Shaar service registry. The
// caller must reject private-session scopes before constructing or invoking it.
class BookmarksModule final : public bookmarks::BookmarkModelObserver {
public:
  using Reply = void (*)(void *, shaar_error_code, const std::string &);

  BookmarksModule(Profile *profile, bool private_scope, shaar_engine *engine,
                  std::string profile_id);
  BookmarksModule(const BookmarksModule &) = delete;
  BookmarksModule &operator=(const BookmarksModule &) = delete;
  ~BookmarksModule() override;

  // Called on Chromium's UI sequence. Completion is always posted, never
  // inline.
  shaar_error_code Submit(shaar_operation operation,
                          const std::string &args_json, Reply reply,
                          void *reply_context);
  void StopWatching();

  base::WeakPtr<BookmarksModule> GetWeakPtr();

  void BookmarkModelLoaded(bool ids_reassigned) override;
  void BookmarkModelBeingDeleted() override;
  void BookmarkNodeMoved(const bookmarks::BookmarkNode *, size_t,
                         const bookmarks::BookmarkNode *, size_t) override;
  void BookmarkNodeAdded(const bookmarks::BookmarkNode *, size_t,
                         bool) override;
  void BookmarkNodeRemoved(const bookmarks::BookmarkNode *, size_t,
                           const bookmarks::BookmarkNode *,
                           const std::set<GURL> &,
                           const base::Location &) override;
  void BookmarkNodeChanged(const bookmarks::BookmarkNode *) override;
  void BookmarkMetaInfoChanged(const bookmarks::BookmarkNode *) override;
  void BookmarkNodeFaviconChanged(const bookmarks::BookmarkNode *) override;
  void BookmarkNodeChildrenReordered(const bookmarks::BookmarkNode *) override;
  void BookmarkAllUserNodesRemoved(const std::set<GURL> &,
                                   const base::Location &) override;

private:
  struct PendingRequest {
    shaar_operation operation;
    std::string arguments;
    Reply reply;
    void *context;
  };
  void QueueInvalidation();
  void EmitInvalidation();
  void ReplyLater(Reply, void *, shaar_error_code, std::string);

  raw_ptr<Profile> profile_;
  const bool private_scope_;
  raw_ptr<shaar_engine> engine_;
  const std::string profile_id_;
  raw_ptr<bookmarks::BookmarkModel> model_ = nullptr;
  bool watching_ = false;
  bool invalidation_queued_ = false;
  std::vector<PendingRequest> pending_requests_;
  base::ScopedObservation<bookmarks::BookmarkModel,
                          bookmarks::BookmarkModelObserver>
      observation_{this};
  base::WeakPtrFactory<BookmarksModule> weak_factory_{this};
};

extern "C" void shaar_bookmarks_register(ShaarModuleRegistry *registry);

} // namespace shaar

#endif // CHROME_BROWSER_SHAAR_BOOKMARKS_SHAAR_BOOKMARKS_H_
