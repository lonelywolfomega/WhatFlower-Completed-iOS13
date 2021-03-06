/*
* This file is part of the SDWebImage package.
* (c) Olivier Poitrey <rs@dailymotion.com>
*
* For the full copyright and license information, please view the LICENSE
* file that was distributed with this source code.
*/

#import "SDAnimatedImagePlayer.h"
#import "NSImage+Compatibility.h"
#import "SDDisplayLink.h"
#import "SDDeviceHelper.h"
#import "SDInternalMacros.h"

@interface SDAnimatedImagePlayer () {
    NSRunLoopMode _runLoopMode;
}

@property (nonatomic, strong, readwrite) UIImage *currentFrame;
@property (nonatomic, assign, readwrite) NSUInteger currentFrameIndex;
@property (nonatomic, assign, readwrite) NSUInteger currentLoopCount;
@property (nonatomic, strong) id<SDAnimatedImageProvider> animatedProvider;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIImage *> *frameBuffer;
@property (nonatomic, assign) NSTimeInterval currentTime;
@property (nonatomic, assign) BOOL bufferMiss;
@property (nonatomic, assign) NSUInteger maxBufferCount;
@property (nonatomic, strong) NSOperationQueue *fetchQueue;
@property (nonatomic, strong) dispatch_semaphore_t lock;
@property (nonatomic, strong) SDDisplayLink *displayLink;

@end

@implementation SDAnimatedImagePlayer

- (instancetype)initWithProvider:(id<SDAnimatedImageProvider>)provider {
    self = [super init];
    if (self) {
        NSUInteger animatedImageFrameCount = provider.animatedImageFrameCount;
        // Check the frame count
        if (animatedImageFrameCount <= 1) {
            return nil;
        }
        self.totalFrameCount = animatedImageFrameCount;
        // Get the current frame and loop count.
        self.totalLoopCount = provider.animatedImageLoopCount;
        self.animatedProvider = provider;
        self.playbackRate = 1.0;
#if SD_UIKIT
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
    }
    return self;
}

+ (instancetype)playerWithProvider:(id<SDAnimatedImageProvider>)provider {
    SDAnimatedImagePlayer *player = [[SDAnimatedImagePlayer alloc] initWithProvider:provider];
    return player;
}

#pragma mark - Life Cycle

- (void)dealloc {
#if SD_UIKIT
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
}

- (void)didReceiveMemoryWarning:(NSNotification *)notification {
    [_fetchQueue cancelAllOperations];
    [_fetchQueue addOperationWithBlock:^{
        NSNumber *currentFrameIndex = @(self.currentFrameIndex);
        SD_LOCK(self.lock);
        NSArray *keys = self.frameBuffer.allKeys;
        // only keep the next frame for later rendering
        for (NSNumber * key in keys) {
            if (![key isEqualToNumber:currentFrameIndex]) {
                [self.frameBuffer removeObjectForKey:key];
            }
        }
        SD_UNLOCK(self.lock);
    }];
}

#pragma mark - Private
- (NSOperationQueue *)fetchQueue {
    if (!_fetchQueue) {
        _fetchQueue = [[NSOperationQueue alloc] init];
        _fetchQueue.maxConcurrentOperationCount = 1;
    }
    return _fetchQueue;
}

- (NSMutableDictionary<NSNumber *,UIImage *> *)frameBuffer {
    if (!_frameBuffer) {
        _frameBuffer = [NSMutableDictionary dictionary];
    }
    return _frameBuffer;
}

- (dispatch_semaphore_t)lock {
    if (!_lock) {
        _lock = dispatch_semaphore_create(1);
    }
    return _lock;
}

- (SDDisplayLink *)displayLink {
    if (!_displayLink) {
        _displayLink = [SDDisplayLink displayLinkWithTarget:self selector:@selector(displayDidRefresh:)];
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:self.runLoopMode];
    }
    return _displayLink;
}

- (void)setRunLoopMode:(NSRunLoopMode)runLoopMode {
    if ([_runLoopMode isEqual:runLoopMode]) {
        return;
    }
    if (_displayLink) {
        if (_runLoopMode) {
            [_displayLink removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:_runLoopMode];
        }
        if (runLoopMode.length > 0) {
            [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:runLoopMode];
        }
    }
    _runLoopMode = [runLoopMode copy];
}

