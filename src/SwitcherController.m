#import "SwitcherController.h"
#import "SwitcherPanel.h"
#import "WindowInfo.h"
#import "WindowRaiser.h"
#import "PrivateAPI.h"

#import <Carbon/Carbon.h>  // for kVK_Tab, kVK_Escape

// How long ⌘ must stay held before the picker appears. A quick ⌘Tab tap
// commits before this fires, so it switches instantly with no UI flash.
static const NSTimeInterval kShowDelay = 0.2;

@interface SwitcherController () {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _runLoopSource;
    EventHandlerRef _hotKeyHandler;
    EventHotKeyRef _forwardHotKey;
    EventHotKeyRef _backwardHotKey;
}
@property(nonatomic, assign) BOOL switching;
@property(nonatomic, assign) NSInteger selectedIndex;
@property(nonatomic, strong) NSArray<WindowInfo *> *windows;
@property(nonatomic, strong) SwitcherPanel *panel;
@property(nonatomic, assign) pid_t selfPID;
@property(nonatomic, strong) NSTimer *showTimer;
@property(nonatomic, assign) BOOL panelVisible;
- (CGEventRef)handleEventOfType:(CGEventType)type event:(CGEventRef)event;
- (void)handleHotKeyBackward:(BOOL)backward;
@end

static const OSType kHotKeySignature = 'McTb';
static const UInt32 kForwardHotKeyID = 1;
static const UInt32 kBackwardHotKeyID = 2;
static const int kNativeCommandTabHotKey = 1;
static const int kNativeCommandShiftTabHotKey = 2;

static CGEventRef EventTapCallback(CGEventTapProxy proxy, CGEventType type,
                                   CGEventRef event, void *refcon) {
    SwitcherController *self = (__bridge SwitcherController *)refcon;
    return [self handleEventOfType:type event:event];
}

static OSStatus HotKeyCallback(EventHandlerCallRef nextHandler, EventRef event,
                               void *refcon) {
    EventHotKeyID hotKeyID = {0};
    OSStatus status = GetEventParameter(event, kEventParamDirectObject,
                                        typeEventHotKeyID, NULL,
                                        sizeof(hotKeyID), NULL, &hotKeyID);
    if (status != noErr || hotKeyID.signature != kHotKeySignature) return status;

    SwitcherController *self = (__bridge SwitcherController *)refcon;
    [self handleHotKeyBackward:hotKeyID.id == kBackwardHotKeyID];
    return noErr;
}

@implementation SwitcherController

- (BOOL)start {
    self.selfPID = getpid();
    self.panel = [[SwitcherPanel alloc] init];

    CGError disableForward = CGSSetSymbolicHotKeyEnabled(
        kNativeCommandTabHotKey, false);
    CGError disableBackward = CGSSetSymbolicHotKeyEnabled(
        kNativeCommandShiftTabHotKey, false);
    if (disableForward != kCGErrorSuccess ||
        disableBackward != kCGErrorSuccess) {
        NSLog(@"[Switcher] Failed to disable native hotkeys: forward %d, backward %d",
              disableForward, disableBackward);
        [self restoreNativeHotKeys];
        return NO;
    }

    EventTypeSpec hotKeyEvent = {kEventClassKeyboard, kEventHotKeyPressed};
    OSStatus handlerStatus = InstallApplicationEventHandler(
        HotKeyCallback, 1, &hotKeyEvent, (__bridge void *)self, &_hotKeyHandler);
    EventHotKeyID forwardID = {kHotKeySignature, kForwardHotKeyID};
    EventHotKeyID backwardID = {kHotKeySignature, kBackwardHotKeyID};
    OSStatus forwardStatus = RegisterEventHotKey(
        kVK_Tab, cmdKey, forwardID, GetApplicationEventTarget(), 0,
        &_forwardHotKey);
    OSStatus backwardStatus = RegisterEventHotKey(
        kVK_Tab, cmdKey | shiftKey, backwardID, GetApplicationEventTarget(), 0,
        &_backwardHotKey);
    if (handlerStatus != noErr || forwardStatus != noErr ||
        backwardStatus != noErr) {
        NSLog(@"[Switcher] Failed to register hotkeys: handler %d, forward %d, backward %d",
              handlerStatus, forwardStatus, backwardStatus);
        if (_forwardHotKey) UnregisterEventHotKey(_forwardHotKey);
        if (_backwardHotKey) UnregisterEventHotKey(_backwardHotKey);
        if (_hotKeyHandler) RemoveEventHandler(_hotKeyHandler);
        _forwardHotKey = NULL;
        _backwardHotKey = NULL;
        _hotKeyHandler = NULL;
        [self restoreNativeHotKeys];
        return NO;
    }

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) |
                       CGEventMaskBit(kCGEventKeyUp) |
                       CGEventMaskBit(kCGEventFlagsChanged);

    // Carbon handles Tab. The HID tap handles Escape and observes Command
    // release so the selected window is committed at the right time.
    _tap = CGEventTapCreate(kCGHIDEventTap,
                            kCGHeadInsertEventTap,
                            kCGEventTapOptionDefault,  // active: may consume
                            mask,
                            EventTapCallback,
                            (__bridge void *)self);
    if (!_tap) {
        NSLog(@"[Switcher] Failed to create event tap — is Accessibility permission granted?");
        UnregisterEventHotKey(_forwardHotKey);
        UnregisterEventHotKey(_backwardHotKey);
        RemoveEventHandler(_hotKeyHandler);
        _forwardHotKey = NULL;
        _backwardHotKey = NULL;
        _hotKeyHandler = NULL;
        [self restoreNativeHotKeys];
        return NO;
    }

    _runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), _runLoopSource, kCFRunLoopCommonModes);
    CGEventTapEnable(_tap, true);
    NSLog(@"[Switcher] Hotkeys and event tap installed. Hold ⌘ and tap Tab.");
    return YES;
}

