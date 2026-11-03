// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/engine/shaar_event_bridge.h"

#include <stddef.h>
#include <pthread.h>

#include <new>

namespace {

constexpr uint32_t kConfigMinimumSize =
    offsetof(shaar_config, event_context) + sizeof(void*);

shaar_error_code Fail(shaar_error_code code,
                      const char* message,
                      size_t message_size,
                      shaar_error* error) {
  if (error) {
    const uint32_t supplied_size = error->size;
    if (supplied_size >= offsetof(shaar_error, code) + sizeof(error->code))
      error->code = code;
    if (supplied_size >=
        offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
      error->platform_code = 0;
    if (supplied_size >= offsetof(shaar_error, message) + sizeof(error->message))
      error->message = {message, message_size};
  }
  return code;
}

#define SHAAR_FAIL(code, literal, error) \
  Fail(code, literal, sizeof(literal) - 1, error)

}  // namespace

extern "C" SHAAR_EXPORT uint32_t shaar_abi_major(void) {
  return SHAAR_ENGINE_ABI_MAJOR;
}

extern "C" SHAAR_EXPORT uint32_t shaar_abi_minor(void) {
  return SHAAR_ENGINE_ABI_MINOR;
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_engine_create(
    const shaar_config* config,
    shaar_engine** out,
    shaar_error* error) {
  if (!out)
    return SHAAR_FAIL(SHAAR_INVALID_ARGUMENT, "missing output handle", error);
  *out = nullptr;
  if (!pthread_main_np())
    return SHAAR_FAIL(SHAAR_INVALID_ARGUMENT, "main thread required", error);
  if (!config || config->size < kConfigMinimumSize)
    return SHAAR_FAIL(SHAAR_INVALID_ARGUMENT, "invalid config size", error);
  if (config->requested_major != SHAAR_ENGINE_ABI_MAJOR ||
      config->requested_minor > SHAAR_ENGINE_ABI_MINOR)
    return SHAAR_FAIL(SHAAR_UNSUPPORTED_ABI, "unsupported ABI", error);
  if (!config->data_root.data || config->data_root.size == 0 ||
      (config->locale.size != 0 && !config->locale.data) || !config->on_event)
    return SHAAR_FAIL(SHAAR_INVALID_ARGUMENT, "invalid config", error);

  shaar_engine* engine = new (std::nothrow) shaar_engine;
  if (!engine)
    return SHAAR_FAIL(SHAAR_IO_ERROR, "engine allocation failed", error);
  engine->on_event = config->on_event;
  engine->event_context = config->event_context;
  engine->data_root.assign(config->data_root.data, config->data_root.size);
  engine->locale.assign(config->locale.data ? config->locale.data : "",
                        config->locale.size);
  if (engine->data_root.find('\0') != std::string::npos ||
      engine->locale.find('\0') != std::string::npos) {
    delete engine;
    return SHAAR_FAIL(SHAAR_INVALID_ARGUMENT, "embedded NUL in config", error);
  }
  *out = engine;
  return SHAAR_FAIL(SHAAR_OK, "", error);
}

extern "C" SHAAR_EXPORT void shaar_engine_release(shaar_engine* engine) {
  if (!engine)
    return;
  if (engine->emitting) {
    if (!engine->run_active)
      engine->release_requested = true;
    return;
  }
  if (engine->run_active)
    return;
  delete engine;
}
