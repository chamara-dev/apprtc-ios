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

#import "ARDAppClient.h"

#import <AVFoundation/AVFoundation.h>

#import "ARDMessageResponse.h"
#import "ARDRegisterResponse.h"
#import "ARDSignalingMessage.h"
#import "ARDUtilities.h"
#import "ARDWebSocketChannel.h"
#import "RTCICECandidate+JSON.h"
#import "RTCICEServer+JSON.h"
#import "RTCMediaConstraints.h"
#import "RTCMediaStream.h"
#import "RTCPair.h"
#import "RTCPeerConnection.h"
#import "RTCPeerConnectionDelegate.h"
#import "RTCPeerConnectionFactory.h"
#import "RTCSessionDescription+JSON.h"
#import "RTCSessionDescriptionDelegate.h"
#import "RTCVideoCapturer.h"
#import "RTCVideoTrack.h"
#import "RTCStatsDelegate.h"

// TODO(tkchin): move these to a configuration object.
static NSString *kARDRoomServerHostUrl =
    @"https://apprtc.appspot.com";
static NSString *kARDRoomServerRegisterFormat =
    @"%@/join/%@";
static NSString *kARDRoomServerMessageFormat =
    @"%@/message/%@/%@";
static NSString *kARDRoomServerByeFormat =
    @"%@/leave/%@/%@";

static NSString *kARDDefaultSTUNServerUrl =
    @"stun:stun.l.google.com:19302";
// TODO(tkchin): figure out a better username for CEOD statistics.
static NSString *kARDTurnRequestUrl =
    @"https://computeengineondemand.appspot.com"
    @"/turn?username=iapprtc&key=4080218913";

static NSString *kARDAppClientErrorDomain = @"ARDAppClient";
static NSInteger kARDAppClientErrorUnknown = -1;
static NSInteger kARDAppClientErrorRoomFull = -2;
static NSInteger kARDAppClientErrorCreateSDP = -3;
static NSInteger kARDAppClientErrorSetSDP = -4;
static NSInteger kARDAppClientErrorNetwork = -5;
static NSInteger kARDAppClientErrorInvalidClient = -6;
static NSInteger kARDAppClientErrorInvalidRoom = -7;


// We need a proxy to NSTimer because it causes a strong retain cycle. When
// using the proxy, |invalidate| must be called before it properly deallocs.
@interface ARDTimerProxy : NSObject

- (instancetype)initWithInterval:(NSTimeInterval)interval
                         repeats:(BOOL)repeats
                    timerHandler:(void (^)(void))timerHandler;
- (void)invalidate;

@end

@implementation ARDTimerProxy {
    NSTimer *_timer;
    void (^_timerHandler)(void);
}

- (instancetype)initWithInterval:(NSTimeInterval)interval
                         repeats:(BOOL)repeats
                    timerHandler:(void (^)(void))timerHandler {
    NSParameterAssert(timerHandler);
    if (self = [super init]) {
        _timerHandler = timerHandler;
        _timer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                  target:self
                                                selector:@selector(timerDidFire:)
                                                userInfo:nil
                                                 repeats:repeats];
    }
    return self;
}

- (void)invalidate {
    [_timer invalidate];
}

- (void)timerDidFire:(NSTimer *)timer {
    _timerHandler();
}

@end




@interface ARDAppClient () <ARDWebSocketChannelDelegate,
    RTCPeerConnectionDelegate, RTCSessionDescriptionDelegate, RTCStatsDelegate>
@property(nonatomic, strong) ARDWebSocketChannel *channel;
@property(nonatomic, strong) RTCPeerConnection *peerConnection;
@property(nonatomic, strong) RTCPeerConnectionFactory *factory;
@property(nonatomic, strong) NSMutableArray *messageQueue;

@property(nonatomic, assign) BOOL isTurnComplete;
@property(nonatomic, assign) BOOL hasReceivedSdp;
@property(nonatomic, readonly) BOOL isRegisteredWithRoomServer;

@property(nonatomic, strong) NSString *roomId;
@property(nonatomic, strong) NSString *clientId;
@property(nonatomic, assign) BOOL isInitiator;
@property(nonatomic, assign) BOOL isSpeakerEnabled;
@property(nonatomic, assign) BOOL startProcessingSignals;
@property(nonatomic, assign) BOOL isReadyToSendOfferToCallee;
@property(nonatomic, strong) NSMutableArray *iceServers;
@property(nonatomic, strong) NSURL *webSocketURL;
@property(nonatomic, strong) NSURL *webSocketRestURL;
@property(nonatomic, strong) RTCAudioTrack *defaultAudioTrack;
@property(nonatomic, strong) RTCVideoTrack *defaultVideoTrack;
@property(nonatomic, strong) NSTimer* renegotiationTimer;
@property(nonatomic, assign) RTCICEConnectionState iceState;

@end

@implementation ARDAppClient{
    ARDTimerProxy *_statsTimer;
}

