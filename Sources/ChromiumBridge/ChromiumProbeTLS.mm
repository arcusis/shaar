#import "include/ChromiumBridge.h"
#include <fcntl.h>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>

NSString *ARCProbeTLSArgument(NSURL *directory, NSString *fingerprint, BOOL testing, NSError **error) {
  if (error) *error = nil;
  if (!fingerprint) return nil; // Normal startup never reads fixture files.
  NSURL *root = directory.URLByDeletingLastPathComponent;
  NSURL *canonical = root.URLByResolvingSymlinksInPath.URLByStandardizingPath;
  NSURL *temporary = [NSURL fileURLWithPath:NSTemporaryDirectory()].URLByResolvingSymlinksInPath.URLByStandardizingPath;
  NSData *decoded = [[NSData alloc] initWithBase64EncodedString:fingerprint options:0];
  struct stat info;
  BOOL valid = testing && directory.isFileURL && decoded.length == 32 &&
    [[decoded base64EncodedStringWithOptions:0] isEqualToString:fingerprint] &&
    [directory.lastPathComponent isEqualToString:@"Chromium"] &&
    [canonical.URLByDeletingLastPathComponent.path isEqualToString:temporary.path] &&
    [canonical.lastPathComponent hasPrefix:@"arcusis-engine-probe-"] &&
    [directory.URLByResolvingSymlinksInPath.URLByDeletingLastPathComponent.path isEqualToString:canonical.path] &&
    lstat(root.path.stringByStandardizingPath.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode) &&
    info.st_uid == getuid() && (info.st_mode & 07777) == 0700;
  if (valid && lstat(directory.path.stringByStandardizingPath.fileSystemRepresentation, &info) == 0) {
    valid = S_ISDIR(info.st_mode) && info.st_uid == getuid();
  }
  if (valid) {
    NSURL *marker = [canonical URLByAppendingPathComponent:@".arcusis-probe"];
    int fd = open(marker.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    static const char expected[] = "arcusis-engine-probe-v1\n";
    char contents[sizeof(expected)] = {};
    valid = fd >= 0 && fstat(fd, &info) == 0 && S_ISREG(info.st_mode) &&
      info.st_uid == getuid() && info.st_nlink == 1 && (info.st_mode & 07777) == 0600 &&
      info.st_size == sizeof(expected) - 1 && read(fd, contents, sizeof(contents)) == sizeof(expected) - 1 &&
      memcmp(contents, expected, sizeof(expected) - 1) == 0;
    if (fd >= 0) close(fd);
  }
  if (!valid) {
    if (error) *error = [NSError errorWithDomain:@"com.arcusis.browser.probe-tls" code:1
      userInfo:@{NSLocalizedDescriptionKey: @"Invalid disposable TLS configuration."}];
    return nil;
  }
  return [@"--ignore-certificate-errors-spki-list=" stringByAppendingString:fingerprint];
}
