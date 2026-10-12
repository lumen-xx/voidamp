// Voidamp Mic: a Core Audio server plug-in with virtual microphones. Each device has an output stream and an
// input stream on one clock; audio written to the output comes back on the input a few milliseconds later.
// Voidamp writes a real microphone (or an app) to the output, and apps such as Discord choose the device as
// their microphone. The output side can't become the default output, so system sound never lands there.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define kDeviceCount 2
#define kChannels 2
#define kBytesPerFrame (kChannels * sizeof(Float32))
// The ring spans far more than one IO cycle, and its length is also the zero time stamp period.
#define kRingFrames 16384
#define kManufacturer CFSTR("Voidamp")

static const Float64 kSampleRates[] = { 44100.0, 48000.0 };
static const UInt32 kSampleRateCount = sizeof(kSampleRates) / sizeof(kSampleRates[0]);

// Object IDs: the plug-in is 1; device i owns three consecutive IDs: the device and its input and output streams.
static inline AudioObjectID DeviceObject(UInt32 i) { return 2 + i * 3; }
static inline AudioObjectID InputStreamObject(UInt32 i) { return 3 + i * 3; }
static inline AudioObjectID OutputStreamObject(UInt32 i) { return 4 + i * 3; }

enum ObjectKind { kKindDevice = 0, kKindInputStream = 1, kKindOutputStream = 2 };

typedef struct {
    Float64 sampleRate;
    Float64 hostTicksPerFrame;
    UInt64 ioClients;
    UInt64 anchorHostTime;
    UInt64 timeStampCount;
    Boolean inputActive;
    Boolean outputActive;
    Float32 *ring;
    pthread_mutex_t mutex;
} Device;

static Device gDevices[kDeviceCount];
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;
static Float64 gHostTicksPerSecond = 0;

// Which device an object belongs to and what it is; -1 for the plug-in or an unknown object.
static int DeviceIndex(AudioObjectID object, enum ObjectKind *kind) {
    if (object < 2) return -1;
    UInt32 index = (object - 2) / 3;
    if (index >= kDeviceCount) return -1;
    if (kind) *kind = (enum ObjectKind)((object - 2) % 3);
    return (int)index;
}

static void FillFormat(AudioStreamBasicDescription *format, Float64 rate) {
    memset(format, 0, sizeof(*format));
    format->mSampleRate = rate;
    format->mFormatID = kAudioFormatLinearPCM;
    format->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format->mBytesPerPacket = kBytesPerFrame;
    format->mFramesPerPacket = 1;
    format->mBytesPerFrame = kBytesPerFrame;
    format->mChannelsPerFrame = kChannels;
    format->mBitsPerChannel = 32;
}

static Boolean IsSupportedRate(Float64 rate) {
    for (UInt32 i = 0; i < kSampleRateCount; i++) if (kSampleRates[i] == rate) return true;
    return false;
}

// MARK: - IUnknown

static HRESULT QueryInterface(void *driver, REFIID uuid, LPVOID *outInterface);
static ULONG AddRef(void *driver);
static ULONG Release(void *driver);
static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host);
static OSStatus CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo *client, AudioObjectID *outDevice);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID device);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID device, const AudioServerPlugInClientInfo *client);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID device, const AudioServerPlugInClientInfo *client);
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt64 action, void *info);
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt64 action, void *info);
static Boolean HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client, const AudioObjectPropertyAddress *address);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client, const AudioObjectPropertyAddress *address, Boolean *outSettable);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 *outSize);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 inSize, UInt32 *outSize, void *outData);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 inSize, const void *inData);
static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client);
static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client, UInt32 operation, Boolean *outWillDo, Boolean *outInPlace);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, AudioObjectID stream, UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *mainBuffer, void *secondaryBuffer);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle);

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient,
    RemoveDeviceClient, PerformDeviceConfigurationChange, AbortDeviceConfigurationChange, HasProperty,
    IsPropertySettable, GetPropertyDataSize, GetPropertyData, SetPropertyData, StartIO, StopIO, GetZeroTimeStamp,
    WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation
};
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePointer;

// The factory named in Info.plist.
__attribute__((visibility("default")))
void *VoidampMic_Create(CFAllocatorRef allocator, CFUUIDRef requestedType) {
    (void)allocator;
    return CFEqual(requestedType, kAudioServerPlugInTypeUUID) ? gDriver : NULL;
}

