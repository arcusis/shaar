// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#include <cmath>

NSString *const ARCMediaSessionMessage = @"arcusisMediaSession";
NSString *const ARCMediaActionMessage = @"arcusisMediaAction";
NSString *const ARCMediaVolumeMessage = @"arcusisMediaVolume";
NSString *const ARCAutoPictureInPictureMessage = @"arcusisAutoPictureInPicture";
NSString *const ARCPictureInPictureCommandMessage = @"arcusisPictureInPicture";

static const NSUInteger ARCMediaTextLimit = 300;
static const NSUInteger ARCMediaArtworkLimit = 2048;

// The script keeps the page's own handlers so actions behave exactly like the page's
// media keys. It falls back to the playing element only where the outcome is certain.
// When a site's automatic picture-in-picture is off it withholds the page's
// `enterpictureinpicture` handler from Chromium, whose automatic picture-in-picture
// requires that registration. Shaar's picture-in-picture controls act on the video in
// Chromium's window itself: a page's handlers may drive another element, and seeking the
// element works on every site whose video has a duration.
static const char *const ARCMediaSessionScriptSource = R"JS((function(post){
'use strict';
if(!/^(https?|file):$/.test(location.protocol))return function(){};
const apply=Reflect.apply,stringify=JSON.stringify,parse=JSON.parse,finite=Number.isFinite;
const later=setTimeout.bind(window),query=Document.prototype.querySelectorAll;
const ACTIONS=['play','pause','previoustrack','nexttrack','seekbackward','seekforward','seekto'];
const EVENTS=['play','playing','pause','ended','emptied','loadedmetadata','durationchange','volumechange',
  'enterpictureinpicture','leavepictureinpicture'];
