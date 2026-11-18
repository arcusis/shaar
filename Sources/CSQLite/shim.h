// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>

static inline int shaar_sqlite_enable_defensive(sqlite3 *database) {
  return sqlite3_db_config(database, SQLITE_DBCONFIG_DEFENSIVE, 1, 0);
}

static inline char *shaar_realpath_or_original(const char *path) {
  char *resolved = realpath(path, NULL);
  return resolved ? resolved : strdup(path);
}
