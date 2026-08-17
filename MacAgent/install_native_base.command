#!/bin/zsh
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_RUNNER="$SOURCE_DIR/applemacled.command"
SOURCE_PYTHON="$SOURCE_DIR/esp32_usb_serial.py"

APP_SUPPORT="$HOME/Library/Application Support/AppleMAC-LED"
APP_BUNDLE="$HOME/Applications/AppleMACLED Agent.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/AppleMACLEDAgent"
APP_RESOURCES="$APP_BUNDLE/Contents/Resources"
RUN_AGENT="$APP_RESOURCES/run-agent.sh"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
LAUNCHER_MARKER="$APP_RESOURCES/native-launcher-version.txt"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
LAUNCH_PLIST="$LAUNCH_DIR/com.applemacled.agent.plist"
LOG_DIR="$HOME/Library/Logs/AppleMAC-LED"
LABEL="com.applemacled.agent"
LEGACY_LABEL="com.applemacled.ble-agent"
LEGACY_PLIST="$LAUNCH_DIR/$LEGACY_LABEL.plist"
UID_VALUE="$(id -u)"
NATIVE_STATE="$APP_SUPPORT/native-ui-state.json"
NATIVE_AUDIO_STATE="$APP_SUPPORT/native-audio-state.json"

if [[ ! -f "$SOURCE_RUNNER" || ! -f "$SOURCE_PYTHON" ]]; then
  echo "Error: the following files must be located next to install.command:"
  echo "  applemacled.command"
  echo "  esp32_usb_serial.py"
  exit 1
fi

if [[ ! -x /usr/bin/clang ]]; then
  echo "clang was not found. Install Apple command-line tools with:"
  echo "  xcode-select --install"
  exit 1
fi

stop_old_agent() {
  launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE" "$LAUNCH_PLIST" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE/$LEGACY_LABEL" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE" "$LEGACY_PLIST" >/dev/null 2>&1 || true
  rm -f "$LEGACY_PLIST"
  pkill -f "esp32_usb_serial.*daemon" >/dev/null 2>&1 || true
  pkill -f "AppleMACLEDAgent" >/dev/null 2>&1 || true
}

echo "Stopping the previous agent version…"
stop_old_agent
sleep 1

echo "Installing the native AppleMACLED Agent…"
mkdir -p \
  "$APP_SUPPORT" \
  "$APP_BUNDLE/Contents/MacOS" \
  "$APP_RESOURCES" \
  "$LAUNCH_DIR" \
  "$LOG_DIR"
chmod 700 "$APP_SUPPORT"

cp "$SOURCE_RUNNER" "$APP_SUPPORT/applemacled.command"
cp "$SOURCE_PYTHON" "$APP_SUPPORT/esp32_usb_serial.py"
chmod +x "$APP_SUPPORT/applemacled.command"
rm -f "$NATIVE_STATE" "$NATIVE_AUDIO_STATE"

cat > "$RUN_AGENT" <<AGENT
#!/bin/zsh
export PYTHONUNBUFFERED=1
exec "$APP_SUPPORT/applemacled.command" daemon \
  --interval 15 \
  --copy-poll-interval 0.10 \
  >> "$LOG_DIR/agent.log" \
  2>> "$LOG_DIR/agent-error.log"
AGENT
chmod +x "$RUN_AGENT"

cat > "$INFO_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>AppleMACLED Agent</string>
  <key>CFBundleExecutable</key>
  <string>AppleMACLEDAgent</string>
  <key>CFBundleIdentifier</key>
  <string>com.applemacled.agent</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AppleMACLED Agent</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>36.14</string>
  <key>CFBundleVersion</key>
  <string>36.14.0</string>
  <key>LSUIElement</key>
  <true/>

  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Bluetooth is used only to detect connected-device events for AppleMAC-LED lighting.</string>
  <key>NSBluetoothPeripheralUsageDescription</key>
  <string>Bluetooth is used only for connected-device lighting events.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Location may be requested by macOS while reading Wi-Fi connection information.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Downloads access is used only to detect active Safari downloads.</string>
  <key>NSScreenCaptureDescription</key>
  <string>Screen and system-audio access is used only for the optional audio-reactive LED effect.</string>
</dict>
</plist>
PLIST



SOURCE_FILE="$(mktemp -t applemacled-native-launcher).m"
cat > "$SOURCE_FILE" <<SRC
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOBluetooth/IOBluetooth.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#include <errno.h>
#include <libproc.h>
#include <sys/resource.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>
#include <math.h>

extern char **environ;
static volatile sig_atomic_t child_pid = -1;
static const unsigned int NativeUiScanTimeoutSeconds = 25;
static NSString *const StatePath = @"$NATIVE_STATE";
static NSString *const AudioStatePath = @"$NATIVE_AUDIO_STATE";

static uint64_t BluetoothConnectEventCounter = 0;
static NSString *BluetoothLastDeviceName = nil;
static NSMutableSet *PreviousConnectedBluetoothDevices = nil;
static BOOL BluetoothBaselineReady = NO;
static NSTimeInterval LastBluetoothScanAt = 0.0;

static void forward_signal(int sig) {
    if (child_pid > 0) kill((pid_t)child_pid, sig);
}

static void native_watchdog_timeout(int sig) {
    (void)sig;
    if (child_pid > 0) kill((pid_t)child_pid, SIGTERM);
    _exit(76);
}

static id AXCopyValue(AXUIElementRef element, CFStringRef attribute) {
    if (element == NULL || attribute == NULL) return nil;
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (error != kAXErrorSuccess || value == NULL) return nil;
    return [(id)value autorelease];
}

static void SetAXTimeout(AXUIElementRef element, CGFloat seconds) {
    if (element == NULL) return;
    AXUIElementSetMessagingTimeout(element, seconds);
}

static void WriteAudioState(BOOL active, double level, double peak, BOOL beat, NSString *diagnostic) {
    if (level < 0.0) level = 0.0;
    if (level > 1.0) level = 1.0;
    if (peak < 0.0) peak = 0.0;
    if (peak > 1.0) peak = 1.0;

    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    [state setObject:@([[NSDate date] timeIntervalSince1970]) forKey:@"updatedAt"];
    [state setObject:@(active) forKey:@"active"];
    [state setObject:@(level) forKey:@"level"];
    [state setObject:@(peak) forKey:@"peak"];
    [state setObject:@(beat) forKey:@"beat"];
    [state setObject:(diagnostic ?: @"") forKey:@"diagnostic"];

    NSError *jsonError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:state options:0 error:&jsonError];
    if (json == nil || jsonError != nil) return;
    [json writeToFile:AudioStatePath options:NSDataWritingAtomic error:nil];
}

@interface AppleMACLEDAudioMeter : NSObject <SCStreamOutput, SCStreamDelegate> {
    SCStream *_stream;
    dispatch_queue_t _queue;
    BOOL _starting;
    BOOL _running;
    BOOL _restartBlocked;
    NSString *_blockedDiagnostic;
    double _smoothLevel;
    double _baselineLevel;
    double _lastPeak;
    NSTimeInterval _lastBeatAt;
    NSTimeInterval _lastSampleAt;
    NSTimeInterval _lastWriteAt;
    NSTimeInterval _lastStartAttemptAt;
}
- (void)startIfNeeded;
- (void)refreshIdleStateIfNeeded;
- (void)blockRestartWithMessage:(NSString *)message;
@end

@implementation AppleMACLEDAudioMeter

- (void)dealloc {
    [_stream release];
    [_blockedDiagnostic release];
    [super dealloc];
}

- (void)blockRestartWithMessage:(NSString *)message {
    _starting = NO;
    _running = NO;
    _restartBlocked = YES;
    [_stream release];
    _stream = nil;
    [_blockedDiagnostic release];
    _blockedDiagnostic = [(message ?: @"ScreenCaptureKit audio unavailable") copy];
    _lastWriteAt = [NSDate timeIntervalSinceReferenceDate];
    WriteAudioState(NO, 0.0, 0.0, NO, _blockedDiagnostic);
}

- (void)startIfNeeded {
    if (_running || _starting || _restartBlocked) return;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (_lastStartAttemptAt > 0.0 && now - _lastStartAttemptAt < 8.0) {
        return;
    }
    _lastStartAttemptAt = now;
    _starting = YES;

    if (@available(macOS 13.0, *)) {
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
            @autoreleasepool {
                if (error != nil || content == nil) {
                    NSString *message = [NSString stringWithFormat:@"ScreenCaptureKit audio unavailable: %@",
                        error.localizedDescription ?: @"unknown error"];
                    [self blockRestartWithMessage:message];
                    return;
                }

                NSArray *displays = [content displays];
                if ([displays count] == 0) {
                    [self blockRestartWithMessage:@"ScreenCaptureKit audio unavailable: no display"];
                    return;
                }

                SCDisplay *display = [displays objectAtIndex:0];
                SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
                SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
                configuration.width = 2;
                configuration.height = 2;
                configuration.queueDepth = 1;
                configuration.minimumFrameInterval = CMTimeMake(1, 10);
                configuration.showsCursor = NO;
                configuration.capturesAudio = YES;
                configuration.sampleRate = 48000;
                configuration.channelCount = 2;
                if ([configuration respondsToSelector:@selector(setExcludesCurrentProcessAudio:)]) {
                    configuration.excludesCurrentProcessAudio = YES;
                }

                SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];
                if (_queue == NULL) {
                    _queue = dispatch_queue_create("com.applemacled.audio-meter", DISPATCH_QUEUE_SERIAL);
                }

                NSError *outputError = nil;
                BOOL added = [stream addStreamOutput:self
                                                type:SCStreamOutputTypeAudio
                                  sampleHandlerQueue:_queue
                                               error:&outputError];
                if (!added || outputError != nil) {
                    NSString *message = [NSString stringWithFormat:@"ScreenCaptureKit audio output failed: %@",
                        outputError.localizedDescription ?: @"unknown error"];
                    [self blockRestartWithMessage:message];
                    [stream release];
                    [configuration release];
                    [filter release];
                    return;
                }

                [_stream release];
                _stream = stream;
                [_stream startCaptureWithCompletionHandler:^(NSError *startError) {
                    @autoreleasepool {
                        _starting = NO;
                        if (startError != nil) {
                            NSString *message = [NSString stringWithFormat:@"ScreenCaptureKit audio start failed: %@",
                                startError.localizedDescription ?: @"unknown error"];
                            [self blockRestartWithMessage:message];
                        } else {
                            _running = YES;
                            _smoothLevel = 0.0;
                            _baselineLevel = 0.0;
                            _lastPeak = 0.0;
                            _lastSampleAt = [NSDate timeIntervalSinceReferenceDate];
                            _lastWriteAt = 0.0;
                            WriteAudioState(NO, 0.0, 0.0, NO, @"ScreenCaptureKit audio started");
                        }
                    }
                }];

                [configuration release];
                [filter release];
            }
        }];
    } else {
        [self blockRestartWithMessage:@"ScreenCaptureKit audio requires macOS 13 or newer"];
    }
}