@synthesize delegate = _delegate;
@synthesize serverDelegate = _serverDelegate;
@synthesize shouldGetStats = _shouldGetStats;
@synthesize state = _state;
@synthesize serverHostUrl = _serverHostUrl;
@synthesize channel = _channel;
@synthesize peerConnection = _peerConnection;
@synthesize factory = _factory;
@synthesize messageQueue = _messageQueue;
@synthesize isTurnComplete = _isTurnComplete;
@synthesize hasReceivedSdp  = _hasReceivedSdp;
@synthesize roomId = _roomId;
@synthesize clientId = _clientId;
@synthesize isInitiator = _isInitiator;
@synthesize startProcessingSignals = _startProcessingSignals;
@synthesize isReadyToSendOfferToCallee = _isReadyToSendOfferToCallee;
@synthesize isSpeakerEnabled = _isSpeakerEnabled;
@synthesize iceServers = _iceServers;
@synthesize webSocketURL = _websocketURL;
@synthesize webSocketRestURL = _websocketRestURL;
@synthesize iceState = _iceState;

- (instancetype)initWithDelegate:(id<ARDAppClientDelegate>)delegate {
  if (self = [super init]) {
    _delegate = delegate;
    _factory = [[RTCPeerConnectionFactory alloc] init];
    _messageQueue = [NSMutableArray array];
    _iceServers = [NSMutableArray arrayWithObject:[self defaultSTUNServer]];
    _serverHostUrl = kARDRoomServerHostUrl;
    _isSpeakerEnabled = YES;
    _startProcessingSignals = YES;
    _isReadyToSendOfferToCallee = YES;
    _iceState = RTCICEConnectionNew;
      
      
      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(orientationChanged:)
                                                   name:@"UIDeviceOrientationDidChangeNotification"
                                                 object:nil];
  }
  return self;
}

- (instancetype)initWithDelegate:(id<ARDAppClientDelegate>)delegate andServerDelegate:(id<ARDAppServerDelegate>)serverDelegate{
    
    if([self initWithDelegate:delegate]){
        _serverDelegate = serverDelegate;
    }
    return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIDeviceOrientationDidChangeNotification" object:nil];
   self.shouldGetStats = NO;
  [self disconnect];
}

- (void)orientationChanged:(NSNotification *)notification {
    UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
    if (UIDeviceOrientationIsLandscape(orientation) || UIDeviceOrientationIsPortrait(orientation)) {
        //Remove current video track
        RTCMediaStream *localStream = _peerConnection.localStreams[0];
        if([localStream.videoTracks count] > 0){
            [localStream removeVideoTrack:localStream.videoTracks[0]];
        }
        
        RTCVideoTrack *localVideoTrack = [self createLocalVideoTrack];
        if (localVideoTrack) {
            [localStream addVideoTrack:localVideoTrack];
            [_delegate appClient:self didReceiveLocalVideoTrack:localVideoTrack];
        }
        [_peerConnection removeStream:localStream];
        [_peerConnection addStream:localStream];
    }
}

- (void)setShouldGetStats:(BOOL)shouldGetStats {
    if (_shouldGetStats == shouldGetStats) {
        return;
    }
    if (shouldGetStats) {
        __weak ARDAppClient *weakSelf = self;
        _statsTimer = [[ARDTimerProxy alloc] initWithInterval:2
                                                      repeats:YES
                                                 timerHandler:^{
                                                     ARDAppClient *strongSelf = weakSelf;
                                                     [strongSelf.peerConnection getStatsWithDelegate:strongSelf
                                                                                    mediaStreamTrack:nil
                                                                                    statsOutputLevel:RTCStatsOutputLevelDebug];
                                                 }];
    } else {
        [_statsTimer invalidate];
        _statsTimer = nil;
    }
    _shouldGetStats = shouldGetStats;
}

- (void)setState:(ARDAppClientState)state {
  if (_state == state) {
    return;
  }
  _state = state;
  [_delegate appClient:self didChangeState:_state];
}

