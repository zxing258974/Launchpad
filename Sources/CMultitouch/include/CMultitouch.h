// 苹果私有框架 MultitouchSupport 的最小封装:读触控板原始触点。
// 结构与函数签名参照 OpenMultitouchSupport(MIT,Kyome22)。运行时 dlopen,框架缺失或改名时 LPMultitouchLoad 返回 false。
#ifndef CMultitouch_h
#define CMultitouch_h

#include <stdbool.h>
#include <CoreFoundation/CoreFoundation.h>

CF_ASSUME_NONNULL_BEGIN

typedef struct {
    float x;
    float y;
} LPMTPoint;

typedef struct {
    LPMTPoint position;
    LPMTPoint velocity;
} LPMTVector;

/// 触点状态:3 = 刚接触,4 = 接触中;其余为悬停、离开等
typedef int LPMTTouchState;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    LPMTTouchState state;
    int fingerId;
    int handId;
    LPMTVector normalizedPosition;
    float total;
    float pressure;
    float angle;
    float majorAxis;
    float minorAxis;
    LPMTVector absolutePosition;
    int field14;
    int field15;
    float density;
} LPMTTouch;

typedef void *LPMTDeviceRef;
typedef void (*LPMTContactCallback)(LPMTDeviceRef device, LPMTTouch *_Nullable touches, int count, double timestamp, int frame);

/// 加载框架并解析所需函数;可重复调用
bool LPMultitouchLoad(void);
/// 当前所有多点触控设备(内建触控板、妙控板等);调用方负责 CFRelease
CFArrayRef _Nullable LPMultitouchCreateDeviceList(void) CF_RETURNS_RETAINED;
/// 返回 0 表示启动成功
int LPMultitouchStart(LPMTDeviceRef device, LPMTContactCallback callback);
void LPMultitouchStop(LPMTDeviceRef device, LPMTContactCallback callback);
bool LPMultitouchIsRunning(LPMTDeviceRef device);
/// 设备在 IORegistry 里的编号:同一台设备不变,断开重连后会换新号;取不到为 0
uint64_t LPMultitouchDeviceID(LPMTDeviceRef device);
/// 设备家族号(妙控鼠标为 112/113);取不到为 -1
int LPMultitouchFamilyID(LPMTDeviceRef device);

CF_ASSUME_NONNULL_END

#endif
