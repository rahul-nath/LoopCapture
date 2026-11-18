#define main LoopCaptureProductMain
#include "../LoopCapture.mm"
#undef main
int main(int argc,const char **argv) {
    @autoreleasepool {
        NSCAssert(argc == 3 || (argc == 4 && !strcmp(argv[3],"--copy")),@"MP4 and GIF paths required");
        NSURL *movie = [NSURL fileURLWithPath:@(argv[1])];
        NSURL *gif = [NSURL fileURLWithPath:@(argv[2])];
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Preview *preview = [[Preview alloc] initWithURL:movie];
        NSCAssert(![NSFileManager.defaultManager fileExistsAtPath:gif.path], @"Opening preview generated a GIF");
        [preview generateGIF:nil];
        [preview generateGIF:nil];
        NSDate *deadlineGIF = [NSDate dateWithTimeIntervalSinceNow:120];
        while (!preview.gifButton.enabled && deadlineGIF.timeIntervalSinceNow > 0)
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        NSCAssert([preview.gif isEqual:gif], @"Requested GIF was not saved");
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)gif,NULL);
        NSCAssert(source && CGImageSourceGetCount(source)>1,@"Animated GIF has multiple frames");
        size_t count = CGImageSourceGetCount(source);
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyProperties(source,NULL));
        NSNumber *loops = properties[(__bridge NSString *)kCGImagePropertyGIFDictionary][(__bridge NSString *)kCGImagePropertyGIFLoopCount];
        NSCAssert(loops && loops.integerValue==0,@"GIF loops indefinitely");
        CFRelease(source);
        if (argc == 4) {
            [preview generateGIF:nil];
            NSCAssert([[NSPasteboard.generalPasteboard dataForType:UTTypeGIF.identifier] isEqualToData:[NSData dataWithContentsOfURL:gif]],@"Explicit Copy GIF");
        }
        double duration = CMTimeGetSeconds([AVURLAsset URLAssetWithURL:movie options:nil].duration);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
        NSInteger lastSeek = -1;
        while (preview.looper.loopCount<2 && [deadline timeIntervalSinceNow]>0) {
            // Long clips test the loop boundary without replaying minutes of footage.
            if (duration>5 && preview.player.currentItem.status==AVPlayerItemStatusReadyToPlay && preview.looper.loopCount!=lastSeek) {
                lastSeek = preview.looper.loopCount;
                [preview.player seekToTime:CMTimeMakeWithSeconds(duration-0.2,600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
            }
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        NSCAssert(preview.looper.loopCount>=2,@"Native preview loops twice");
        [preview finish];
        NSCAssert([NSFileManager.defaultManager fileExistsAtPath:movie.path],@"Closing preview preserves saved movie");
        printf("PASS: %zu GIF frames, infinite GIF loop, on-demand generation, %ld native preview loops, close retains clip\n",count,(long)preview.looper.loopCount);
    }
}