- (void)connectToRoomWithId:(NSString *)roomId
                    options:(NSDictionary *)options {
  NSParameterAssert(roomId.length);
  NSParameterAssert(_state == kARDAppClientStateDisconnected);
  self.state = kARDAppClientStateConnecting;

  // Request TURN.
  __weak ARDAppClient *weakSelf = self;
  NSURL *turnRequestURL = [NSURL URLWithString:kARDTurnRequestUrl];
  [self requestTURNServersWithURL:turnRequestURL
                completionHandler:^(NSArray *turnServers) {
    ARDAppClient *strongSelf = weakSelf;
    [strongSelf.iceServers addObjectsFromArray:turnServers];
    strongSelf.isTurnComplete = YES;
    [strongSelf startSignalingIfReady];
  }];

  // Register with room server.
  [self registerWithRoomServerForRoomId:roomId
                      completionHandler:^(ARDRegisterResponse *response) {
    ARDAppClient *strongSelf = weakSelf;
    if (!response || response.result != kARDRegisterResultTypeSuccess) {
      NSLog(@"Failed to register with room server. Result:%d",
          (int)response.result);
      [strongSelf disconnect];
      NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"Room is full.",
      };
      NSError *error =
          [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                     code:kARDAppClientErrorRoomFull
                                 userInfo:userInfo];
      [strongSelf.delegate appClient:strongSelf didError:error];
      return;
    }
    NSLog(@"Registered with room server.");
    strongSelf.roomId = response.roomId;
    strongSelf.clientId = response.clientId;
    strongSelf.isInitiator = response.isInitiator;
    for (ARDSignalingMessage *message in response.messages) {
      if (message.type == kARDSignalingMessageTypeOffer ||
          message.type == kARDSignalingMessageTypeAnswer) {
        strongSelf.hasReceivedSdp = YES;
        [strongSelf.messageQueue insertObject:message atIndex:0];
      } else {
        [strongSelf.messageQueue addObject:message];
      }
    }
    strongSelf.webSocketURL = response.webSocketURL;
    strongSelf.webSocketRestURL = response.webSocketRestURL;
    [strongSelf registerWithColliderIfReady];
    [strongSelf startSignalingIfReady];
  }];
    
}

- (void)initARDAppClientWithOption:(NSDictionary *)options {
    
    NSParameterAssert(_state == kARDAppClientStateDisconnected);
    self.state = kARDAppClientStateConnecting;
    
    // Request TURN.
    __weak ARDAppClient *weakSelf = self;
    NSURL *turnRequestURL = [NSURL URLWithString:kARDTurnRequestUrl];
    [self requestTURNServersWithURL:turnRequestURL
                  completionHandler:^(NSArray *turnServers) {
                      ARDAppClient *strongSelf = weakSelf;
                      [strongSelf.iceServers addObjectsFromArray:turnServers];
                      strongSelf.isTurnComplete = YES;
                      [strongSelf startSignalingIfReady];
                  }];
    weakSelf.isInitiator = [[options objectForKey:@"isInitiator"] boolValue];
    weakSelf.startProcessingSignals = [[options objectForKey:@"startMessageProcessing"] boolValue];
    weakSelf.isReadyToSendOfferToCallee = [[options objectForKey:@"isReadyToSendOffer"] boolValue];
    [weakSelf startSignalingIfReady];
}

- (void)updateRTCInitiatorStatus:(BOOL)isInitiator{
    self.isInitiator = isInitiator;
}

- (void)startProcessSignalsFromCaller{
    self.startProcessingSignals = TRUE;
    self.isReadyToSendOfferToCallee = TRUE;
    [self drainMessageQueueIfReady];
}

- (void)startSendOfferToCallee{
    self.isReadyToSendOfferToCallee = TRUE;
    self.startProcessingSignals = TRUE;
    [self sendOffer];
}

- (void)disconnect {
  if (_state == kARDAppClientStateDisconnected) {
    return;
  }
  if (self.isRegisteredWithRoomServer && (self.iceState != RTCICEConnectionDisconnected && self.iceState != RTCICEConnectionFailed)) {
    [self unregisterWithRoomServer];
  }
  if (_channel) {
    if (_channel.state == kARDWebSocketChannelStateRegistered) {
      // Tell the other client we're hanging up.
      ARDByeMessage *byeMessage = [[ARDByeMessage alloc] init];
      NSData *byeData = [byeMessage JSONData];
      [_channel sendData:byeData];
    }
    // Disconnect from collider.
    _channel = nil;
  }
    
  _clientId = nil;
  _roomId = nil;
  _isInitiator = NO;
  _hasReceivedSdp = NO;
  _messageQueue = [NSMutableArray array];
  _peerConnection = nil;
  self.state = kARDAppClientStateDisconnected;
}

- (void) onReceivedServerMessages:(ARDSignalingMessage *)message {
    
    switch (message.type) {
        case kARDSignalingMessageTypeOffer:
        case kARDSignalingMessageTypeAnswer:
            _hasReceivedSdp = YES;
            [_messageQueue insertObject:message atIndex:0];
            break;
        case kARDSignalingMessageTypeCandidate:
            [_messageQueue addObject:message];
            break;
        case kARDSignalingMessageTypeBye:
            [self processSignalingMessage:message];
            return;
    }
    [self drainMessageQueueIfReady];
}

#pragma mark - ARDWebSocketChannelDelegate

- (void)channel:(ARDWebSocketChannel *)channel
    didReceiveMessage:(ARDSignalingMessage *)message {
    
    NSLog(@"didReceiveMessage:%i", message.type);
    
  switch (message.type) {
    case kARDSignalingMessageTypeOffer:
    case kARDSignalingMessageTypeAnswer:
      _hasReceivedSdp = YES;
      [_messageQueue insertObject:message atIndex:0];
      break;
    case kARDSignalingMessageTypeCandidate:
      [_messageQueue addObject:message];
      break;
    case kARDSignalingMessageTypeBye:
      [self processSignalingMessage:message];
      return;
  }
  [self drainMessageQueueIfReady];
}

