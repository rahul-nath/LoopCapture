#import <AppKit/AppKit.h>
#import <AVKit/AVKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Carbon/Carbon.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
#include <variant>
#include <optional>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>

static NSRect CaptureRect(NSRect selection, NSRect screen) {
    return NSMakeRect(NSMinX(selection)-NSMinX(screen), NSMaxY(screen)-NSMaxY(selection), selection.size.width, selection.size.height);
}
static BOOL SaveDraft(NSURL *source, NSURL *destination, NSError **error) {
    if ([source.URLByStandardizingPath isEqual:destination.URLByStandardizingPath]) return YES;
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *staging = [[destination URLByDeletingLastPathComponent] URLByAppendingPathComponent:
        [NSString stringWithFormat:@".loopcapture-%@.mp4", NSUUID.UUID.UUIDString]];
    if (![files copyItemAtURL:source toURL:staging error:error]) return NO;
    BOOL success;
    if ([files fileExistsAtPath:destination.path]) {
        success = [files replaceItemAtURL:destination withItemAtURL:staging backupItemName:nil options:0 resultingItemURL:nil error:error];
    } else { success = [files moveItemAtURL:staging toURL:destination error:error]; }
    [files removeItemAtURL:staging error:nil];
    return success;
}

static NSURL *ScreenshotFolder() {
    NSString *path = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.apple.screencapture"][@"location"];
    if (path.length) return [NSURL fileURLWithPath:path.stringByExpandingTildeInPath isDirectory:YES];
    return [NSFileManager.defaultManager URLsForDirectory:NSDesktopDirectory inDomains:NSUserDomainMask][0];
}
static NSError *MediaError(NSString *message) {
    return [NSError errorWithDomain:@"LoopCapture" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
// The complete duration is preserved. Long recordings reduce the GIF frame rate,
// bounding the conversion work without truncating the clipboard animation.
static BOOL ExportGIF(NSURL *movie, NSURL *gif, NSError **error) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:movie options:nil];
    double duration = CMTimeGetSeconds(asset.duration);
    if (!isfinite(duration) || duration <= 0) { if (error) *error = MediaError(@"The recording contains no playable frames."); return NO; }
    size_t count = MAX(1,MIN(600,(size_t)ceil(duration*10)));
    CGImageDestinationRef writer = CGImageDestinationCreateWithURL((__bridge CFURLRef)gif,(__bridge CFStringRef)UTTypeGIF.identifier,count,NULL);
    if (!writer) { if (error) *error = MediaError(@"Could not create the clipboard GIF."); return NO; }
    NSDictionary *loop = @{(__bridge NSString *)kCGImagePropertyGIFDictionary:@{(__bridge NSString *)kCGImagePropertyGIFLoopCount:@0}};
    CGImageDestinationSetProperties(writer,(__bridge CFDictionaryRef)loop);
    AVAssetImageGenerator *reader = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    reader.appliesPreferredTrackTransform = YES; reader.maximumSize = CGSizeMake(960,960);
    reader.requestedTimeToleranceBefore = CMTimeMake(1,20); reader.requestedTimeToleranceAfter = CMTimeMake(1,20);
    double delay = MAX(0.1,duration/count);
    NSDictionary *frame = @{(__bridge NSString *)kCGImagePropertyGIFDictionary:@{(__bridge NSString *)kCGImagePropertyGIFDelayTime:@(delay),(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime:@(delay)}};
    BOOL success = YES;
    for (size_t i = 0; i < count; ++i) {
        @autoreleasepool {
            dispatch_semaphore_t ready = dispatch_semaphore_create(0);
            __block NSBitmapImageRep *bitmap = nil;
            __block NSError *frameError = nil;
            [reader generateCGImageAsynchronouslyForTime:CMTimeMakeWithSeconds(i*duration/count,600) completionHandler:^(CGImageRef image,CMTime actual,NSError *failure) {
                if (image) bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
                frameError = failure; dispatch_semaphore_signal(ready);
            }];
            BOOL timedOut = dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC)) != 0;
            if (timedOut || !bitmap) {
                [reader cancelAllCGImageGeneration]; success = NO;
                if (error) *error = timedOut ? MediaError(@"Clipboard conversion timed out. The MP4 is saved.") : frameError;
                break;
            }
            CGImageDestinationAddImage(writer,bitmap.CGImage,(__bridge CFDictionaryRef)frame);
        }
    }
    if (success && !CGImageDestinationFinalize(writer)) { success = NO; if (error) *error = MediaError(@"Could not finish the clipboard GIF."); }
    CFRelease(writer);
    if (!success) [NSFileManager.defaultManager removeItemAtURL:gif error:nil];
    return success;
}
static NSArray<AVAssetTrack *> *MovieTracks(AVAsset *asset, AVMediaType type) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSArray<AVAssetTrack *> *tracks;
    [asset loadTracksWithMediaType:type completionHandler:^(NSArray<AVAssetTrack *> *result, NSError *error) {
        tracks = error ? nil : result;
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return tracks;
}

// Called on the publishing queue after the original MP4 is safely saved.
static BOOL CompactMovie(NSURL *movie) {
    AVURLAsset *input = [AVURLAsset URLAssetWithURL:movie options:nil];
    double seconds = CMTimeGetSeconds(input.duration);
    if (!isfinite(seconds) || seconds <= 0) return NO;
    NSNumber *originalSize = nil;
    if (![movie getResourceValue:&originalSize forKey:NSURLFileSizeKey error:nil]) return NO;
    if (originalSize.longLongValue <= seconds * (2e9 / 3600)) return YES;

    AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:input
        presetName:AVAssetExportPresetHighestQuality];
    if (!exporter) return NO;
    NSURL *candidate = [[movie URLByDeletingLastPathComponent] URLByAppendingPathComponent:
        [NSString stringWithFormat:@".compact-%@.mp4", NSUUID.UUID.UUIDString]];
    exporter.outputURL = candidate;
    exporter.outputFileType = AVFileTypeMPEG4;
    exporter.fileLengthLimit = MAX(1, (long long)(seconds * (3928000.0 / 8)));
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [exporter exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(finished); }];
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);

    NSFileManager *files = NSFileManager.defaultManager;
    BOOL valid = exporter.status == AVAssetExportSessionStatusCompleted;
    if (valid) {
        AVURLAsset *result = [AVURLAsset URLAssetWithURL:candidate options:nil];
        NSNumber *size = nil;
        valid = [candidate getResourceValue:&size forKey:NSURLFileSizeKey error:nil]
            && size.longLongValue > 0 && size.longLongValue < originalSize.longLongValue
            && fabs(CMTimeGetSeconds(result.duration) - seconds) <= 0.1;
        for (AVMediaType type in @[AVMediaTypeVideo, AVMediaTypeAudio]) {
            NSArray<AVAssetTrack *> *before = MovieTracks(input, type);
            NSArray<AVAssetTrack *> *after = MovieTracks(result, type);
            valid = valid && before && after && before.count == after.count;
            for (NSUInteger i = 0; valid && i < before.count; i++) {
                CMTimeRange a = before[i].timeRange, b = after[i].timeRange;
                valid = fabs(CMTimeGetSeconds(a.start) - CMTimeGetSeconds(b.start)) <= 0.1
                    && fabs(CMTimeGetSeconds(CMTimeRangeGetEnd(a)) - CMTimeGetSeconds(CMTimeRangeGetEnd(b))) <= 0.1;
            }
        }
    }
    if (valid) valid = [files replaceItemAtURL:movie withItemAtURL:candidate backupItemName:nil
                                      options:0 resultingItemURL:nil error:nil];
    [files removeItemAtURL:candidate error:nil];
    return valid;
}