static HRESULT QueryInterface(void *driver, REFIID uuid, LPVOID *outInterface) {
    if (driver != gDriver || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriver;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AddRef(void *driver) {
    if (driver != gDriver) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG Release(void *driver) {
    if (driver != gDriver) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

// MARK: - Plug-in lifecycle

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (driver != gDriver) return kAudioHardwareBadObjectError;
    gHost = host;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    gHostTicksPerSecond = 1e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    for (UInt32 i = 0; i < kDeviceCount; i++) {
        Device *device = &gDevices[i];
        device->sampleRate = 48000.0;
        device->hostTicksPerFrame = gHostTicksPerSecond / device->sampleRate;
        device->inputActive = true;
        device->outputActive = true;
        device->ring = calloc((size_t)kRingFrames * kChannels, sizeof(Float32));
        pthread_mutex_init(&device->mutex, NULL);
    }
    return noErr;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo *client, AudioObjectID *outDevice) {
    (void)driver; (void)description; (void)client; (void)outDevice;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID device) {
    (void)driver; (void)device;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID device, const AudioServerPlugInClientInfo *client) {
    (void)client;
    return driver == gDriver && DeviceIndex(device, NULL) >= 0 ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID device, const AudioServerPlugInClientInfo *client) {
    (void)client;
    return driver == gDriver && DeviceIndex(device, NULL) >= 0 ? noErr : kAudioHardwareBadObjectError;
}

// The only configuration change is the sample rate; the action carries the new rate.
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt64 action, void *info) {
    (void)info;
    enum ObjectKind kind;
    int index = DeviceIndex(object, &kind);
    if (driver != gDriver || index < 0 || kind != kKindDevice) return kAudioHardwareBadObjectError;
    Float64 rate = (Float64)action;
    if (!IsSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
    Device *device = &gDevices[index];
    pthread_mutex_lock(&device->mutex);
    device->sampleRate = rate;
    device->hostTicksPerFrame = gHostTicksPerSecond / rate;
    memset(device->ring, 0, (size_t)kRingFrames * kBytesPerFrame);
    pthread_mutex_unlock(&device->mutex);
    return noErr;
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt64 action, void *info) {
    (void)driver; (void)device; (void)action; (void)info;
    return noErr;
}

// Rate changes go through the host, which stops IO and then calls PerformDeviceConfigurationChange.
static OSStatus RequestRate(int index, Float64 rate) {
    if (!IsSupportedRate(rate)) return kAudioDeviceUnsupportedFormatError;
    if (rate == gDevices[index].sampleRate || gHost == NULL) return noErr;
    return gHost->RequestDeviceConfigurationChange(gHost, DeviceObject((UInt32)index), (UInt64)rate, NULL);
}

// MARK: - Properties

static CFStringRef DeviceName(UInt32 i) { return CFStringCreateWithFormat(NULL, NULL, CFSTR("Voidamp Mic %u"), (unsigned)(i + 1)); }
static CFStringRef DeviceUID(UInt32 i) { return CFStringCreateWithFormat(NULL, NULL, CFSTR("app.voidamp.mic.%u"), (unsigned)(i + 1)); }

static Boolean HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client, const AudioObjectPropertyAddress *address) {
    (void)client;
    if (driver != gDriver || address == NULL) return false;
    if (object == kAudioObjectPlugInObject) {
        switch (address->mSelector) {
            case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyBoxList:
            case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice: case kAudioPlugInPropertyResourceBundle:
                return true;
        }
        return false;
    }
    enum ObjectKind kind;
    if (DeviceIndex(object, &kind) < 0) return false;
    if (kind == kKindDevice) {
        switch (address->mSelector) {
            case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: case kAudioDevicePropertyLatency: case kAudioDevicePropertyStreams:
            case kAudioObjectPropertyControlList: case kAudioDevicePropertySafetyOffset: case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates: case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyPreferredChannelsForStereo: case kAudioDevicePropertyPreferredChannelLayout:
            case kAudioDevicePropertyZeroTimeStampPeriod:
                return true;
        }
        return false;
    }
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects: case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
    }
    return false;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client, const AudioObjectPropertyAddress *address, Boolean *outSettable) {
    if (!HasProperty(driver, object, client, address) || outSettable == NULL) return kAudioHardwareUnknownPropertyError;
    enum ObjectKind kind = kKindDevice;
    Boolean isDevice = DeviceIndex(object, &kind) >= 0;
    switch (address->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
            *outSettable = isDevice && kind == kKindDevice; break;
        case kAudioStreamPropertyIsActive: case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
            *outSettable = isDevice && kind != kKindDevice; break;
        default:
            *outSettable = false;
    }
    return noErr;
}

// The streams a device lists for a scope: global lists both.
static UInt32 StreamsForScope(UInt32 index, AudioObjectPropertyScope scope, AudioObjectID *streams) {
    UInt32 count = 0;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput) streams[count++] = InputStreamObject(index);
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput) streams[count++] = OutputStreamObject(index);
    return count;
}