- (double)sampleValueFromBytes:(const uint8_t *)bytes
               bytesPerSample:(UInt32)bytesPerSample
                       isFloat:(BOOL)isFloat
                      isSigned:(BOOL)isSigned {
    if (isFloat && bytesPerSample == 4) {
        float sample = 0.0f;
        memcpy(&sample, bytes, sizeof(sample));
        return isfinite(sample) ? (double)sample : 0.0;
    }
    if (isFloat && bytesPerSample == 8) {
        double sample = 0.0;
        memcpy(&sample, bytes, sizeof(sample));
        return isfinite(sample) ? sample : 0.0;
    }
    if (isSigned && bytesPerSample == 2) {
        int16_t sample = 0;
        memcpy(&sample, bytes, sizeof(sample));
        return (double)sample / 32768.0;
    }
    if (isSigned && bytesPerSample == 4) {
        int32_t sample = 0;
        memcpy(&sample, bytes, sizeof(sample));
        return (double)sample / 2147483648.0;
    }
    if (!isSigned && bytesPerSample == 1) {
        uint8_t sample = *bytes;
        return ((double)sample - 128.0) / 128.0;
    }
    return 0.0;
}

- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (sampleBuffer == NULL || !CMSampleBufferIsValid(sampleBuffer) || !CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }

    CMAudioFormatDescriptionRef formatDescription =
        (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
    if (asbd == NULL || asbd->mFormatID != kAudioFormatLinearPCM || asbd->mBitsPerChannel == 0) {
        return;
    }

    size_t bufferListSize = 0;
    OSStatus sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer, &bufferListSize, NULL, 0,
        kCFAllocatorDefault, kCFAllocatorDefault, 0, NULL
    );
    if (sizeStatus != noErr || bufferListSize == 0) {
        return;
    }

    AudioBufferList *bufferList = (AudioBufferList *)calloc(1, bufferListSize);
    if (bufferList == NULL) {
        return;
    }

    CMBlockBufferRef blockBuffer = NULL;
    OSStatus listStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer, NULL, bufferList, bufferListSize,
        kCFAllocatorDefault, kCFAllocatorDefault,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        &blockBuffer
    );
    if (listStatus != noErr) {
        free(bufferList);
        if (blockBuffer != NULL) CFRelease(blockBuffer);
        return;
    }

    const UInt32 bytesPerSample = asbd->mBitsPerChannel / 8;
    const BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const BOOL isSigned = (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    double sumSquares = 0.0;
    double peak = 0.0;
    uint64_t sampleCount = 0;

    for (UInt32 bufferIndex = 0; bufferIndex < bufferList->mNumberBuffers; bufferIndex++) {
        AudioBuffer audioBuffer = bufferList->mBuffers[bufferIndex];
        if (audioBuffer.mData == NULL || audioBuffer.mDataByteSize < bytesPerSample) {
            continue;
        }

        const uint8_t *data = (const uint8_t *)audioBuffer.mData;
        const UInt32 samplesInBuffer = audioBuffer.mDataByteSize / bytesPerSample;
        for (UInt32 sampleIndex = 0; sampleIndex < samplesInBuffer; sampleIndex++) {
            double sample = [self sampleValueFromBytes:(data + sampleIndex * bytesPerSample)
                                       bytesPerSample:bytesPerSample
                                               isFloat:isFloat
                                              isSigned:isSigned];
            if (!isfinite(sample)) continue;
            double absSample = fabs(sample);
            if (absSample > 1.0) absSample = 1.0;
            sumSquares += sample * sample;
            if (absSample > peak) peak = absSample;
            sampleCount++;
        }
    }

    if (blockBuffer != NULL) CFRelease(blockBuffer);
    free(bufferList);
    if (sampleCount == 0) {
        return;
    }

    double rms = sqrt(sumSquares / (double)sampleCount);
    double level = rms * 3.6;
    if (level > 1.0) level = 1.0;
    if (peak > 1.0) peak = 1.0;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    _lastSampleAt = now;
    _lastPeak = peak;
    _smoothLevel = _smoothLevel * 0.68 + level * 0.32;
    if (_smoothLevel < 0.002) _smoothLevel = 0.0;

    if (_baselineLevel <= 0.0) {
        _baselineLevel = _smoothLevel;
    } else {
        _baselineLevel = _baselineLevel * 0.985 + _smoothLevel * 0.015;
    }

    BOOL active = (_smoothLevel > 0.012 || peak > 0.045);
    BOOL beat = NO;
    double beatThreshold = fmax(0.16, _baselineLevel * 1.55);
    if (
        active &&
        peak > 0.10 &&
        _smoothLevel > beatThreshold &&
        now - _lastBeatAt > 0.18
    ) {
        beat = YES;
        _lastBeatAt = now;
    }

    if (now - _lastWriteAt >= 0.035 || beat || !active) {
        _lastWriteAt = now;
        WriteAudioState(
            active,
            active ? _smoothLevel : 0.0,
            active ? peak : 0.0,
            beat,
            active ? @"ScreenCaptureKit audio active" : @"ScreenCaptureKit audio idle"
        );
    }
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeAudio) {
        return;
    }
    [self processAudioSampleBuffer:sampleBuffer];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    NSString *message = [NSString stringWithFormat:@"ScreenCaptureKit audio stopped: %@",
        error.localizedDescription ?: @"unknown error"];
    [self blockRestartWithMessage:message];
}

- (void)refreshIdleStateIfNeeded {
    if (_restartBlocked) {
        NSTimeInterval blockedNow = [NSDate timeIntervalSinceReferenceDate];
        if (blockedNow - _lastWriteAt >= 1.0) {
            _lastWriteAt = blockedNow;
            WriteAudioState(NO, 0.0, 0.0, NO, _blockedDiagnostic);
        }
        return;
    }
    if (!_running) return;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - _lastWriteAt < 0.25) return;
    if (now - _lastSampleAt < 0.25) return;

    _smoothLevel *= 0.60;
    if (_smoothLevel < 0.01) _smoothLevel = 0.0;
    _lastPeak *= 0.50;
    _lastWriteAt = now;
    WriteAudioState(_smoothLevel > 0.012, _smoothLevel, _lastPeak, NO, @"ScreenCaptureKit audio idle");
}

@end

static AppleMACLEDAudioMeter *AudioMeter = nil;

static void EnsureAudioMeterStarted(void) {
    if (AudioMeter == nil) {
        AudioMeter = [[AppleMACLEDAudioMeter alloc] init];
    }
    [AudioMeter startIfNeeded];
    [AudioMeter refreshIdleStateIfNeeded];
}

static NSString *StringValue(id value) {
    if (value == nil) return @"";
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString] ?: @"";
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *text = [value stringValue];
        if (text != nil) return text;
    }
    NSString *text = [value description];
    return text ?: @"";
}

static NSString *FilesystemPathFromObject(id object) {
    if (object == nil) return nil;
    if ([object isKindOfClass:[NSURL class]]) {
        return [(NSURL *)object path];
    }
    if ([object isKindOfClass:[NSString class]]) {
        NSString *text = [(NSString *)object stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([text length] == 0) return nil;
        if ([text hasPrefix:@"file:"]) {
            NSURL *url = [NSURL URLWithString:text];
            NSString *path = [url path];
            if ([path length] > 0) return [path stringByExpandingTildeInPath];
        }
        return [text stringByExpandingTildeInPath];
    }
    if ([object isKindOfClass:[NSData class]]) {
        BOOL stale = NO;
        NSError *error = nil;
        NSURL *url = [NSURL URLByResolvingBookmarkData:(NSData *)object
            options:NSURLBookmarkResolutionWithoutUI
            relativeToURL:nil
            bookmarkDataIsStale:&stale
            error:&error];
        NSString *path = [url path];
        return [path length] > 0 ? path : nil;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSArray *keys = @[@"path", @"Path", @"url", @"URL", @"NSURL", @"_NSURLPathKey"];
        for (NSString *key in keys) {
            NSString *path = FilesystemPathFromObject([(NSDictionary *)object objectForKey:key]);
            if ([path length] > 0) return path;
        }
    }
    if ([object isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)object) {
            NSString *path = FilesystemPathFromObject(item);
            if ([path length] > 0) return path;
        }
    }
    return nil;
}

static void AddDirectoryIfPresent(NSMutableArray *paths, NSString *path) {
    if ([path length] == 0) return;
    NSString *expanded = [path stringByExpandingTildeInPath];
    BOOL isDirectory = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:expanded isDirectory:&isDirectory]
            && isDirectory
            && ![paths containsObject:expanded]) {
        [paths addObject:expanded];
    }
}

