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
  EXPECT_FALSE(shaar::media::IsValidControl(1199, 0, false));
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
