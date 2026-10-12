// Loads VoidampMic.driver in-process and drives it the way coreaudiod would: discovery, properties, a sample
// rate change and IO. Audio written to a device's output must come back on its input, once.
// Usage: DriverCheck path/to/VoidampMic.driver

#include <CoreAudio/AudioServerPlugIn.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static AudioServerPlugInDriverRef gDriver;
static int gFailures = 0;

#define CHECK(condition, message) do { if (condition) printf("ok   %s\n", message); else { printf("FAIL %s\n", message); gFailures++; } } while (0)

static OSStatus PropertiesChanged(AudioServerPlugInHostRef host, AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress *addresses) {
    (void)host; (void)object; (void)count; (void)addresses; return noErr;
}
// The host's storage for the plug-in, kept in memory.
static CFMutableDictionaryRef gStorage;
static OSStatus CopyFromStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef *outData) {
    (void)host;
    CFPropertyListRef value = CFDictionaryGetValue(gStorage, key);
    *outData = value ? CFRetain(value) : NULL;
    return noErr;
}
static OSStatus WriteToStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef data) {
    (void)host; CFDictionarySetValue(gStorage, key, data); return noErr;
}
static OSStatus DeleteFromStorage(AudioServerPlugInHostRef host, CFStringRef key) {
    (void)host; CFDictionaryRemoveValue(gStorage, key); return noErr;
}
// Like coreaudiod, apply a requested change straight away.
static OSStatus RequestChange(AudioServerPlugInHostRef host, AudioObjectID device, UInt64 action, void *info) {
    (void)host; return (*gDriver)->PerformDeviceConfigurationChange(gDriver, device, action, info);
}
static AudioServerPlugInHostInterface gHost = { PropertiesChanged, CopyFromStorage, WriteToStorage, DeleteFromStorage, RequestChange };

static OSStatus Get(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope, UInt32 size, void *data, UInt32 *outSize) {
    AudioObjectPropertyAddress address = { selector, scope, kAudioObjectPropertyElementMain };
    UInt32 written = 0;
    OSStatus status = (*gDriver)->GetPropertyData(gDriver, object, 0, &address, 0, NULL, size, &written, data);
    if (outSize) *outSize = written;
    return status;
}

static Boolean StringEquals(CFStringRef string, const char *expected) {
    char buffer[256] = { 0 };
    CFStringGetCString(string, buffer, sizeof buffer, kCFStringEncodingUTF8);
    return strcmp(buffer, expected) == 0;
}

