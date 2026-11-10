// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/quit_probe/shaar_quit_probe.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace {

using shaar::quit_probe::ActivateGate;
using shaar::quit_probe::ActivationRefusal;
using shaar::quit_probe::CancelGate;
using shaar::quit_probe::CancelKeepsHold;
using shaar::quit_probe::CancelRefusal;
using shaar::quit_probe::HoldAuditJSON;
using shaar::quit_probe::LoopbackHttpHost;
using shaar::quit_probe::PointInsideProbeView;
using shaar::quit_probe::PrepareGate;
using shaar::quit_probe::PrepareRefusal;
using shaar::quit_probe::ProbeRefusal;
using shaar::quit_probe::RefusalMessage;
using shaar::quit_probe::TargetGate;

TargetGate OwnedHiddenTab() {
  TargetGate gate;
  gate.testing = true;
  gate.marked_probe = true;
  gate.target_present = true;
  gate.selected_regular = true;
  gate.private_tab = false;
  gate.hidden_host = true;
  return gate;
}

TEST(ShaarQuitProbeTest, ActivationAllowsHiddenSelectedLoopbackPoint) {
  ActivateGate gate;
  gate.target = OwnedHiddenTab();
  gate.point_inside = true;
  EXPECT_EQ(ActivationRefusal(gate), ProbeRefusal::kNone);
}

TEST(ShaarQuitProbeTest, ActivationRefusesVisiblePrivateAndOutsidePoints) {
  ActivateGate visible;
  visible.target = OwnedHiddenTab();
  visible.target.hidden_host = false;
  visible.point_inside = true;
  EXPECT_EQ(ActivationRefusal(visible), ProbeRefusal::kVisibleHost);

  ActivateGate private_tab;
  private_tab.target = OwnedHiddenTab();
  private_tab.target.private_tab = true;
  private_tab.point_inside = true;
  EXPECT_EQ(ActivationRefusal(private_tab), ProbeRefusal::kPrivateTab);

  ActivateGate outside;
  outside.target = OwnedHiddenTab();
  outside.point_inside = false;
  EXPECT_EQ(ActivationRefusal(outside), ProbeRefusal::kPointOutside);
  EXPECT_EQ(RefusalMessage(ProbeRefusal::kPointOutside),
            std::string("trusted click viewport unavailable"));
}

TEST(ShaarQuitProbeTest, PointStaysInsideTheProbeViewport) {
  EXPECT_TRUE(PointInsideProbeView(12, 18, 800, 600));
  EXPECT_FALSE(PointInsideProbeView(-1, 18, 800, 600));
  EXPECT_FALSE(PointInsideProbeView(12, 8193, 9000, 9000));
  EXPECT_FALSE(PointInsideProbeView(800, 18, 800, 600));
  EXPECT_FALSE(PointInsideProbeView(12, 18, 0, 600));
}

TEST(ShaarQuitProbeTest, PrepareRequiresLoopbackAndRefusesAnActiveQuit) {
  PrepareGate gate;
  gate.target = OwnedHiddenTab();
  gate.loopback = true;
  EXPECT_EQ(PrepareRefusal(gate), ProbeRefusal::kNone);

  gate.loopback = false;
  EXPECT_EQ(PrepareRefusal(gate), ProbeRefusal::kNotLoopback);

  gate.loopback = true;
  gate.trying_to_quit = true;
  EXPECT_EQ(PrepareRefusal(gate), ProbeRefusal::kQuitting);
}

TEST(ShaarQuitProbeTest, LoopbackIsHttpLocalhostOnly) {
  EXPECT_TRUE(LoopbackHttpHost("http", "127.0.0.1"));
  EXPECT_TRUE(LoopbackHttpHost("http", "localhost"));
  EXPECT_TRUE(LoopbackHttpHost("http", "::1"));
  EXPECT_TRUE(LoopbackHttpHost("http", "[::1]"));
  EXPECT_FALSE(LoopbackHttpHost("https", "127.0.0.1"));
  EXPECT_FALSE(LoopbackHttpHost("http", "example.com"));
}

TEST(ShaarQuitProbeTest, CancelClearsHoldOnlyAfterTheDialogIsDismissed) {
  CancelGate gate;
  gate.target = OwnedHiddenTab();
  gate.trying_to_quit = true;
  gate.hold_present = true;
  gate.same_owner = true;
  gate.dialog_handled = true;
  EXPECT_EQ(CancelRefusal(gate), ProbeRefusal::kNone);
  EXPECT_FALSE(CancelKeepsHold(ProbeRefusal::kNone));

  gate.dialog_handled = false;
  EXPECT_EQ(CancelRefusal(gate), ProbeRefusal::kNoDialog);
  EXPECT_TRUE(CancelKeepsHold(ProbeRefusal::kNoDialog));
  EXPECT_NE(std::string(RefusalMessage(ProbeRefusal::kNoDialog)).find("dialog"),
            std::string::npos);
  EXPECT_NE(std::string(RefusalMessage(ProbeRefusal::kNoDialog)).find("No"),
            std::string::npos);

  gate.dialog_handled = true;
  gate.trying_to_quit = false;
  EXPECT_EQ(CancelRefusal(gate), ProbeRefusal::kNotQuitting);
  EXPECT_TRUE(CancelKeepsHold(ProbeRefusal::kNotQuitting));

  gate.trying_to_quit = true;
  gate.same_owner = false;
  EXPECT_EQ(CancelRefusal(gate), ProbeRefusal::kStaleOwner);
  EXPECT_TRUE(CancelKeepsHold(ProbeRefusal::kStaleOwner));
}

TEST(ShaarQuitProbeTest, HoldAuditKeepsTheFixtureKeys) {
  const std::string pending = HoldAuditJSON(true, true, true);
  EXPECT_NE(pending.find("\"holdCommandPending\":true"), std::string::npos);
  EXPECT_NE(pending.find("\"holdConfirmedPending\":true"), std::string::npos);
  EXPECT_NE(pending.find("\"selectedNormalTab\":true"), std::string::npos);

  const std::string idle = HoldAuditJSON(false, false, false);
  EXPECT_NE(idle.find("\"holdCommandPending\":false"), std::string::npos);
  EXPECT_NE(idle.find("\"selectedNormalTab\":false"), std::string::npos);
}

}  // namespace
