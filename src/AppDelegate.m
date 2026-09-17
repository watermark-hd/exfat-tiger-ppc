#import "AppDelegate.h"
#import <Security/Security.h>
#import <sys/param.h>
#import <sys/mount.h>

#define MOUNT_EXFAT_PATH @"/usr/local/sbin/mount.exfat"
#define UMOUNT_PATH @"/sbin/umount"
#define DISKUTIL_PATH @"/usr/sbin/diskutil"
#define MOUNT_PATH @"/sbin/mount"

/*
 * Japanese UI strings, built at runtime from explicit UTF-16 code points instead
 * of source-embedded literals. This GCC 4.0.1 / Tiger toolchain does not reliably
 * round-trip non-ASCII bytes (or even \uXXXX universal-character-name escapes)
 * inside @"..." literals into the right NSString contents, so constructing them
 * by hand here is the only encoding-proof option.
 */
static NSString *JPStringFromCodes(const unsigned short *codes, unsigned count)
{
    unichar buffer[64];
    unsigned i;
    for (i = 0; i < count && i < 64; i++) {
        buffer[i] = (unichar)codes[i];
    }
    return [NSString stringWithCharacters:buffer length:count];
}

/*
 * No .lproj bundles / NSLocalizedString here (no nib, no Xcode project, keeping
 * the build dead simple per BUILDING.md) -- just check the user's preferred
 * language directly and pick a plain-ASCII English string instead of the
 * Japanese one when it's not Japanese. Falls back to English on any failure.
 */
static BOOL IsJapaneseSystem(void)
{
    NSArray *languages = [[NSUserDefaults standardUserDefaults] objectForKey:@"AppleLanguages"];
    NSString *primary;
    if ([languages count] == 0) return NO;
    primary = [languages objectAtIndex:0];
    return [primary hasPrefix:@"ja"];
}

static NSString *L(const unsigned short *jaCodes, unsigned jaCount, NSString *en)
{
    if (IsJapaneseSystem()) {
        return JPStringFromCodes(jaCodes, jaCount);
    }
    return en;
}

static const unsigned short kCodesEject[]        = {0x53d6, 0x308a, 0x51fa, 0x3059}; /* 取り出す */
static const unsigned short kCodesMount[]        = {0x30de, 0x30a6, 0x30f3, 0x30c8}; /* マウント */
static const unsigned short kCodesQuit[]         = {0x7d42, 0x4e86};                 /* 終了 */
static const unsigned short kCodesNoDriveTail[]  = {0x30c9, 0x30e9, 0x30a4, 0x30d6, 0x304c,
                                                     0x898b, 0x3064, 0x304b, 0x308a, 0x307e,
                                                     0x305b, 0x3093};                 /* ドライブが見つかりません */
static const unsigned short kCodesMountFail[]    = {0x30de, 0x30a6, 0x30f3, 0x30c8, 0x306b,
                                                     0x5931, 0x6557, 0x3057, 0x307e, 0x3057,
                                                     0x305f};                         /* マウントに失敗しました */
static const unsigned short kCodesEjectFail[]    = {0x53d6, 0x308a, 0x51fa, 0x3057, 0x306b,
                                                     0x5931, 0x6557, 0x3057, 0x307e, 0x3057,
                                                     0x305f};                         /* 取り出しに失敗しました */
static const unsigned short kCodesCLIMissing[]   = {0x30B3, 0x30DE, 0x30F3, 0x30C9, 0x30E9,
                                                     0x30A4, 0x30F3, 0x30C4, 0x30FC, 0x30EB,
                                                     0x304C, 0x898B, 0x3064, 0x304B, 0x308A,
                                                     0x307E, 0x305B, 0x3093};         /* コマンドラインツールが見つかりません */
