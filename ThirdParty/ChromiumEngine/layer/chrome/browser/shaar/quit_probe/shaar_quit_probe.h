// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_QUIT_PROBE_SHAAR_QUIT_PROBE_H_
#define CHROME_BROWSER_SHAAR_QUIT_PROBE_SHAAR_QUIT_PROBE_H_

#include <string>
#include <string_view>

namespace shaar::quit_probe {

// Shared gates for the hidden private-quit probe. The Chromium glue in the
// .mm file fills these flags; the decisions stay free of a live browser.

enum class ProbeRefusal {
  kNone,
  kNotTesting,
  kForeignProbe,
  kMissingTarget,
  kNotSelected,
  kPrivateTab,
  kVisibleHost,
  kPointOutside,
  kNotLoopback,
  kQuitting,
  kNotQuitting,
  kNoHold,
  kStaleOwner,
  kNoDialog,
};

struct TargetGate {
  bool testing = false;
  bool marked_probe = false;
  bool target_present = false;
  bool selected_regular = false;
  bool private_tab = false;
  bool hidden_host = false;
};

struct ActivateGate {
  TargetGate target;
  bool point_inside = false;
};

struct PrepareGate {
  TargetGate target;
  bool loopback = false;
  bool trying_to_quit = false;
};

struct CancelGate {
  TargetGate target;
  bool trying_to_quit = false;
  bool hold_present = false;
  bool same_owner = false;
  bool dialog_handled = false;
};

// Private tabs are refused on purpose. The testing-only click and the dialog
// hold run only on the selected regular tab, including while a private window
// is open beside it.
inline ProbeRefusal TargetRefusal(const TargetGate& gate, bool require_hidden) {
  if (!gate.testing)
    return ProbeRefusal::kNotTesting;
  if (!gate.marked_probe)
    return ProbeRefusal::kForeignProbe;
  if (!gate.target_present)
    return ProbeRefusal::kMissingTarget;
  if (gate.private_tab)
    return ProbeRefusal::kPrivateTab;
  if (!gate.selected_regular)
    return ProbeRefusal::kNotSelected;
  if (require_hidden && !gate.hidden_host)
    return ProbeRefusal::kVisibleHost;
  return ProbeRefusal::kNone;
}

inline ProbeRefusal ActivationRefusal(const ActivateGate& gate) {
  const ProbeRefusal target = TargetRefusal(gate.target, true);
  if (target != ProbeRefusal::kNone)
    return target;
  if (!gate.point_inside)
    return ProbeRefusal::kPointOutside;
  return ProbeRefusal::kNone;
}

inline ProbeRefusal PrepareRefusal(const PrepareGate& gate) {
  const ProbeRefusal target = TargetRefusal(gate.target, true);
  if (target != ProbeRefusal::kNone)
    return target;
  if (!gate.loopback)
    return ProbeRefusal::kNotLoopback;
  if (gate.trying_to_quit)
    return ProbeRefusal::kQuitting;
  return ProbeRefusal::kNone;
}

inline ProbeRefusal CancelRefusal(const CancelGate& gate) {
  const ProbeRefusal target = TargetRefusal(gate.target, false);
  if (target != ProbeRefusal::kNone)
    return target;
  if (!gate.trying_to_quit)
    return ProbeRefusal::kNotQuitting;
  if (!gate.hold_present)
    return ProbeRefusal::kNoHold;
  if (!gate.same_owner)
    return ProbeRefusal::kStaleOwner;
  if (!gate.dialog_handled)
    return ProbeRefusal::kNoDialog;
  return ProbeRefusal::kNone;
}

// A dismissed dialog clears the hold. Every other result keeps it so a later
// attempt can still see the same owner.
inline bool CancelKeepsHold(ProbeRefusal refusal) {
  return refusal != ProbeRefusal::kNone;
}

inline bool PointInsideProbeView(int x, int y, int width, int height) {
  if (x < 0 || y < 0 || x > 8192 || y > 8192)
    return false;
  if (width <= 0 || height <= 0)
    return false;
  return x < width && y < height;
}

inline bool LoopbackHttpHost(std::string_view scheme, std::string_view host) {
  if (scheme != "http")
    return false;
  return host == "127.0.0.1" || host == "localhost" || host == "::1" ||
         host == "[::1]";
}

inline const char* BoolJSON(bool value) {
  return value ? "true" : "false";
}

inline std::string HoldAuditJSON(bool command_pending,
                                 bool confirmed_pending,
                                 bool selected_normal_tab) {
  std::string json = "{\"schemaVersion\":1,\"holdCommandPending\":";
  json += BoolJSON(command_pending);
  json += ",\"holdConfirmedPending\":";
  json += BoolJSON(confirmed_pending);
  json += ",\"selectedNormalTab\":";
  json += BoolJSON(selected_normal_tab);
  json += "}";
  return json;
}

inline const char* RefusalMessage(ProbeRefusal refusal) {
  switch (refusal) {
    case ProbeRefusal::kNone:
      return "";
    case ProbeRefusal::kNotTesting:
      return "verification mode required";
    case ProbeRefusal::kForeignProbe:
      return "foreign probe root";
    case ProbeRefusal::kMissingTarget:
      return "probe tab is missing";
    case ProbeRefusal::kNotSelected:
      return "probe tab is not selected";
    case ProbeRefusal::kPrivateTab:
      return "private tab is not the quit probe";
    case ProbeRefusal::kVisibleHost:
      return "probe window is visible";
    case ProbeRefusal::kPointOutside:
      return "trusted click viewport unavailable";
    case ProbeRefusal::kNotLoopback:
      return "probe document is not loopback";
    case ProbeRefusal::kQuitting:
      return "quit is already in progress";
    case ProbeRefusal::kNotQuitting:
      return "not quitting";
    case ProbeRefusal::kNoHold:
      return "probe hold is missing";
    case ProbeRefusal::kStaleOwner:
      return "probe hold owner is stale";
    case ProbeRefusal::kNoDialog:
      return "No dialog is showing";
  }
  return "quit probe failed";
}

inline const char* TrustedClickFailureMessage() {
  return "trusted click could not be sent";
}

}  // namespace shaar::quit_probe

#endif  // CHROME_BROWSER_SHAAR_QUIT_PROBE_SHAAR_QUIT_PROBE_H_