- (void)channel:(ARDWebSocketChannel *)channel
    didChangeState:(ARDWebSocketChannelState)state {
  switch (state) {
    case kARDWebSocketChannelStateOpen:
      break;
    case kARDWebSocketChannelStateRegistered:
      break;
    case kARDWebSocketChannelStateClosed:
    case kARDWebSocketChannelStateError:
      // TODO(tkchin): reconnection scenarios. Right now we just disconnect
      // completely if the websocket connection fails.
      [self disconnect];
      break;
  }
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    signalingStateChanged:(RTCSignalingState)stateChanged {
  NSLog(@"Signaling state changed: %d", stateChanged);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
           addedStream:(RTCMediaStream *)stream {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"Received %lu video tracks and %lu audio tracks",
        (unsigned long)stream.videoTracks.count,
        (unsigned long)stream.audioTracks.count);
    if (stream.videoTracks.count) {
      RTCVideoTrack *videoTrack = stream.videoTracks[0];
      [_delegate appClient:self didReceiveRemoteVideoTrack:videoTrack];
      if (_isSpeakerEnabled) [self enableSpeaker]; //Use the "handsfree" speaker instead of the ear speaker.

    }
  });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
        removedStream:(RTCMediaStream *)stream {
  NSLog(@"Stream was removed.");
}

- (void)peerConnectionOnRenegotiationNeeded:
    (RTCPeerConnection *)peerConnection {
    NSLog(@"Renegotiation :%d", peerConnection.iceConnectionState);
    if(peerConnection.iceConnectionState == RTCICEConnectionCompleted){
        NSLog(@"send offer again");
        [self.renegotiationTimer invalidate];
        self.renegotiationTimer = nil;
        self.renegotiationTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(sendOffer) userInfo:nil repeats:NO];
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    iceConnectionChanged:(RTCICEConnectionState)newState {
    NSLog(@"ICE state changed: %d", newState);
    self.iceState = newState;
    if((newState == RTCICEConnectionDisconnected) || (newState == RTCICEConnectionFailed)){
        NSLog(@"ICE Disconnected or Failed");
        dispatch_async(dispatch_get_main_queue(), ^{
            //Have to implement proper delegate method to dismiss the videochatview
            [self.delegate appClient:self didError:nil];
        });
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    iceGatheringChanged:(RTCICEGatheringState)newState {
  NSLog(@"ICE gathering state changed: %d", newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
       gotICECandidate:(RTCICECandidate *)candidate {
  dispatch_async(dispatch_get_main_queue(), ^{
    ARDICECandidateMessage *message =
        [[ARDICECandidateMessage alloc] initWithCandidate:candidate];
    [self sendSignalingMessage:message];
  });
}

- (void)peerConnection:(RTCPeerConnection*)peerConnection
    didOpenDataChannel:(RTCDataChannel*)dataChannel {
}

#pragma mark - RTCStatsDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection
           didGetStats:(NSArray *)stats {
    dispatch_async(dispatch_get_main_queue(), ^{
        [_delegate appClient:self didGetStats:stats];
    });
}


#pragma mark - RTCSessionDescriptionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didCreateSessionDescription:(RTCSessionDescription *)sdp
                          error:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (error) {
      NSLog(@"Failed to create session description. Error: %@", error);
      [self disconnect];
      NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"Failed to create session description.",
      };
      NSError *sdpError =
          [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                     code:kARDAppClientErrorCreateSDP
                                 userInfo:userInfo];
      [_delegate appClient:self didError:sdpError];
      return;
    }

      NSString *sdpString = [self preferVideoCodec:@"H264" inSDP:sdp.description];
      RTCSessionDescription *updatedSDP = [[RTCSessionDescription alloc] initWithType:sdp.type sdp:sdpString];
      [_peerConnection setLocalDescriptionWithDelegate:self
                                    sessionDescription:updatedSDP];
      ARDSessionDescriptionMessage *message =
      [[ARDSessionDescriptionMessage alloc] initWithDescription:updatedSDP];
      [self sendSignalingMessage:message];
  });
}

- (NSString *)preferVideoCodec:(NSString *)codec inSDP:(NSString *)sdpString
{
    NSString *lineSeparator = @"\n";
    NSString *mLineSeparator = @" ";
    // Copied from PeerConnectionClient.java.
    // TODO(tkchin): Move this to a shared C++ file.
    NSMutableArray *lines = [NSMutableArray arrayWithArray:[sdpString componentsSeparatedByString:lineSeparator]];
    NSInteger mLineIndex = -1;
    NSString *codecRtpMap = nil;
    // a=rtpmap:<payload type> <encoding name>/<clock rate>
    // [/<encoding parameters>]
    NSString *pattern = [NSString stringWithFormat:@"^a=rtpmap:(\\d+) %@(/\\d+)+[\r]?$", codec];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                           options:0
                                                                             error:nil];
    for (NSInteger i = 0; (i < lines.count) && (mLineIndex == -1 || !codecRtpMap); ++i) {
        NSString *line = lines[i];
        if ([line hasPrefix:@"m=video"]) {
            mLineIndex = i;
            continue;
        }
        NSTextCheckingResult *codecMatches = [regex firstMatchInString:line
                                                               options:0
                                                                 range:NSMakeRange(0, line.length)];
        if (codecMatches) {
            codecRtpMap = [line substringWithRange:[codecMatches rangeAtIndex:1]];
            continue;
        }
    }
    
    if (mLineIndex == -1) {
        NSLog(@"No m=video line, so can't prefer %@", codec);
        return sdpString;
    }
    
    if (!codecRtpMap) {
        NSLog(@"No rtpmap for %@", codec);
        return sdpString;
    }
    
    NSArray *origMLineParts = [lines[mLineIndex] componentsSeparatedByString:mLineSeparator];
    
    if (origMLineParts.count > 3) {
        NSMutableArray *newMLineParts = [NSMutableArray arrayWithCapacity:origMLineParts.count];
        NSInteger origPartIndex = 0;
        
        // Format is: m=<media> <port> <proto> <fmt> ...
        [newMLineParts addObject:origMLineParts[origPartIndex++]];
        [newMLineParts addObject:origMLineParts[origPartIndex++]];
        [newMLineParts addObject:origMLineParts[origPartIndex++]];
        [newMLineParts addObject:codecRtpMap];
        
        for (; origPartIndex < origMLineParts.count; ++origPartIndex) {
            if (![codecRtpMap isEqualToString:origMLineParts[origPartIndex]]) {
                [newMLineParts addObject:origMLineParts[origPartIndex]];
            }
        }
        NSString *newMLine = [newMLineParts componentsJoinedByString:mLineSeparator];
        [lines replaceObjectAtIndex:mLineIndex withObject:newMLine];
    }
    else {
        NSLog(@"Wrong SDP media description format: %@", lines[mLineIndex]);
    }
    
    return [lines componentsJoinedByString:lineSeparator];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didSetSessionDescriptionWithError:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (error) {
      NSLog(@"Failed to set session description. Error: %@", error);
      [self disconnect];
      NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"Failed to set session description.",
      };
      NSError *sdpError =
          [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                     code:kARDAppClientErrorSetSDP
                                 userInfo:userInfo];
      [_delegate appClient:self didError:sdpError];
      return;
    }
    // If we're answering and we've just set the remote offer we need to create
    // an answer and set the local description.
    if (!_isInitiator && !_peerConnection.localDescription) {
      RTCMediaConstraints *constraints = [self defaultAnswerConstraints];
      [_peerConnection createAnswerWithDelegate:self
                                    constraints:constraints];

    }
  });
}