static const unsigned short kCodesInstallFailed[] = {0x30B3, 0x30DE, 0x30F3, 0x30C9, 0x30E9,
                                                      0x30A4, 0x30F3, 0x30C4, 0x30FC, 0x30EB,
                                                      0x3092, 0x30A4, 0x30F3, 0x30B9, 0x30C8,
                                                      0x30FC, 0x30EB, 0x3067, 0x304D, 0x307E,
                                                      0x305B, 0x3093, 0x3067, 0x3057, 0x305F};
                                                     /* コマンドラインツールをインストールできませんでした */

@implementation AppDelegate

- (id)init
{
    self = [super init];
    if (self != nil) {
        mountBaseDir = [[NSHomeDirectory() stringByAppendingPathComponent:@"exfat-volumes"] retain];

        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:mountBaseDir isDirectory:&isDir]) {
            [fm createDirectoryAtPath:mountBaseDir attributes:nil];
        }
    }
    return self;
}

- (void)dealloc
{
    [mountBaseDir release];
    [statusItem release];
    [super dealloc];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    statusItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength] retain];
    [statusItem setTitle:@"exFAT"];
    [statusItem setHighlightMode:YES];
    [statusItem setTarget:self];
    [statusItem setAction:@selector(statusItemClicked:)];
}

#pragma mark - Shell helpers

- (NSString *)runTaskAtPath:(NSString *)launchPath arguments:(NSArray *)args
{
    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    NSString *output;
    NSData *data;
    NSFileHandle *fh;

    [task setLaunchPath:launchPath];
    [task setArguments:args];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];

    fh = [pipe fileHandleForReading];

    NS_DURING
        [task launch];
        data = [fh readDataToEndOfFile];
        [task waitUntilExit];
    NS_HANDLER
        data = [NSData data];
    NS_ENDHANDLER

    [task release];

    output = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (output == nil) {
        output = @"";
    }
    return output;
}

#pragma mark - CLI tools install

/*
 * The CLI tools ship as a `bin/` folder sitting next to the .app in the release
 * zip (same layout install.sh expects: `$(dirname "$0")/bin`). Finding it this
 * way means the app can install them itself without needing to know where the
 * user extracted the zip.
 */
- (NSString *)siblingBinDir
{
    NSString *appDir = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
    return [appDir stringByAppendingPathComponent:@"bin"];
}

/*
 * Runs the same copy/symlink steps as install.sh, elevated via
 * AuthorizationExecuteWithPrivileges -- the old, pre-SMJobBless way to ask for
 * admin rights from a GUI app, but it's still there on Tiger and needs no
 * separate privileged helper tool, which fits this project's "no moving parts"
 * approach. AuthorizationExecuteWithPrivileges itself just forks the tool and
 * returns; reading its pipe to EOF is the standard way to actually wait for it.
 */
- (BOOL)installCLIToolsFromBinDir:(NSString *)binDir
{
    AuthorizationItem right = {kAuthorizationRightExecute, 0, NULL, 0};
    AuthorizationRights rights = {1, &right};
    AuthorizationFlags flags = kAuthorizationFlagDefaults |
                                kAuthorizationFlagInteractionAllowed |
                                kAuthorizationFlagPreAuthorize |
                                kAuthorizationFlagExtendRights;
    AuthorizationRef authRef;
    OSStatus status;
    NSString *script;
    const char *tool = "/bin/sh";
    char *args[3];
    FILE *pipe = NULL;

    status = AuthorizationCreate(&rights, kAuthorizationEmptyEnvironment, flags, &authRef);
    if (status != errAuthorizationSuccess) {
        return NO;
    }

    script = [NSString stringWithFormat:
        @"set -e; mkdir -p /usr/local/sbin; "
         "cp '%@/mount.exfat-fuse' '%@/exfatfsck' '%@/mkexfatfs' '%@/exfatlabel' '%@/dumpexfat' '%@/exfatattrib' /usr/local/sbin/; "
         "chmod 755 /usr/local/sbin/mount.exfat-fuse /usr/local/sbin/exfatfsck /usr/local/sbin/mkexfatfs /usr/local/sbin/exfatlabel /usr/local/sbin/dumpexfat /usr/local/sbin/exfatattrib; "
         "ln -sf mount.exfat-fuse /usr/local/sbin/mount.exfat; "
         "ln -sf exfatfsck /usr/local/sbin/fsck.exfat; "
         "ln -sf mkexfatfs /usr/local/sbin/mkfs.exfat",
        binDir, binDir, binDir, binDir, binDir, binDir];

    args[0] = "-c";
    args[1] = (char *)[script UTF8String];
    args[2] = NULL;

    status = AuthorizationExecuteWithPrivileges(authRef, tool, kAuthorizationFlagDefaults, args, &pipe);
    if (pipe != NULL) {
        char buf[256];
        while (fread(buf, 1, sizeof(buf), pipe) > 0) { }
        fclose(pipe);
    }

    AuthorizationFree(authRef, kAuthorizationFlagDefaults);
    return (status == errAuthorizationSuccess);
}