static BOOL CopyClip(NSURL *url, BOOL image) {
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return NO;
    NSPasteboardItem *item = [NSPasteboardItem new];
    [item setString:url.absoluteString forType:NSPasteboardTypeFileURL];
    [item setData:data forType:image ? UTTypeGIF.identifier : UTTypeMPEG4Movie.identifier];
    // Keep the MIME representation as well as the native UTI for paste receivers.
    [item setData:data forType:image ? @"image/gif" : @"video/mp4"];
    NSPasteboard *clipboard = NSPasteboard.generalPasteboard;
    [clipboard clearContents]; return [clipboard writeObjects:@[item]];
}

@interface SelectionWindow : NSWindow @end
@implementation SelectionWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface SelectionView : NSView
@property(copy) void (^selected)(NSRect);
@property(copy) void (^cancelled)(void);
@end
@implementation SelectionView {
    NSPoint _anchor;
    NSRect _rectangle;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)drawRect:(NSRect)dirty {
    [[NSColor colorWithWhite:0 alpha:0.34] setFill];
    NSRectFill(self.bounds);
    if (!NSIsEmptyRect(_rectangle)) {
        [NSColor.clearColor setFill];
        NSRectFillUsingOperation(_rectangle, NSCompositingOperationCopy);
        [NSColor.systemBlueColor setStroke];
        NSBezierPath *border = [NSBezierPath bezierPathWithRect:_rectangle];
        border.lineWidth = 2; [border stroke];
    }
    NSString *text = @"Drag an area  •  Release to record  •  Return for full display  •  Esc cancels";
    NSDictionary *attributes = @{NSFontAttributeName:[NSFont systemFontOfSize:18 weight:NSFontWeightSemibold],
                                NSForegroundColorAttributeName:NSColor.whiteColor};
    NSSize size = [text sizeWithAttributes:attributes];
    [text drawAtPoint:NSMakePoint((self.bounds.size.width-size.width)/2, self.bounds.size.height-80) withAttributes:attributes];
}
- (void)mouseDown:(NSEvent *)event { _anchor = [self convertPoint:event.locationInWindow fromView:nil]; }
- (void)mouseDragged:(NSEvent *)event {
    NSPoint end = [self convertPoint:event.locationInWindow fromView:nil];
    _rectangle = NSIntersectionRect(NSMakeRect(MIN(_anchor.x,end.x),MIN(_anchor.y,end.y),fabs(end.x-_anchor.x),fabs(end.y-_anchor.y)),self.bounds);
    self.needsDisplay = YES;
}
- (void)mouseUp:(NSEvent *)event {
    [self mouseDragged:event];
    if (_rectangle.size.width >= 16 && _rectangle.size.height >= 16) self.selected(_rectangle);
    else { _rectangle = NSZeroRect; self.needsDisplay = YES; }
}
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53) self.cancelled();
    else if (event.keyCode == 36 || event.keyCode == 49) self.selected(self.bounds);
}
@end

