// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumMediaSession.h"
#import "ChromiumShaarFeatureTransport.h"
#import <objc/runtime.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cmath>

NSString *const ARCMediaSessionMessage = @"arcusisMediaSession";
NSString *const ARCMediaActionMessage = @"arcusisMediaAction";
NSString *const ARCMediaVolumeMessage = @"arcusisMediaVolume";
NSString *const ARCAutoPictureInPictureMessage = @"arcusisAutoPictureInPicture";
NSString *const ARCPictureInPictureCommandMessage = @"arcusisPictureInPicture";

static const NSUInteger ARCMediaTextLimit = 300;
static const NSUInteger ARCMediaArtworkLimit = 2048;

static BOOL ARCMediaIsJSONBoolean(id value) {
  return [value isKindOfClass:NSNumber.class] &&
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

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
// A live video can gain decoded dimensions after the first playing report.
const EVENTS=['play','playing','pause','ended','emptied','loadedmetadata','resize','durationchange','volumechange',
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
  return ARCMediaIsJSONBoolean(value) && [value boolValue];
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

static const void *ShaarMediaCacheKey = &ShaarMediaCacheKey;
static const void *ShaarMediaRefreshKey = &ShaarMediaRefreshKey;
static const void *ShaarMediaPipKey = &ShaarMediaPipKey;
static NSString *ARCMediaSessionActionName(ARCMediaSessionAction action);

static NSMutableDictionary *ShaarMediaCache(ARCShaarRuntime *runtime, const void *key) {
  NSMutableDictionary *cache = objc_getAssociatedObject(runtime, key);
  if (!cache) {
    cache = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(runtime, key, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return cache;
}

static NSString *ShaarMediaActionName(NSNumber *command) {
  if (![command isKindOfClass:NSNumber.class]) return nil;
  switch (command.intValue) {
    case SHAAR_MEDIA_PLAY: return @"play";
    case SHAAR_MEDIA_PAUSE: return @"pause";
    case SHAAR_MEDIA_PREVIOUS_TRACK: return @"previoustrack";
    case SHAAR_MEDIA_NEXT_TRACK: return @"nexttrack";
    case SHAAR_MEDIA_SEEK_BACKWARD: return @"seekbackward";
    case SHAAR_MEDIA_SEEK_FORWARD: return @"seekforward";
    case SHAAR_MEDIA_SEEK_TO: return @"seekto";
    default: return nil;
  }
}

NSDictionary<NSString *, id> *ARCShaarMediaPublicState(NSDictionary<NSString *, id> *native) {
  if (![native[@"schemaVersion"] isEqual:@1]) return nil;
  NSString *playback = native[@"playbackState"];
  if (![playback isKindOfClass:NSString.class] ||
      ![@[@"none", @"paused", @"playing"] containsObject:playback]) return nil;
  NSMutableArray *actions = [NSMutableArray array];
  NSArray *supported = [native[@"supportedActions"] isKindOfClass:NSArray.class]
      ? native[@"supportedActions"] : @[];
  for (id command in supported) {
    NSString *name = ShaarMediaActionName(command);
    if (name) [actions addObject:name];
  }
  NSMutableDictionary *state = [@{
    @"playbackState": playback,
    @"title": ARCMediaText(native[@"title"]),
    @"artist": ARCMediaText(native[@"artist"]),
    @"album": ARCMediaText(native[@"album"]),
    @"artwork": ARCMediaArtwork(native[@"artwork"]),
    @"actions": actions, @"hasVideo": @(ARCMediaFlag(native[@"hasVideo"])),
    @"canSeek": @(ARCMediaFlag(native[@"canSeek"])),
    @"muted": @(ARCMediaFlag(native[@"tabMuted"])),
    @"silent": @(![native[@"silent"] isKindOfClass:NSNumber.class] ||
                  ARCMediaFlag(native[@"silent"]) || ARCMediaFlag(native[@"tabMuted"])),
    @"volume": ARCMediaVolume(native[@"pageVolume"]),
  } mutableCopy];
  if ([native[@"pipVideoState"] isEqual:@"inPictureInPicture"])
    state[@"pictureInPicture"] = @{
      @"playing": @([playback isEqualToString:@"playing"]),
      @"live": @(![native[@"pipVideoIsLive"] isKindOfClass:NSNumber.class] ||
                 ARCMediaFlag(native[@"pipVideoIsLive"]))};
  return state;
}

static void ShaarPublishMediaState(ARCShaarRuntime *runtime, NSString *tabID,
                                   NSDictionary *state) {
  NSMutableDictionary *cache = ShaarMediaCache(runtime, ShaarMediaCacheKey);
  NSDictionary *previous = cache[tabID];
  if (state) cache[tabID] = state;
  else [cache removeObjectForKey:tabID];
  if (![previous isEqual:state] && runtime.onMediaSessionChanged)
    runtime.onMediaSessionChanged(tabID, state);
}

static void ShaarPublishPictureInPicture(ARCShaarRuntime *runtime, NSString *tabID, BOOL active) {
  NSMutableDictionary *cache = ShaarMediaCache(runtime, ShaarMediaPipKey);
  BOOL previous = [cache[tabID] boolValue];
  if (active) cache[tabID] = @YES;
  else [cache removeObjectForKey:tabID];
  if (previous != active && runtime.onPictureInPictureChanged)
    runtime.onPictureInPictureChanged(tabID, active);
}

@implementation ARCShaarRuntime (MediaSession)

- (void)receiveShaarMediaEventForTabID:(NSString *)tabID payload:(NSDictionary *)payload {
  if (!tabID.length || ![payload[@"schemaVersion"] isEqual:@1]) return;
  NSString *kind = payload[@"kind"];
  if ([kind isEqualToString:@"capture_changed"]) {
    NSNumber *camera = payload[@"camera"];
    NSNumber *microphone = payload[@"microphone"];
    NSNumber *screen = payload[@"screen"];
    if (!ARCMediaIsJSONBoolean(camera) || !ARCMediaIsJSONBoolean(microphone) ||
        !ARCMediaIsJSONBoolean(screen)) return;
    if (self.onMediaAccess) {
      self.onMediaAccess(tabID, @{@"camera": camera, @"microphone": microphone,
                                  @"screen": screen});
    }
    return;
  }
  if ([kind isEqualToString:@"state_changed"]) {
    NSDictionary *native = payload[@"state"];
    if (![native isKindOfClass:NSDictionary.class]) return;
    NSDictionary *state = ARCShaarMediaPublicState(native);
    if (!state) return;
    ShaarPublishPictureInPicture(self, tabID, state[@"pictureInPicture"] != nil);
    ShaarPublishMediaState(self, tabID, state);
    return;
  }
  if ([kind isEqualToString:@"pip_changed"]) {
    NSString *state = payload[@"state"];
    if (![state isEqualToString:@"inPictureInPicture"] && ![state isEqualToString:@"none"])
      return;
    ShaarPublishPictureInPicture(self, tabID, [state isEqualToString:@"inPictureInPicture"]);
    [ShaarMediaCache(self, ShaarMediaRefreshKey) removeObjectForKey:tabID];
    [self mediaSessionStateForTabID:tabID];
  }
}

- (void)forgetShaarMediaForTabID:(NSString *)tabID {
  if (self.onMediaAccess) {
    self.onMediaAccess(tabID, @{@"camera": @NO, @"microphone": @NO, @"screen": @NO});
  }
  [ShaarMediaCache(self, ShaarMediaCacheKey) removeObjectForKey:tabID];
  [ShaarMediaCache(self, ShaarMediaRefreshKey) removeObjectForKey:tabID];
  [ShaarMediaCache(self, ShaarMediaPipKey) removeObjectForKey:tabID];
}

- (NSDictionary<NSString *, id> *)mediaSessionStateForTabID:(NSString *)tabID {
  NSString *profileID = [self shaarProfileIDForTabID:tabID];
  if (!profileID) return nil;
  NSMutableDictionary *refreshes = ShaarMediaCache(self, ShaarMediaRefreshKey);
  NSDate *last = refreshes[tabID];
  if (!last || [last timeIntervalSinceNow] < -1) {
    refreshes[tabID] = NSDate.date;
    [self shaarSubmit:SHAAR_OP_MEDIA_GET_STATE profileID:profileID tabID:tabID
             payload:@{@"schemaVersion": @1} completion:^(NSDictionary *result, NSError *error) {
      if (error || ![self shaarProfileIDForTabID:tabID]) return;
      NSDictionary *state = ARCShaarMediaPublicState(result);
      ShaarPublishPictureInPicture(self, tabID, state[@"pictureInPicture"] != nil);
      ShaarPublishMediaState(self, tabID, state);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (![self shaarHasTabID:tabID profileID:profileID selected:YES]) return;
        [self mediaSessionStateForTabID:tabID];
      });
    }];
  }
  return ShaarMediaCache(self, ShaarMediaCacheKey)[tabID];
}

- (BOOL)sendMediaSessionAction:(ARCMediaSessionAction)action seconds:(double)seconds tabID:(NSString *)tabID {
  NSString *profileID = [self shaarProfileIDForTabID:tabID];
  NSString *name = ARCMediaSessionActionName(action);
  NSDictionary *state = [self mediaSessionStateForTabID:tabID];
  if (!profileID || !name || ![state[@"actions"] containsObject:name]) return NO;
  NSMutableDictionary *payload = [@{@"schemaVersion": @1, @"command": @(action)} mutableCopy];
  if (action == ARCMediaSessionActionSeekTo) {
    if (!std::isfinite(seconds) || seconds < 0 || seconds > 86400) return NO;
    payload[@"value"] = @(seconds);
  }
  if (action == ARCMediaSessionActionSeekBackward ||
      action == ARCMediaSessionActionSeekForward) {
    if (!std::isfinite(seconds) || seconds < 0 || seconds > 86400) return NO;
    if (seconds > 0) payload[@"value"] = @(seconds);
  }
  return [self shaarSubmit:SHAAR_OP_MEDIA_CONTROL profileID:profileID tabID:tabID
                  payload:payload completion:nil];
}

- (BOOL)setMuted:(BOOL)muted tabID:(NSString *)tabID {
  NSString *profileID = [self shaarProfileIDForTabID:tabID];
  if (!profileID) return NO;
  return [self shaarSubmit:SHAAR_OP_MEDIA_CONTROL profileID:profileID tabID:tabID
                  payload:@{@"schemaVersion": @1, @"command": @(SHAAR_MEDIA_SET_TAB_MUTED), @"value": @(muted)}
               completion:^(NSDictionary *result, NSError *error) {
    if (!error) {
      [ShaarMediaCache(self, ShaarMediaRefreshKey) removeObjectForKey:tabID];
      [self mediaSessionStateForTabID:tabID];
    }
  }];
}

- (BOOL)setMediaVolume:(double)volume tabID:(NSString *)tabID {
  if (!std::isfinite(volume) || volume < 0 || volume > 1) return NO;
  NSString *profileID = [self shaarProfileIDForTabID:tabID];
  if (!profileID) return NO;
  return [self shaarSubmit:SHAAR_OP_MEDIA_CONTROL profileID:profileID tabID:tabID
                  payload:@{@"schemaVersion": @1, @"command": @(SHAAR_MEDIA_SET_ELEMENT_VOLUME), @"value": @(volume)}
               completion:nil];
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
