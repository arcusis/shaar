// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/site_data/shaar_site_data.h"

extern "C" void shaar_site_data_register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  static const shaar::SiteDataModuleHandlers handlers{
      .submit = &HandleSiteDataOperation};
  registry->Register(SHAAR_OP_SITE_SETTINGS_GET,
                     SHAAR_OP_THIRD_PARTY_COOKIES_SET,
                     &HandleSiteDataOperation);
  registry->RegisterModule(SHAAR_MODULE_SITE_DATA, &handlers);
}