- (NSRunLoopMode)runLoopMode {
    if (!_runLoopMode) {
        _runLoopMode = [[self class] defaultRunLoopMode];
    }
    return _runLoopMode;
}

#pragma mark - State Control

- (void)setupCurrentFrame {
    if (self.currentFrameIndex != 0) {
        return;
    }
    if ([self.animatedProvider isKindOfClass:[UIImage class]]) {
        UIImage *image = (UIImage *)self.animatedProvider;
        // Use the poster image if available
        #if SD_MAC
        UIImage *posterFrame = [[NSImage alloc] initWithCGImage:image.CGImage scale:image.scale orientation:kCGImagePropertyOrientationUp];
        #else
        UIImage *posterFrame = [[UIImage alloc] initWithCGImage:image.CGImage scale:image.scale orientation:image.imageOrientation];
        #endif
        if (posterFrame) {
            self.currentFrame = posterFrame;
            SD_LOCK(self.lock);
            self.frameBuffer[@(self.currentFrameIndex)] = self.currentFrame;
            SD_UNLOCK(self.lock);
            [self handleFrameChange];
        }
    }
}

- (void)resetCurrentFrameIndex {
    self.currentFrame = nil;
    self.currentFrameIndex = 0;
    self.currentLoopCount = 0;
    self.currentTime = 0;
    self.bufferMiss = NO;
    [self handleFrameChange];
}

- (void)clearFrameBuffer {
    SD_LOCK(self.lock);
    [_frameBuffer removeAllObjects];
    SD_UNLOCK(self.lock);
}

#pragma mark - Animation Control
- (void)startPlaying {
    [self.displayLink start];
    // Calculate max buffer size
    [self calculateMaxBufferCount];
    // Setup frame
    if (self.currentFrameIndex == 0 && !self.currentFrame) {
        [self setupCurrentFrame];
    }
}

- (void)stopPlaying {
    [_fetchQueue cancelAllOperations];
    // Using `_displayLink` here because when UIImageView dealloc, it may trigger `[self stopAnimating]`, we already release the display link in SDAnimatedImageView's dealloc method.
    [_displayLink stop];
    [self resetCurrentFrameIndex];
}

- (void)pausePlaying {
    [_fetchQueue cancelAllOperations];
    [_displayLink stop];
}

- (BOOL)isPlaying {
    return self.displayLink.isRunning;
}

- (void)seekToFrameAtIndex:(NSUInteger)index loopCount:(NSUInteger)loopCount {
    if (index >= self.totalFrameCount) {
        return;
    }
    self.currentFrameIndex = index;
    self.currentLoopCount = loopCount;
    [self handleFrameChange];
}