/*
 * Called right before a mount attempt. Returns YES if the CLI tools are ready
 * to use (already installed, or just got installed). Returns NO if the user
 * cancelled the admin prompt (silently -- they already saw that dialog and
 * said no, no need to pile another alert on top) or if something's actually
 * wrong (missing bin/, or the install itself failed), in which case an alert
 * explains what happened.
 */
- (BOOL)ensureCLIToolsInstalled
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *binDir;
    BOOL isDir = NO;

    if ([fm fileExistsAtPath:MOUNT_EXFAT_PATH]) {
        return YES;
    }

    binDir = [self siblingBinDir];
    if (![fm fileExistsAtPath:binDir isDirectory:&isDir] || !isDir) {
        NSAlert *alert = [NSAlert alertWithMessageText:L(kCodesCLIMissing, 18, @"exFAT command line tools not found")
                                          defaultButton:@"OK"
                                        alternateButton:nil
                                            otherButton:nil
                              informativeTextWithFormat:@"%@", binDir];
        [alert runModal];
        return NO;
    }

    if (![self installCLIToolsFromBinDir:binDir]) {
        return NO; /* most likely the user cancelled the admin password prompt */
    }

    if (![fm fileExistsAtPath:MOUNT_EXFAT_PATH]) {
        NSAlert *alert = [NSAlert alertWithMessageText:L(kCodesInstallFailed, 25, @"Couldn't install the command line tools")
                                          defaultButton:@"OK"
                                        alternateButton:nil
                                            otherButton:nil
                              informativeTextWithFormat:@"%@", binDir];
        [alert runModal];
        return NO;
    }

    return YES;
}

#pragma mark - diskutil / mount parsing

/* Splits a string on runs of whitespace, discarding empty tokens. No regex needed. */
- (NSArray *)tokenizeWhitespace:(NSString *)line
{
    NSMutableArray *tokens = [NSMutableArray array];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    unsigned len = [line length];
    unsigned i = 0;

    while (i < len) {
        unsigned start;
        while (i < len && [ws characterIsMember:[line characterAtIndex:i]]) i++;
        if (i >= len) break;
        start = i;
        while (i < len && ![ws characterIsMember:[line characterAtIndex:i]]) i++;
        [tokens addObject:[line substringWithRange:NSMakeRange(start, i - start)]];
    }
    return tokens;
}