@interface Selection : NSObject
@property(strong) SelectionWindow *window;
- (instancetype)initWithScreen:(NSScreen *)screen selected:(void (^)(NSRect))selected cancelled:(void (^)(void))cancelled;
@end
@implementation Selection
- (instancetype)initWithScreen:(NSScreen *)screen selected:(void (^)(NSRect))selected cancelled:(void (^)(void))cancelled {
    if ((self = [super init])) {
        _window = [[SelectionWindow alloc] initWithContentRect:screen.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        _window.level = NSScreenSaverWindowLevel;
        _window.backgroundColor = NSColor.clearColor; _window.opaque = NO; _window.hasShadow = NO;
        _window.releasedWhenClosed = NO;
        _window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
        SelectionView *view = [[SelectionView alloc] initWithFrame:NSMakeRect(0,0,screen.frame.size.width,screen.frame.size.height)];
        view.selected = ^(NSRect local) { selected(NSOffsetRect(local,screen.frame.origin.x,screen.frame.origin.y)); };
        view.cancelled = cancelled; _window.contentView = view;
        [NSApp activateIgnoringOtherApps:YES]; [_window makeKeyAndOrderFront:nil]; [_window makeFirstResponder:view];
    }
    return self;
}
- (void)dealloc { [_window close]; }
@end

@interface Capture : NSObject <SCStreamDelegate, SCRecordingOutputDelegate>
@property(strong) NSURL *url;
@property(strong) SCStream *stream;
@property(strong) SCRecordingOutput *output;
@property(copy) void (^started)(void);
@property(copy) void (^finished)(void);
@property(copy) void (^failed)(NSError *);
- (instancetype)initWithDisplay:(SCDisplay *)display applications:(NSArray<SCRunningApplication *> *)apps rectangle:(NSRect)rect scale:(CGFloat)scale url:(NSURL *)url error:(NSError **)error;
@end
@implementation Capture
- (instancetype)initWithDisplay:(SCDisplay *)display applications:(NSArray<SCRunningApplication *> *)apps rectangle:(NSRect)rect scale:(CGFloat)scale url:(NSURL *)url error:(NSError **)error {
    if ((self = [super init])) {
        _url = url;
        NSMutableArray *ownApp = NSMutableArray.array;
        for (SCRunningApplication *app in apps) if (app.processID == getpid()) [ownApp addObject:app];
        if (!ownApp.count) { if (error) *error = MediaError(@"Could not exclude LoopCapture's windows from this recording. Try again."); return nil; }
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingApplications:ownApp exceptingWindows:@[]];
        SCStreamConfiguration *config = [SCStreamConfiguration new];
        config.sourceRect = rect;
        CGFloat pixels = MIN(scale, 1920/MAX(rect.size.width,rect.size.height));
        config.width = MAX(2,(NSInteger)(rect.size.width*pixels)/2*2);
        config.height = MAX(2,(NSInteger)(rect.size.height*pixels)/2*2);
        config.minimumFrameInterval = CMTimeMake(1,30); config.showsCursor = YES;
        // One SCRecordingOutput owns the shared audio/video timeline and MP4.
        config.capturesAudio = YES;
        config.excludesCurrentProcessAudio = YES;
        config.captureMicrophone = NO;
        _stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
        SCRecordingOutputConfiguration *recording = [SCRecordingOutputConfiguration new];
        recording.outputURL = url; recording.videoCodecType = AVVideoCodecTypeH264; recording.outputFileType = AVFileTypeMPEG4;
        _output = [[SCRecordingOutput alloc] initWithConfiguration:recording delegate:self];
        if (![_stream addRecordingOutput:_output error:error]) return nil;
    }
    return self;
}
- (void)recordingOutputDidStartRecording:(SCRecordingOutput *)output {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.started) self.started(); });
}
- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)output {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.finished) self.finished(); });
}
- (void)recordingOutput:(SCRecordingOutput *)output didFailWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.failed) self.failed(error); });
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.failed) self.failed(error); });
}
@end

