#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject
{
    NSStatusItem *statusItem;
    NSString *mountBaseDir;
}

- (void)statusItemClicked:(id)sender;
- (void)mountAction:(id)sender;
- (void)unmountAction:(id)sender;
- (void)quitAction:(id)sender;
- (NSString *)desktopLinkPathForIdentifier:(NSString *)identifier;
- (void)removeDesktopLinkForIdentifier:(NSString *)identifier;

@end
