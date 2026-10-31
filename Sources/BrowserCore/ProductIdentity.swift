// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The browser is Shaar (Hebrew שער, "gateway"); Arcusis is the company that makes it.
public enum ProductIdentity {
  public static let name = "Shaar"
  public static let meaning = "שער — the gateway to the internet"
  /// Kept from Arcusis Browser builds so existing profiles, sessions, and passwords still load.
  public static let dataFolderName = "Arcusis Browser"
}