static UInt32 ChannelLayoutSize(void) {
    return (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 *outSize) {
    (void)qualifierSize; (void)qualifier;
    if (!HasProperty(driver, object, client, address) || outSize == NULL) return kAudioHardwareUnknownPropertyError;
    AudioObjectID streams[2];
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: *outSize = sizeof(AudioClassID); return noErr;
        case kAudioObjectPropertyOwner: *outSize = sizeof(AudioObjectID); return noErr;
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID: case kAudioPlugInPropertyResourceBundle:
            *outSize = sizeof(CFStringRef); return noErr;
        case kAudioPlugInPropertyBoxList: case kAudioObjectPropertyControlList: *outSize = 0; return noErr;
        case kAudioPlugInPropertyDeviceList: *outSize = kDeviceCount * sizeof(AudioObjectID); return noErr;
        case kAudioPlugInPropertyTranslateUIDToDevice: *outSize = sizeof(AudioObjectID); return noErr;
        case kAudioDevicePropertyRelatedDevices: *outSize = sizeof(AudioObjectID); return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates: *outSize = kSampleRateCount * sizeof(AudioValueRange); return noErr;
        case kAudioDevicePropertyNominalSampleRate: *outSize = sizeof(Float64); return noErr;
        case kAudioDevicePropertyPreferredChannelsForStereo: *outSize = 2 * sizeof(UInt32); return noErr;
        case kAudioDevicePropertyPreferredChannelLayout: *outSize = ChannelLayoutSize(); return noErr;
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: *outSize = sizeof(AudioStreamBasicDescription); return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            *outSize = kSampleRateCount * sizeof(AudioStreamRangedDescription); return noErr;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            if (object == kAudioObjectPlugInObject) { *outSize = kDeviceCount * sizeof(AudioObjectID); return noErr; }
            enum ObjectKind kind;
            int index = DeviceIndex(object, &kind);
            *outSize = kind == kKindDevice ? StreamsForScope((UInt32)index, address->mScope, streams) * sizeof(AudioObjectID) : 0;
            return noErr;
        }
        default: *outSize = sizeof(UInt32); return noErr;
    }
}

#define REQUIRE_SIZE(type) do { if (inSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; *outSize = sizeof(type); } while (0)

