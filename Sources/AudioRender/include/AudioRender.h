// SPDX-License-Identifier: GPL-3.0-or-later
//
// AudioRender — Objective-C/C real-time bridge between the sudamp pull AO and AVAudioEngine (DESIGN §5.2).
// No Swift runs on the CoreAudio IO thread: the source node's render block is ObjC and only calls C
// (sa_render_process), touching nothing but a C struct captured at creation.
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include "sa_render.h"

NS_ASSUME_NONNULL_BEGIN

/// Owns the C render state and the AVAudioSourceNode (48 kHz, stereo, deinterleaved Float32) that renders it.
/// The node's block keeps the state alive, so it stays valid for as long as either object exists.
@interface SARenderBridge : NSObject

- (instancetype)init NS_DESIGNATED_INITIALIZER;

/// The source node to attach to an AVAudioEngine. Created once; reattach it to a rebuilt engine as needed.
@property (nonatomic, readonly) AVAudioSourceNode *sourceNode;
/// 48 kHz stereo deinterleaved Float32 (`standardFormatWithSampleRate:channels:`).
@property (nonatomic, readonly) AVAudioFormat *format;
/// The C render state: call the sa_render_* functions on it from any thread.
@property (nonatomic, readonly) SARender *render;

/// The pull AO description linked into this binary ("sudamp pull AO").
+ (NSString *)aoDescription;

@end

NS_ASSUME_NONNULL_END
