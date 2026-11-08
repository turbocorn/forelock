// Forelock-only host. Loaded by /usr/bin/perl, never linked into Forelock.
// Upstream private API wrapper: ../Vendor/MediaRemoteAdapter (BSD-3-Clause).
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import "private/MediaRemote.h"
#import "adapter/globals.h"
#import <unistd.h>
#import <fcntl.h>
#import <signal.h>
#import <math.h>

static NSString *const targetBundle = @"ru.yandex.desktop.music";
static NSString *session;
static uint64_t epoch = 0, sequence = 0;
static NSString *signature;
static NSDictionary *lastState;
static NSData *lastArt, *blockedArt;
static NSString *lastTrack, *lastAlbum;
static dispatch_queue_t work;
static CFRunLoopRef loop;
static BOOL scheduled = NO;
static pid_t parentPID;

static NSString *text(id value, NSUInteger limit) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *s = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length <= limit ? s : @"";
}
static BOOL finiteNumber(id value, double min, double max) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) && [value doubleValue] >= min && [value doubleValue] <= max;
}
static void emit(NSString *type, NSDictionary *fields) {
    NSMutableDictionary *record = [fields mutableCopy];
    record[@"v"] = @1; record[@"type"] = type; record[@"session"] = session;
    record[@"generation"] = @(epoch); record[@"sequence"] = @(++sequence);
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (!data || data.length > 1500000) return;
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
}
static void unavailable(NSString *reason) {
    if (signature || lastState) epoch++;
    signature = nil; lastState = nil; lastArt = nil; blockedArt = nil; lastTrack = nil; lastAlbum = nil;
    emit(@"state", @{@"available":@NO, @"reason":reason});
}
static BOOL waitUntil(dispatch_semaphore_t semaphore, NSDate *deadline) {
    double remaining = deadline.timeIntervalSinceNow;
    return remaining > 0 && dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining*NSEC_PER_SEC))) == 0;
}
static NSDictionary *client(NSDate *deadline) {
    __block int pid = 0; __block NSString *bundle;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    g_mediaRemote.getNowPlayingApplicationPID(g_serialdispatchQueue, ^(int value) {pid=value; dispatch_semaphore_signal(done);});
    if (!waitUntil(done, deadline) || pid <= 0) return nil;
    done = dispatch_semaphore_create(0);
    g_mediaRemote.getNowPlayingClient(g_serialdispatchQueue, ^(id value) {
        if ([value respondsToSelector:@selector(bundleIdentifier)]) bundle = text([value bundleIdentifier], 128);
        dispatch_semaphore_signal(done);
    });
    if (!waitUntil(done, deadline) || !bundle.length) return nil;
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!app || app.terminated || ![app.bundleIdentifier isEqualToString:bundle]) return nil;
    return @{@"bundle":bundle, @"pid":@(pid)};
}
static NSData *artwork(id value) {
    if (![value isKindOfClass:NSData.class] || [value length] == 0 || [value length] > 1000000) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)value, NULL);
    if (!source) return nil;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    double w = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
    double h = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
    return w > 0 && h > 0 && w <= 2048 && h <= 2048 && w*h <= 4000000 ? value : nil;
}
// A source/metadata sample is accepted only when both surrounding client reads
// identify the same running Yandex PID and playing agrees with metadata rate.
static NSDictionary *observe(NSString **reason) {
    if (![NSRunningApplication runningApplicationsWithBundleIdentifier:targetBundle].count) {*reason=@"not-running"; return nil;}
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.9];
    NSDictionary *before = client(deadline);
    if (!before) {*reason=@"ambiguous"; return nil;}
    if (![before[@"bundle"] isEqualToString:targetBundle]) {*reason=@"foreign-source"; return nil;}
    __block NSDictionary *info; __block BOOL playing = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    g_mediaRemote.getNowPlayingInfo(g_serialdispatchQueue, ^(NSDictionary *value) {info=[value copy]; dispatch_semaphore_signal(done);});
    if (!waitUntil(done, deadline)) {*reason=@"timeout"; return nil;}
    done=dispatch_semaphore_create(0);
    g_mediaRemote.getNowPlayingApplicationIsPlaying(g_serialdispatchQueue, ^(bool value) {playing=value; dispatch_semaphore_signal(done);});
    if (!waitUntil(done, deadline)) {*reason=@"timeout"; return nil;}
    NSDictionary *after = client(deadline);
    if (!after || ![before isEqualToDictionary:after]) {*reason=@"source-changed"; return nil;}
    NSString *title=text(info[kMRMediaRemoteNowPlayingInfoTitle],512);
    id rate=info[kMRMediaRemoteNowPlayingInfoPlaybackRate];
    if (!title.length || !finiteNumber(rate,0,4) || (([rate doubleValue]>0) != playing)) {*reason=@"ambiguous"; return nil;}
    NSMutableDictionary *state=[@{@"available":@YES,@"bundleIdentifier":targetBundle,@"pid":after[@"pid"],@"title":title,
        @"artist":text(info[kMRMediaRemoteNowPlayingInfoArtist],1024),@"album":text(info[kMRMediaRemoteNowPlayingInfoAlbum],512),@"playing":@(playing)} mutableCopy];
    state[@"commands"]=[info[kMRMediaRemoteNowPlayingInfoProhibitsSkip] boolValue] ? @[@"play",@"pause"] : @[@"play",@"pause",@"next",@"previous"];
    id duration=info[kMRMediaRemoteNowPlayingInfoDuration], position=info[kMRMediaRemoteNowPlayingInfoElapsedTime];
    if (finiteNumber(duration,0.001,604800)) state[@"duration"]=duration;
    if (finiteNumber(position,0,604800)) {
        double current=[position doubleValue]; id timestamp=info[kMRMediaRemoteNowPlayingInfoTimestamp];
        if (playing) {
            if (![timestamp isKindOfClass:NSDate.class] || [timestamp timeIntervalSinceNow]>2) {*reason=@"ambiguous";return nil;}
            current += MAX(0,-[timestamp timeIntervalSinceNow])*[rate doubleValue];
        }
        if (state[@"duration"] && current>[duration doubleValue]+3) {*reason=@"ambiguous"; return nil;}
        if(current>604800){*reason=@"ambiguous";return nil;}
        state[@"position"]=@(state[@"duration"] ? MIN(current,[duration doubleValue]) : current);
    }
    NSData *data=artwork(info[kMRMediaRemoteNowPlayingInfoArtworkData]);
    if (data) state[@"rawArt"]=data;
    return state;
}
static NSString *identity(NSDictionary *s) {
    return [@[s[@"pid"]?:@0,s[@"title"]?:@"",s[@"artist"]?:@"",s[@"album"]?:@"",s[@"duration"]?:@0] componentsJoinedByString:@"\x1f"];
}
static void acceptObserved(NSDictionary *sample) {
    NSString *track=identity(sample);
    NSString *album=[@[sample[@"artist"],sample[@"album"]] componentsJoinedByString:@"\x1f"];
    NSData *incoming=sample[@"rawArt"];
    if (lastTrack && ![lastTrack isEqualToString:track]) {
        blockedArt = ![lastAlbum isEqualToString:album] ? lastArt : nil;
        lastArt=nil;
    }
    if (incoming && ![incoming isEqualToData:blockedArt]) {lastArt=incoming; blockedArt=nil;}
    lastTrack=track; lastAlbum=album;
    NSString *nextSignature=[track stringByAppendingFormat:@"/%@/%@",sample[@"playing"],[sample[@"commands"] componentsJoinedByString:@","]];
    if (![signature isEqualToString:nextSignature]) {epoch++; signature=nextSignature;}
    NSMutableDictionary *record=[sample mutableCopy]; [record removeObjectForKey:@"rawArt"];
    if (lastArt) record[@"artwork"]=[lastArt base64EncodedStringWithOptions:0];
    lastState=sample;
    emit(@"state",record);
}
static void refresh(void) {
    @autoreleasepool {NSString *reason; NSDictionary *s=observe(&reason); if(s) acceptObserved(s); else unavailable(reason?:@"unavailable");}
}
static void scheduleRefresh(void) {
    dispatch_async(work, ^{if(scheduled)return;scheduled=YES;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),work,^{scheduled=NO;refresh();});});
}
static void result(NSString *request, BOOL ok, NSString *code, BOOL sent) {
    emit(@"result",@{@"requestID":request,@"ok":@(ok),@"code":code,@"sent":@(sent)});
}
static void command(NSDictionary *message) {
    NSString *request=text(message[@"requestID"],64);
    if (!request.length || ![message[@"v"] isEqual:@1] || ![message[@"type"] isEqual:@"command"]) return;
    NSDictionary *mapping=@{@"play":@0,@"pause":@1,@"next":@4,@"previous":@5};
    NSString *name=text(message[@"command"],16); NSNumber *number=mapping[name];
    if (!number || ![message[@"session"] isEqual:session] || !finiteNumber(message[@"generation"],1,9007199254740991) || [message[@"generation"] unsignedLongLongValue]!=epoch || !lastState) {result(request,NO,@"stale-generation",NO);return;}
    uint64_t requestedEpoch=epoch;
    NSString *reason; NSDictionary *before=observe(&reason);
    if (!before) {unavailable(reason?:@"unavailable");result(request,NO,@"source-unverified",NO);return;}
    acceptObserved(before);
    if (requestedEpoch!=epoch || ![message[@"pid"] isEqual:before[@"pid"]]) {result(request,NO,@"stale-generation",NO);return;}
    if(![before[@"commands"] containsObject:name]){result(request,NO,@"unsupported-command",NO);return;}
    // Recheck live client in the callback immediately before global send.
    // There is still NO atomic binding to a PID: the residual race is inherent.
    __block BOOL sent=NO; dispatch_semaphore_t done=dispatch_semaphore_create(0);
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:0.6];
    g_mediaRemote.getNowPlayingClient(g_serialdispatchQueue, ^(id value) {
        NSString *bid=[value respondsToSelector:@selector(bundleIdentifier)]?[value bundleIdentifier]:nil;
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:[before[@"pid"] intValue]];
        if (deadline.timeIntervalSinceNow>0 && [bid isEqualToString:targetBundle] && [app.bundleIdentifier isEqualToString:targetBundle] && !app.terminated)
            sent=g_mediaRemote.sendCommand((MRCommand)number.intValue,nil);
        dispatch_semaphore_signal(done);
    });
    if (!waitUntil(done,deadline) || !sent) {unavailable(@"source-unverified"); result(request,NO,@"source-unverified",NO);return;}
    for (int attempt=0;attempt<10;attempt++) {
        usleep(100000);
        NSDictionary *after=observe(&reason);
        if (!after) {unavailable(reason?:@"unavailable"); if([reason isEqual:@"foreign-source"]||[reason isEqual:@"not-running"])break; continue;}
        acceptObserved(after);
        BOOL changed = ![identity(before) isEqualToString:identity(after)] || ([before[@"position"] doubleValue]-[after[@"position"] doubleValue]>1);
        if (([name isEqual:@"play"] && [after[@"playing"] boolValue]) || ([name isEqual:@"pause"] && ![after[@"playing"] boolValue]) || (([name isEqual:@"next"]||[name isEqual:@"previous"])&&changed)) {result(request,YES,@"confirmed",YES);return;}
    }
    result(request,NO,@"not-confirmed",YES);
}
void forelock_host_run(void) {
    @autoreleasepool {
        session=NSUUID.UUID.UUIDString; work=dispatch_queue_create("Forelock.MediaRemote.Host",dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL,DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
        loop=CFRunLoopGetCurrent(); parentPID=getenv("FORELOCK_PARENT_PID") ? atoi(getenv("FORELOCK_PARENT_PID")) : 0;
        if(parentPID<=1 || getppid()!=parentPID){emit(@"fatal",@{@"reason":@"invalid-parent"});return;}
        if(!g_mediaRemote.getNowPlayingApplicationPID || !g_mediaRemote.getNowPlayingClient || !g_mediaRemote.getNowPlayingInfo || !g_mediaRemote.getNowPlayingApplicationIsPlaying || !g_mediaRemote.sendCommand || !g_mediaRemote.registerForNowPlayingNotifications) {emit(@"fatal",@{@"reason":@"unsupported-api"});return;}
        setvbuf(stdout,NULL,_IOLBF,0);
        emit(@"ready",@{@"revision":@"0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd"});
        g_mediaRemote.registerForNowPlayingNotifications(dispatch_get_main_queue());
        NSMutableArray *observers=[NSMutableArray array];
        for(NSString *name in @[kMRMediaRemoteNowPlayingInfoDidChangeNotification,kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification,kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification])
            [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n){scheduleRefresh();}]];
        [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:kMRMediaRemoteNowPlayingApplicationDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n){dispatch_async(work,^{unavailable(@"source-changed");});scheduleRefresh();}]];
        dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,work);
        dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),2*NSEC_PER_SEC,100*NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer,^{if(getppid()!=parentPID){CFRunLoopStop(loop);return;} refresh();});dispatch_resume(timer);
        int flags=fcntl(STDIN_FILENO,F_GETFL,0);fcntl(STDIN_FILENO,F_SETFL,flags|O_NONBLOCK);
        dispatch_source_t input=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,STDIN_FILENO,0,work);
        NSMutableData *buffer=[NSMutableData data];
        dispatch_source_set_event_handler(input,^{
            uint8_t bytes[4096];ssize_t count=read(STDIN_FILENO,bytes,sizeof(bytes));
            if(count==0){CFRunLoopStop(loop);return;} if(count<0){if(errno!=EAGAIN&&errno!=EINTR)CFRunLoopStop(loop);return;}
            [buffer appendBytes:bytes length:(NSUInteger)count];
            if(buffer.length>8192){CFRunLoopStop(loop);return;}
            while(YES){
                NSRange line=[buffer rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0,buffer.length)];if(line.location==NSNotFound)break;
                NSData *data=[buffer subdataWithRange:NSMakeRange(0,line.location)];[buffer replaceBytesInRange:NSMakeRange(0,line.location+1) withBytes:NULL length:0];
                if(data.length>4096){CFRunLoopStop(loop);return;}
                id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if(![json isKindOfClass:NSDictionary.class]){CFRunLoopStop(loop);return;} command(json);
            }
        }); dispatch_resume(input);
        CFRunLoopRun();
        dispatch_source_cancel(input);dispatch_source_cancel(timer);
        for(id token in observers)[NSNotificationCenter.defaultCenter removeObserver:token];
        if(g_mediaRemote.unregisterForNowPlayingNotifications)g_mediaRemote.unregisterForNowPlayingNotifications();
    }
}