#pragma mark - Private

- (BOOL)isRegisteredWithRoomServer {
    if(self.serverDelegate){
        return TRUE;
    }else{
        return _clientId.length;
    }
}

- (void)startSignalingIfReady {
  if (!_isTurnComplete || !self.isRegisteredWithRoomServer) {
    return;
  }
  self.state = kARDAppClientStateConnected;

  // Create peer connection.
  RTCMediaConstraints *constraints = [self defaultPeerConnectionConstraints];
  _peerConnection = [_factory peerConnectionWithICEServers:_iceServers
                                               constraints:constraints
                                                  delegate:self];
  RTCMediaStream *localStream = [self createLocalMediaStream];
  [_peerConnection addStream:localStream];

  if (_isInitiator && self.isReadyToSendOfferToCallee) {
    [self sendOffer];
  } else {
    [self waitForAnswer];
  }
}

- (void)sendOffer {
  [_peerConnection createOfferWithDelegate:self
                               constraints:[self defaultOfferConstraints]];
}

- (void)waitForAnswer {
  [self drainMessageQueueIfReady];
}

- (void)drainMessageQueueIfReady {
  if (!_peerConnection || !_hasReceivedSdp || !_startProcessingSignals) {
    return;
  }
  for (ARDSignalingMessage *message in _messageQueue) {
    [self processSignalingMessage:message];
  }
  [_messageQueue removeAllObjects];
}

- (void)processSignalingMessage:(ARDSignalingMessage *)message {
  NSParameterAssert(_peerConnection ||
      message.type == kARDSignalingMessageTypeBye);
  switch (message.type) {
    case kARDSignalingMessageTypeOffer:
    case kARDSignalingMessageTypeAnswer: {
      ARDSessionDescriptionMessage *sdpMessage =
          (ARDSessionDescriptionMessage *)message;
      RTCSessionDescription *description = sdpMessage.sessionDescription;
      [_peerConnection setRemoteDescriptionWithDelegate:self
                                     sessionDescription:description];
      break;
    }
    case kARDSignalingMessageTypeCandidate: {
      ARDICECandidateMessage *candidateMessage =
          (ARDICECandidateMessage *)message;
      [_peerConnection addICECandidate:candidateMessage.candidate];
      break;
    }
    case kARDSignalingMessageTypeBye:
      // Other client disconnected.
      // TODO(tkchin): support waiting in room for next client. For now just
      // disconnect.
      [self disconnect];
      break;
  }
}

