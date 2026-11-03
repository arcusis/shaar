// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_LIFECYCLE_SHAAR_MODULE_REGISTRY_H_
#define CHROME_BROWSER_SHAAR_LIFECYCLE_SHAAR_MODULE_REGISTRY_H_

#include <stdint.h>

#include <map>

#include "chrome/browser/shaar/public/shaar_engine.h"

// Internal C++ dispatch contract shared by independently implemented Shaar
// modules. It is not part of the public C ABI.
struct ShaarModuleRegistry {
  using Handler = shaar_error_code (*)(
      shaar_engine*, shaar_scope, shaar_window*, shaar_tab*, shaar_operation,
      shaar_bytes, shaar_request_id, shaar_reply_fn, void*, shaar_error*);
  using CancelHandler = shaar_error_code (*)(shaar_engine*, shaar_request_id,
                                              shaar_error*);

  struct Range {
    uint32_t first;
    uint32_t last;
    Handler handler;
    CancelHandler cancel_handler;
  };

  bool Register(uint32_t first,
                uint32_t last,
                Handler handler,
                CancelHandler cancel_handler = nullptr);
  Handler Find(shaar_operation operation) const;
  CancelHandler FindCancel(shaar_operation operation) const;
  bool Reserve(shaar_engine* engine, shaar_request_id request_id,
               CancelHandler cancel_handler);
  bool IsPending(shaar_engine* engine, shaar_request_id request_id) const;
  CancelHandler PendingCancel(shaar_engine* engine,
                              shaar_request_id request_id) const;
  bool BeginCompletion(shaar_request_id request_id);
  void FinishCompletion(shaar_request_id request_id);
  bool empty() const { return ranges_.empty(); }

 private:
  std::map<uint32_t, Range> ranges_;
  struct PendingRequest {
    shaar_engine* engine;
    CancelHandler cancel_handler;
    bool completing = false;
  };
  std::map<shaar_request_id, PendingRequest> pending_requests_;
};

// Module register functions have C linkage and register one or more disjoint
// operation ranges. An accepted handler must deliver exactly one reply later
// on the UI thread; it must never invoke the reply inline.

namespace shaar::lifecycle {
ShaarModuleRegistry& ModuleRegistry();
void RegisterLinkedModules(ShaarModuleRegistry* registry);
}  // namespace shaar::lifecycle

#endif  // CHROME_BROWSER_SHAAR_LIFECYCLE_SHAAR_MODULE_REGISTRY_H_
