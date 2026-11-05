// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import BrowserCore

@Test func browserImportErrorsUseTheSelectedLanguage() {
  #expect(
    BrowserImport.ImportError.unsupported.errorDescription
      == BrowserImport.ImportError.unsupported.localizedMessage())
  #expect(
    BrowserImport.ImportError.unsupported.localizedMessage(language: .english)
      == "Choose a Chrome, Edge, Brave, Arc, Safari, or Firefox profile folder or bookmark export.")
  #expect(
    BrowserImport.ImportError.unsupported.localizedMessage(language: .hebrew)
      == "בחרו תיקיית פרופיל או ייצוא סימניות מ‑Chrome, Edge, Brave, Arc, Safari או Firefox.")
  #expect(
    BrowserImport.ImportError.privateProfile.localizedMessage(language: .hebrew)
      == "אי אפשר לייבא פרופיל גלישה פרטית. בחרו פרופיל רגיל.")
  #expect(
    BrowserImport.ImportError.databaseUnavailable("locked").localizedMessage(language: .hebrew)
      == "לא ניתן לקרוא בבטחה את מסד הנתונים של היסטוריית הדפדפן שנבחר.")
  #expect(
    BrowserImport.ImportError.tooManyRows.localizedMessage(language: .hebrew)
      == "פרופיל הדפדפן שנבחר מכיל יותר נתונים מכפי שניתן לייבא בבת אחת.")
}