const session=navigator.mediaSession,proto=session&&Object.getPrototypeOf(session);
const handlers=new Map(),tracked=new WeakSet();
let setAutoPictureInPicture=()=>{};
let current=null,last='',queued=false,autoPictureInPicture=true;
const playing=m=>!m.paused&&!m.ended;
const seekable=m=>!!m&&finite(m.duration)&&m.duration>0&&m.seekable.length>0;
const activeMedia=()=>{
  for(const m of apply(query,document,['video,audio']))if(playing(m))return m;
  return current;
};
const pictureInPictureVideo=()=>{
  const video=document.pictureInPictureElement;
  return video instanceof HTMLVideoElement?video:null;
};
const pictureInPictureState=()=>{
  const video=pictureInPictureVideo();
  return video?{playing:playing(video),live:video.duration===Infinity}:null;
};
const artworkOf=metadata=>{
  const list=metadata&&metadata.artwork;
  if(!list||!list.length)return '';
  try{return new URL(list[list.length-1].src,location.href).href;}catch(e){return '';}
};
const snapshot=()=>{
  const media=activeMedia(),metadata=session?session.metadata:null;
  let state=session?session.playbackState:'none';
  if(state==='none'&&media)state=playing(media)?'playing':'paused';
  if(state==='none'&&!metadata)return null;
  const supported=new Set(handlers.keys());
  if(media){supported.add('play');supported.add('pause');}
  if(seekable(media)){supported.add('seekbackward');supported.add('seekforward');supported.add('seekto');}
  return {playbackState:state,title:(metadata&&metadata.title)||document.title||'',
    artist:(metadata&&metadata.artist)||'',album:(metadata&&metadata.album)||'',
    artwork:artworkOf(metadata),actions:ACTIONS.filter(a=>supported.has(a)),
    hasVideo:!!media&&media.localName==='video'&&media.videoWidth>0,
    canSeek:supported.has('seekto'),silent:!media||media.muted||media.volume===0,
    volume:media?media.volume:null,
    pictureInPicture:pictureInPictureState()};
};
const report=()=>{
  queued=false;
  let json;
  try{json=stringify(snapshot());}catch(e){return;}
  if(json===last)return;
  last=json;
  post('arcusisMediaSession',json);
};
const schedule=()=>{if(queued)return;queued=true;later(report,150);};
const onMedia=event=>{
  const media=event.target;
  if(!(media instanceof HTMLMediaElement))return;
  if(event.type==='play'||event.type==='playing')current=media;
  schedule();
};
for(const type of EVENTS)document.addEventListener(type,onMedia,true);
const play=HTMLMediaElement.prototype.play;
HTMLMediaElement.prototype.play=function(){
  if(!this.isConnected&&!tracked.has(this)){
    tracked.add(this);
    for(const type of EVENTS)this.addEventListener(type,onMedia);
  }
  return apply(play,this,arguments);
};
if(proto){
  const wrapSetter=name=>{
    const descriptor=Object.getOwnPropertyDescriptor(proto,name);
    if(!descriptor||!descriptor.set)return;
    Object.defineProperty(proto,name,{...descriptor,set(value){apply(descriptor.set,this,[value]);schedule();}});
  };
  wrapSetter('metadata');
  wrapSetter('playbackState');
  const setActionHandler=proto.setActionHandler;
  const register=(action,handler)=>{
    const withheld=action==='enterpictureinpicture'&&!autoPictureInPicture;
    apply(setActionHandler,session,[action,withheld?null:handler]);
  };
  proto.setActionHandler=function(action,handler){
    if(this!==session)return apply(setActionHandler,this,arguments);
    const name=String(action),value=typeof handler==='function'?handler:null;
    register(name,value);
    if(value)handlers.set(name,value);
    else handlers.delete(name);
    schedule();
  };
  setAutoPictureInPicture=allowed=>{
    if(autoPictureInPicture===allowed)return;
    autoPictureInPicture=allowed;
    if(handlers.has('enterpictureinpicture'))register('enterpictureinpicture',handlers.get('enterpictureinpicture'));
  };
}
const invoke=(action,details)=>{
  const handler=handlers.get(action);
  if(!handler)return false;
  apply(handler,undefined,[Object.assign({action},details)]);
  return true;
};
const seekBy=(media,offset)=>{
  media.currentTime=Math.min(Math.max(0,media.currentTime+offset),media.duration);
};
const perform=(action,seconds)=>{
  const media=activeMedia();
  const offset=finite(seconds)&&seconds>0?seconds:10;
  switch(action){
    case 'play':if(!invoke('play')&&media)media.play();break;
    case 'pause':if(!invoke('pause')&&media)media.pause();break;
    case 'previoustrack':case 'nexttrack':invoke(action);break;
    case 'seekbackward':if(!invoke(action,{seekOffset:offset})&&seekable(media))seekBy(media,-offset);break;
    case 'seekforward':if(!invoke(action,{seekOffset:offset})&&seekable(media))seekBy(media,offset);break;
    case 'seekto':
      if(!finite(seconds)||seconds<0)break;
      if(!invoke('seekto',{seekTime:seconds})&&seekable(media))media.currentTime=Math.min(seconds,media.duration);
      break;
  }
  schedule();
};
const pictureInPicture=(command,seconds)=>{
  const video=pictureInPictureVideo();
  if(!video)return;
  if(command==='play')video.play();
  else if(command==='pause')video.pause();
  else if(command==='skip'&&finite(seconds)&&finite(video.duration))seekBy(video,seconds);
  schedule();
};
const setVolume=value=>{
  const media=activeMedia();
  if(!media||typeof value!=='number'||!finite(value)||value<0||value>1)return;
  media.volume=value;
  if(value>0)media.muted=false;
  schedule();
};
addEventListener('pagehide',()=>{last='null';post('arcusisMediaSession','null');},true);
addEventListener('pageshow',event=>{if(event.persisted){last='';schedule();}},true);
return function(kind,json){
  try{
    const message=parse(json);
    if(kind==='arcusisMediaAction')perform(String(message.action),Number(message.seconds));
    else if(kind==='arcusisMediaVolume')setVolume(message.volume);
    else if(kind==='arcusisAutoPictureInPicture')setAutoPictureInPicture(message.allowed===true);
    else if(kind==='arcusisPictureInPicture')pictureInPicture(String(message.command),Number(message.seconds));
  }catch(e){}
};
}))JS";

NSString *ARCMediaSessionPageScript(void) {
  return [NSString stringWithUTF8String:ARCMediaSessionScriptSource];
}

NSString *ARCComposedPageScript(NSArray<NSString *> *scripts) {
  if (scripts.count == 1) return scripts.firstObject;
  return [NSString stringWithFormat:
      @"(function(post){const receivers=[%@].map(install=>install(post));"
       "return function(kind,json){for(const receive of receivers)receive(kind,json);};})",
      [scripts componentsJoinedByString:@","]];
}

static NSArray<NSString *> *ARCMediaSessionActionNames(void) {
  return @[@"play", @"pause", @"previoustrack", @"nexttrack", @"seekbackward", @"seekforward", @"seekto"];
}

static NSString *ARCMediaText(id value) {
  if (![value isKindOfClass:NSString.class]) return @"";
  NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return text.length > ARCMediaTextLimit ? [text substringToIndex:ARCMediaTextLimit] : text;
}