- (void)sendSignalingMessage:(ARDSignalingMessage *)message {
    
  if (_isInitiator) {
      if(self.serverDelegate){
          [self.serverDelegate appClient:self messageReadyForServer:message];
      }else{
          [self sendSignalingMessageToRoomServer:message completionHandler:nil];
      }
  } else {
      if (self.serverDelegate) {
          [self.serverDelegate appClient:self messageReadyForServer:message];
      }else{
          [self sendSignalingMessageToCollider:message];
      }
  }
}


- (RTCVideoTrack *)createLocalVideoTrack {
    // The iOS simulator doesn't provide any sort of camera capture
    // support or emulation (http://goo.gl/rHAnC1) so don't bother
    // trying to open a local stream.
    // TODO(tkchin): local video capture for OSX. See
    // https://code.google.com/p/webrtc/issues/detail?id=3417.

    RTCVideoTrack *localVideoTrack = nil;
#if !TARGET_IPHONE_SIMULATOR && TARGET_OS_IPHONE

    NSString *cameraID = nil;
    for (AVCaptureDevice *captureDevice in
         [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if (captureDevice.position == AVCaptureDevicePositionFront) {
            cameraID = [captureDevice localizedName];
            break;
        }
    }
    NSAssert(cameraID, @"Unable to get the front camera id");
    
    RTCVideoCapturer *capturer = [RTCVideoCapturer capturerWithDeviceName:cameraID];
    RTCMediaConstraints *mediaConstraints = [self defaultMediaStreamConstraints];
    RTCVideoSource *videoSource = [_factory videoSourceWithCapturer:capturer constraints:mediaConstraints];
    localVideoTrack = [_factory videoTrackWithID:@"ARDAMSv0" source:videoSource];
#endif
    return localVideoTrack;
}

- (RTCMediaStream *)createLocalMediaStream {
    RTCMediaStream* localStream = [_factory mediaStreamWithLabel:@"ARDAMS"];

    RTCVideoTrack *localVideoTrack = [self createLocalVideoTrack];
    if (localVideoTrack) {
        [localStream addVideoTrack:localVideoTrack];
        [_delegate appClient:self didReceiveLocalVideoTrack:localVideoTrack];
    }
    
    [localStream addAudioTrack:[_factory audioTrackWithID:@"ARDAMSa0"]];
    if (_isSpeakerEnabled) [self enableSpeaker];
    return localStream;
}

- (void)requestTURNServersWithURL:(NSURL *)requestURL
    completionHandler:(void (^)(NSArray *turnServers))completionHandler {
  NSParameterAssert([requestURL absoluteString].length);
  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:requestURL];
  // We need to set origin because TURN provider whitelists requests based on
  // origin.
  [request addValue:@"Mozilla/5.0" forHTTPHeaderField:@"user-agent"];
  [request addValue:self.serverHostUrl forHTTPHeaderField:@"origin"];
  [NSURLConnection sendAsyncRequest:request
                  completionHandler:^(NSURLResponse *response,
                                      NSData *data,
                                      NSError *error) {
    NSArray *turnServers = [NSArray array];
    if (error) {
      NSLog(@"Unable to get TURN server.");
      completionHandler(turnServers);
      return;
    }
    NSDictionary *dict = [NSDictionary dictionaryWithJSONData:data];
    turnServers = [RTCICEServer serversFromCEODJSONDictionary:dict];
    completionHandler(turnServers);
  }];
}

#pragma mark - Room server methods

- (void)registerWithRoomServerForRoomId:(NSString *)roomId
    completionHandler:(void (^)(ARDRegisterResponse *))completionHandler {
  NSString *urlString =
      [NSString stringWithFormat:kARDRoomServerRegisterFormat, self.serverHostUrl, roomId];
  NSURL *roomURL = [NSURL URLWithString:urlString];
  NSLog(@"Registering with room server.");
  __weak ARDAppClient *weakSelf = self;
  [NSURLConnection sendAsyncPostToURL:roomURL
                             withData:nil
                    completionHandler:^(BOOL succeeded, NSData *data) {
    ARDAppClient *strongSelf = weakSelf;
    if (!succeeded) {
      NSError *error = [self roomServerNetworkError];
      [strongSelf.delegate appClient:strongSelf didError:error];
      completionHandler(nil);
      return;
    }
    ARDRegisterResponse *response =
        [ARDRegisterResponse responseFromJSONData:data];
    completionHandler(response);
  }];
}