static BOOL Truthy(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value boolValue];
    NSString *text = [[StringValue(value) lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [text isEqualToString:@"1"] || [text isEqualToString:@"true"] || [text isEqualToString:@"yes"];
}

static NSString *ElementText(AXUIElementRef element) {
    NSArray *attributes = @[
        (NSString *)kAXTitleAttribute,
        (NSString *)kAXDescriptionAttribute,
        (NSString *)kAXHelpAttribute,
        (NSString *)kAXValueAttribute,
        (NSString *)kAXRoleDescriptionAttribute,
        @"AXLabel", @"AXIdentifier", @"AXDOMIdentifier",
        @"AXPlaceholderValue", @"AXURL", @"AXDocument"
    ];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *attribute in attributes) {
        id value = AXCopyValue(element, (CFStringRef)attribute);
        if ([value isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)value) {
                NSString *text = StringValue(item);
                if ([text length] > 0) [parts addObject:text];
            }
        } else {
            NSString *text = StringValue(value);
            if ([text length] > 0) [parts addObject:text];
        }
    }
    return [[[parts componentsJoinedByString:@" "] lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}





static NSString *OpenAIElementText(AXUIElementRef element) {
    NSArray *attributes = @[
        (NSString *)kAXTitleAttribute,
        (NSString *)kAXDescriptionAttribute,
        (NSString *)kAXHelpAttribute,
        (NSString *)kAXValueAttribute,
        @"AXLabel", @"AXIdentifier", @"AXDOMIdentifier"
    ];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *attribute in attributes) {
        id value = AXCopyValue(element, (CFStringRef)attribute);
        if ([value isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)value) {
                NSString *text = StringValue(item);
                if ([text length] > 0) [parts addObject:text];
            }
        } else {
            NSString *text = StringValue(value);
            if ([text length] > 0) [parts addObject:text];
        }
    }
    return [[[parts componentsJoinedByString:@" "] lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *SafariIdentityText(AXUIElementRef element) {
    NSArray *attributes = @[
        @"AXURL", @"AXDocument"
    ];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *attribute in attributes) {
        id value = AXCopyValue(element, (CFStringRef)attribute);
        NSString *text = StringValue(value);
        if ([text length] > 0) [parts addObject:text];
    }
    return [[[parts componentsJoinedByString:@" "] lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *SafariAddressFieldText(AXUIElementRef element) {
    NSString *role = StringValue(AXCopyValue(element, kAXRoleAttribute));
    NSString *roleDescription = StringValue(AXCopyValue(element, kAXRoleDescriptionAttribute));
    NSString *identifier = StringValue(AXCopyValue(element, CFSTR("AXIdentifier")));
    NSString *description = StringValue(AXCopyValue(element, kAXDescriptionAttribute));
    NSString *placeholder = StringValue(AXCopyValue(element, CFSTR("AXPlaceholderValue")));
    NSString *marker = [[NSString stringWithFormat:@"%@ %@ %@ %@ %@",
        role ?: @"",
        roleDescription ?: @"",
        identifier ?: @"",
        description ?: @"",
        placeholder ?: @""]
        lowercaseString];

    BOOL looksLikeAddressField =
        [role isEqualToString:@"AXTextField"]
        && ([marker rangeOfString:@"address"].location != NSNotFound
            || [marker rangeOfString:@"search"].location != NSNotFound
            || [marker rangeOfString:@"smart"].location != NSNotFound
            || [marker rangeOfString:@"адрес"].location != NSNotFound
            || [marker rangeOfString:@"поиск"].location != NSNotFound
            || [marker rangeOfString:@"смарт"].location != NSNotFound);
    if (!looksLikeAddressField) return @"";

    NSString *value = [[StringValue(AXCopyValue(element, kAXValueAttribute)) lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([value length] == 0) return @"";

    BOOL looksLikeURL =
        [value hasPrefix:@"http://"]
        || [value hasPrefix:@"https://"]
        || [value hasPrefix:@"chatgpt.com"]
        || [value hasPrefix:@"chat.openai.com"];
    return looksLikeURL ? value : @"";
}

static void AddPreferredChildren(NSMutableArray *queue, AXUIElementRef element) {


    NSArray *attributes = @[@"AXVisibleChildren", (NSString *)kAXChildrenAttribute, @"AXContents"];
    for (NSString *attribute in attributes) {
        id children = AXCopyValue(element, (CFStringRef)attribute);
        if ([children isKindOfClass:[NSArray class]] && [(NSArray *)children count] > 0) {
            for (id child in (NSArray *)children) {
                if (child != nil) [queue addObject:child];
            }
            return;
        }
    }
}

static void AddAllAvailableChildren(NSMutableArray *queue, AXUIElementRef element) {
    NSArray *attributes = @[@"AXVisibleChildren", (NSString *)kAXChildrenAttribute, @"AXContents"];
    NSMutableSet *added = [NSMutableSet set];
    for (NSString *attribute in attributes) {
        id children = AXCopyValue(element, (CFStringRef)attribute);
        if (![children isKindOfClass:[NSArray class]]) continue;
        for (id child in (NSArray *)children) {
            if (child == nil) continue;
            NSValue *pointer = [NSValue valueWithPointer:(const void *)child];
            if ([added containsObject:pointer]) continue;
            [added addObject:pointer];
            [queue addObject:child];
        }
    }
}

static BOOL RoleSkipsLargeChildren(NSString *role) {
    NSArray *roles = @[
        @"AXOutline", @"AXTable", @"AXList", @"AXScrollArea",
        @"AXBrowser", @"AXGrid", @"AXCollection", @"AXMenu",
        @"AXMenuBar", @"AXMenuItem"
    ];
    return [roles containsObject:role ?: @""];
}

static BOOL AppStoreRoleSkipsChildren(NSString *role) {
    NSArray *roles = @[
        @"AXMenu", @"AXMenuBar", @"AXMenuItem"
    ];
    return [roles containsObject:role ?: @""];
}

static BOOL ContainsPattern(NSString *text, NSArray *patterns) {
    if ([text length] == 0) return NO;
    for (NSString *pattern in patterns) {
        if ([text rangeOfString:pattern].location != NSNotFound) return YES;
    }
    return NO;
}

static NSDictionary *FindSafariChatContext(AXUIElementRef root, NSArray *chatPatterns) {
    NSMutableArray *queue = [NSMutableArray arrayWithObject:(id)root];
    NSMutableSet *visited = [NSMutableSet set];
    NSUInteger index = 0;
    NSUInteger examined = 0;
    NSString *matched = @"";

    while (index < [queue count] && examined < 700) {
        AXUIElementRef element = (AXUIElementRef)[queue objectAtIndex:index++];
        NSValue *pointer = [NSValue valueWithPointer:(const void *)element];
        if ([visited containsObject:pointer]) continue;
        [visited addObject:pointer];
        examined++;

        NSString *text = SafariIdentityText(element);
        if (ContainsPattern(text, chatPatterns)) {
            matched = [text length] > 160 ? [text substringToIndex:160] : text;
            return @{ @"chat": @YES, @"marker": matched, @"elements": @(examined) };
        }

        NSString *addressText = SafariAddressFieldText(element);
        if (ContainsPattern(addressText, chatPatterns)) {
            matched = [addressText length] > 160 ? [addressText substringToIndex:160] : addressText;
            return @{ @"chat": @YES, @"marker": matched, @"elements": @(examined) };
        }

        NSString *role = StringValue(AXCopyValue(element, kAXRoleAttribute));
        if (![role isEqualToString:@"AXWebArea"] && !RoleSkipsLargeChildren(role)) {
            AddPreferredChildren(queue, element);
        }
    }

    return @{ @"chat": @NO, @"marker": @"", @"elements": @(examined) };
}




static NSString *TrashFingerprint(void) {
    NSMutableSet *paths = [NSMutableSet set];
    NSString *homeTrash = [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
    if ([homeTrash length] > 0) [paths addObject:homeTrash];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *volumes = [fm mountedVolumeURLsIncludingResourceValuesForKeys:nil options:0];
    NSString *uidText = [NSString stringWithFormat:@"%u", (unsigned)getuid()];
    for (NSURL *volume in volumes ?: @[]) {
        NSString *root = [volume path];
        if ([root length] == 0) continue;
        NSString *trashes = [root stringByAppendingPathComponent:@".Trashes"];
        [paths addObject:trashes];
        [paths addObject:[trashes stringByAppendingPathComponent:uidText]];
    }

    NSMutableArray *parts = [NSMutableArray array];
    NSArray *sorted = [[paths allObjects] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *path in sorted) {
        struct stat st;
        if (lstat([path fileSystemRepresentation], &st) != 0) continue;
        [parts addObject:[NSString stringWithFormat:@"%@:%llu:%lld.%09ld:%lld.%09ld:%lld",
            path,
            (unsigned long long)st.st_ino,
            (long long)st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec,
            (long long)st.st_ctimespec.tv_sec, st.st_ctimespec.tv_nsec,
            (long long)st.st_size]];
    }
    return [parts count] > 0 ? [parts componentsJoinedByString:@"|"] : @"unavailable";
}

static NSDictionary *ScanSafariDownloadToolbar(AXUIElementRef root) {
    NSMutableArray *queue = [NSMutableArray arrayWithObject:(id)root];
    NSMutableSet *visited = [NSMutableSet set];
    NSUInteger index = 0;
    NSUInteger examined = 0;
    NSUInteger progressCount = 0;
    BOOL explicitActive = NO;
    NSString *marker = @"";

    NSArray *downloadPatterns = @[
        @"download", @"downloads", @"downloading", @"show downloads",
        @"загрузк", @"скачив", @"показать загрузки", @"осталось"
    ];
    NSArray *activePatterns = @[
        @"downloading", @"download in progress", @"remaining", @"pause download",
        @"загружается", @"идет загрузка", @"осталось", @"приостановить загрузку"
    ];

    while (index < [queue count] && examined < 900) {
        AXUIElementRef element = (AXUIElementRef)[queue objectAtIndex:index++];
        NSValue *pointer = [NSValue valueWithPointer:(const void *)element];
        if ([visited containsObject:pointer]) continue;
        [visited addObject:pointer];
        examined++;
        if (Truthy(AXCopyValue(element, CFSTR("AXHidden")))) continue;

        NSString *role = StringValue(AXCopyValue(element, kAXRoleAttribute));
        NSString *text = ElementText(element);
        BOOL toolbar = [role isEqualToString:(NSString *)kAXToolbarRole]
            || [role rangeOfString:@"Toolbar"].location != NSNotFound;

        if (toolbar || ContainsPattern(text, downloadPatterns)) {
            NSMutableArray *toolbarQueue = [NSMutableArray arrayWithObject:(id)element];
            NSMutableSet *toolbarVisited = [NSMutableSet set];
            NSUInteger toolbarIndex = 0;
            NSUInteger toolbarExamined = 0;
            BOOL hasDownloadMarker = toolbar || ContainsPattern(text, downloadPatterns);

            while (toolbarIndex < [toolbarQueue count] && toolbarExamined < 450) {
                AXUIElementRef child = (AXUIElementRef)[toolbarQueue objectAtIndex:toolbarIndex++];
                NSValue *childPointer = [NSValue valueWithPointer:(const void *)child];
                if ([toolbarVisited containsObject:childPointer]) continue;
                [toolbarVisited addObject:childPointer];
                toolbarExamined++;
                if (Truthy(AXCopyValue(child, CFSTR("AXHidden")))) continue;

                NSString *childRole = StringValue(AXCopyValue(child, kAXRoleAttribute));
                NSString *childText = ElementText(child);
                if (ContainsPattern(childText, downloadPatterns)) {
                    hasDownloadMarker = YES;
                    if ([marker length] == 0) {
                        marker = [childText length] > 160 ? [childText substringToIndex:160] : childText;
                    }
                }
                if (ContainsPattern(childText, activePatterns)) explicitActive = YES;

                BOOL progress = [childRole isEqualToString:(NSString *)kAXProgressIndicatorRole]
                    || [childRole rangeOfString:@"Progress"].location != NSNotFound;
                if (progress && hasDownloadMarker) {
                    progressCount++;
                }
                if (![childRole isEqualToString:@"AXWebArea"]) {
                    AddPreferredChildren(toolbarQueue, child);
                }
            }
            if (hasDownloadMarker && (progressCount > 0 || explicitActive)) break;
        }

        if (![role isEqualToString:@"AXWebArea"]
                && !RoleSkipsLargeChildren(role)) {
            AddPreferredChildren(queue, element);
        }
    }

    BOOL active = progressCount > 0 || explicitActive;
    NSUInteger count = progressCount > 0 ? progressCount : (active ? 1 : 0);
    NSString *diag = active
        ? [NSString stringWithFormat:@"active=%lu, marker=%@", (unsigned long)count, marker]
        : @"no active downloads found in the Safari toolbar";
    return @{ @"active": @(active), @"count": @(count), @"diag": diag };
}


static NSTimeInterval SafariDownloadFileLastScanAt = 0.0;
static BOOL SafariDownloadFileCachedActive = NO;
static NSUInteger SafariDownloadFileCachedCount = 0;
static NSString *SafariDownloadFileCachedDiagnostic = nil;

static NSArray *SafariDownloadDirectories(void) {
    NSMutableArray *paths = [NSMutableArray array];
    NSArray *defaults = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES);
    for (NSString *path in defaults ?: @[]) {
        AddDirectoryIfPresent(paths, path);
    }

    NSArray *preferenceKeys = @[
        @"DownloadsPath", @"DownloadPath", @"DownloadsFolder",
        @"DownloadsPathBookmark", @"DownloadsFolderBookmark",
        @"NSNavLastRootDirectory"
    ];
    for (NSString *key in preferenceKeys) {
        CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)key, CFSTR("com.apple.Safari"));
        if (value != NULL) {
            id object = [(id)value autorelease];
            AddDirectoryIfPresent(paths, FilesystemPathFromObject(object));
        }
    }

    NSString *home = NSHomeDirectory();
    NSArray *plistPaths = @[
        [home stringByAppendingPathComponent:@"Library/Preferences/com.apple.Safari.plist"],
        [home stringByAppendingPathComponent:@"Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist"]
    ];
    for (NSString *plistPath in plistPaths) {
        NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if (![preferences isKindOfClass:[NSDictionary class]]) continue;
        for (NSString *key in preferenceKeys) {
            AddDirectoryIfPresent(paths, FilesystemPathFromObject([preferences objectForKey:key]));
        }
    }

    return paths;
}

static NSDictionary *ScanSafariDownloadFiles(NSTimeInterval nowEpoch) {
    if (SafariDownloadFileLastScanAt > 0.0
            && nowEpoch - SafariDownloadFileLastScanAt < 0.45) {
        return @{ @"active": @(SafariDownloadFileCachedActive),
                  @"count": @(SafariDownloadFileCachedCount),
                  @"diag": SafariDownloadFileCachedDiagnostic ?: @"waiting for Safari file check" };
    }
    SafariDownloadFileLastScanAt = nowEpoch;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger count = 0;
    NSMutableArray *examples = [NSMutableArray array];
    NSMutableArray *errors = [NSMutableArray array];

    for (NSString *directory in SafariDownloadDirectories()) {
        NSError *error = nil;
        NSArray *items = [fm contentsOfDirectoryAtPath:directory error:&error];
        if (items == nil) {
            if (error != nil) {
                [errors addObject:[NSString stringWithFormat:@"%@:%ld",
                    [directory lastPathComponent], (long)[error code]]];
            }
            continue;
        }
        for (NSString *name in items) {
            NSString *lower = [name lowercaseString];
            BOOL partial = [lower hasSuffix:@".download"]
                || [lower hasSuffix:@".part"]
                || [lower hasSuffix:@".partial"]
                || [lower hasSuffix:@".download.part"];
            if (!partial) continue;
            count++;
            if ([examples count] < 3) [examples addObject:name];
        }
    }

    SafariDownloadFileCachedActive = count > 0;
    SafariDownloadFileCachedCount = count;
    NSString *diag = nil;
    if (count > 0) {
        diag = [NSString stringWithFormat:@"file downloads=%lu, marker=%@",
            (unsigned long)count, [examples componentsJoinedByString:@", "]];
    } else if ([errors count] > 0) {
        diag = [NSString stringWithFormat:@"file downloads not found; access=%@",
            [errors componentsJoinedByString:@","]];
    } else {
        diag = @"Safari file downloads not found";
    }
    [SafariDownloadFileCachedDiagnostic release];
    SafariDownloadFileCachedDiagnostic = [diag copy];
    return @{ @"active": @(SafariDownloadFileCachedActive),
              @"count": @(SafariDownloadFileCachedCount),
              @"diag": SafariDownloadFileCachedDiagnostic };
}

static NSArray *SafariDownloadHistoryPaths(void) {
    NSString *home = NSHomeDirectory();
    return @[
        [home stringByAppendingPathComponent:@"Library/Safari/Downloads.plist"],
        [home stringByAppendingPathComponent:@"Library/Containers/com.apple.Safari/Data/Library/Safari/Downloads.plist"]
    ];
}

static NSArray *SafariDownloadEntriesFromRoot(id root) {
    if ([root isKindOfClass:[NSArray class]]) return (NSArray *)root;
    if (![root isKindOfClass:[NSDictionary class]]) return @[];

    NSDictionary *dictionary = (NSDictionary *)root;
    NSArray *preferredKeys = @[@"DownloadHistory", @"Downloads", @"DownloadEntries", @"entries"];
    for (NSString *key in preferredKeys) {
        id value = [dictionary objectForKey:key];
        if ([value isKindOfClass:[NSArray class]]) return (NSArray *)value;
    }
    for (id key in dictionary) {
        id value = [dictionary objectForKey:key];
        if ([value isKindOfClass:[NSArray class]]) return (NSArray *)value;
    }
    return @[];
}

static long long NumberForKeys(NSDictionary *dictionary, NSArray *keys) {
    for (NSString *key in keys) {
        id value = [dictionary objectForKey:key];
        if ([value respondsToSelector:@selector(longLongValue)]) {
            return [value longLongValue];
        }
    }
    return -1;
}

static BOOL SafariDownloadEntryFinished(NSDictionary *entry) {
    for (id rawKey in entry) {
        NSString *key = [[StringValue(rawKey) lowercaseString]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([key rangeOfString:@"finish"].location == NSNotFound
                && [key rangeOfString:@"completed"].location == NSNotFound) {
            continue;
        }
        id value = [entry objectForKey:rawKey];
        if (value == nil || value == [NSNull null]) continue;
        if ([value isKindOfClass:[NSNumber class]] && ![(NSNumber *)value boolValue]) continue;
        if ([StringValue(value) length] > 0) return YES;
    }
    return NO;
}

static NSDictionary *ScanSafariDownloadHistory(NSTimeInterval nowEpoch) {
    NSUInteger count = 0;
    NSMutableArray *examples = [NSMutableArray array];
    NSMutableArray *errors = [NSMutableArray array];
    NSArray *activePatterns = @[
        @"downloading", @"download in progress", @"in progress", @"remaining",
        @"загружается", @"скачивается", @"идет загрузка", @"осталось"
    ];

    for (NSString *path in SafariDownloadHistoryPaths()) {
        struct stat st;
        if (lstat([path fileSystemRepresentation], &st) != 0) continue;

        id root = [NSArray arrayWithContentsOfFile:path];
        if (root == nil) root = [NSDictionary dictionaryWithContentsOfFile:path];
        if (root == nil) {
            [errors addObject:[NSString stringWithFormat:@"%@:%d",
                [path lastPathComponent], errno]];
            continue;
        }

        BOOL recent = nowEpoch - (NSTimeInterval)st.st_mtimespec.tv_sec <= 15.0;
        if (!recent) continue;

        NSArray *entries = SafariDownloadEntriesFromRoot(root);
        for (id item in entries) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *entry = (NSDictionary *)item;
            if (SafariDownloadEntryFinished(entry)) continue;

            long long total = NumberForKeys(entry, @[
                @"DownloadEntryProgressTotalToLoad",
                @"ProgressTotalToLoad",
                @"totalBytes",
                @"total"
            ]);
            long long loaded = NumberForKeys(entry, @[
                @"DownloadEntryProgressBytesSoFar",
                @"ProgressBytesSoFar",
                @"bytesLoaded",
                @"loaded"
            ]);
            BOOL progressActive = total > 0 && loaded >= 0 && loaded < total;
            NSString *status = [[[NSString stringWithFormat:@"%@ %@ %@",
                StringValue([entry objectForKey:@"DownloadEntryStatus"]),
                StringValue([entry objectForKey:@"status"]),
                StringValue([entry objectForKey:@"state"])] lowercaseString]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            BOOL statusActive = ContainsPattern(status, activePatterns);
            if (!progressActive && !statusActive) continue;

            count++;
            if ([examples count] < 3) {
                NSString *marker = FilesystemPathFromObject([entry objectForKey:@"DownloadEntryPath"]);
                if ([marker length] == 0) marker = StringValue([entry objectForKey:@"DownloadEntryURL"]);
                if ([marker length] == 0) marker = StringValue([entry objectForKey:@"DownloadEntryIdentifier"]);
                if ([marker length] > 0) [examples addObject:[marker lastPathComponent]];
            }
        }
    }

    NSString *diag = nil;
    if (count > 0) {
        diag = [NSString stringWithFormat:@"history=%lu, marker=%@",
            (unsigned long)count, [examples componentsJoinedByString:@", "]];
    } else if ([errors count] > 0) {
        diag = [NSString stringWithFormat:@"history unavailable: %@",
            [errors componentsJoinedByString:@","]];
    } else {
        diag = @"history did not report active downloads";
    }
    return @{ @"active": @(count > 0), @"count": @(count), @"diag": diag };
}

static NSDictionary *ScanSafari(pid_t pid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    SetAXTimeout(app, 0.18);
    id root = AXCopyValue(app, kAXFocusedWindowAttribute);
    if (root == nil) root = AXCopyValue(app, kAXMainWindowAttribute);
    if (root == nil) {
        id windows = AXCopyValue(app, kAXWindowsAttribute);
        if ([windows isKindOfClass:[NSArray class]] && [(NSArray *)windows count] > 0) {
            root = [(NSArray *)windows objectAtIndex:0];
        }
    }
    if (root == nil) {
        CFRelease(app);
        return @{ @"tab": @NO, @"busy": @NO, @"downloadActive": @NO, @"downloadCount": @0, @"downloadDiag": @"Safari did not return a window", @"diag": @"Safari did not return an active window" };
    }

    NSArray *chatPatterns = @[@"chatgpt.com", @"chat.openai.com"];
    NSDictionary *chatContext = FindSafariChatContext((AXUIElementRef)root, chatPatterns);
    BOOL chat = [chatContext[@"chat"] boolValue];
    NSString *chatMatched = chatContext[@"marker"] ?: @"";
    NSUInteger chatExamined = [chatContext[@"elements"] unsignedIntegerValue];
    NSString *title = StringValue(AXCopyValue((AXUIElementRef)root, kAXTitleAttribute));
    if (!chat) {
        NSString *diag = [NSString stringWithFormat:@"title=%@, elements=%lu, tab=not-chatgpt",
            title ?: @"", (unsigned long)chatExamined];
        CFRelease(app);
        return @{
            @"tab": @NO,
            @"busy": @NO,
            @"downloadActive": @NO,
            @"downloadCount": @0,
            @"downloadDiag": @"Safari UI skipped: tab is not ChatGPT",
            @"diag": diag
        };
    }

    NSDictionary *downloads = ScanSafariDownloadToolbar((AXUIElementRef)root);

    NSArray *stopPatterns = @[
        @"stop generating", @"stop response", @"stop streaming", @"stop thinking",
        @"stop running", @"cancel generation", @"cancel response", @"interrupt response",
        @"остановить генерацию", @"остановить ответ", @"остановить размышление",
        @"остановить выполнение", @"прервать генерацию", @"прервать ответ",
        @"прервать выполнение", @"stop-button", @"stop_button", @"composer-stop"
    ];

    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    NSMutableSet *visited = [NSMutableSet set];
    NSUInteger index = 0;
    NSUInteger examined = 0;
    BOOL busy = NO;
    NSString *busyMatched = @"";

    while (index < [queue count] && examined < 3500) {
        AXUIElementRef element = (AXUIElementRef)[queue objectAtIndex:index++];
        NSValue *pointer = [NSValue valueWithPointer:(const void *)element];
        if ([visited containsObject:pointer]) continue;
        [visited addObject:pointer];
        examined++;

        if (Truthy(AXCopyValue(element, CFSTR("AXHidden")))) continue;

        NSString *role = StringValue(AXCopyValue(element, kAXRoleAttribute));
        BOOL button = [role isEqualToString:(NSString *)kAXButtonRole]
            || [role rangeOfString:@"Button"].location != NSNotFound;
        BOOL possibleControl = button
            || [role isEqualToString:@"AXGroup"]
            || [role isEqualToString:@"AXGenericElement"]
            || [role isEqualToString:@"AXLink"];
        NSString *text = possibleControl ? OpenAIElementText(element) : @"";




        id enabledValue = AXCopyValue(element, kAXEnabledAttribute);
        BOOL enabled = enabledValue == nil || Truthy(enabledValue);
        BOOL explicitStopIdentifier =
            [text rangeOfString:@"stop-button"].location != NSNotFound
            || [text rangeOfString:@"stop_button"].location != NSNotFound
            || [text rangeOfString:@"composer-stop"].location != NSNotFound;

        BOOL exactStopLabel = [text isEqualToString:@"stop"]
            || [text isEqualToString:@"остановить"]
            || [text hasPrefix:@"stop button"]
            || [text hasPrefix:@"остановить кнопка"];
        if (enabled && (button || explicitStopIdentifier)
            && (exactStopLabel || ContainsPattern(text, stopPatterns))) {
            busy = YES;
            busyMatched = [text length] > 180 ? [text substringToIndex:180] : text;
        }

        if (busy) break;
        AddAllAvailableChildren(queue, element);
    }

    NSMutableString *diag = [NSMutableString stringWithFormat:@"title=%@, elements=%lu",
        title ?: @"", (unsigned long)examined];
    if ([chatMatched length]) [diag appendFormat:@", tab=%@", chatMatched];
    if ([busyMatched length]) [diag appendFormat:@", stop=%@", busyMatched];
    else if (chat) [diag appendString:@", stop=not-found"];

    CFRelease(app);
    return @{
        @"tab": @(chat),
        @"busy": @(chat && busy),
        @"downloadActive": downloads[@"active"] ?: @NO,
        @"downloadCount": downloads[@"count"] ?: @0,
        @"downloadDiag": downloads[@"diag"] ?: @"",
        @"diag": diag
    };
}

static BOOL IsAppStoreApplication(NSRunningApplication *application) {
    if (application == nil) return NO;
    NSString *bundle = [[[application bundleIdentifier] ?: @"" lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *name = [[[application localizedName] ?: @"" lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [bundle isEqualToString:@"com.apple.appstore"]
        || [name isEqualToString:@"app store"]
        || [name isEqualToString:@"appstore"];
}

static NSTimeInterval AppStoreLastUIActiveAt = 0.0;

static NSDictionary *ScanAppStoreUI(pid_t pid, NSTimeInterval nowEpoch) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    SetAXTimeout(app, 0.25);
    id windows = AXCopyValue(app, kAXWindowsAttribute);
    NSMutableArray *roots = [NSMutableArray arrayWithObject:(id)app];
    if ([windows isKindOfClass:[NSArray class]]) [roots addObjectsFromArray:(NSArray *)windows];

    NSMutableArray *queue = [NSMutableArray arrayWithArray:roots];
    NSMutableSet *visited = [NSMutableSet set];
    NSUInteger index = 0;
    NSUInteger examined = 0;
    NSUInteger progressCount = 0;
    BOOL controlActive = NO;
    BOOL statusActive = NO;
    NSString *matched = @"";
    NSArray *controlPatterns = @[
        @"pause download", @"cancel download", @"stop download",
        @"pause update", @"cancel update", @"stop update",
        @"приостановить загрузку", @"отменить загрузку", @"остановить загрузку",
        @"приостановить обновление", @"отменить обновление", @"остановить обновление",
        @"пауза загрузки", @"пауза обновления"
    ];
    NSArray *statusPatterns = @[
        @"downloading", @"installing", @"updating", @"download in progress",
        @"update in progress", @"preparing to install", @"waiting to download",
        @"downloaded", @"installing update", @"installing app",
        @"загружается", @"скачивается", @"идет загрузка", @"выполняется загрузка",
        @"устанавливается", @"идет установка", @"обновляется", @"выполняется обновление",
        @"подготовка к установке", @"ожидание загрузки", @"загружено"
    ];

    while (index < [queue count] && examined < 5200) {
        AXUIElementRef element = (AXUIElementRef)[queue objectAtIndex:index++];
        NSValue *pointer = [NSValue valueWithPointer:(const void *)element];
        if ([visited containsObject:pointer]) continue;
        [visited addObject:pointer];
        examined++;
        if (Truthy(AXCopyValue(element, CFSTR("AXHidden")))) continue;

        NSString *role = StringValue(AXCopyValue(element, kAXRoleAttribute));
        NSString *text = ElementText(element);
        BOOL button = [role isEqualToString:(NSString *)kAXButtonRole]
            || [role rangeOfString:@"Button"].location != NSNotFound;
        BOOL progress = [role isEqualToString:(NSString *)kAXProgressIndicatorRole]
            || [role rangeOfString:@"Progress"].location != NSNotFound;
        id enabledValue = AXCopyValue(element, kAXEnabledAttribute);
        BOOL enabled = enabledValue == nil || Truthy(enabledValue);

        if (progress) {
            id value = AXCopyValue(element, kAXValueAttribute);
            double number = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : -1.0;
            // Determinate progress is the strongest UI marker. Indeterminate
            // spinners are accepted only when their text explicitly says that
            // a download/update/install is in progress.
            if ((number > 0.0 && number < 100.0) || ContainsPattern(text, statusPatterns)) {
                progressCount++;
                if ([matched length] == 0 && [text length] > 0) {
                    matched = [text length] > 180 ? [text substringToIndex:180] : text;
                }
            }
        }

        if (enabled && button && ContainsPattern(text, controlPatterns)) {
            controlActive = YES;
            if ([matched length] == 0) matched = [text length] > 180 ? [text substringToIndex:180] : text;
        }
        if (ContainsPattern(text, statusPatterns)) {
            BOOL meaningfulRole = button || progress
                || [role isEqualToString:@"AXStaticText"]
                || [role isEqualToString:@"AXGroup"];
            if (meaningfulRole) {
                statusActive = YES;
                if ([matched length] == 0) matched = [text length] > 180 ? [text substringToIndex:180] : text;
            }
        }

        if (!AppStoreRoleSkipsChildren(role)) AddPreferredChildren(queue, element);
    }

    BOOL freshActive = progressCount > 0 || controlActive || statusActive;
    if (freshActive) AppStoreLastUIActiveAt = nowEpoch;
    BOOL active = freshActive || (AppStoreLastUIActiveAt > 0.0 && nowEpoch - AppStoreLastUIActiveAt < 8.0);
    NSUInteger count = progressCount > 0 ? progressCount : (active ? 1 : 0);
    NSString *diag = active
        ? [NSString stringWithFormat:@"UI active=%lu, fresh=%@, elements=%lu, marker=%@",
            (unsigned long)count, freshActive ? @"yes" : @"hold",
            (unsigned long)examined, matched]
        : [NSString stringWithFormat:@"UI idle, roots=%lu, elements=%lu",
            (unsigned long)[roots count], (unsigned long)examined];
    CFRelease(app);
    return @{ @"active": @(active), @"count": @(count), @"diag": diag };
}

static NSMutableDictionary *AppStorePreviousIO = nil;
static NSMutableDictionary *AppStorePreviousCPU = nil;
static NSTimeInterval AppStoreLastIOAt = 0.0;
static NSTimeInterval AppStoreLastProcessScanAt = 0.0;
static BOOL AppStoreCachedProcessActive = NO;
static NSString *AppStoreCachedProcessDiagnostic = nil;

static NSString *ProcessExecutableName(pid_t pid) {
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, pathBuffer, sizeof(pathBuffer)) > 0) {
        NSString *path = [NSString stringWithUTF8String:pathBuffer] ?: @"";
        NSString *name = [[path lastPathComponent] lowercaseString];
        if ([name length] > 0) return name;
    }
    char nameBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_name(pid, nameBuffer, sizeof(nameBuffer)) > 0) {
        return [[NSString stringWithUTF8String:nameBuffer] lowercaseString] ?: @"";
    }
    return @"";
}

static BOOL AppStoreProcessNameMatches(NSString *name) {
    NSArray *patterns = @[
        @"storedownloadd", @"appstoredownloadd", @"storeassetd",
        @"appstoreagent", @"appstored", @"appstorecomponentsd",
        @"appstoredaemon", @"storeprivilegedtaskservice",
        @"commerce", @"commercekit", @"installcoordinationd",
        @"installd", @"appinstalld", @"system_installd"
    ];
    for (NSString *pattern in patterns) {
        if ([name isEqualToString:pattern] || [name rangeOfString:pattern].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL AppStoreStrongDownloadProcessName(NSString *name) {
    return [name rangeOfString:@"storedownload"].location != NSNotFound
        || [name rangeOfString:@"appstoredownload"].location != NSNotFound;
}

static BOOL AppStoreAssetProcessName(NSString *name) {
    return [name rangeOfString:@"storeasset"].location != NSNotFound;
}

static BOOL AppStoreInstallerProcessName(NSString *name) {
    return [name rangeOfString:@"installd"].location != NSNotFound
        || [name rangeOfString:@"installcoordination"].location != NSNotFound
        || [name rangeOfString:@"appinstalld"].location != NSNotFound;
}

static NSDictionary *ScanAppStoreProcesses(NSTimeInterval nowEpoch, BOOL appStoreRunning) {
    static BOOL baselineReady = NO;
    static NSTimeInterval lastStrongHelperAt = 0.0;
    if (AppStoreLastProcessScanAt > 0.0
            && nowEpoch - AppStoreLastProcessScanAt < 0.65) {
        return @{ @"active": @(AppStoreCachedProcessActive),
                  @"diag": AppStoreCachedProcessDiagnostic ?: @"waiting for App Store I/O" };
    }
    AppStoreLastProcessScanAt = nowEpoch;
    if (AppStorePreviousIO == nil) AppStorePreviousIO = [[NSMutableDictionary alloc] init];
    if (AppStorePreviousCPU == nil) AppStorePreviousCPU = [[NSMutableDictionary alloc] init];

    int count = proc_listallpids(NULL, 0);
    if (count <= 0) {
        AppStoreCachedProcessActive = nowEpoch - AppStoreLastIOAt < 12.0;
        [AppStoreCachedProcessDiagnostic release];
        AppStoreCachedProcessDiagnostic = [@"proc_listallpids unavailable" copy];
        return @{ @"active": @(AppStoreCachedProcessActive), @"diag": AppStoreCachedProcessDiagnostic };
    }

    pid_t *pids = calloc((size_t)count, sizeof(pid_t));
    int actual = proc_listallpids(pids, count * (int)sizeof(pid_t));
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *names = [NSMutableArray array];
    BOOL activity = NO;
    NSMutableArray *evidence = [NSMutableArray array];
    uint64_t largestDiskDelta = 0;
    uint64_t largestCPUDelta = 0;

    for (int i = 0; i < actual; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        NSString *name = ProcessExecutableName(pid);
        if (!AppStoreProcessNameMatches(name)) continue;

        NSNumber *key = @(pid);
        [seen addObject:key];
        if (![names containsObject:name]) [names addObject:name];

        struct rusage_info_v4 usage;
        memset(&usage, 0, sizeof(usage));
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) continue;
        uint64_t totalIO = usage.ri_diskio_bytesread + usage.ri_diskio_byteswritten;
        uint64_t totalCPU = usage.ri_user_time + usage.ri_system_time;
        NSNumber *previousIONumber = AppStorePreviousIO[key];
        NSNumber *previousCPUNumber = AppStorePreviousCPU[key];
        uint64_t deltaIO = previousIONumber != nil && totalIO > [previousIONumber unsignedLongLongValue]
            ? totalIO - [previousIONumber unsignedLongLongValue] : 0;
        uint64_t deltaCPU = previousCPUNumber != nil && totalCPU > [previousCPUNumber unsignedLongLongValue]
            ? totalCPU - [previousCPUNumber unsignedLongLongValue] : 0;
        if (deltaIO > largestDiskDelta) largestDiskDelta = deltaIO;
        if (deltaCPU > largestCPUDelta) largestCPUDelta = deltaCPU;

        BOOL appeared = baselineReady && previousIONumber == nil;
        BOOL strongHelper = AppStoreStrongDownloadProcessName(name);
        BOOL assetHelper = AppStoreAssetProcessName(name);
        BOOL installerHelper = AppStoreInstallerProcessName(name);

        if (strongHelper || assetHelper) {
            lastStrongHelperAt = nowEpoch;
        }

        BOOL strongEvidence = NO;
        BOOL weakEvidence = NO;
        if (strongHelper) {
            strongEvidence = appeared
                || deltaIO >= 32768ULL
                || deltaCPU >= 20000000ULL;
        } else if (assetHelper) {
            strongEvidence = deltaIO >= 1048576ULL
                || deltaCPU >= 100000000ULL;
        } else if (installerHelper) {
            weakEvidence = appStoreRunning
                && (nowEpoch - lastStrongHelperAt < 45.0)
                && (deltaIO >= 131072ULL || deltaCPU >= 80000000ULL);
        } else {
            weakEvidence = appStoreRunning
                && (deltaIO >= 4194304ULL || deltaCPU >= 250000000ULL);
        }

        if (strongEvidence || weakEvidence) {
            activity = YES;
            if ([evidence count] < 5) {
                [evidence addObject:[NSString stringWithFormat:@"%@:%lluKB/%llums",
                    name,
                    (unsigned long long)(deltaIO / 1024ULL),
                    (unsigned long long)(deltaCPU / 1000000ULL)]];
            }
        }
        AppStorePreviousIO[key] = @(totalIO);
        AppStorePreviousCPU[key] = @(totalCPU);
    }
    free(pids);

    for (NSNumber *key in [NSArray arrayWithArray:[AppStorePreviousIO allKeys]]) {
        if (![seen containsObject:key]) {
            [AppStorePreviousIO removeObjectForKey:key];
            [AppStorePreviousCPU removeObjectForKey:key];
        }
    }
    baselineReady = YES;
    if (activity) AppStoreLastIOAt = nowEpoch;
    BOOL active = nowEpoch - AppStoreLastIOAt < 20.0;
    NSString *diag = [NSString stringWithFormat:@"download-process=%@, evidence=%@, io=%lluKB, cpu=%llums, hold=%@",
        [names componentsJoinedByString:@","], activity ? @"yes" : @"no",
        (unsigned long long)(largestDiskDelta / 1024ULL),
        (unsigned long long)(largestCPUDelta / 1000000ULL),
        active ? @"yes" : @"no"];
    if ([evidence count] > 0) {
        diag = [diag stringByAppendingFormat:@", marker=%@",
            [evidence componentsJoinedByString:@","]];
    }
    AppStoreCachedProcessActive = active;
    [AppStoreCachedProcessDiagnostic release];
    AppStoreCachedProcessDiagnostic = [diag copy];
    return @{ @"active": @(active), @"diag": AppStoreCachedProcessDiagnostic };
}

static BOOL IsOpenAIApplication(NSRunningApplication *application) {
    if (application == nil) return NO;
    NSString *bundleRaw = [application bundleIdentifier] ?: @"";
    NSString *nameRaw = [application localizedName] ?: @"";
    NSString *bundle = [[bundleRaw lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *name = [[nameRaw lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    return [bundle rangeOfString:@"openai"].location != NSNotFound
        || [bundle rangeOfString:@"chatgpt"].location != NSNotFound
        || [bundle rangeOfString:@"codex"].location != NSNotFound
        || [name isEqualToString:@"chatgpt"]
        || [name rangeOfString:@"chatgpt"].location != NSNotFound
        || [name isEqualToString:@"codex"]
        || [name rangeOfString:@"codex"].location != NSNotFound;
}

static BOOL IsOpenAIHelperApplication(NSRunningApplication *application) {
    if (application == nil) return NO;
    NSString *bundle = [[[application bundleIdentifier] ?: @"" lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *name = [[[application localizedName] ?: @"" lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSArray *helperPatterns = @[
        @"computer use", @"helper", @"renderer", @"gpu", @"utility",
        @"crashpad", @"web content", @"network service", @"plugin helper",
        @"agent service", @"xpc service"
    ];
    return ContainsPattern(name, helperPatterns) || ContainsPattern(bundle, helperPatterns);
}

static NSDictionary *ScanFinder(void) {
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.finder"];
    if ([apps count] == 0) {
        return @{ @"active": @NO, @"trashPromptActive": @NO,
            @"trashProgressActive": @NO, @"diag": @"Finder is not running" };
    }

    pid_t pid = (pid_t)[(NSRunningApplication *)[apps objectAtIndex:0] processIdentifier];
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    SetAXTimeout(app, 0.14);
    id windows = AXCopyValue(app, kAXWindowsAttribute);
    if (![windows isKindOfClass:[NSArray class]]) {
        CFRelease(app);
        return @{ @"active": @NO, @"trashPromptActive": @NO,
            @"trashProgressActive": @NO, @"diag": @"Finder did not return any windows" };
    }

    NSArray *copyPatterns = @[
        @"copying", @"preparing to copy", @"items to", @"item to",
        @"duplicating", @"moving", @"копирование", @"копируется",
        @"подготовка к копированию", @"дублирование", @"перемещение"
    ];
    NSArray *trashConfirmButtonPatterns = @[
        @"empty trash", @"delete all items", @"erase all items",
        @"очистить корзину", @"стереть все объекты", @"удалить все объекты"
    ];
    NSArray *trashProgressPatterns = @[
        @"emptying trash", @"deleting items from trash", @"deleting from trash",
        @"очистка корзины", @"удаление объектов из корзины",
        @"удаляются объекты из корзины", @"стирание объектов из корзины"
    ];

    BOOL active = NO;
    BOOL trashPromptActive = NO;
    BOOL trashProgressActive = NO;
    NSUInteger totalExamined = 0;
    NSString *matched = @"";
    NSString *trashPromptMatched = @"";
    NSString *trashProgressMatched = @"";

    for (id window in (NSArray *)windows) {
        NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
        NSMutableSet *visited = [NSMutableSet set];
        NSUInteger index = 0;
        NSUInteger windowExamined = 0;
        BOOL progress = NO;
        BOOL copyText = NO;
        BOOL busy = NO;

        while (index < [queue count] && windowExamined < 450 && totalExamined < 1800) {
            AXUIElementRef element = (AXUIElementRef)[queue objectAtIndex:index++];
            NSValue *pointer = [NSValue valueWithPointer:(const void *)element];
            if ([visited containsObject:pointer]) continue;
            [visited addObject:pointer];
            windowExamined++;
            totalExamined++;

            if (Truthy(AXCopyValue(element, CFSTR("AXHidden")))) continue;

            NSString *role = StringValue(AXCopyValue(element, kAXRoleAttribute));
            NSString *textValue = ElementText(element);
            if ([role isEqualToString:(NSString *)kAXProgressIndicatorRole]) progress = YES;
            if (Truthy(AXCopyValue(element, CFSTR("AXBusy")))) busy = YES;

            BOOL menuRole = [role isEqualToString:@"AXMenuItem"]
                || [role isEqualToString:@"AXMenu"]
                || [role isEqualToString:@"AXMenuBar"];
            BOOL buttonRole = [role isEqualToString:@"AXButton"];
            BOOL explicitProgressMarker =
                [textValue rangeOfString:@"progress"].location != NSNotFound
                || [textValue rangeOfString:@"axprogress"].location != NSNotFound
                || [textValue rangeOfString:@"progress indicator"].location != NSNotFound
                || [textValue rangeOfString:@"индикатор выполнения"].location != NSNotFound;

            if (!menuRole && ContainsPattern(textValue, copyPatterns)) {
                copyText = YES;
                if (explicitProgressMarker) progress = YES;
                if ([matched length] == 0) {
                    matched = [textValue length] > 180 ? [textValue substringToIndex:180] : textValue;
                }
            }



            if (buttonRole && ContainsPattern(textValue, trashConfirmButtonPatterns)) {
                trashPromptActive = YES;
                if ([trashPromptMatched length] == 0) {
                    trashPromptMatched = [textValue length] > 180
                        ? [textValue substringToIndex:180] : textValue;
                }
            }


            if (!menuRole && !buttonRole && ContainsPattern(textValue, trashProgressPatterns)) {
                trashProgressActive = YES;
                if ([trashProgressMatched length] == 0) {
                    trashProgressMatched = [textValue length] > 180
                        ? [textValue substringToIndex:180] : textValue;
                }
            }

            if (copyText && (progress || busy || explicitProgressMarker)) {
                active = YES;
            }

            if (!RoleSkipsLargeChildren(role)) AddPreferredChildren(queue, element);
        }
    }

    NSMutableString *diag = [NSMutableString stringWithFormat:@"windows=%lu, elements=%lu%@, active=%@",
        (unsigned long)[(NSArray *)windows count], (unsigned long)totalExamined,
        [matched length] ? [NSString stringWithFormat:@", marker=%@", matched] : @"",
        active ? @"yes" : @"no"];
    if ([trashPromptMatched length]) [diag appendFormat:@", trash-prompt=%@", trashPromptMatched];
    if ([trashProgressMatched length]) [diag appendFormat:@", trash-progress=%@", trashProgressMatched];

    CFRelease(app);
    return @{
        @"active": @(active),
        @"trashPromptActive": @(trashPromptActive),
        @"trashProgressActive": @(trashProgressActive),
        @"diag": diag
    };
}

static BOOL IsSafariApplication(NSRunningApplication *application) {
    if (application == nil) return NO;
    NSString *bundle = [application bundleIdentifier] ?: @"";
    return [bundle isEqualToString:@"com.apple.Safari"]
        || [bundle isEqualToString:@"com.apple.SafariTechnologyPreview"];
}

static void UpdateBluetoothConnectionEvents(NSTimeInterval nowEpoch) {
    if (nowEpoch - LastBluetoothScanAt < 0.8) return;
    LastBluetoothScanAt = nowEpoch;

    IOBluetoothHostController *controller = [IOBluetoothHostController defaultController];
    if (controller == nil || [controller powerState] != kBluetoothHCIPowerStateON) {
        [PreviousConnectedBluetoothDevices release];
        PreviousConnectedBluetoothDevices = nil;
        BluetoothBaselineReady = NO;
        return;
    }

    NSArray *paired = [IOBluetoothDevice pairedDevices] ?: @[];
    NSMutableSet *connected = [NSMutableSet set];
    NSMutableDictionary *names = [NSMutableDictionary dictionary];

    for (IOBluetoothDevice *device in paired) {
        if (device == nil || ![device isConnected]) continue;

        NSString *name = [device name] ?: @"Bluetooth device";
        NSString *lowerName = [name lowercaseString];

        if ([lowerName rangeOfString:@"applemac-led"].location != NSNotFound) {
            continue;
        }

        NSString *identity = [device addressString];
        if ([identity length] == 0) identity = name;
        if ([identity length] == 0) continue;

        [connected addObject:identity];
        [names setObject:name forKey:identity];
    }

    if (!BluetoothBaselineReady) {
        [PreviousConnectedBluetoothDevices release];
        PreviousConnectedBluetoothDevices = [connected mutableCopy];
        BluetoothBaselineReady = YES;
        return;
    }

    NSMutableSet *added = [connected mutableCopy];
    if (PreviousConnectedBluetoothDevices != nil) {
        [added minusSet:PreviousConnectedBluetoothDevices];
    }

    if ([added count] > 0) {
        BluetoothConnectEventCounter += (uint64_t)[added count];
        NSString *identity = [added anyObject];
        NSString *displayName = [names objectForKey:identity];
        if ([displayName length] == 0) displayName = identity;
        [BluetoothLastDeviceName release];
        BluetoothLastDeviceName = [displayName copy];
    }

    [added release];
    [PreviousConnectedBluetoothDevices release];
    PreviousConnectedBluetoothDevices = [connected mutableCopy];
}

static void WriteNativeState(void) {
    static uint64_t trashEventCounter = 0;
    static BOOL previousTrashPromptActive = NO;
    static BOOL previousTrashProgressActive = NO;
    static BOOL trashVerificationPending = NO;
    static NSString *trashFingerprintBefore = nil;
    static NSTimeInterval trashVerificationDeadline = 0.0;
    static NSTimeInterval lastTrashEventAt = 0.0;
    static NSTimeInterval safariFastScanUntil = 0.0;
    static NSTimeInterval lastSafariBackgroundProbeAt = 0.0;
    static BOOL cachedSafariDownloadActive = NO;
    static NSUInteger cachedSafariDownloadCount = 0;
    static NSString *cachedSafariDownloadDiagnostic = nil;
    static NSTimeInterval nextFinderScanAt = 0.0;
    static NSDictionary *cachedFinder = nil;

    BOOL trusted = AXIsProcessTrusted();
    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    NSString *frontBundle = [front bundleIdentifier] ?: @"";
    NSString *frontName = [front localizedName] ?: @"";
    NSTimeInterval nowEpoch = [[NSDate date] timeIntervalSince1970];

    BOOL finderForeground = [frontBundle isEqualToString:@"com.apple.finder"];
    BOOL shouldScanFinder = trusted && (
        finderForeground
        || previousTrashPromptActive
        || previousTrashProgressActive
        || trashVerificationPending
        || cachedFinder == nil
        || nowEpoch >= nextFinderScanAt
    );
    if (shouldScanFinder) {
        NSDictionary *freshFinder = ScanFinder();
        [cachedFinder release];
        cachedFinder = [freshFinder retain];
        nextFinderScanAt = nowEpoch + (finderForeground ? 0.55 : 2.50);
    } else if (!trusted) {
        [cachedFinder release];
        cachedFinder = nil;
    }
    NSDictionary *finder = trusted
        ? (cachedFinder ?: @{ @"active": @NO, @"trashPromptActive": @NO,
            @"trashProgressActive": @NO, @"diag": @"Finder is waiting for a check" })
        : @{ @"active": @NO, @"trashPromptActive": @NO,
            @"trashProgressActive": @NO, @"diag": @"Accessibility permission is missing" };

    BOOL trashPromptActive = [finder[@"trashPromptActive"] boolValue];
    BOOL trashProgressActive = [finder[@"trashProgressActive"] boolValue];
    NSString *currentTrashFingerprint = TrashFingerprint();



    if (trashPromptActive && !previousTrashPromptActive) {
        [trashFingerprintBefore release];
        trashFingerprintBefore = [currentTrashFingerprint copy];
        trashVerificationPending = NO;
    }



    if (!trashPromptActive && previousTrashPromptActive) {
        trashVerificationPending = YES;
        trashVerificationDeadline = nowEpoch + 3.0;
    }



    if (trashProgressActive && !previousTrashProgressActive
            && nowEpoch - lastTrashEventAt >= 2.0) {
        trashEventCounter++;
        lastTrashEventAt = nowEpoch;
        trashVerificationPending = NO;
        [trashFingerprintBefore release];
        trashFingerprintBefore = nil;
    }



    if (trashVerificationPending) {
        BOOL fingerprintAvailable = ![currentTrashFingerprint isEqualToString:@"unavailable"]
            && trashFingerprintBefore != nil
            && ![trashFingerprintBefore isEqualToString:@"unavailable"];
        if (fingerprintAvailable
                && ![currentTrashFingerprint isEqualToString:trashFingerprintBefore]) {
            if (nowEpoch - lastTrashEventAt >= 2.0) {
                trashEventCounter++;
                lastTrashEventAt = nowEpoch;
            }
            trashVerificationPending = NO;
            [trashFingerprintBefore release];
            trashFingerprintBefore = nil;
        } else if (nowEpoch >= trashVerificationDeadline) {

            trashVerificationPending = NO;
            [trashFingerprintBefore release];
            trashFingerprintBefore = nil;
        }
    }

    previousTrashPromptActive = trashPromptActive;
    previousTrashProgressActive = trashProgressActive;





    NSRunningApplication *safariApp = nil;
    BOOL safariForeground = IsSafariApplication(front);
    if (safariForeground) {
        safariApp = front;
    } else {
        for (NSRunningApplication *application in [[NSWorkspace sharedWorkspace] runningApplications]) {
            if (![application isTerminated] && IsSafariApplication(application)) {
                safariApp = application;
                break;
            }
        }
    }

    NSDictionary *safari = @{ @"tab": @NO, @"busy": @NO, @"downloadActive": @NO, @"downloadCount": @0, @"downloadDiag": @"Safari is not running", @"diag": @"Safari is not running" };
    if (trusted && safariApp != nil) {
        NSTimeInterval safariBackgroundInterval =
            (cachedSafariDownloadActive || nowEpoch < safariFastScanUntil) ? 1.25 : 6.0;
        BOOL periodicProbe = nowEpoch - lastSafariBackgroundProbeAt >= safariBackgroundInterval;
        BOOL shouldScan = safariForeground || nowEpoch < safariFastScanUntil || periodicProbe;
        if (shouldScan) {
            safari = ScanSafari((pid_t)[safariApp processIdentifier]);
            if (!safariForeground) lastSafariBackgroundProbeAt = nowEpoch;
            if ([safari[@"busy"] boolValue]) safariFastScanUntil = nowEpoch + 3.0;
            cachedSafariDownloadActive = [safari[@"downloadActive"] boolValue];
            cachedSafariDownloadCount = [safari[@"downloadCount"] unsignedIntegerValue];
            [cachedSafariDownloadDiagnostic release];
            cachedSafariDownloadDiagnostic = [(safari[@"downloadDiag"] ?: @"") copy];
        } else {
            safari = @{ @"tab": @NO, @"busy": @NO,
                @"downloadActive": @(cachedSafariDownloadActive),
                @"downloadCount": @(cachedSafariDownloadCount),
                @"downloadDiag": cachedSafariDownloadDiagnostic ?: @"Safari is in the background; waiting for the next check",
                @"diag": @"Safari is in the background; waiting for the next control check" };
        }
    } else if (safariApp == nil) {
        cachedSafariDownloadActive = NO;
        cachedSafariDownloadCount = 0;
        [cachedSafariDownloadDiagnostic release];
        cachedSafariDownloadDiagnostic = nil;
    }




    BOOL openAIForeground = IsOpenAIApplication(front)
        && !IsOpenAIHelperApplication(front);
    NSRunningApplication *openAIUIApp = nil;

    for (NSRunningApplication *application in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if ([application isTerminated] || !IsOpenAIApplication(application)) continue;
        if (IsOpenAIHelperApplication(application)) continue;
        if (openAIUIApp == nil || application == front) openAIUIApp = application;
        if (application == front) break;
    }

    BOOL openAIActive = openAIUIApp != nil;
    BOOL openAIBusy = NO;
    NSString *openAIName = openAIActive
        ? ([openAIUIApp localizedName] ?: @"ChatGPT")
        : @"";
    NSString *openAIDiagnostic = openAIActive
        ? @"ChatGPT/Codex found; AX is disabled and activity is determined by lifecycle"
        : @"ChatGPT/Codex application is not running";

    NSDictionary *safariFiles = ScanSafariDownloadFiles(nowEpoch);
    NSDictionary *safariHistory = ScanSafariDownloadHistory(nowEpoch);
    BOOL safariUIActive = [safari[@"downloadActive"] boolValue];
    BOOL safariFileActive = [safariFiles[@"active"] boolValue];
    BOOL safariHistoryActive = [safariHistory[@"active"] boolValue];
    NSUInteger safariUICount = [safari[@"downloadCount"] unsignedIntegerValue];
    NSUInteger safariFileCount = [safariFiles[@"count"] unsignedIntegerValue];
    NSUInteger safariHistoryCount = [safariHistory[@"count"] unsignedIntegerValue];
    BOOL safariCombinedDownloadActive = safariUIActive || safariFileActive || safariHistoryActive;
    NSUInteger safariCombinedDownloadCount = MAX(MAX(safariUICount, safariFileCount), safariHistoryCount);
    NSString *safariCombinedDownloadDiagnostic = [NSString stringWithFormat:@"UI=%@; files=%@; history=%@",
        safari[@"downloadDiag"] ?: @"",
        safariFiles[@"diag"] ?: @"",
        safariHistory[@"diag"] ?: @""];

    static NSTimeInterval lastAppStoreUIScanAt = 0.0;
    static NSDictionary *cachedAppStoreUI = nil;
    NSRunningApplication *appStoreApp = nil;
    BOOL appStoreForeground = IsAppStoreApplication(front);
    for (NSRunningApplication *application in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (![application isTerminated] && IsAppStoreApplication(application)) {
            appStoreApp = application;
            break;
        }
    }
    NSDictionary *appStoreProcess = ScanAppStoreProcesses(nowEpoch, appStoreApp != nil);
    NSTimeInterval appStoreUIInterval = appStoreForeground ? 0.75 : 1.50;
    BOOL shouldScanAppStoreUI = trusted && appStoreApp != nil
        && (cachedAppStoreUI == nil || nowEpoch - lastAppStoreUIScanAt >= appStoreUIInterval);
    if (shouldScanAppStoreUI) {
        NSDictionary *fresh = ScanAppStoreUI((pid_t)[appStoreApp processIdentifier], nowEpoch);
        [cachedAppStoreUI release];
        cachedAppStoreUI = [fresh retain];
        lastAppStoreUIScanAt = nowEpoch;
    } else if (appStoreApp == nil) {
        [cachedAppStoreUI release];
        cachedAppStoreUI = nil;
        lastAppStoreUIScanAt = 0.0;
    }
    NSDictionary *appStoreUI = cachedAppStoreUI
        ?: @{ @"active": @NO, @"count": @0,
              @"diag": appStoreApp != nil ? @"App Store UI is waiting for a check" : @"App Store is not running" };
    BOOL appStoreDownloadActive = [appStoreUI[@"active"] boolValue]
        || [appStoreProcess[@"active"] boolValue];
    NSString *appStoreDiagnostic = [NSString stringWithFormat:@"%@; %@",
        appStoreUI[@"diag"] ?: @"", appStoreProcess[@"diag"] ?: @""];

    NSDictionary *state = @{
        @"updatedAt": @(nowEpoch),
        @"axTrusted": @(trusted),
        @"frontBundle": frontBundle,
        @"frontName": frontName,
        @"bluetoothEventCounter": @(BluetoothConnectEventCounter),
        @"bluetoothDeviceName": BluetoothLastDeviceName ?: @"",
        @"finderForeground": @(finderForeground),
        @"finderCopyActive": finder[@"active"] ?: @NO,
        @"finderDiagnostic": finder[@"diag"] ?: @"",
        @"trashEventCounter": @(trashEventCounter),
        @"trashPromptActive": @(trashPromptActive),
        @"trashProgressActive": @(trashProgressActive),
        @"trashVerificationPending": @(trashVerificationPending),
        @"safariForeground": @(safariForeground),
        @"safariChatGPTTabActive": safari[@"tab"] ?: @NO,
        @"safariChatGPTBusy": safari[@"busy"] ?: @NO,
        @"safariDownloadActive": @(safariCombinedDownloadActive),
        @"safariDownloadCount": @(safariCombinedDownloadCount),
        @"safariDownloadDiagnostic": safariCombinedDownloadDiagnostic,
        @"safariDiagnostic": safari[@"diag"] ?: @"",
        @"appStoreDownloadActive": @(appStoreDownloadActive),
        @"appStoreDiagnostic": appStoreDiagnostic,
        @"openAIAppForeground": @(openAIForeground),
        @"openAIAppActive": @(openAIActive),
        @"openAIAppBusy": @(openAIBusy),
        @"openAIAppName": openAIName,
        @"openAIAppDiagnostic": openAIDiagnostic
    };

    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:state options:0 error:&error];
    if (json != nil) {
        [json writeToFile:StatePath options:NSDataWritingAtomic error:&error];
    }

    UpdateBluetoothConnectionEvents(nowEpoch);
}


int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSDictionary *options = @{ (NSString *)kAXTrustedCheckOptionPrompt: @NO };
        AXIsProcessTrustedWithOptions((CFDictionaryRef)options);

        const char *runner = "$RUN_AGENT";
        pid_t pid = 0;
        char *const argv[] = {"/bin/zsh", (char *)runner, NULL};

        signal(SIGTERM, forward_signal);
        signal(SIGINT, forward_signal);
        signal(SIGHUP, forward_signal);
        signal(SIGALRM, native_watchdog_timeout);

        int result = posix_spawn(&pid, "/bin/zsh", NULL, NULL, argv, environ);
        if (result != 0) {
            fprintf(stderr, "AppleMACLED Agent: posix_spawn failed: %s\\n", strerror(result));
            return 1;
        }

        child_pid = (sig_atomic_t)pid;
        int status = 0;
        NSTimeInterval nextScan = 0.0;
        for (;;) {
            pid_t waited = waitpid(pid, &status, WNOHANG);
            if (waited == pid) break;
            if (waited == -1 && errno != EINTR) return 1;

            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            if (now >= nextScan) {
                alarm(NativeUiScanTimeoutSeconds);
                @autoreleasepool { WriteNativeState(); }
                alarm(0);
                nextScan = now + 0.50;
            }
            @autoreleasepool { EnsureAudioMeterStarted(); }

            [[NSRunLoop currentRunLoop]
                runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.04]];
        }

        if (WIFEXITED(status)) return WEXITSTATUS(status);
        if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
        return 1;
    }
}
SRC

/usr/bin/clang -O2 -Wall -Wextra \
  -fblocks \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework IOBluetooth \
  -framework ScreenCaptureKit \
  -framework CoreMedia \
  -framework AudioToolbox \
  "$SOURCE_FILE" -o "$APP_EXECUTABLE"
rm -f "$SOURCE_FILE"
chmod +x "$APP_EXECUTABLE"
echo "36.14-lighting" > "$LAUNCHER_MARKER"

cat > "$LAUNCH_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_EXECUTABLE</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launcher.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launcher-error.log</string>
</dict>
</plist>
PLIST

plutil -lint "$INFO_PLIST" >/dev/null
plutil -lint "$LAUNCH_PLIST" >/dev/null
/usr/bin/codesign --force --deep --sign - \
  --identifier com.applemacled.agent \
  --requirements '=designated => identifier "com.applemacled.agent"' \
  "$APP_BUNDLE" >/dev/null

if ! /usr/bin/codesign -d -r- "$APP_BUNDLE" 2>&1 \
  | /usr/bin/grep -Fq 'designated => identifier "com.applemacled.agent"'; then
  echo "Error: the application does not have a stable code-signing identity."
  exit 1
fi

touch "$LOG_DIR/launcher.log" "$LOG_DIR/launcher-error.log" "$LOG_DIR/agent.log" "$LOG_DIR/agent-error.log"




launchctl bootstrap "gui/$UID_VALUE" "$LAUNCH_PLIST"
launchctl kickstart -k "gui/$UID_VALUE/$LABEL"

sleep 2
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true

echo
echo "Done. The native AppleMACLED Agent application is installed."
echo
echo "IMPORTANT: enable AppleMACLED Agent in:"
echo "  Privacy & Security → Accessibility"
echo
echo "Finder/Safari Automation and Input Monitoring are not required by this version."
echo "ChatGPT/Codex does not use Accessibility; only task lifecycle is used."
echo "For the Safari file indicator, macOS may request access to the Downloads folder."
echo "For music mode, macOS may request Screen Recording/system audio permission."
echo
echo "After enabling Accessibility, restart the agent:"
echo "  launchctl kickstart -k \"gui/$(id -u)/com.applemacled.agent\""
echo
echo "Main log:"
echo "  tail -f \"$LOG_DIR/agent.log\""
echo
echo "Native state:"
echo "  cat \"$NATIVE_STATE\""
echo
echo "Audio state:"
echo "  cat \"$NATIVE_AUDIO_STATE\""
echo
