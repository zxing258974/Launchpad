#include "CMultitouch.h"
#include <dlfcn.h>
#include <IOKit/IOKitLib.h>

static CFMutableArrayRef (*createList)(void);
static void (*registerCallback)(LPMTDeviceRef, LPMTContactCallback);
static void (*unregisterCallback)(LPMTDeviceRef, LPMTContactCallback);
static int (*startDevice)(LPMTDeviceRef, int);
static int (*stopDevice)(LPMTDeviceRef);
// 以下几个可选,取不到时相应功能退化
static bool (*isRunning)(LPMTDeviceRef);
static io_service_t (*getService)(LPMTDeviceRef);
static int (*getFamilyID)(LPMTDeviceRef, int *);

bool LPMultitouchLoad(void) {
    if (createList && registerCallback && unregisterCallback && startDevice && stopDevice) return true;
    void *handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (!handle) return false;
    createList = dlsym(handle, "MTDeviceCreateList");
    registerCallback = dlsym(handle, "MTRegisterContactFrameCallback");
    unregisterCallback = dlsym(handle, "MTUnregisterContactFrameCallback");
    startDevice = dlsym(handle, "MTDeviceStart");
    stopDevice = dlsym(handle, "MTDeviceStop");
    isRunning = dlsym(handle, "MTDeviceIsRunning");
    getService = dlsym(handle, "MTDeviceGetService");
    getFamilyID = dlsym(handle, "MTDeviceGetFamilyID");
    return createList && registerCallback && unregisterCallback && startDevice && stopDevice;
}

CFArrayRef LPMultitouchCreateDeviceList(void) {
    return createList ? createList() : NULL;
}

int LPMultitouchStart(LPMTDeviceRef device, LPMTContactCallback callback) {
    if (!registerCallback || !startDevice) return -1;
    registerCallback(device, callback);
    return startDevice(device, 0);
}

void LPMultitouchStop(LPMTDeviceRef device, LPMTContactCallback callback) {
    if (!unregisterCallback || !stopDevice) return;
    unregisterCallback(device, callback);
    stopDevice(device);
}

bool LPMultitouchIsRunning(LPMTDeviceRef device) {
    return isRunning ? isRunning(device) : true;
}

uint64_t LPMultitouchDeviceID(LPMTDeviceRef device) {
    if (!getService) return 0;
    io_service_t service = getService(device);
    uint64_t entryID = 0;
    if (service && IORegistryEntryGetRegistryEntryID(service, &entryID) != KERN_SUCCESS) return 0;
    return entryID;
}

int LPMultitouchFamilyID(LPMTDeviceRef device) {
    int family = -1;
    if (getFamilyID) getFamilyID(device, &family);
    return family;
}