/* "disk6s1" -> YES, "disk6" or "disk6s1x" or "foo" -> NO. No regex needed. */
- (BOOL)isValidPartitionIdentifier:(NSString *)name
{
    unsigned len = [name length];
    unsigned i;
    int sIndex = -1;
    NSString *beforeS;
    NSString *afterS;
    NSString *numPart;

    if (![name hasPrefix:@"disk"]) return NO;
    if (len < 6) return NO;

    for (i = 0; i < len; i++) {
        if ([name characterAtIndex:i] == 's') sIndex = (int)i;
    }
    if (sIndex < 0) return NO;

    beforeS = [name substringToIndex:sIndex];
    afterS = [name substringFromIndex:sIndex + 1];
    if (![beforeS hasPrefix:@"disk"]) return NO;

    numPart = [beforeS substringFromIndex:4];
    if ([numPart length] == 0 || [afterS length] == 0) return NO;

    for (i = 0; i < [numPart length]; i++) {
        unichar c = [numPart characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    for (i = 0; i < [afterS length]; i++) {
        unichar c = [afterS characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

/* "GB" -> YES, "14.4" or "disk6s1" -> NO. diskutil always prints size as a
   plain number token immediately followed by one of these unit tokens. */
- (BOOL)isSizeUnitToken:(NSString *)token
{
    NSString *lower = [token lowercaseString];
    return [lower isEqualToString:@"bytes"] || [lower isEqualToString:@"kb"] ||
           [lower isEqualToString:@"mb"] || [lower isEqualToString:@"gb"] ||
           [lower isEqualToString:@"tb"] || [lower isEqualToString:@"pb"];
}

/*
 * Runs `diskutil list` ONCE (not diskutil info per-disk) and returns an array of
 * two-element arrays [identifier, detail] for partitions whose type looks like
 * NTFS or FAT (exFAT drives commonly show up mislabeled as "Windows_NTFS" on an
 * MBR disk, or "Microsoft Basic Data" on a GPT one -- both are the generic
 * "some Windows filesystem" label, since Mac OS X can't tell exFAT apart from
 * its neighbors without actually reading it).
 *
 * Deliberately avoids `diskutil info <id>` in a loop: calling it once per partition
 * can force every attached disk to spin up/respond individually, which stalled the
 * whole machine when several large external drives were asleep.
 */
- (NSArray *)scanCandidatePartitions
{
    NSMutableArray *result = [NSMutableArray array];
    NSString *output = [self runTaskAtPath:DISKUTIL_PATH arguments:[NSArray arrayWithObject:@"list"]];
    NSArray *lines = [output componentsSeparatedByString:@"\n"];
    NSEnumerator *e = [lines objectEnumerator];
    NSString *rawLine;

    while ((rawLine = [e nextObject]) != nil) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSRange colonRange;
        NSString *afterColon;
        NSArray *tokens;
        unsigned tokenCount;
        NSString *identifier;
        NSString *type;
        NSString *lowerType;
        NSString *detail;
        BOOL looksLikeCandidate;

        if ([line length] == 0) continue;

        /* rows we want look like "0: Windows_NTFS   14.4 GB   disk6s1", but the
           TYPE column can itself be multiple words (e.g. "Microsoft Basic Data") */
        colonRange = [line rangeOfString:@":"];
        if (colonRange.location == NSNotFound) continue;
        if (colonRange.location == 0) continue;

        {
            unsigned i;
            BOOL allDigits = YES;
            NSString *prefix = [line substringToIndex:colonRange.location];
            for (i = 0; i < [prefix length]; i++) {
                unichar c = [prefix characterAtIndex:i];
                if (c < '0' || c > '9') { allDigits = NO; break; }
            }
            if (!allDigits) continue;
        }

        afterColon = [line substringFromIndex:colonRange.location + 1];
        tokens = [self tokenizeWhitespace:afterColon];
        tokenCount = [tokens count];
        if (tokenCount < 4) continue; /* need at least: type, size, unit, identifier */

        identifier = [tokens objectAtIndex:tokenCount - 1];
        if (![self isValidPartitionIdentifier:identifier]) continue;

        /* the size unit anchors where the type field ends, so the type can be
           recovered in full no matter how many words it's made of */
        if (![self isSizeUnitToken:[tokens objectAtIndex:tokenCount - 2]]) continue;

        type = [[tokens subarrayWithRange:NSMakeRange(0, tokenCount - 3)] componentsJoinedByString:@" "];
        if ([type length] == 0) continue;

        lowerType = [type lowercaseString];
        looksLikeCandidate = ([lowerType rangeOfString:@"ntfs"].location != NSNotFound) ||
                              ([lowerType rangeOfString:@"fat"].location != NSNotFound) ||
                              ([lowerType rangeOfString:@"microsoft basic data"].location != NSNotFound);
        if (!looksLikeCandidate) continue;

        detail = [NSString stringWithFormat:@"%@ %@",
                  [tokens objectAtIndex:tokenCount - 3], [tokens objectAtIndex:tokenCount - 2]];
        [result addObject:[NSArray arrayWithObjects:identifier, detail, nil]];
    }
    return result;
}

/* Returns dictionary of identifier -> mountpoint, for mounts currently living under mountBaseDir. */
- (NSDictionary *)currentMountsUnderBase
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSString *output = [self runTaskAtPath:MOUNT_PATH arguments:[NSArray array]];
    NSArray *lines = [output componentsSeparatedByString:@"\n"];
    NSEnumerator *e = [lines objectEnumerator];
    NSString *line;

    while ((line = [e nextObject]) != nil) {
        NSRange onRange = [line rangeOfString:@" on "];
        NSString *device;
        NSString *rest;
        NSRange parenRange;
        NSString *mountPoint;
        NSString *identifier;

        if (onRange.location == NSNotFound) continue;

        device = [line substringToIndex:onRange.location];
        rest = [line substringFromIndex:onRange.location + 4];
        parenRange = [rest rangeOfString:@" ("];
        if (parenRange.location == NSNotFound) continue;

        mountPoint = [rest substringToIndex:parenRange.location];
        if (![mountPoint hasPrefix:mountBaseDir]) continue;

        identifier = [device lastPathComponent];
        [result setObject:mountPoint forKey:identifier];
    }

    /*
     * Clean up "ghost" mounts: if the USB drive was unplugged without ejecting
     * through this app first, the FUSE mount stays in the kernel mount table
     * forever (with no backing device left), and would otherwise show up
     * duplicated alongside a freshly-reinserted drive under a new disk number.
     * /dev/<identifier> disappears the moment the drive is actually gone, so
     * that's a cheap, reliable way to tell a ghost from a real mount.
     */
    {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray *staleIdentifiers = [NSMutableArray array];
        NSEnumerator *ke = [result keyEnumerator];
        NSString *ident;

        while ((ident = [ke nextObject]) != nil) {
            NSString *devPath = [@"/dev/" stringByAppendingString:ident];
            if (![fm fileExistsAtPath:devPath]) {
                [staleIdentifiers addObject:ident];
            }
        }

        if ([staleIdentifiers count] > 0) {
            NSEnumerator *se = [staleIdentifiers objectEnumerator];
            NSString *staleIdent;
            while ((staleIdent = [se nextObject]) != nil) {
                NSString *stalePoint = [result objectForKey:staleIdent];
                [self removeDesktopLinkForIdentifier:staleIdent];
                [self runTaskAtPath:UMOUNT_PATH arguments:[NSArray arrayWithObject:stalePoint]];
                [self runTaskAtPath:UMOUNT_PATH arguments:[NSArray arrayWithObjects:@"-f", stalePoint, nil]];
                [result removeObjectForKey:staleIdent];
            }
        }
    }

    return result;
}

/*
 * Get Info on the Desktop symlink can't show Capacity/Available for this mount:
 * "-o nobrowse" (see mountAction:) deliberately keeps it out of DiskArbitration
 * to avoid the old MacFUSE ghost-icon bug, but that also means Finder never
 * recognizes the mount point as a real volume, symlink or not. Showing free/used
 * space right in the menu sidesteps Finder entirely instead of fighting it.
 */
- (NSString *)freeSpaceStringForMountPoint:(NSString *)mountPoint
{
    struct statfs fsInfo;
    double freeGB;
    double totalGB;

    if (statfs([mountPoint fileSystemRepresentation], &fsInfo) != 0) {
        return nil;
    }

    freeGB = ((double)fsInfo.f_bavail * (double)fsInfo.f_bsize) / (1024.0 * 1024.0 * 1024.0);
    totalGB = ((double)fsInfo.f_blocks * (double)fsInfo.f_bsize) / (1024.0 * 1024.0 * 1024.0);
    return [NSString stringWithFormat:@"%.1f/%.1f GB free", freeGB, totalGB];
}

#pragma mark - Menu

- (void)statusItemClicked:(id)sender
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    NSDictionary *mounted = [self currentMountsUnderBase];
    NSArray *scanned = [self scanCandidatePartitions];
    NSMutableArray *candidates = [NSMutableArray array];
    NSEnumerator *ie;
    NSArray *pair;

    [menu setAutoenablesItems:NO];

    ie = [scanned objectEnumerator];
    while ((pair = [ie nextObject]) != nil) {
        NSString *ident = [pair objectAtIndex:0];
        if ([mounted objectForKey:ident] != nil) continue;
        [candidates addObject:pair];
    }

    if ([mounted count] > 0) {
        NSEnumerator *ke = [mounted keyEnumerator];
        NSString *mIdent;
        NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:L(kCodesEject, 4, @"Eject") action:NULL keyEquivalent:@""];
        [header setEnabled:NO];
        [menu addItem:header];
        [header release];

        while ((mIdent = [ke nextObject]) != nil) {
            NSString *mp = [mounted objectForKey:mIdent];
            NSString *freeSpace = [self freeSpaceStringForMountPoint:mp];
            NSString *title = (freeSpace != nil)
                ? [NSString stringWithFormat:@"%@: %@ (%@)", L(kCodesEject, 4, @"Eject"), mIdent, freeSpace]
                : [NSString stringWithFormat:@"%@: %@", L(kCodesEject, 4, @"Eject"), mIdent];
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                            action:@selector(unmountAction:)
                                                     keyEquivalent:@""];
            [item setTarget:self];
            [item setRepresentedObject:mp];
            [menu addItem:item];
            [item release];
        }
        [menu addItem:[NSMenuItem separatorItem]];
    }

    if ([candidates count] > 0) {
        NSEnumerator *ce = [candidates objectEnumerator];
        NSArray *c;
        NSMenuItem *header2 = [[NSMenuItem alloc] initWithTitle:L(kCodesMount, 4, @"Mount") action:NULL keyEquivalent:@""];
        [header2 setEnabled:NO];
        [menu addItem:header2];
        [header2 release];

        while ((c = [ce nextObject]) != nil) {
            NSString *cIdent = [c objectAtIndex:0];
            NSString *size = [c objectAtIndex:1];
            NSString *title = [NSString stringWithFormat:@"%@: %@ (%@)", L(kCodesMount, 4, @"Mount"), cIdent, size];
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                            action:@selector(mountAction:)
                                                     keyEquivalent:@""];
            [item setTarget:self];
            [item setRepresentedObject:cIdent];
            [menu addItem:item];
            [item release];
        }
        [menu addItem:[NSMenuItem separatorItem]];
    }

    if ([mounted count] == 0 && [candidates count] == 0) {
        NSString *emptyTitle = IsJapaneseSystem()
            ? [@"exFAT" stringByAppendingString:JPStringFromCodes(kCodesNoDriveTail, 12)]
            : @"No exFAT drives found";
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:emptyTitle
                                                         action:NULL
                                                  keyEquivalent:@""];
        [empty setEnabled:NO];
        [menu addItem:empty];
        [empty release];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    {
        NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:L(kCodesQuit, 2, @"Quit")
                                                            action:@selector(quitAction:)
                                                     keyEquivalent:@""];
        [quitItem setTarget:self];
        [menu addItem:quitItem];
        [quitItem release];
    }

    [statusItem popUpStatusItemMenu:menu];
    [menu release];
}