int main(int argc, const char **argv) {
    if (argc < 2) { fprintf(stderr, "Usage: DriverCheck VoidampMic.driver\n"); return 2; }
    char executable[1024];
    snprintf(executable, sizeof executable, "%s/Contents/MacOS/VoidampMic", argv[1]);
    void *library = dlopen(executable, RTLD_NOW | RTLD_LOCAL);
    if (!library) { printf("FAIL loading %s: %s\n", executable, dlerror()); return 1; }
    void *(*create)(CFAllocatorRef, CFUUIDRef) = dlsym(library, "VoidampMic_Create");
    CHECK(create != NULL, "factory VoidampMic_Create is exported");
    if (!create) return 1;

    void *object = create(NULL, kAudioServerPlugInTypeUUID);
    CHECK(object != NULL, "factory answers the server plug-in type");
    CHECK(create(NULL, IUnknownUUID) == NULL, "factory refuses other types");
    AudioServerPlugInDriverRef driver = NULL;
    CFUUIDBytes interface = CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID);
    HRESULT query = (*(AudioServerPlugInDriverRef)object)->QueryInterface(object, interface, (void **)&driver);
    CHECK(query == S_OK && driver != NULL, "driver interface is available");
    gDriver = driver;
    gStorage = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CHECK((*gDriver)->Initialize(gDriver, &gHost) == noErr, "initializes");

    AudioObjectID devices[8] = { 0 };
    UInt32 size = 0;
    Get(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, sizeof devices, devices, &size);
    CHECK(size == 2 * sizeof(AudioObjectID) && devices[0] == 2 && devices[1] == 5, "lists two devices");

    for (int i = 0; i < 2; i++) {
        AudioObjectID device = devices[i];
        char expectedName[64], expectedUID[64], label[160];
        snprintf(expectedName, sizeof expectedName, "Voidamp Mic %d", i + 1);
        snprintf(expectedUID, sizeof expectedUID, "app.voidamp.mic.%d", i + 1);
        CFStringRef name = NULL, uid = NULL;
        Get(device, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, sizeof name, &name, NULL);
        Get(device, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, sizeof uid, &uid, NULL);
        snprintf(label, sizeof label, "device %u is named %s with UID %s", device, expectedName, expectedUID);
        CHECK(name && uid && StringEquals(name, expectedName) && StringEquals(uid, expectedUID), label);
        if (name) CFRelease(name);
        if (uid) CFRelease(uid);

        UInt32 inputDefault = 0, outputDefault = 1, systemDefault = 1;
        Get(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput, 4, &inputDefault, NULL);
        Get(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput, 4, &outputDefault, NULL);
        Get(device, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput, 4, &systemDefault, NULL);
        CHECK(inputDefault == 1 && outputDefault == 0 && systemDefault == 0, "can be the default microphone, never the default or alert output");

        AudioObjectID streams[4] = { 0 };
        Get(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, sizeof streams, streams, &size);
        CHECK(size == 4 && streams[0] == device + 1, "one input stream");
        UInt32 direction = 0;
        Get(streams[0], kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal, 4, &direction, NULL);
        CHECK(direction == 1, "input stream reads");
        Get(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, sizeof streams, streams, &size);
        CHECK(size == 4 && streams[0] == device + 2, "one output stream");

        AudioStreamBasicDescription format;
        Get(device + 1, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, sizeof format, &format, NULL);
        CHECK(format.mSampleRate == 48000 && format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32 &&
              (format.mFormatFlags & kAudioFormatFlagIsFloat), "48 kHz stereo float");
    }

    AudioObjectID found = 0;
    CFStringRef wanted = CFSTR("app.voidamp.mic.2");
    AudioObjectPropertyAddress translate = { kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    (*gDriver)->GetPropertyData(gDriver, kAudioObjectPlugInObject, 0, &translate, sizeof wanted, &wanted, sizeof found, &size, &found);
    CHECK(found == 5, "finds a device by UID");

    // Sample rate changes go through the host and back.
    AudioObjectPropertyAddress rate = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 value = 44100;
    CHECK((*gDriver)->SetPropertyData(gDriver, 2, 0, &rate, 0, NULL, sizeof value, &value) == noErr, "accepts 44.1 kHz");
    Get(2, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, sizeof value, &value, NULL);
    CHECK(value == 44100, "runs at 44.1 kHz");
    value = 32000;
    CHECK((*gDriver)->SetPropertyData(gDriver, 2, 0, &rate, 0, NULL, sizeof value, &value) != noErr, "refuses 32 kHz");
    value = 48000;
    (*gDriver)->SetPropertyData(gDriver, 2, 0, &rate, 0, NULL, sizeof value, &value);

    CHECK(!(*gDriver)->HasProperty(gDriver, 99, 0, &rate), "unknown objects have no properties");

    // Renaming: apps see the new name, it survives a restart of the driver, and an empty name restores the default.
    AudioObjectPropertyAddress nameAddress = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Boolean settable = false;
    (*gDriver)->IsPropertySettable(gDriver, 2, 0, &nameAddress, &settable);
    CHECK(settable, "device name is settable");
    CFStringRef newName = CFSTR("  Discord Mic  ");
    CHECK((*gDriver)->SetPropertyData(gDriver, 2, 0, &nameAddress, 0, NULL, sizeof newName, &newName) == noErr, "renames Mic 1");
    CFStringRef current = NULL;
    Get(2, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, sizeof current, &current, NULL);
    CHECK(current && StringEquals(current, "Discord Mic"), "apps see the new name, trimmed");
    if (current) CFRelease(current);
    (*gDriver)->Initialize(gDriver, &gHost);
    Get(2, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, sizeof current, &current, NULL);
    CHECK(current && StringEquals(current, "Discord Mic"), "the name survives a restart");
    if (current) CFRelease(current);
    Get(5, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, sizeof current, &current, NULL);
    CHECK(current && StringEquals(current, "Voidamp Mic 2"), "Mic 2 keeps its name");
    if (current) CFRelease(current);
    CFStringRef empty = CFSTR(" ");
    (*gDriver)->SetPropertyData(gDriver, 2, 0, &nameAddress, 0, NULL, sizeof empty, &empty);
    Get(2, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, sizeof current, &current, NULL);
    CHECK(current && StringEquals(current, "Voidamp Mic 1") && CFDictionaryGetCount(gStorage) == 0, "an empty name restores the default");
    if (current) CFRelease(current);
    CHECK((*gDriver)->SetPropertyData(gDriver, 3, 0, &nameAddress, 0, NULL, sizeof newName, &newName) != noErr, "streams can't be renamed");

    // IO: write a tone at an output time, read it back at the same input time, once.
    CHECK((*gDriver)->StartIO(gDriver, 2, 1) == noErr, "starts IO");
    UInt32 running = 0;
    Get(2, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, 4, &running, NULL);
    CHECK(running == 1, "reports running");
    Float64 sampleTime = -1; UInt64 hostTime = 0, seed = 0;
    CHECK((*gDriver)->GetZeroTimeStamp(gDriver, 2, 1, &sampleTime, &hostTime, &seed) == noErr && sampleTime == 0 && hostTime > 0, "gives a zero time stamp");
    Boolean willDo = false, inPlace = false;
    (*gDriver)->WillDoIOOperation(gDriver, 2, 1, kAudioServerPlugInIOOperationWriteMix, &willDo, &inPlace);
    CHECK(willDo && inPlace, "takes the output mix in place");

    enum { kFrames = 512 };
    Float32 tone[kFrames * 2], heard[kFrames * 2];
    Float64 starts[] = { 1000, 16384 - 200, 40000.0 };
    for (int test = 0; test < 3; test++) {
        for (int f = 0; f < kFrames; f++) tone[f * 2] = tone[f * 2 + 1] = 0.5f * sinf((float)f * 0.05f + (float)test);
        AudioServerPlugInIOCycleInfo cycle;
        memset(&cycle, 0, sizeof cycle);
        cycle.mOutputTime.mSampleTime = starts[test];
        cycle.mInputTime.mSampleTime = starts[test];
        (*gDriver)->DoIOOperation(gDriver, 2, 4, 1, kAudioServerPlugInIOOperationWriteMix, kFrames, &cycle, tone, NULL);
        memset(heard, 0, sizeof heard);
        (*gDriver)->DoIOOperation(gDriver, 2, 3, 1, kAudioServerPlugInIOOperationReadInput, kFrames, &cycle, heard, NULL);
        char label[96];
        snprintf(label, sizeof label, "loops audio back at sample %.0f", starts[test]);
        CHECK(memcmp(tone, heard, sizeof tone) == 0, label);
        (*gDriver)->DoIOOperation(gDriver, 2, 3, 1, kAudioServerPlugInIOOperationReadInput, kFrames, &cycle, heard, NULL);
        Float32 loudest = 0;
        for (int s = 0; s < kFrames * 2; s++) loudest = fmaxf(loudest, fabsf(heard[s]));
        CHECK(loudest == 0, "reads each sample once, then silence");
    }
    // The other device is separate.
    AudioServerPlugInIOCycleInfo cycle;
    memset(&cycle, 0, sizeof cycle);
    cycle.mOutputTime.mSampleTime = cycle.mInputTime.mSampleTime = 2000;
    (*gDriver)->DoIOOperation(gDriver, 2, 4, 1, kAudioServerPlugInIOOperationWriteMix, kFrames, &cycle, tone, NULL);
    (*gDriver)->StartIO(gDriver, 5, 1);
    memset(heard, 0, sizeof heard);
    (*gDriver)->DoIOOperation(gDriver, 5, 6, 1, kAudioServerPlugInIOOperationReadInput, kFrames, &cycle, heard, NULL);
    Float32 leaked = 0;
    for (int s = 0; s < kFrames * 2; s++) leaked = fmaxf(leaked, fabsf(heard[s]));
    CHECK(leaked == 0, "Mic 2 doesn't hear Mic 1");
    CHECK((*gDriver)->StopIO(gDriver, 2, 1) == noErr && (*gDriver)->StopIO(gDriver, 5, 1) == noErr, "stops IO");
    Get(2, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, 4, &running, NULL);
    CHECK(running == 0, "reports stopped");

    printf(gFailures == 0 ? "PASS: driver\n" : "FAIL: %d checks\n", gFailures);
    return gFailures == 0 ? 0 : 1;
}