static NSString *ARCMediaArtwork(id value) {
  if (![value isKindOfClass:NSString.class] || [(NSString *)value length] > ARCMediaArtworkLimit) return @"";
  NSURL *url = [NSURL URLWithString:value];
  NSString *scheme = url.scheme.lowercaseString;
  return url.host.length && ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) ? value : @"";
}

static NSArray<NSString *> *ARCMediaActions(id value) {
  if (![value isKindOfClass:NSArray.class]) return @[];
  NSSet *reported = [NSSet setWithArray:value];
  NSMutableArray *actions = [NSMutableArray array];
  for (NSString *name in ARCMediaSessionActionNames()) {
    if ([reported containsObject:name]) [actions addObject:name];
  }
  return actions;
}

static BOOL ARCMediaFlag(id value) {
  return [value isKindOfClass:NSNumber.class] && [value boolValue];
}

static id ARCMediaVolume(id value) {
  if (![value isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NSNull.null;
  double volume = [value doubleValue];
  return std::isfinite(volume) && volume >= 0 && volume <= 1 ? @(volume) : NSNull.null;
}

/// The video in Chromium's picture-in-picture window, or NSNull when the frame has none.
static id ARCPictureInPictureVideo(id value) {
  if (![value isKindOfClass:NSDictionary.class]) return NSNull.null;
  return @{@"playing": @(ARCMediaFlag(value[@"playing"])), @"live": @(ARCMediaFlag(value[@"live"]))};
}

/// Page messages are untrusted: keep only known keys with bounded, typed values.
static NSDictionary<NSString *, id> *ARCMediaSessionStateFromJSON(NSString *json) {
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  if (!data || data.length > 16384) return nil;
  id report = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
  if (![report isKindOfClass:NSDictionary.class]) return nil;
  NSString *playback = report[@"playbackState"];
  if (![@[@"none", @"paused", @"playing"] containsObject:playback ?: @""]) return nil;
  return @{
    @"playbackState": playback,
    @"title": ARCMediaText(report[@"title"]),
    @"artist": ARCMediaText(report[@"artist"]),
    @"album": ARCMediaText(report[@"album"]),
    @"artwork": ARCMediaArtwork(report[@"artwork"]),
    @"actions": ARCMediaActions(report[@"actions"]),
    @"hasVideo": @(ARCMediaFlag(report[@"hasVideo"])),
    @"canSeek": @(ARCMediaFlag(report[@"canSeek"])),
    @"silent": @(ARCMediaFlag(report[@"silent"])),
    @"volume": ARCMediaVolume(report[@"volume"]),
    @"pictureInPicture": ARCPictureInPictureVideo(report[@"pictureInPicture"]),
  };
}

@implementation ARCMediaSessionTracker {
  // tab -> frame -> state, plus each tab's frames in report order.
  NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSDictionary *> *> *_frames;
  NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *_order;
}

- (instancetype)init {
  if (!(self = [super init])) return nil;
  _frames = [NSMutableDictionary dictionary];
  _order = [NSMutableDictionary dictionary];
  return self;
}

- (BOOL)receiveJSON:(NSString *)json frameID:(NSString *)frameID tabID:(NSString *)tabID {
  NSDictionary *before = [self stateForTabID:tabID];
  NSDictionary *state = ARCMediaSessionStateFromJSON(json);
  NSMutableArray *order = _order[tabID] ?: [NSMutableArray array];
  [order removeObject:frameID];
  if (state) {
    if (!_frames[tabID]) _frames[tabID] = [NSMutableDictionary dictionary];
    _frames[tabID][frameID] = state;
    [order addObject:frameID];
    _order[tabID] = order;
  } else {
    [_frames[tabID] removeObjectForKey:frameID];
    if (!_frames[tabID].count) [self forgetTabID:tabID];
  }
  NSDictionary *after = [self stateForTabID:tabID];
  return !(before == after || [before isEqualToDictionary:after]);
}

/// A playing frame wins; otherwise the frame that reported most recently.
- (NSString *)frameIDForTabID:(NSString *)tabID {
  NSArray<NSString *> *order = _order[tabID];
  for (NSString *frameID in order.reverseObjectEnumerator) {
    if ([_frames[tabID][frameID][@"playbackState"] isEqualToString:@"playing"]) return frameID;
  }
  return order.lastObject;
}

/// The reduced frame's state with the picture-in-picture video of whichever frame has one.
- (NSDictionary<NSString *, id> *)stateForTabID:(NSString *)tabID {
  NSString *frameID = [self frameIDForTabID:tabID];
  if (!frameID) return nil;
  NSMutableDictionary *state = [_frames[tabID][frameID] mutableCopy];
  for (NSString *other in _order[tabID].reverseObjectEnumerator) {
    id video = _frames[tabID][other][@"pictureInPicture"];
    if ([video isKindOfClass:NSDictionary.class]) {
      state[@"pictureInPicture"] = video;
      break;
    }
  }
  return state;
}

- (NSArray<NSString *> *)frameIDsForTabID:(NSString *)tabID {
  return [_order[tabID] copy] ?: @[];
}

- (BOOL)forgetTabID:(NSString *)tabID {
  BOOL had = _frames[tabID].count > 0;
  [_frames removeObjectForKey:tabID];
  [_order removeObjectForKey:tabID];
  return had;
}

@end

static NSString *ARCMediaSessionActionName(ARCMediaSessionAction action) {
  switch (action) {
    case ARCMediaSessionActionPlay: return @"play";
    case ARCMediaSessionActionPause: return @"pause";
    case ARCMediaSessionActionPreviousTrack: return @"previoustrack";
    case ARCMediaSessionActionNextTrack: return @"nexttrack";
    case ARCMediaSessionActionSeekBackward: return @"seekbackward";
    case ARCMediaSessionActionSeekForward: return @"seekforward";
    case ARCMediaSessionActionSeekTo: return @"seekto";
  }
  return nil;
}

@implementation ARCChromiumRuntime (MediaSession)

- (NSDictionary<NSString *, id> *)mediaSessionStateForTabID:(NSString *)tabID {
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  NSDictionary *state = [_mediaSessions stateForTabID:tabID];
  if (!tab || !state) return nil;
  NSMutableDictionary *result = [state mutableCopy];
  result[@"muted"] = @(tab.muted);
  return result;
}

- (BOOL)sendMediaSessionAction:(ARCMediaSessionAction)action seconds:(double)seconds tabID:(NSString *)tabID {
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  NSString *name = ARCMediaSessionActionName(action);
  NSString *frameID = [_mediaSessions frameIDForTabID:tabID];
  NSArray *supported = [_mediaSessions stateForTabID:tabID][@"actions"];
  if (!tab || !name || !frameID || ![supported containsObject:name]) return NO;
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{
    @"action": name, @"seconds": @(std::isfinite(seconds) ? seconds : 0),
  } options:0 error:nil];
  if (!data) return NO;
  // Chromium may freeze a hidden page; an explicit control must reach it. Shaar never
  // freezes pages itself, so this only undoes the engine's background freezing.
  tab.frozen = NO;
  [tab callFrame:frameID kind:ARCMediaActionMessage
            json:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
  return YES;
}

- (BOOL)setMuted:(BOOL)muted tabID:(NSString *)tabID {
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  if (!tab) return NO;
  tab.muted = muted;
  [self publishMediaSessionForTabID:tabID];
  return YES;
}

- (BOOL)setMediaVolume:(double)volume tabID:(NSString *)tabID {
  if (!std::isfinite(volume) || volume < 0 || volume > 1) return NO;
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  NSString *frameID = [_mediaSessions frameIDForTabID:tabID];
  id current = [_mediaSessions stateForTabID:tabID][@"volume"];
  if (!tab || !frameID || ![current isKindOfClass:NSNumber.class]) return NO;
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"volume": @(volume)} options:0 error:nil];
  if (!data) return NO;
  tab.frozen = NO;
  if (volume > 0) tab.muted = NO;
  [tab callFrame:frameID kind:ARCMediaVolumeMessage
            json:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
  [self publishMediaSessionForTabID:tabID];
  return YES;
}

@end

@implementation ARCChromiumRuntime (MediaSessionSupport)

- (void)receiveMediaSessionJSON:(NSString *)json frameID:(NSString *)frameID tab:(ArdiaCoreTab *)tab {
  NSString *identity = [self identityForTab:tab];
  if (!identity || !frameID.length || tab.closed) return;
  if ([_mediaSessions receiveJSON:json frameID:frameID tabID:identity]) {
    [self publishMediaSessionForTabID:identity];
  }
}

- (void)publishMediaSessionForTabID:(NSString *)tabID {
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  if (!state || state.closing || state.closed || _closingBrowser || !self.onMediaSessionChanged) return;
  self.onMediaSessionChanged(tabID, [self mediaSessionStateForTabID:tabID]);
}

- (void)resetMediaSessionForTabID:(NSString *)tabID notify:(BOOL)notify {
  if ([_mediaSessions forgetTabID:tabID] && notify) [self publishMediaSessionForTabID:tabID];
}

@end