- (void)sendSignalingMessageToRoomServer:(ARDSignalingMessage *)message
    completionHandler:(void (^)(ARDMessageResponse *))completionHandler {
  NSData *data = [message JSONData];
  NSString *urlString =
      [NSString stringWithFormat:
          kARDRoomServerMessageFormat, self.serverHostUrl, _roomId, _clientId];
  NSURL *url = [NSURL URLWithString:urlString];
  NSLog(@"C->RS POST: %@", message);
  __weak ARDAppClient *weakSelf = self;
  [NSURLConnection sendAsyncPostToURL:url
                             withData:data
                    completionHandler:^(BOOL succeeded, NSData *data) {
    ARDAppClient *strongSelf = weakSelf;
    if (!succeeded) {
      NSError *error = [self roomServerNetworkError];
      [strongSelf.delegate appClient:strongSelf didError:error];
      return;
    }
    ARDMessageResponse *response =
        [ARDMessageResponse responseFromJSONData:data];
    NSError *error = nil;
    switch (response.result) {
      case kARDMessageResultTypeSuccess:
        break;
      case kARDMessageResultTypeUnknown:
        error =
            [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                       code:kARDAppClientErrorUnknown
                                   userInfo:@{
          NSLocalizedDescriptionKey: @"Unknown error.",
        }];
      case kARDMessageResultTypeInvalidClient:
        error =
            [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                       code:kARDAppClientErrorInvalidClient
                                   userInfo:@{
          NSLocalizedDescriptionKey: @"Invalid client.",
        }];
        break;
      case kARDMessageResultTypeInvalidRoom:
        error =
            [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                       code:kARDAppClientErrorInvalidRoom
                                   userInfo:@{
          NSLocalizedDescriptionKey: @"Invalid room.",
        }];
        break;
    };
    if (error) {
      [strongSelf.delegate appClient:strongSelf didError:error];
    }
    if (completionHandler) {
      completionHandler(response);
    }
  }];
}

- (void)unregisterWithRoomServer {
    
    if(self.serverDelegate){
        [self.serverDelegate appClient:self messageReadyForServer:[[ARDByeMessage alloc] init]];
    }else{
        NSString *urlString =
        [NSString stringWithFormat:kARDRoomServerByeFormat, self.serverHostUrl, _roomId, _clientId];
        NSURL *url = [NSURL URLWithString:urlString];
        NSLog(@"C->RS: BYE");
        //Make sure to do a POST
        [NSURLConnection sendAsyncPostToURL:url withData:nil completionHandler:^(BOOL succeeded, NSData *data) {
            if (succeeded) {
                NSLog(@"Unregistered from room server.");
            } else {
                NSLog(@"Failed to unregister from room server.");
            }
        }];
    }
}

- (NSError *)roomServerNetworkError {
  NSError *error =
      [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                 code:kARDAppClientErrorNetwork
                             userInfo:@{
    NSLocalizedDescriptionKey: @"Room server network error",
  }];
  return error;
}

#pragma mark - Collider methods

- (void)registerWithColliderIfReady {
  if (!self.isRegisteredWithRoomServer) {
    return;
  }
  // Open WebSocket connection.
  _channel =
      [[ARDWebSocketChannel alloc] initWithURL:_websocketURL
                                       restURL:_websocketRestURL
                                      delegate:self];
  [_channel registerForRoomId:_roomId clientId:_clientId];
}

- (void)sendSignalingMessageToCollider:(ARDSignalingMessage *)message {
  NSData *data = [message JSONData];
  [_channel sendData:data];
}

#pragma mark - Defaults

- (RTCMediaConstraints *)defaultMediaStreamConstraints {
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc]
          initWithMandatoryConstraints:nil
                   optionalConstraints:nil];
  return constraints;
}

- (RTCMediaConstraints *)defaultAnswerConstraints {
  return [self defaultOfferConstraints];
}

- (RTCMediaConstraints *)defaultOfferConstraints {
  NSArray *mandatoryConstraints = @[
      [[RTCPair alloc] initWithKey:@"OfferToReceiveAudio" value:@"true"],
      [[RTCPair alloc] initWithKey:@"OfferToReceiveVideo" value:@"true"]
  ];
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc]
          initWithMandatoryConstraints:mandatoryConstraints
                   optionalConstraints:nil];
  return constraints;
}

- (RTCMediaConstraints *)defaultPeerConnectionConstraints {
  NSArray *optionalConstraints = @[
      [[RTCPair alloc] initWithKey:@"DtlsSrtpKeyAgreement" value:@"true"]
  ];
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc]
          initWithMandatoryConstraints:nil
                   optionalConstraints:optionalConstraints];
  return constraints;
}

- (RTCICEServer *)defaultSTUNServer {
  NSURL *defaultSTUNServerURL = [NSURL URLWithString:kARDDefaultSTUNServerUrl];
  return [[RTCICEServer alloc] initWithURI:defaultSTUNServerURL
                                  username:@""
                                  password:@""];
}