@interface Preview : NSObject <NSWindowDelegate>
@property(strong) NSURL *url;
@property(strong) NSURL *gif;
@property(strong) NSButton *gifButton;
@property(strong) NSWindow *window;
@property(strong) AVQueuePlayer *player;
@property(strong) AVPlayerLooper *looper;
@property(copy) void (^closed)(void);
@property(copy) void (^failed)(NSString *);
- (instancetype)initWithURL:(NSURL *)url;
@end
@implementation Preview
- (instancetype)initWithURL:(NSURL *)url {
    if ((self = [super init])) {
        _url = url; _player = [AVQueuePlayer new];
        _looper = [AVPlayerLooper playerLooperWithPlayer:_player templateItem:[AVPlayerItem playerItemWithURL:url]];
        _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,740,480) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
        _window.title = @"LoopCapture - Preview"; _window.releasedWhenClosed = NO; _window.delegate = self;
        _window.minSize = NSMakeSize(620,380);
        NSView *root = [NSView new]; _window.contentView = root;
        AVPlayerView *video = [AVPlayerView new];
        video.player = _player; video.controlsStyle = AVPlayerViewControlsStyleInline; video.videoGravity = AVLayerVideoGravityResizeAspect;
        NSTextField *note = [NSTextField labelWithString:@"MP4 saved"];
        note.textColor = NSColor.secondaryLabelColor;
        _gifButton = [NSButton buttonWithTitle:@"Generate GIF" target:self action:@selector(generateGIF:)];
        NSButton *videoCopy = [NSButton buttonWithTitle:@"Copy Video" target:self action:@selector(copyVideo:)];
        NSButton *reveal = [NSButton buttonWithTitle:@"Show in Finder" target:self action:@selector(reveal:)];
        NSStackView *bar = [NSStackView stackViewWithViews:@[note,_gifButton,videoCopy,reveal]]; bar.spacing = 12; bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        for (NSView *view in @[video,bar]) { view.translatesAutoresizingMaskIntoConstraints = NO; [root addSubview:view]; }
        [NSLayoutConstraint activateConstraints:@[
            [video.leadingAnchor constraintEqualToAnchor:root.leadingAnchor], [video.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [video.topAnchor constraintEqualToAnchor:root.topAnchor], [video.bottomAnchor constraintEqualToAnchor:bar.topAnchor constant:-12],
            [bar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16], [bar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
            [bar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-16]]];
        [_window center]; [NSApp activateIgnoringOtherApps:YES]; [_window makeKeyAndOrderFront:nil]; [_player play];
    }
    return self;
}
- (void)finish { [_player pause]; [_looper disableLooping]; [_window orderOut:nil]; if (_closed) _closed(); }
- (void)generateGIF:(id)sender {
    if (!_gifButton.enabled) return;
    if (_gif) {
        [self copyAnimation:sender];
        return;
    }
    _gifButton.enabled = NO;
    _gifButton.title = @"Generating…";
    NSURL *movie = _url;
    NSURL *gif = [movie.URLByDeletingPathExtension URLByAppendingPathExtension:@"gif"];
    __weak Preview *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *staging = [gif.URLByDeletingLastPathComponent URLByAppendingPathComponent:
            [NSString stringWithFormat:@".gif-%@.gif", NSUUID.UUID.UUIDString]];
        NSError *error = nil;
        NSFileManager *files = NSFileManager.defaultManager;
        BOOL saved = ExportGIF(movie, staging, &error) && [files moveItemAtURL:staging toURL:gif error:&error];
        [files removeItemAtURL:staging error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            Preview *preview = weakSelf;
            if (!preview) return;
            preview.gifButton.enabled = YES;
            preview.gifButton.title = saved ? @"Copy GIF" : @"Generate GIF";
            if (saved) preview.gif = gif;
            else if (preview.failed) preview.failed(error.localizedDescription ?: @"Could not save the GIF.");
        });
    });
}
- (void)copyAnimation:(id)sender { if (!CopyClip(_gif,YES) && _failed) _failed(@"Could not copy the animation."); }
- (void)copyVideo:(id)sender { if (!CopyClip(_url,NO) && _failed) _failed(@"Could not copy the video."); }
- (void)reveal:(id)sender { [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[_url]]; }
- (BOOL)windowShouldClose:(NSWindow *)sender { [self finish]; return NO; }
@end

// Each state carries exactly the resource it owns. Capture is not Recording until the writer confirms it started.
struct Idle {};
struct Selecting { Selection *value; explicit Selecting(Selection *v):value(v) { NSCAssert(v,@"Missing selection"); } };
// Keep the selector visible until ScreenCaptureKit identifies its owner. The
// resulting app filter also excludes windows created later during recording.
struct Preparing { NSUUID *token; Selection *selection; Preparing(NSUUID *v,Selection *s):token(v),selection(s) { NSCAssert(v && s,@"Missing preparation resource"); } };
struct Starting { Capture *value; explicit Starting(Capture *v):value(v) { NSCAssert(v,@"Missing capture"); } };
struct Recording { Capture *value; explicit Recording(Capture *v):value(v) { NSCAssert(v,@"Missing capture"); } };
struct Finishing { Capture *value; explicit Finishing(Capture *v):value(v) { NSCAssert(v,@"Missing capture"); } };
struct Publishing { NSURL *draft; explicit Publishing(NSURL *v):draft(v) { NSCAssert(v,@"Missing draft"); } };
struct Reviewing { Preview *value; explicit Reviewing(Preview *v):value(v) { NSCAssert(v,@"Missing preview"); } };
using State = std::variant<Idle,Selecting,Preparing,Starting,Recording,Finishing,Publishing,Reviewing>;

static constexpr UInt32 CaptureModifiers = cmdKey | shiftKey | controlKey;
static constexpr UInt32 DigitKeyCodes[] = {kVK_ANSI_5,kVK_ANSI_6,kVK_ANSI_7,kVK_ANSI_8,kVK_ANSI_9};
static NSString *ShortcutLabel(int digit) { return [NSString stringWithFormat:@"⌘⇧⌃%d",digit]; }
struct Shortcut { int digit; EventHotKeyRef ref; };
struct AllShortcutsTaken {};
struct ShortcutError { OSStatus status; };
using ShortcutResult = std::variant<Shortcut,AllShortcutsTaken,ShortcutError>;

// The successful registration stays reserved while the user considers the offer.
template <typename Register>
static ShortcutResult FindShortcut(int first,int skip,Register reserve) {
    for (int offset=0; offset<5; ++offset) {
        int digit = 5 + (first-5+offset)%5;
        if (digit == skip) continue;
        EventHotKeyRef ref = nullptr;
        OSStatus status = reserve(digit,DigitKeyCodes[digit-5],&ref);
        if (status == noErr) return Shortcut{digit,ref};
        if (status != eventHotKeyExistsErr) return ShortcutError{status};
    }
    return AllShortcutsTaken{};
}
static bool IsSystemShortcut(NSArray *systemKeys,UInt32 code) {
    for (NSDictionary *key in systemKeys) {
        if ([key[(__bridge NSString *)kHISymbolicHotKeyEnabled] boolValue] &&
            [key[(__bridge NSString *)kHISymbolicHotKeyCode] unsignedIntValue] == code &&
            [key[(__bridge NSString *)kHISymbolicHotKeyModifiers] unsignedIntValue] == CaptureModifiers) return true;
    }
    return false;
}

