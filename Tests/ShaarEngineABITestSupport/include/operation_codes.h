// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef SHAAR_ENGINE_ABI_TEST_OPERATION_CODES_H_
#define SHAAR_ENGINE_ABI_TEST_OPERATION_CODES_H_

#include <stdint.h>

typedef struct {
  uint32_t tab_navigate;
  uint32_t tab_go;
  uint32_t tab_reload;
  uint32_t tab_stop;
  uint32_t download_list;
  uint32_t download_control;
  uint32_t download_directory;
  uint32_t bookmark_tree;
  uint32_t bookmark_apply;
  uint32_t bookmark_watch;
  uint32_t history_query;
  uint32_t history_insert;
  uint32_t history_delete;
  uint32_t history_watch;
  uint32_t history_unwatch;
  uint32_t site_settings_get;
  uint32_t site_settings_set;
  uint32_t site_settings_reset;
  uint32_t extension_list;
  uint32_t extension_manage;
  uint32_t extension_action;
  uint32_t extension_install_decision;
  uint32_t extension_popup_close;
  uint32_t tab_find;
  uint32_t tab_stop_find;
  uint32_t devtools_call;
  uint32_t devtools_panel_open;
  uint32_t devtools_panel_close;
  uint32_t devtools_panel_screencast;
  uint32_t media_get_state;
  uint32_t media_control;
  uint32_t media_capture_reply;
  uint32_t storage_keychain_identity;
} shaar_test_operation_codes;

void shaar_test_get_operation_codes(shaar_test_operation_codes *codes);

#endif  // SHAAR_ENGINE_ABI_TEST_OPERATION_CODES_H_