#pragma mark - Audio mute/unmute
- (void)muteAudioIn {
    NSLog(@"audio muted");
    RTCMediaStream *localStream = _peerConnection.localStreams[0];
    self.defaultAudioTrack = localStream.audioTracks[0];
    [localStream removeAudioTrack:localStream.audioTracks[0]];
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
}
- (void)unmuteAudioIn {
    NSLog(@"audio unmuted");
    RTCMediaStream* localStream = _peerConnection.localStreams[0];
    [localStream addAudioTrack:self.defaultAudioTrack];
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
    if (_isSpeakerEnabled) [self enableSpeaker];
}

#pragma mark - Video mute/unmute
- (void)muteVideoIn {
    NSLog(@"video muted");
#if !TARGET_OS_SIMULATOR && TARGET_OS_IPHONE
    RTCMediaStream *localStream = _peerConnection.localStreams[0];
    self.defaultVideoTrack = localStream.videoTracks[0];
    [localStream removeVideoTrack:localStream.videoTracks[0]];
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
#endif
}
- (void)unmuteVideoIn {
    NSLog(@"video unmuted");
#if !TARGET_OS_SIMULATOR && TARGET_OS_IPHONE
    RTCMediaStream* localStream = _peerConnection.localStreams[0];
    [_peerConnection removeStream:localStream];
    [localStream addVideoTrack:self.defaultVideoTrack];
    [_peerConnection addStream:localStream];
#endif
}

#pragma mark - swap camera
- (RTCVideoTrack *)createLocalVideoTrackBackCamera {
    RTCVideoTrack *localVideoTrack = nil;
#if !TARGET_IPHONE_SIMULATOR && TARGET_OS_IPHONE
    //AVCaptureDevicePositionFront
    NSString *cameraID = nil;
    for (AVCaptureDevice *captureDevice in
         [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if (captureDevice.position == AVCaptureDevicePositionBack) {
            cameraID = [captureDevice localizedName];
            break;
        }
    }
    NSAssert(cameraID, @"Unable to get the back camera id");
    
    RTCVideoCapturer *capturer = [RTCVideoCapturer capturerWithDeviceName:cameraID];
    RTCMediaConstraints *mediaConstraints = [self defaultMediaStreamConstraints];
    RTCVideoSource *videoSource = [_factory videoSourceWithCapturer:capturer constraints:mediaConstraints];
    localVideoTrack = [_factory videoTrackWithID:@"ARDAMSv0" source:videoSource];
#endif
    return localVideoTrack;
}
- (void)swapCameraToFront{
#if !TARGET_OS_SIMULATOR && TARGET_OS_IPHONE
    
    RTCMediaStream *localStream = _peerConnection.localStreams[0];
    if([localStream.videoTracks count] == 0) return; // swap camera is disabled if video source is not available
    [localStream removeVideoTrack:localStream.videoTracks[0]];
    
    RTCVideoTrack *localVideoTrack = [self createLocalVideoTrack];

    if (localVideoTrack) {
        [localStream addVideoTrack:localVideoTrack];
        [_delegate appClient:self didReceiveLocalVideoTrack:localVideoTrack];
    }
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
#endif
}
- (void)swapCameraToBack{
#if !TARGET_OS_SIMULATOR && TARGET_OS_IPHONE
    RTCMediaStream *localStream = _peerConnection.localStreams[0];
    if([localStream.videoTracks count] == 0) return;// swap camera is disabled if video source is not available
    [localStream removeVideoTrack:localStream.videoTracks[0]];
    
    RTCVideoTrack *localVideoTrack = [self createLocalVideoTrackBackCamera];
    
    if (localVideoTrack) {
        [localStream addVideoTrack:localVideoTrack];
        [_delegate appClient:self didReceiveLocalVideoTrack:localVideoTrack];
    }
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
#endif
}

#pragma mark - enable/disable speaker

- (void)enableSpeaker {
    [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil];
    _isSpeakerEnabled = YES;
}

- (void)disableSpeaker {
    [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:nil];
    _isSpeakerEnabled = NO;
}

- (void) increaseMicrophoneInputGane:(int)precentage{
    
    float gain= ((precentage > 100) ? 100 :  precentage)/100.00;
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    //if (audioSession.isInputGainSettable) {
        NSError *error = nil;
        BOOL success = [audioSession setInputGain:gain error:&error];
        if (!success) {
            NSLog(@"increaseMicrophoneInputGane:%@", error);
        }
    //}
    //else {
    //    NSLog(@"Cannot set input gain");
    //}
}

- (void) decreaseMicrophoneInputGane:(int)precentage{
    
    float gain= ((precentage < 0) ? 0 :  precentage)/100.00;
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    //if (audioSession.isInputGainSettable) {
        NSError *error = nil;
        BOOL success = [audioSession setInputGain:gain error:&error];
        if (!success) {
            NSLog(@"decreaseMicrophoneInputGane:%@", error);
        }
    //}
    //else {
    //    NSLog(@"Cannot set input gain");
    //}
}


@end
