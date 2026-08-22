#import "AppDelegate.h"

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

/*
 * Runs `diskutil list` ONCE (not diskutil info per-disk) and returns an array of
 * two-element arrays [identifier, detail] for partitions whose type looks like
 * NTFS or FAT (exFAT drives commonly show up mislabeled as "Windows_NTFS").
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
        NSString *identifier;
        NSString *type;
        NSString *lowerType;
        BOOL looksLikeCandidate;

        if ([line length] == 0) continue;

        /* rows we want look like "0: Windows_NTFS   14.4 GB   disk6s1" */
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
        if ([tokens count] < 2) continue;

        identifier = [tokens lastObject];
        if (![self isValidPartitionIdentifier:identifier]) continue;

        type = [tokens objectAtIndex:0];
        lowerType = [type lowercaseString];
        looksLikeCandidate = ([lowerType rangeOfString:@"ntfs"].location != NSNotFound) ||
                              ([lowerType rangeOfString:@"fat"].location != NSNotFound);
        if (!looksLikeCandidate) continue;

        {
            /* everything between the type and the identifier (name/size) as a label */
            NSRange middleRange = NSMakeRange(1, [tokens count] - 2);
            NSString *detail = [[tokens subarrayWithRange:middleRange] componentsJoinedByString:@" "];
            [result addObject:[NSArray arrayWithObjects:identifier, detail, nil]];
        }
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
        NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:JPStringFromCodes(kCodesEject, 4) action:NULL keyEquivalent:@""];
        [header setEnabled:NO];
        [menu addItem:header];
        [header release];

        while ((mIdent = [ke nextObject]) != nil) {
            NSString *mp = [mounted objectForKey:mIdent];
            NSString *title = [NSString stringWithFormat:@"%@: %@", JPStringFromCodes(kCodesEject, 4), mIdent];
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
        NSMenuItem *header2 = [[NSMenuItem alloc] initWithTitle:JPStringFromCodes(kCodesMount, 4) action:NULL keyEquivalent:@""];
        [header2 setEnabled:NO];
        [menu addItem:header2];
        [header2 release];

        while ((c = [ce nextObject]) != nil) {
            NSString *cIdent = [c objectAtIndex:0];
            NSString *size = [c objectAtIndex:1];
            NSString *title = [NSString stringWithFormat:@"%@: %@ (%@)", JPStringFromCodes(kCodesMount, 4), cIdent, size];
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
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:[@"exFAT" stringByAppendingString:JPStringFromCodes(kCodesNoDriveTail, 12)]
                                                         action:NULL
                                                  keyEquivalent:@""];
        [empty setEnabled:NO];
        [menu addItem:empty];
        [empty release];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    {
        NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:JPStringFromCodes(kCodesQuit, 2)
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
        NSAlert *alert = [NSAlert alertWithMessageText:JPStringFromCodes(kCodesMountFail, 11)
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
        NSAlert *alert = [NSAlert alertWithMessageText:JPStringFromCodes(kCodesEjectFail, 11)
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
