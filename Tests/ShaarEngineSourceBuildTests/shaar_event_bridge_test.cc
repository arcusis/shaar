// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include <assert.h>

#include <string>
#include <vector>

#include "chrome/browser/shaar/engine/shaar_event_bridge.h"

namespace {

struct Capture {
  shaar_engine* engine = nullptr;
  std::vector<uint64_t> sequences;
  std::vector<std::string> payloads;
  shaar_error_code nested = SHAAR_OK;
  bool release_on_event = false;
};

void OnEvent(void* context, const shaar_event* event) {
  auto* capture = static_cast<Capture*>(context);
  capture->sequences.push_back(event->sequence);
  capture->payloads.emplace_back(event->payload_json.data,
                                 event->payload_json.size);
  if (capture->release_on_event) {
    shaar_engine_release(capture->engine);
    capture->engine = nullptr;
    return;
  }
  if (capture->sequences.size() == 1) {
    constexpr char kNested[] = "{\"kind\":\"nested\",\"schemaVersion\":1}";
    capture->nested = shaar::EmitEvent(
        capture->engine, SHAAR_EVENT_ENGINE, {}, {}, {}, {},
        {kNested, sizeof(kNested) - 1});
  }
}

}  // namespace

int main() {
  assert(shaar_abi_major() == 1);
  assert(shaar_abi_minor() == SHAAR_ENGINE_ABI_MINOR);
  Capture capture;
  shaar_config config = {};
  config.size = sizeof(config);
  config.requested_major = 1;
  config.data_root = {"/tmp/shaar-test", 15};
  config.locale = {"en", 2};
  config.on_event = OnEvent;
  config.event_context = &capture;
  shaar_error error = {};
  error.size = sizeof(error);
  shaar_engine* engine = nullptr;
  assert(shaar_engine_create(&config, &engine, &error) == SHAAR_OK);
  assert(engine != nullptr);
  capture.engine = engine;
  assert(shaar::EmitEvent(engine, SHAAR_EVENT_PROFILE, {}, {}, {}, {},
                          {"{}", 2}) == SHAAR_INVALID_ARGUMENT);
  const std::string first = "{\"kind\":\"ready\",\"schemaVersion\":1}";
  assert(shaar::EmitEvent(engine, SHAAR_EVENT_ENGINE, {}, {}, {}, {},
                          {first.data(), first.size()}) == SHAAR_OK);
  assert(capture.nested == SHAAR_CONFLICT);
  const std::string second = "{\"kind\":\"loaded\",\"schemaVersion\":1}";
  assert(shaar::EmitEvent(engine, SHAAR_EVENT_PROFILE, {"p", 1}, {}, {}, {},
                          {second.data(), second.size()}) == SHAAR_OK);
  assert((capture.sequences == std::vector<uint64_t>{1, 2}));
  assert(capture.payloads[0] == first && capture.payloads[1] == second);
  shaar_engine_release(engine);

  Capture release_capture;
  release_capture.release_on_event = true;
  config.event_context = &release_capture;
  assert(shaar_engine_create(&config, &engine, &error) == SHAAR_OK);
  release_capture.engine = engine;
  assert(shaar::EmitEvent(engine, SHAAR_EVENT_ENGINE, {}, {}, {}, {},
                          {first.data(), first.size()}) == SHAAR_OK);
  assert(release_capture.engine == nullptr);
  assert(release_capture.sequences == std::vector<uint64_t>{1});

  config.requested_major = 2;
  engine = reinterpret_cast<shaar_engine*>(0x1);
  assert(shaar_engine_create(&config, &engine, &error) == SHAAR_UNSUPPORTED_ABI);
  assert(engine == nullptr);
  assert(error.code == SHAAR_UNSUPPORTED_ABI);
}
