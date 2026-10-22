// SPDX-License-Identifier: GPL-3.0-or-later
//
// Creates the AVAudioSourceNode whose render block forwards straight to sa_render_process (C). The block
// captures only a C pointer plus an owner object kept for lifetime, so the IO thread never sends an ObjC message,
// allocates, or runs Swift (a Swift render closure trapped on the IO thread under Swift 6, DESIGN §5.2).

#import "AudioRender.h"

#include "sudamp_ao.h"

/// Frees the C state when the last of {bridge, render block} goes away.
@interface SARenderStateOwner : NSObject
@property (nonatomic, readonly) SARender *render;
@end

@implementation SARenderStateOwner
- (instancetype)init
{
    if ((self = [super init])) {
        _render = sa_render_create();
        if (!_render)
            return nil;
    }
    return self;
}

- (void)dealloc
{
    sa_render_destroy(_render);
}
@end

@implementation SARenderBridge {
    SARenderStateOwner *_owner;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _owner = [[SARenderStateOwner alloc] init];
        if (!_owner)
            return nil;
        _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:SA_RENDER_SAMPLE_RATE channels:2];
        SARender *render = _owner.render;
        SARenderStateOwner *keepAlive = _owner;
        _sourceNode = [[AVAudioSourceNode alloc]
            initWithFormat:_format
               renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount,
                                     AudioBufferList *outputData) {
                   (void)timestamp;
                   (void)keepAlive; // captured for lifetime only; never messaged here
                   if (outputData->mNumberBuffers < 2) {
                       for (UInt32 b = 0; b < outputData->mNumberBuffers; b++)
                           memset(outputData->mBuffers[b].mData, 0, outputData->mBuffers[b].mDataByteSize);
                       *isSilence = YES;
                       return noErr;
                   }
                   bool silent = false;
                   sa_render_process(render, (float *)outputData->mBuffers[0].mData,
                                     (float *)outputData->mBuffers[1].mData, frameCount, &silent);
                   if (silent)
                       *isSilence = YES;
                   return noErr;
               }];
    }
    return self;
}

- (SARender *)render
{
    return _owner.render;
}

+ (NSString *)aoDescription
{
    return [NSString stringWithUTF8String:sudamp_ao_description()];
}

@end