#pragma mark - Core Render
- (void)displayDidRefresh:(SDDisplayLink *)displayLink {
    // If for some reason a wild call makes it through when we shouldn't be animating, bail.
    // Early return!
    if (!self.isPlaying) {
        return;
    }
    // Calculate refresh duration
    NSTimeInterval duration = self.displayLink.duration;
    
    NSUInteger totalFrameCount = self.totalFrameCount;
    if (totalFrameCount <= 1) {
        // Total frame count less than 1, wrong configuration and stop animating
        [self stopPlaying];
        return;
    }
    NSUInteger currentFrameIndex = self.currentFrameIndex;
    NSUInteger nextFrameIndex = (currentFrameIndex + 1) % totalFrameCount;
    
    NSTimeInterval playbackRate = self.playbackRate;
    if (playbackRate <= 0) {
        // Does not support <= 0 play rate
        [self stopPlaying];
        return;
    }
    
    // Check if we have the frame buffer firstly to improve performance
    if (!self.bufferMiss) {
        // Then check if timestamp is reached
        self.currentTime += duration;
        NSTimeInterval currentDuration = [self.animatedProvider animatedImageDurationAtIndex:currentFrameIndex];
        currentDuration = currentDuration / playbackRate;
        if (self.currentTime < currentDuration) {
            // Current frame timestamp not reached, return
            return;
        }
        self.currentTime -= currentDuration;
        NSTimeInterval nextDuration = [self.animatedProvider animatedImageDurationAtIndex:nextFrameIndex];
        nextDuration = nextDuration / playbackRate;
        if (self.currentTime > nextDuration) {
            // Do not skip frame
            self.currentTime = nextDuration;
        }
    }
    
    // Update the current frame
    UIImage *currentFrame;
    UIImage *fetchFrame;
    SD_LOCK(self.lock);
    currentFrame = self.frameBuffer[@(currentFrameIndex)];
    fetchFrame = currentFrame ? self.frameBuffer[@(nextFrameIndex)] : nil;
    SD_UNLOCK(self.lock);
    BOOL bufferFull = NO;
    if (currentFrame) {
        SD_LOCK(self.lock);
        // Remove the frame buffer if need
        if (self.frameBuffer.count > self.maxBufferCount) {
            self.frameBuffer[@(currentFrameIndex)] = nil;
        }
        // Check whether we can stop fetch
        if (self.frameBuffer.count == totalFrameCount) {
            bufferFull = YES;
        }
        SD_UNLOCK(self.lock);
        self.currentFrame = currentFrame;
        [self handleFrameChange];
        self.currentFrameIndex = nextFrameIndex;
        self.bufferMiss = NO;
    } else {
        self.bufferMiss = YES;
    }
    
    // Update the loop count when last frame rendered
    if (nextFrameIndex == 0 && !self.bufferMiss) {
        // Update the loop count
        self.currentLoopCount++;
        [self handleLoopChnage];
        // if reached the max loop count, stop animating, 0 means loop indefinitely
        NSUInteger maxLoopCount = self.totalLoopCount;
        if (maxLoopCount != 0 && (self.currentLoopCount >= maxLoopCount)) {
            [self stopPlaying];
            return;
        }
    }
    
    // Since we support handler, check animating state again
    if (!self.isPlaying) {
        return;
    }
    
    // Check if we should prefetch next frame or current frame
    NSUInteger fetchFrameIndex;
    if (self.bufferMiss) {
        // When buffer miss, means the decode speed is slower than render speed, we fetch current miss frame
        fetchFrameIndex = currentFrameIndex;
    } else {
        // Or, most cases, the decode speed is faster than render speed, we fetch next frame
        fetchFrameIndex = nextFrameIndex;
    }
    
    if (!fetchFrame && !bufferFull && self.fetchQueue.operationCount == 0) {
        // Prefetch next frame in background queue
        id<SDAnimatedImageProvider> animatedProvider = self.animatedProvider;
        @weakify(self);
        NSOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
            @strongify(self);
            if (!self) {
                return;
            }
            UIImage *frame = [animatedProvider animatedImageFrameAtIndex:fetchFrameIndex];

            BOOL isAnimating = self.displayLink.isRunning;
            if (isAnimating) {
                SD_LOCK(self.lock);
                self.frameBuffer[@(fetchFrameIndex)] = frame;
                SD_UNLOCK(self.lock);
            }
        }];
        [self.fetchQueue addOperation:operation];
    }
}

- (void)handleFrameChange {
    if (self.animationFrameHandler) {
        self.animationFrameHandler(self.currentFrameIndex, self.currentFrame);
    }
}

- (void)handleLoopChnage {
    if (self.animationLoopHandler) {
        self.animationLoopHandler(self.currentLoopCount);
    }
}

#pragma mark - Util
- (void)calculateMaxBufferCount {
    NSUInteger bytes = CGImageGetBytesPerRow(self.currentFrame.CGImage) * CGImageGetHeight(self.currentFrame.CGImage);
    if (bytes == 0) bytes = 1024;
    
    NSUInteger max = 0;
    if (self.maxBufferSize > 0) {
        max = self.maxBufferSize;
    } else {
        // Calculate based on current memory, these factors are by experience
        NSUInteger total = [SDDeviceHelper totalMemory];
        NSUInteger free = [SDDeviceHelper freeMemory];
        max = MIN(total * 0.2, free * 0.6);
    }
    
    NSUInteger maxBufferCount = (double)max / (double)bytes;
    if (!maxBufferCount) {
        // At least 1 frame
        maxBufferCount = 1;
    }
    
    self.maxBufferCount = maxBufferCount;
}

+ (NSString *)defaultRunLoopMode {
    // Key off `activeProcessorCount` (as opposed to `processorCount`) since the system could shut down cores in certain situations.
    return [NSProcessInfo processInfo].activeProcessorCount > 1 ? NSRunLoopCommonModes : NSDefaultRunLoopMode;
}

@end