- (void)restoreNativeHotKeys {
    CGSSetSymbolicHotKeyEnabled(kNativeCommandTabHotKey, true);
    CGSSetSymbolicHotKeyEnabled(kNativeCommandShiftTabHotKey, true);
}

- (CGEventRef)handleEventOfType:(CGEventType)type event:(CGEventRef)event {
    // The system disables the tap if a callback runs too long or on user input
    // events during a modal loop — re-enable it and move on.
    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        if (_tap) CGEventTapEnable(_tap, true);
        return event;
    }

    CGKeyCode keycode =
        (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    CGEventFlags flags = CGEventGetFlags(event);
    BOOL cmd = (flags & kCGEventFlagMaskCommand) != 0;

    switch (type) {
        case kCGEventKeyDown:
            if (keycode == kVK_Escape && self.switching) {
                [self cancel];
                return NULL;
            }
            break;

        case kCGEventKeyUp:
            // Escape key-down is consumed while switching, so consume its
            // matching key-up as well.
            if (self.switching && keycode == kVK_Escape)
                return NULL;
            break;

        case kCGEventFlagsChanged:
            // ⌘ released → commit the current selection.
            if (self.switching && !cmd) {
                [self commit];
            }
            break;

        default:
            break;
    }
    return event;
}

- (void)handleHotKeyBackward:(BOOL)backward {
    if (!self.switching) {
        [self beginSwitchingBackward:backward];
    } else {
        [self advanceBackward:backward];
    }
}

#pragma mark - State machine

- (BOOL)beginSwitchingBackward:(BOOL)backward {
    self.windows = [WindowInfo currentSpaceWindowsExcludingPID:self.selfPID];
    // We always take over ⌘Tab so the native switcher never appears — even with
    // zero windows, where the picker just shows a "No windows" message.
    self.switching = YES;
    self.panelVisible = NO;
    NSInteger last = (NSInteger)self.windows.count - 1;
    self.selectedIndex = backward ? last : 1;
    if (self.selectedIndex > last) self.selectedIndex = last;  // clamp (single window)
    // Defer showing the picker: a quick tap commits before this fires and just
    // switches to the selected window with no UI. Hold ⌘ past kShowDelay to see
    // the picker.
    self.showTimer = [NSTimer scheduledTimerWithTimeInterval:kShowDelay
                                                     target:self
                                                   selector:@selector(showTimerFired:)
                                                   userInfo:nil
                                                    repeats:NO];
    return YES;
}

- (void)showTimerFired:(NSTimer *)timer {
    if (!self.switching) return;
    // Resolve window titles only now that the picker is actually appearing —
    // a quick tap commits before this and never pays for the AX round-trips.
    WindowInfo *selectedWindow =
        (self.selectedIndex >= 0 && self.selectedIndex < (NSInteger)self.windows.count)
            ? self.windows[self.selectedIndex] : nil;
    self.windows = [WindowInfo filterAndFillTitlesViaAccessibility:self.windows];
    // Keep the same selection if it survived filtering. If the selected entry
    // was the auxiliary surface, use the usual previous-window choice instead.
    NSUInteger selected = selectedWindow
        ? [self.windows indexOfObjectIdenticalTo:selectedWindow] : NSNotFound;
    if (selected != NSNotFound) {
        self.selectedIndex = (NSInteger)selected;
    } else {
        self.selectedIndex = self.windows.count > 1 ? 1 : 0;
    }
    NSInteger last = (NSInteger)self.windows.count - 1;
    if (self.selectedIndex > last) self.selectedIndex = last;
    [self.panel showWindows:self.windows selectedIndex:self.selectedIndex];
    self.panelVisible = YES;
}

- (void)advanceBackward:(BOOL)backward {
    NSInteger n = (NSInteger)self.windows.count;
    if (n == 0) return;
    self.selectedIndex = ((self.selectedIndex + (backward ? -1 : 1)) % n + n) % n;
    // If the picker is already up, reflect the new selection; otherwise it will
    // show the current selection once the timer fires.
    if (self.panelVisible) [self.panel updateSelectedIndex:self.selectedIndex];
}

- (void)commit {
    WindowInfo *chosen = nil;
    if (self.selectedIndex >= 0 && self.selectedIndex < (NSInteger)self.windows.count) {
        chosen = self.windows[self.selectedIndex];
    }
    [self endSwitching];
    // Raising a window makes synchronous AX calls into the target app. Defer it
    // off the event-tap callback: this callback runs on the main run loop for an
    // active, session-wide tap, so a beachballed target must not block it — that
    // would stall keyboard input in every app until the system disables the tap.
    if (chosen) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [WindowRaiser raise:chosen];
        });
    }
}

- (void)cancel {
    [self endSwitching];
}

- (void)endSwitching {
    self.switching = NO;
    [self.showTimer invalidate];
    self.showTimer = nil;
    if (self.panelVisible) {
        [self.panel dismiss];
        self.panelVisible = NO;
    }
    self.windows = nil;
    self.selectedIndex = 0;
}

@end
