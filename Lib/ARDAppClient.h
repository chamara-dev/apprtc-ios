/*
 * libjingle
 * Copyright 2014, Google Inc.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *  1. Redistributions of source code must retain the above copyright notice,
 *     this list of conditions and the following disclaimer.
 *  2. Redistributions in binary form must reproduce the above copyright notice,
 *     this list of conditions and the following disclaimer in the documentation
 *     and/or other materials provided with the distribution.
 *  3. The name of the author may not be used to endorse or promote products
 *     derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 * EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <Foundation/Foundation.h>

#import "RTCVideoTrack.h"

typedef NS_ENUM(NSInteger, ARDAppClientState) {
  // Disconnected from servers.
  kARDAppClientStateDisconnected,
  // Connecting to servers.
  kARDAppClientStateConnecting,
  // Connected to servers.
  kARDAppClientStateConnected,
};

@class ARDAppClient;
@protocol ARDAppClientDelegate <NSObject>

- (void)appClient:(ARDAppClient *)client
    didChangeState:(ARDAppClientState)state;

- (void)appClient:(ARDAppClient *)client
    didReceiveLocalVideoTrack:(RTCVideoTrack *)localVideoTrack;

- (void)appClient:(ARDAppClient *)client
    didReceiveRemoteVideoTrack:(RTCVideoTrack *)remoteVideoTrack;

- (void)appClient:(ARDAppClient *)client
         didError:(NSError *)error;

- (void)appClient:(ARDAppClient *)client
      didGetStats:(NSArray *)stats;
@end


@class ARDSignalingMessage;
@protocol ARDAppServerDelegate <NSObject>
@required
- (void)appClient:(ARDAppClient *)client messageReadyForServer:(ARDSignalingMessage *)message;
@end


// Handles connections to the AppRTC server for a given room.
@interface ARDAppClient : NSObject

// If |shouldGetStats| is true, stats will be reported in 1s intervals through
// the delegate.
@property(nonatomic, assign) BOOL shouldGetStats;
@property(nonatomic, readonly) ARDAppClientState state;
@property(nonatomic, weak) id<ARDAppClientDelegate> delegate;
@property(nonatomic, weak) id<ARDAppServerDelegate> serverDelegate;
@property(nonatomic, strong) NSString *serverHostUrl;

- (instancetype)initWithDelegate:(id<ARDAppClientDelegate>)delegate;

- (instancetype)initWithDelegate:(id<ARDAppClientDelegate>)delegate andServerDelegate:(id<ARDAppServerDelegate>)serverDelegate;

// Establishes a connection with the AppRTC servers for the given room id.
// TODO(tkchin): provide available keys/values for options. This will be used
// for call configurations such as overriding server choice, specifying codecs
// and so on.
- (void)connectToRoomWithId:(NSString *)roomId
                    options:(NSDictionary *)options;

- (void)initARDAppClientWithOption:(NSDictionary *)options;

- (void)updateRTCInitiatorStatus:(BOOL)isInitiator;

- (void)startSendOfferToCallee;

- (void)onReceivedServerMessages:(ARDSignalingMessage *)message;

- (void)startProcessSignalsFromCaller;

- (NSString *)preferVideoCodec:(NSString *)codec inSDP:(NSString *)sdpString;

- (void)orientationChanged:(NSNotification *)notification;


// Mute and unmute Audio-In
- (void)muteAudioIn;
- (void)unmuteAudioIn;
- (void) increaseMicrophoneInputGane:(int)precentage;
- (void) decreaseMicrophoneInputGane:(int)precentage;

// Mute and unmute Video-In
- (void)muteVideoIn;
- (void)unmuteVideoIn;

// Enabling / Disabling Speakerphone
- (void)enableSpeaker;
- (void)disableSpeaker;

// Swap camera functionality
- (void)swapCameraToFront;
- (void)swapCameraToBack;

// Disconnects from the AppRTC servers and any connected clients.
- (void)disconnect;

@end