static OSStatus GetPlugInProperty(const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 inSize, UInt32 *outSize, void *outData) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: REQUIRE_SIZE(AudioClassID); *(AudioClassID *)outData = kAudioObjectClassID; return noErr;
        case kAudioObjectPropertyClass: REQUIRE_SIZE(AudioClassID); *(AudioClassID *)outData = kAudioPlugInClassID; return noErr;
        case kAudioObjectPropertyOwner: REQUIRE_SIZE(AudioObjectID); *(AudioObjectID *)outData = kAudioObjectUnknown; return noErr;
        case kAudioObjectPropertyManufacturer: REQUIRE_SIZE(CFStringRef); *(CFStringRef *)outData = kManufacturer; return noErr;
        case kAudioPlugInPropertyResourceBundle: REQUIRE_SIZE(CFStringRef); *(CFStringRef *)outData = CFSTR(""); return noErr;
        case kAudioPlugInPropertyBoxList: *outSize = 0; return noErr;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            UInt32 count = inSize / sizeof(AudioObjectID);
            if (count > kDeviceCount) count = kDeviceCount;
            for (UInt32 i = 0; i < count; i++) ((AudioObjectID *)outData)[i] = DeviceObject(i);
            *outSize = count * sizeof(AudioObjectID);
            return noErr;
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            REQUIRE_SIZE(AudioObjectID);
            if (qualifierSize < sizeof(CFStringRef) || qualifier == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef *)qualifier;
            AudioObjectID found = kAudioObjectUnknown;
            for (UInt32 i = 0; i < kDeviceCount; i++) {
                CFStringRef candidate = DeviceUID(i);
                if (uid && CFEqual(uid, candidate)) found = DeviceObject(i);
                CFRelease(candidate);
            }
            *(AudioObjectID *)outData = found;
            return noErr;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus GetDeviceProperty(UInt32 index, const AudioObjectPropertyAddress *address, UInt32 inSize, UInt32 *outSize, void *outData) {
    Device *device = &gDevices[index];
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: REQUIRE_SIZE(AudioClassID); *(AudioClassID *)outData = kAudioObjectClassID; return noErr;
        case kAudioObjectPropertyClass: REQUIRE_SIZE(AudioClassID); *(AudioClassID *)outData = kAudioDeviceClassID; return noErr;
        case kAudioObjectPropertyOwner: REQUIRE_SIZE(AudioObjectID); *(AudioObjectID *)outData = kAudioObjectPlugInObject; return noErr;
        case kAudioObjectPropertyName: REQUIRE_SIZE(CFStringRef); *(CFStringRef *)outData = DeviceName(index); return noErr;
        case kAudioObjectPropertyManufacturer: REQUIRE_SIZE(CFStringRef); *(CFStringRef *)outData = kManufacturer; return noErr;
        case kAudioDevicePropertyDeviceUID: REQUIRE_SIZE(CFStringRef); *(CFStringRef *)outData = DeviceUID(index); return noErr;
        case kAudioDevicePropertyModelUID: REQUIRE_SIZE(CFStringRef); *(CFStringRef *)outData = CFSTR("app.voidamp.mic.model"); return noErr;
        case kAudioDevicePropertyTransportType: REQUIRE_SIZE(UInt32); *(UInt32 *)outData = kAudioDeviceTransportTypeVirtual; return noErr;
        case kAudioDevicePropertyRelatedDevices: REQUIRE_SIZE(AudioObjectID); *(AudioObjectID *)outData = DeviceObject(index); return noErr;
        case kAudioDevicePropertyClockDomain: REQUIRE_SIZE(UInt32); *(UInt32 *)outData = 0; return noErr;
        case kAudioDevicePropertyDeviceIsAlive: REQUIRE_SIZE(UInt32); *(UInt32 *)outData = 1; return noErr;
        case kAudioDevicePropertyDeviceIsRunning: {
            REQUIRE_SIZE(UInt32);
            pthread_mutex_lock(&device->mutex);
            *(UInt32 *)outData = device->ioClients > 0;
            pthread_mutex_unlock(&device->mutex);
            return noErr;
        }
        // A microphone: it can be the default input, never the default or alert output.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            REQUIRE_SIZE(UInt32); *(UInt32 *)outData = address->mScope == kAudioObjectPropertyScopeInput; return noErr;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: REQUIRE_SIZE(UInt32); *(UInt32 *)outData = 0; return noErr;
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
            REQUIRE_SIZE(UInt32); *(UInt32 *)outData = 0; return noErr;
        case kAudioDevicePropertyIsHidden: REQUIRE_SIZE(UInt32); *(UInt32 *)outData = 0; return noErr;
        case kAudioDevicePropertyZeroTimeStampPeriod: REQUIRE_SIZE(UInt32); *(UInt32 *)outData = kRingFrames; return noErr;
        case kAudioObjectPropertyControlList: *outSize = 0; return noErr;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            AudioObjectID streams[2];
            UInt32 count = StreamsForScope(index, address->mScope, streams);
            UInt32 room = inSize / sizeof(AudioObjectID);
            if (count > room) count = room;
            memcpy(outData, streams, count * sizeof(AudioObjectID));
            *outSize = count * sizeof(AudioObjectID);
            return noErr;
        }
        case kAudioDevicePropertyNominalSampleRate: {
            REQUIRE_SIZE(Float64);
            pthread_mutex_lock(&device->mutex);
            *(Float64 *)outData = device->sampleRate;
            pthread_mutex_unlock(&device->mutex);
            return noErr;
        }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 count = inSize / sizeof(AudioValueRange);
            if (count > kSampleRateCount) count = kSampleRateCount;
            for (UInt32 i = 0; i < count; i++) ((AudioValueRange *)outData)[i] = (AudioValueRange){ kSampleRates[i], kSampleRates[i] };
            *outSize = count * sizeof(AudioValueRange);
            return noErr;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)outData)[0] = 1; ((UInt32 *)outData)[1] = 2;
            *outSize = 2 * sizeof(UInt32);
            return noErr;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = ChannelLayoutSize();
            if (inSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout *layout = outData;
            memset(layout, 0, size);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = kChannels;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outSize = size;
            return noErr;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus GetStreamProperty(UInt32 index, enum ObjectKind kind, const AudioObjectPropertyAddress *address, UInt32 inSize, UInt32 *outSize, void *outData) {
    Device *device = &gDevices[index];
    Boolean input = kind == kKindInputStream;
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: REQUIRE_SIZE(AudioClassID); *(AudioClassID *)outData = kAudioObjectClassID; return noErr;
        case kAudioObjectPropertyClass: REQUIRE_SIZE(AudioClassID); *(AudioClassID *)outData = kAudioStreamClassID; return noErr;
        case kAudioObjectPropertyOwner: REQUIRE_SIZE(AudioObjectID); *(AudioObjectID *)outData = DeviceObject(index); return noErr;
        case kAudioObjectPropertyOwnedObjects: *outSize = 0; return noErr;
        case kAudioStreamPropertyIsActive: {
            REQUIRE_SIZE(UInt32);
            pthread_mutex_lock(&device->mutex);
            *(UInt32 *)outData = input ? device->inputActive : device->outputActive;
            pthread_mutex_unlock(&device->mutex);
            return noErr;
        }
        case kAudioStreamPropertyDirection: REQUIRE_SIZE(UInt32); *(UInt32 *)outData = input ? 1 : 0; return noErr;
        case kAudioStreamPropertyTerminalType:
            REQUIRE_SIZE(UInt32); *(UInt32 *)outData = input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine; return noErr;
        case kAudioStreamPropertyStartingChannel: REQUIRE_SIZE(UInt32); *(UInt32 *)outData = 1; return noErr;
        case kAudioStreamPropertyLatency: REQUIRE_SIZE(UInt32); *(UInt32 *)outData = 0; return noErr;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            REQUIRE_SIZE(AudioStreamBasicDescription);
            pthread_mutex_lock(&device->mutex);
            FillFormat(outData, device->sampleRate);
            pthread_mutex_unlock(&device->mutex);
            return noErr;
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 count = inSize / sizeof(AudioStreamRangedDescription);
            if (count > kSampleRateCount) count = kSampleRateCount;
            for (UInt32 i = 0; i < count; i++) {
                AudioStreamRangedDescription *description = &((AudioStreamRangedDescription *)outData)[i];
                FillFormat(&description->mFormat, kSampleRates[i]);
                description->mSampleRateRange = (AudioValueRange){ kSampleRates[i], kSampleRates[i] };
            }
            *outSize = count * sizeof(AudioStreamRangedDescription);
            return noErr;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 inSize, UInt32 *outSize, void *outData) {
    if (!HasProperty(driver, object, client, address) || outSize == NULL || (outData == NULL && inSize > 0)) return kAudioHardwareUnknownPropertyError;
    if (object == kAudioObjectPlugInObject) return GetPlugInProperty(address, qualifierSize, qualifier, inSize, outSize, outData);
    enum ObjectKind kind;
    int index = DeviceIndex(object, &kind);
    if (index < 0) return kAudioHardwareBadObjectError;
    return kind == kKindDevice ? GetDeviceProperty((UInt32)index, address, inSize, outSize, outData)
                               : GetStreamProperty((UInt32)index, kind, address, inSize, outSize, outData);
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 inSize, const void *inData) {
    (void)qualifierSize; (void)qualifier;
    Boolean settable = false;
    if (IsPropertySettable(driver, object, client, address, &settable) != noErr || !settable || inData == NULL) return kAudioHardwareUnknownPropertyError;
    enum ObjectKind kind;
    int index = DeviceIndex(object, &kind);
    if (index < 0) return kAudioHardwareBadObjectError;
    Device *device = &gDevices[index];
    switch (address->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
            if (inSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            return RequestRate(index, *(const Float64 *)inData);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (inSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription *format = inData;
            if (format->mFormatID != kAudioFormatLinearPCM || format->mChannelsPerFrame != kChannels || format->mBitsPerChannel != 32)
                return kAudioDeviceUnsupportedFormatError;
            return RequestRate(index, format->mSampleRate);
        }
        case kAudioStreamPropertyIsActive: {
            if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            Boolean active = *(const UInt32 *)inData != 0;
            pthread_mutex_lock(&device->mutex);
            if (kind == kKindInputStream) device->inputActive = active; else device->outputActive = active;
            pthread_mutex_unlock(&device->mutex);
            if (gHost) gHost->PropertiesChanged(gHost, object, 1, address);
            return noErr;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

// MARK: - IO

static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client) {
    (void)client;
    enum ObjectKind kind;
    int index = DeviceIndex(object, &kind);
    if (driver != gDriver || index < 0 || kind != kKindDevice) return kAudioHardwareBadObjectError;
    Device *device = &gDevices[index];
    pthread_mutex_lock(&device->mutex);
    if (device->ioClients == 0) {
        device->anchorHostTime = mach_absolute_time();
        device->timeStampCount = 0;
        memset(device->ring, 0, (size_t)kRingFrames * kBytesPerFrame);
    }
    device->ioClients++;
    pthread_mutex_unlock(&device->mutex);
    return noErr;
}

static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client) {
    (void)client;
    enum ObjectKind kind;
    int index = DeviceIndex(object, &kind);
    if (driver != gDriver || index < 0 || kind != kKindDevice) return kAudioHardwareBadObjectError;
    Device *device = &gDevices[index];
    pthread_mutex_lock(&device->mutex);
    if (device->ioClients > 0) device->ioClients--;
    pthread_mutex_unlock(&device->mutex);
    return noErr;
}

// The device clock runs from the host clock: one zero time stamp per ring length.
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)client;
    enum ObjectKind kind;
    int index = DeviceIndex(object, &kind);
    if (driver != gDriver || index < 0 || kind != kKindDevice) return kAudioHardwareBadObjectError;
    Device *device = &gDevices[index];
    pthread_mutex_lock(&device->mutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerRing = device->hostTicksPerFrame * (Float64)kRingFrames;
    UInt64 next = device->anchorHostTime + (UInt64)((Float64)(device->timeStampCount + 1) * ticksPerRing);
    if (next <= now) device->timeStampCount++;
    *outSampleTime = (Float64)(device->timeStampCount * kRingFrames);
    *outHostTime = device->anchorHostTime + (UInt64)((Float64)device->timeStampCount * ticksPerRing);
    *outSeed = 1;
    pthread_mutex_unlock(&device->mutex);
    return noErr;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client, UInt32 operation, Boolean *outWillDo, Boolean *outInPlace) {
    (void)client;
    if (driver != gDriver || DeviceIndex(object, NULL) < 0) return kAudioHardwareBadObjectError;
    Boolean handled = operation == kAudioServerPlugInIOOperationReadInput || operation == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = handled;
    if (outInPlace) *outInPlace = true;
    return noErr;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)client; (void)operation; (void)frames; (void)cycle;
    return driver == gDriver && DeviceIndex(object, NULL) >= 0 ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)client; (void)operation; (void)frames; (void)cycle;
    return driver == gDriver && DeviceIndex(object, NULL) >= 0 ? noErr : kAudioHardwareBadObjectError;
}