#pragma mark - Actions

/*
 * Finder picking up a FUSE mount as "MacFUSE Volume N" on its own turned out to be
 * unreliable -- sometimes it appears, sometimes it doesn't, for reasons that don't
 * seem to depend on anything this app does. A plain Desktop symlink to the mount
 * point sidesteps that flakiness entirely: no dependency on Finder's own DiskArbitration
 * notifications, so it shows up (and goes away) the same way every single time.
 */
- (NSString *)desktopLinkPathForIdentifier:(NSString *)identifier
{
    NSString *desktop = [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
    NSString *name = [NSString stringWithFormat:@"exFAT (%@)", identifier];
    return [desktop stringByAppendingPathComponent:name];
}

- (void)removeDesktopLinkForIdentifier:(NSString *)identifier
{
    NSString *linkPath = [self desktopLinkPathForIdentifier:identifier];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:linkPath]) {
        [fm removeFileAtPath:linkPath handler:nil];
    }
}

- (void)mountAction:(id)sender
{
    NSString *identifier = [sender representedObject];
    NSString *devicePath = [NSString stringWithFormat:@"/dev/%@", identifier];
    NSString *mountPoint = [mountBaseDir stringByAppendingPathComponent:identifier];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    NSString *output;
    NSDictionary *mounted;

    if (![self ensureCLIToolsInstalled]) {
        return;
    }

    if (![fm fileExistsAtPath:mountPoint isDirectory:&isDir]) {
        [fm createDirectoryAtPath:mountPoint attributes:nil];
    }

    /*
     * exFAT drives are recorded as "Windows_NTFS" at the partition-map level, so
     * Tiger's own built-in read-only NTFS driver auto-mounts them on insertion.
     * It can't actually parse exFAT internals, so that mount just shows up empty.
     * Clear it out of the way first so the real FUSE mount is the only one left.
     */
    [self runTaskAtPath:DISKUTIL_PATH arguments:[NSArray arrayWithObjects:@"unmount", devicePath, nil]];

    /*
     * "-o nobrowse" tells MacFUSE not to register this mount with DiskArbitration
     * at all, so Finder never creates its own "MacFUSE Volume N" icon for it --
     * that icon turned out to appear unreliably and, worse, to survive unmounting
     * as a dead, empty-looking stale icon. The Desktop symlink below is the only
     * entry point we want.
     */
    output = [self runTaskAtPath:MOUNT_EXFAT_PATH
                        arguments:[NSArray arrayWithObjects:@"-o", @"nobrowse", devicePath, mountPoint, nil]];

    mounted = [self currentMountsUnderBase];
    if ([mounted objectForKey:identifier] == nil) {
        NSAlert *alert = [NSAlert alertWithMessageText:L(kCodesMountFail, 11, @"Failed to mount")
                                          defaultButton:@"OK"
                                        alternateButton:nil
                                            otherButton:nil
                              informativeTextWithFormat:@"%@\n\n%@", devicePath, output];
        [alert runModal];
    } else {
        [self removeDesktopLinkForIdentifier:identifier];
        [fm createSymbolicLinkAtPath:[self desktopLinkPathForIdentifier:identifier] pathContent:mountPoint];
    }
}

- (void)unmountAction:(id)sender
{
    NSString *mountPoint = [sender representedObject];
    NSString *identifier = [mountPoint lastPathComponent];
    NSString *output = [self runTaskAtPath:UMOUNT_PATH arguments:[NSArray arrayWithObject:mountPoint]];
    NSDictionary *mounted = [self currentMountsUnderBase];
    NSEnumerator *ke = [mounted keyEnumerator];
    NSString *k;
    BOOL stillMounted = NO;

    while ((k = [ke nextObject]) != nil) {
        if ([[mounted objectForKey:k] isEqualToString:mountPoint]) {
            stillMounted = YES;
            break;
        }
    }

    if (stillMounted) {
        NSAlert *alert = [NSAlert alertWithMessageText:L(kCodesEjectFail, 11, @"Failed to eject")
                                          defaultButton:@"OK"
                                        alternateButton:nil
                                            otherButton:nil
                              informativeTextWithFormat:@"%@\n\n%@", mountPoint, output];
        [alert runModal];
    } else {
        [self removeDesktopLinkForIdentifier:identifier];
    }
}

- (void)quitAction:(id)sender
{
    [NSApp terminate:self];
}

@end