@interface App : NSObject <NSApplicationDelegate> {
    State _state;
    std::optional<Shortcut> _shortcut;
    EventHotKeyRef _spaceKey;
    EventHandlerRef _handler;
    NSStatusItem *_status;
    NSMenuItem *_recordItem;
    NSMenuItem *_stopItem;
    NSTimer *_timer;
    NSURL *_drafts;
    BOOL _permissionRequested;
    int _lock;
}
- (void)toggle:(id)sender;
- (void)stop:(id)sender;
- (void)shortcutPressed:(UInt32)digit;
@end

static OSStatus HotKeyHandler(EventHandlerCallRef next, EventRef event, void *pointer) {
    EventHotKeyID key = {};
    GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);
    App *app = (__bridge App *)pointer;
    if (key.signature != 0x4c434150) return eventNotHandledErr;
    if (key.id == 2) [app stop:nil]; else [app shortcutPressed:key.id];
    return noErr;
}
@implementation App
- (void)alert:(NSString *)message {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new]; alert.messageText = @"LoopCapture"; alert.informativeText = message; [alert runModal];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    // Preserve the release lock and drafts from earlier versions across updates.
    BOOL release = [bundleID isEqualToString:@"local.rahul.LoopCapture"];
    NSString *lockName = release ? @"loopcapture" : bundleID;
    _lock = open([[NSString stringWithFormat:@"/tmp/%@-%d.lock",lockName,getuid()] UTF8String],O_CREAT|O_RDWR,0600);
    if (_lock < 0 || flock(_lock,LOCK_EX|LOCK_NB)) {
        for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID])
            if (app.processIdentifier != getpid()) [app activateWithOptions:NSApplicationActivateAllWindows];
        [NSApp terminate:nil]; return;
    }
    NSString *draftsPath = release ? @"LoopCapture/Drafts" : [bundleID stringByAppendingPathComponent:@"Drafts"];
    _drafts = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask][0] URLByAppendingPathComponent:draftsPath isDirectory:YES];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:_drafts withIntermediateDirectories:YES attributes:nil error:&error]) { [self alert:error.localizedDescription]; [NSApp terminate:nil]; return; }
    NSMenu *menu = [NSMenu new];
    _recordItem = [menu addItemWithTitle:@"Record Area" action:@selector(toggle:) keyEquivalent:@""];
    _stopItem = [menu addItemWithTitle:@"Stop Recording" action:@selector(stop:) keyEquivalent:@""];
    _stopItem.hidden = YES;
    [menu addItemWithTitle:@"Try Next Recording Shortcut…" action:@selector(nextShortcut:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Screen Recording Access…" action:@selector(permissionSettings:) keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit LoopCapture" action:@selector(quit:) keyEquivalent:@"q"];
    for (NSMenuItem *item in menu.itemArray) item.target = self;
    _status = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _status.button.image = [NSImage imageWithSystemSymbolName:@"record.circle" accessibilityDescription:@"LoopCapture"];
    _status.button.toolTip = @"LoopCapture"; _status.menu = menu;
    NSMenu *main = [NSMenu new]; NSMenuItem *item = [NSMenuItem new]; item.submenu = menu; [main addItem:item]; NSApp.mainMenu = main;
    [self configureShortcut:NO];
    NSArray<NSURL *> *drafts = [NSFileManager.defaultManager contentsOfDirectoryAtURL:_drafts includingPropertiesForKeys:nil options:0 error:nil];
    for (NSURL *url in drafts) if ([url.pathExtension isEqualToString:@"mp4"]) { [self preview:url]; return; }
}
- (void)shortcutPressed:(UInt32)digit {
    if (!NSApp.modalWindow && _shortcut && (UInt32)_shortcut->digit == digit) [self toggle:nil];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(nextShortcut:))
        return std::holds_alternative<Idle>(_state) || std::holds_alternative<Reviewing>(_state);
    return YES;
}
- (void)nextShortcut:(id)sender { [self configureShortcut:YES]; }
- (void)configureShortcut:(BOOL)requested {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{@"RecordingShortcutDigit": @5}];
    NSInteger preferred = [defaults integerForKey:@"RecordingShortcutDigit"];
    if (preferred != 0 && (preferred < 5 || preferred > 9)) preferred = 5;
    OSStatus status = noErr;
    if (!_handler) {
        EventTypeSpec event = {kEventClassKeyboard,kEventHotKeyPressed};
        status = InstallEventHandler(GetApplicationEventTarget(),HotKeyHandler,1,&event,(__bridge void *)self,&_handler);
        if (status != noErr) {
            [self alert:[NSString stringWithFormat:@"Keyboard shortcuts are unavailable (macOS error %d). Use the LoopCapture menu to record and stop.",(int)status]];
            return;
        }
    }
    if (!requested && preferred == 0) return;
    int current = _shortcut ? _shortcut->digit : 0;
    int first = current ? 5 + (current-5+1)%5 : preferred ? (int)preferred : 5;
    CFArrayRef keys = nullptr;
    status = CopySymbolicHotKeys(&keys);
    NSArray *systemKeys = CFBridgingRelease(keys);
    if (status != noErr) {
        [self alert:[NSString stringWithFormat:@"Could not check system keyboard shortcuts (macOS error %d). Use Record Area in the LoopCapture menu.",(int)status]];
        return;
    }
    ShortcutResult result = FindShortcut(first,current,[&](int digit,UInt32 code,EventHotKeyRef *ref) -> OSStatus {
        if (IsSystemShortcut(systemKeys,code)) return eventHotKeyExistsErr;
        return RegisterEventHotKey(code,CaptureModifiers,{0x4c434150,(UInt32)digit},GetApplicationEventTarget(),kEventHotKeyExclusive,ref);
    });
    if (auto error = std::get_if<ShortcutError>(&result)) {
        [self alert:[NSString stringWithFormat:@"Keyboard shortcut registration failed (macOS error %d). Use Record Area in the LoopCapture menu.",(int)error->status]];
        return;
    }
    auto candidate = std::get_if<Shortcut>(&result);
    if (!candidate) {
        [self alert:current ? @"All other recording shortcuts from 5 through 9 are in use. Your current shortcut is still active." :
                              @"The recording shortcuts from ⌘⇧⌃5 through ⌘⇧⌃9 are all in use. Choose Record Area in the LoopCapture menu, or try again after changing the conflicting shortcuts."];
        return;
    }
    NSString *label = ShortcutLabel(candidate->digit);
    if (requested || candidate->digit != preferred) {
        NSAlert *offer = [NSAlert new];
        offer.messageText = [NSString stringWithFormat:@"Use %@ for LoopCapture?",label];
        offer.informativeText = !requested ? [NSString stringWithFormat:@"%@ is already in use. %@ is the next available recording shortcut.",ShortcutLabel((int)preferred),label] :
                                            @"The shortcut starts a recording selection or stops a recording.";
        [offer addButtonWithTitle:[@"Use " stringByAppendingString:label]];
        [offer addButtonWithTitle:current ? @"Keep Current Shortcut" : @"Use Menu Only"];
        [NSApp activateIgnoringOtherApps:YES];
        if ([offer runModal] != NSAlertFirstButtonReturn) {
            UnregisterEventHotKey(candidate->ref);
            if (!current) [defaults setInteger:0 forKey:@"RecordingShortcutDigit"];
            return;
        }
    }
    if (_shortcut) UnregisterEventHotKey(_shortcut->ref);
    _shortcut = *candidate;
    [defaults setInteger:candidate->digit forKey:@"RecordingShortcutDigit"];
    _recordItem.title = [@"Record Area  " stringByAppendingString:label];
    _status.button.toolTip = [@"LoopCapture - " stringByAppendingString:label];
}
- (void)toggle:(id)sender {
    if (std::holds_alternative<Idle>(_state)) [self select];
    else if (std::holds_alternative<Selecting>(_state)) _state = Idle{};
    else if (std::holds_alternative<Recording>(_state)) [self stop:nil];
    else if (auto review = std::get_if<Reviewing>(&_state)) { [review->value finish]; [self select]; }
}
- (void)select {
    BOOL authorized = CGPreflightScreenCaptureAccess();
    if (!authorized && !_permissionRequested) {
        _permissionRequested = YES;
        authorized = CGRequestScreenCaptureAccess();
    }
    if (!authorized) {
        [NSApp activateIgnoringOtherApps:YES];
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Allow screen and system audio recording";
        alert.informativeText = [NSString stringWithFormat:
            @"In System Settings, enable the app at %@ and choose Quit & Reopen if macOS asks. "
             "If an older LoopCapture entry is already enabled and recording still fails, remove that entry with the minus button, then add this copy with the plus button.",
            NSBundle.mainBundle.bundlePath];
        [alert addButtonWithTitle:@"Open Settings"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) [self permissionSettings:nil];
        return;
    }
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *candidate in NSScreen.screens) if (NSPointInRect(NSEvent.mouseLocation,candidate.frame)) screen = candidate;
    if (!screen) return;
    __weak App *weakSelf = self;
    _state = Selecting([[Selection alloc] initWithScreen:screen selected:^(NSRect rect) {
        App *self = weakSelf; if (self && std::holds_alternative<Selecting>(self->_state)) [self begin:rect screen:screen];
    } cancelled:^{ App *self = weakSelf; if (self && std::holds_alternative<Selecting>(self->_state)) self->_state = Idle{}; }]);
}
- (void)permissionSettings:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}
- (BOOL)owns:(Capture *)capture {
    if (auto active = std::get_if<Starting>(&_state)) return active->value == capture;
    if (auto active = std::get_if<Recording>(&_state)) return active->value == capture;
    if (auto active = std::get_if<Finishing>(&_state)) return active->value == capture;
    return NO;
}
- (void)begin:(NSRect)rect screen:(NSScreen *)screen {
    NSCAssert(std::holds_alternative<Selecting>(_state),@"Capture starts only from selection");
    NSUUID *token = NSUUID.UUID; _state = Preparing(token,std::get<Selecting>(_state).value);
    NSURL *url = [_drafts URLByAppendingPathComponent:[NSString stringWithFormat:@"%ld-%@.mp4",(long)NSDate.date.timeIntervalSince1970,token.UUIDString]];
    __weak App *weakSelf = self;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content,NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            App *self = weakSelf; if (!self) return;
            auto preparing = std::get_if<Preparing>(&self->_state);
            if (!preparing || ![preparing->token isEqual:token]) return;
            if (error) { self->_state = Idle{}; [self alert:error.localizedDescription]; return; }
            CGDirectDisplayID displayID = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
            SCDisplay *display = nil;
            for (SCDisplay *candidate in content.displays) if (candidate.displayID == displayID) display = candidate;
            if (!display) { self->_state = Idle{}; [self alert:@"The selected display disconnected."]; return; }
            NSError *failure = nil;
            Capture *capture = [[Capture alloc] initWithDisplay:display applications:content.applications rectangle:CaptureRect(rect,screen.frame) scale:screen.backingScaleFactor url:url error:&failure];
            if (!capture) { self->_state = Idle{}; [self alert:failure.localizedDescription]; return; }
            __weak Capture *weakCapture = capture;
            capture.started = ^{
                App *self = weakSelf; Capture *active = weakCapture;
                if (!self || !active) return;
                auto starting = std::get_if<Starting>(&self->_state);
                if (!starting || starting->value != active) return;
                self->_state = Recording(active);
                BOOL space = self->_handler && RegisterEventHotKey(49,0,{0x4c434150,2},GetApplicationEventTarget(),0,&self->_spaceKey) == noErr;
                [self showRecordingStatus:space];
            };
            capture.finished = ^{
                App *self = weakSelf; Capture *active = weakCapture;
                if (!self || !active || ![self owns:active]) return;
                [self disableRecordingControls]; [self resetRecordingStatus]; [self preview:active.url];
            };
            capture.failed = ^(NSError *failure) {
                App *self = weakSelf; Capture *active = weakCapture;
                if (!self || !active || ![self owns:active]) return;
                [self disableRecordingControls]; [self resetRecordingStatus]; self->_state = Idle{};
                [self alert:[NSString stringWithFormat:@"Recording failed.\n%@",failure.localizedDescription]];
            };
            self->_state = Starting(capture);
            [capture.stream startCaptureWithCompletionHandler:^(NSError *error) {
                if (error) dispatch_async(dispatch_get_main_queue(), ^{ if (capture.failed) capture.failed(error); });
            }];
        });
    }];
}
- (void)showRecordingStatus:(BOOL)space {
    _stopItem.title = space ? @"Stop Recording  Space" : @"Stop Recording";
    _stopItem.hidden = NO;
    _status.button.image = [NSImage imageWithSystemSymbolName:@"stop.circle.fill" accessibilityDescription:@"Recording"];
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    if (space) [keys addObject:@"Space"];
    if (_shortcut) [keys addObject:ShortcutLabel(_shortcut->digit)];
    _status.button.toolTip = keys.count ? [NSString stringWithFormat:@"Recording • %@ stops",[keys componentsJoinedByString:@" or "]] :
                                          @"Recording • Choose Stop Recording in the LoopCapture menu";
    __weak App *weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        App *self = weakSelf; if (!self) return;
        if (auto recording = std::get_if<Recording>(&self->_state)) {
            double seconds = CMTimeGetSeconds(recording->value.output.recordedDuration);
            if (isfinite(seconds)) self->_status.button.title = [NSString stringWithFormat:@" %02d:%02d",(int)seconds/60,(int)seconds%60];
        }
    }];
}
- (void)disableRecordingControls {
    _stopItem.hidden = YES;
    if (_spaceKey) UnregisterEventHotKey(_spaceKey);
    _spaceKey = NULL;
}
- (void)resetRecordingStatus {
    [_timer invalidate]; _timer = nil;
    _status.button.title = @""; _status.button.image = [NSImage imageWithSystemSymbolName:@"record.circle" accessibilityDescription:@"LoopCapture"];
    _status.button.toolTip = _shortcut ? [@"LoopCapture - " stringByAppendingString:ShortcutLabel(_shortcut->digit)] : @"LoopCapture";
}
- (void)stop:(id)sender {
    auto recording = std::get_if<Recording>(&_state); if (!recording) return;
    Capture *capture = recording->value; _state = Finishing(capture); [self disableRecordingControls];
    [capture.stream stopCaptureWithCompletionHandler:^(NSError *error) {
        if (error) dispatch_async(dispatch_get_main_queue(), ^{ if (capture.failed) capture.failed(error); });
    }];
}
- (void)preview:(NSURL *)url {
    __weak App *weakSelf = self;
    _state = Publishing(url); _status.button.title = @" Saving…";
    NSURL *folder = ScreenshotFolder();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSDateFormatter *format = [NSDateFormatter new]; format.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
            NSString *stem = [NSString stringWithFormat:@"Screen Recording %@ %@",[format stringFromDate:NSDate.date],[NSUUID.UUID.UUIDString substringToIndex:8]];
            NSURL *saved = [folder URLByAppendingPathComponent:[stem stringByAppendingPathExtension:@"mp4"]];
            BOOL success = [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&error] && SaveDraft(url,saved,&error);
            BOOL compact = YES;
            if (success) {
                [NSFileManager.defaultManager removeItemAtURL:url error:nil];
                compact = CompactMovie(saved);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                App *self = weakSelf; if (!self) return;
                auto publishing = std::get_if<Publishing>(&self->_state);
                if (!publishing || ![publishing->draft isEqual:url]) return;
                self->_status.button.title = @"";
                if (!success) {
                    self->_state = Idle{};
                    [self alert:[NSString stringWithFormat:@"Could not save to %@. Your draft is retained; reopen LoopCapture to retry.\n%@",folder.path,error.localizedDescription]];
                    return;
                }
                NSPasteboard *clipboard = NSPasteboard.generalPasteboard;
                [clipboard clearContents];
                BOOL copied = [clipboard writeObjects:@[saved]];
                Preview *preview = [[Preview alloc] initWithURL:saved];
                preview.closed = ^{ App *self = weakSelf; if (self) self->_state = Idle{}; };
                preview.failed = ^(NSString *message) { [weakSelf alert:message]; };
                self->_state = Reviewing(preview);
                if (!compact) self->_status.button.toolTip = @"Original MP4 saved at capture quality.";
                if (!copied) [self alert:@"MP4 saved. Use Copy Video to copy it."];
            });
        }
    });
}
- (void)quit:(id)sender {
    if (std::holds_alternative<Idle>(_state) || std::holds_alternative<Selecting>(_state) || std::holds_alternative<Reviewing>(_state)) [NSApp terminate:nil];
    else if (std::holds_alternative<Recording>(_state)) [self stop:nil];
    else [self toggle:nil];
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self disableRecordingControls]; if (_shortcut) UnregisterEventHotKey(_shortcut->ref); if (_handler) RemoveEventHandler(_handler);
    if (_lock >= 0) close(_lock);
}
@end