static inline UInt64 RingPosition(Float64 sampleTime) {
    SInt64 time = (SInt64)sampleTime;
    SInt64 position = time % kRingFrames;
    return (UInt64)(position < 0 ? position + kRingFrames : position);
}

// The mixed output is stored at its output time; the input reads at its (earlier) input time and clears what it
// read, so a microphone nobody feeds stays silent instead of repeating old audio.
static OSStatus DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID object, AudioObjectID stream, UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *mainBuffer, void *secondaryBuffer) {
    (void)client; (void)secondaryBuffer;
    enum ObjectKind kind;
    int index = DeviceIndex(object, &kind);
    if (driver != gDriver || index < 0 || kind != kKindDevice || cycle == NULL || mainBuffer == NULL) return kAudioHardwareBadObjectError;
    Float32 *ring = gDevices[index].ring;
    Float32 *buffer = mainBuffer;
    if (frames > kRingFrames) frames = kRingFrames;
    if (operation == kAudioServerPlugInIOOperationWriteMix && stream == OutputStreamObject((UInt32)index)) {
        UInt64 position = RingPosition(cycle->mOutputTime.mSampleTime);
        for (UInt32 frame = 0; frame < frames; frame++) {
            UInt64 slot = (position + frame) % kRingFrames;
            for (UInt32 channel = 0; channel < kChannels; channel++) ring[slot * kChannels + channel] = buffer[frame * kChannels + channel];
        }
    } else if (operation == kAudioServerPlugInIOOperationReadInput && stream == InputStreamObject((UInt32)index)) {
        UInt64 position = RingPosition(cycle->mInputTime.mSampleTime);
        for (UInt32 frame = 0; frame < frames; frame++) {
            UInt64 slot = (position + frame) % kRingFrames;
            for (UInt32 channel = 0; channel < kChannels; channel++) {
                buffer[frame * kChannels + channel] = ring[slot * kChannels + channel];
                ring[slot * kChannels + channel] = 0;
            }
        }
    }
    return noErr;
}
