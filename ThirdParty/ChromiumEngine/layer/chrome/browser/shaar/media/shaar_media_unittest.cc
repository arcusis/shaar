// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/media/shaar_media.h"

#include <cmath>

#include "services/media_session/public/mojom/media_session.mojom.h"
#include "testing/gtest/include/gtest/gtest.h"

TEST(ShaarMediaTest, ValidatesValueBoundsAndPresenceByCommand) {
  EXPECT_TRUE(shaar::media::IsValidControl(SHAAR_MEDIA_SET_ELEMENT_VOLUME, 0.5, true));
  EXPECT_FALSE(shaar::media::IsValidControl(SHAAR_MEDIA_SET_ELEMENT_VOLUME, 1.1, true));
  EXPECT_FALSE(shaar::media::IsValidControl(SHAAR_MEDIA_SET_ELEMENT_VOLUME,
                                             std::nan(""), true));
  EXPECT_TRUE(shaar::media::IsValidControl(SHAAR_MEDIA_SEEK_TO, 3600, true));
  EXPECT_FALSE(shaar::media::IsValidControl(SHAAR_MEDIA_SEEK_TO, -1, true));
  EXPECT_FALSE(shaar::media::IsValidControl(SHAAR_MEDIA_PLAY, 0, true));
  EXPECT_TRUE(shaar::media::IsValidControl(SHAAR_MEDIA_PLAY, 0, false));
  EXPECT_TRUE(shaar::media::IsValidControl(SHAAR_MEDIA_SEEK_BACKWARD, 10, true));
  EXPECT_FALSE(shaar::media::IsValidControl(SHAAR_MEDIA_SEEK_FORWARD, -10, true));
  EXPECT_TRUE(shaar::media::IsValidControl(SHAAR_MEDIA_PIP_SKIP, -10, true));
  EXPECT_FALSE(shaar::media::IsValidControl(1199, 0, false));
}

TEST(ShaarMediaTest, ElementControlsSeekTenSecondsAndRequestNativePiP) {
  const std::u16string seek = shaar::media::ElementActionScriptForTesting(
      SHAAR_MEDIA_SEEK_BACKWARD, 10);
  EXPECT_NE(seek.find(u"command=4,value=10"), std::u16string::npos);
  EXPECT_NE(seek.find(u"best.currentTime+(command===4?-value"),
            std::u16string::npos);
  const std::u16string pip = shaar::media::ElementActionScriptForTesting(
      SHAAR_MEDIA_PIP_ENTER, 0);
  EXPECT_NE(pip.find(u"requestPictureInPicture()"), std::u16string::npos);
  EXPECT_NE(pip.find(u"element.disablePictureInPicture"),
            std::u16string::npos);
  EXPECT_TRUE(pip.ends_with(u"})()"));
}

TEST(ShaarMediaTest, MapsOnlySupportedChromiumSessionActions) {
  media_session::mojom::MediaSessionAction action;
  EXPECT_TRUE(shaar::media::MapSessionAction(SHAAR_MEDIA_NEXT_TRACK, &action));
  EXPECT_EQ(action, media_session::mojom::MediaSessionAction::kNextTrack);
  EXPECT_TRUE(shaar::media::MapSessionAction(SHAAR_MEDIA_SEEK_TO, &action));
  EXPECT_EQ(action, media_session::mojom::MediaSessionAction::kSeekTo);
  EXPECT_FALSE(shaar::media::MapSessionAction(SHAAR_MEDIA_SET_ELEMENT_VOLUME, &action));
  EXPECT_FALSE(shaar::media::MapSessionAction(SHAAR_MEDIA_PIP_SKIP, &action));
}

TEST(ShaarMediaTest, ElementVolumeScriptTargetsOnlyPlayingPageMedia) {
  const std::u16string script = shaar::media::VolumeScriptForTesting(0.625);
  EXPECT_NE(script.find(u"document.querySelectorAll('audio,video')"),
            std::u16string::npos);
  EXPECT_NE(script.find(u"!element.paused&&!element.ended"),
            std::u16string::npos);
  EXPECT_NE(script.find(u"element.volume=0.625"), std::u16string::npos);
}

TEST(ShaarMediaTest, RegistersItsModuleAndOperationHandler) {
  ShaarModuleRegistry registry;
  shaar_media_register(&registry);
  EXPECT_NE(registry.FindModule(SHAAR_MODULE_MEDIA), nullptr);
  EXPECT_EQ(registry.Find(SHAAR_OP_MEDIA_GET_STATE), &HandleMediaOperation);
}