static int SelfTest() {
    auto probe = [](int first,int current,NSIndexSet *available) {
        return FindShortcut(first,current,[=](int digit,UInt32 code,EventHotKeyRef *ref) -> OSStatus {
            return [available containsIndex:digit] ? noErr : eventHotKeyExistsErr;
        });
    };
    NSIndexSet *all = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(5,5)];
    NSCAssert(std::get<Shortcut>(probe(5,0,all)).digit == 5,@"Default shortcut");
    NSCAssert(std::get<Shortcut>(probe(7,0,all)).digit == 7,@"Restore user's choice");
    NSCAssert(std::get<Shortcut>(probe(5,0,[NSIndexSet indexSetWithIndex:7])).digit == 7,@"Skip conflicts");
    NSCAssert(std::get<Shortcut>(probe(8,7,[NSIndexSet indexSetWithIndex:5])).digit == 5,@"Wrap around after 9");
    NSCAssert(std::holds_alternative<AllShortcutsTaken>(probe(5,0,[NSIndexSet indexSet])),@"Menu-only when all unavailable");
    NSCAssert(std::holds_alternative<AllShortcutsTaken>(probe(8,7,[NSIndexSet indexSetWithIndex:7])),@"Keep active binding if other four conflict");
    int attempts = 0;
    auto failure = FindShortcut(5,0,[&](int,UInt32,EventHotKeyRef *) -> OSStatus { ++attempts; return paramErr; });
    NSCAssert(std::get<ShortcutError>(failure).status == paramErr && attempts == 1,@"Report unexpected registration errors");
    NSDictionary *key = @{(__bridge NSString *)kHISymbolicHotKeyCode: @(kVK_ANSI_5),
                          (__bridge NSString *)kHISymbolicHotKeyModifiers: @(CaptureModifiers),
                          (__bridge NSString *)kHISymbolicHotKeyEnabled: @YES};
    NSCAssert(IsSystemShortcut(@[key],kVK_ANSI_5) && !IsSystemShortcut(@[key],kVK_ANSI_6),@"Respect the enabled macOS shortcut");
    NSMutableDictionary *changed = [key mutableCopy];
    changed[(__bridge NSString *)kHISymbolicHotKeyModifiers] = @(cmdKey | shiftKey);
    NSCAssert(!IsSystemShortcut(@[changed],kVK_ANSI_5),@"The native Screenshot shortcut uses different modifiers");
    changed[(__bridge NSString *)kHISymbolicHotKeyModifiers] = @(CaptureModifiers);
    changed[(__bridge NSString *)kHISymbolicHotKeyEnabled] = @NO;
    NSCAssert(!IsSystemShortcut(@[changed],kVK_ANSI_5),@"Ignore disabled system shortcuts");
    puts("PASS: shortcut selection, preference, conflicts, wraparound, exhaustion, system keyboard bindings and registration failures");
    NSCAssert(NSEqualRects(CaptureRect(NSMakeRect(-1400,-800,300,200),NSMakeRect(-1600,-900,1600,900)),NSMakeRect(200,600,300,200)),@"Secondary-display coordinates");
    NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSError *error = nil;
    NSCAssert([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error],@"Test directory");
    NSURL *source = [directory URLByAppendingPathComponent:@"draft.mp4"], *destination = [directory URLByAppendingPathComponent:@"saved.mp4"];
    NSData *data = [@"recording" dataUsingEncoding:NSUTF8StringEncoding];
    [data writeToURL:source atomically:YES];
    NSCAssert(SaveDraft(source,destination,&error) && [[NSData dataWithContentsOfURL:destination] isEqual:data],@"Save");
    [[@"old" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:destination atomically:YES];
    NSCAssert(SaveDraft(source,destination,&error) && [[NSData dataWithContentsOfURL:destination] isEqual:data],@"Overwrite");
    NSCAssert(!SaveDraft(source,[directory URLByAppendingPathComponent:@"missing/file.mp4"],&error) && [NSFileManager.defaultManager fileExistsAtPath:source.path],@"Failed save retains draft");
    [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
    puts("PASS: secondary-display coordinates, save, overwrite, failed-save draft retention");
    return 0;
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1],"--self-test")) return SelfTest();
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        App *app = [App new]; NSApp.delegate = app; [NSApp run];
    }
    return 0;
}
