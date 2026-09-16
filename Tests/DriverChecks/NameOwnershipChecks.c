// SPDX-License-Identifier: AGPL-3.0-only
#include <pthread.h>
#include <stdbool.h>

static int checked_unlock(pthread_mutex_t *mutex);
#define pthread_mutex_unlock checked_unlock
#include <BlackHole.c>
#undef pthread_mutex_unlock

#include <stdio.h>
#include <stdlib.h>

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "Driver name ownership check failed at line %d\n", __LINE__); \
        exit(1); \
    } \
} while (0)

static bool replaceAfterUnlock;
static CFStringRef replacement;

static void set_name(CFStringRef name) {
    AudioObjectPropertyAddress address = {
        kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    AudioObjectPropertyAddress changed[2];
    UInt32 count = 0;
    CHECK(BlackHole_SetBoxPropertyData(gAudioServerPlugInDriverRef, kObjectID_Box,
        0, &address, 0, NULL, sizeof(name), &name, &count, changed) == noErr);
}

static int checked_unlock(pthread_mutex_t *mutex) {
    int result = pthread_mutex_unlock(mutex);
    if (result == 0 && mutex == &gPlugIn_StateMutex && replaceAfterUnlock) {
        replaceAfterUnlock = false;
        // Schedule a valid setter exactly after the getter releases the shared
        // lock. This deterministically exercises a concurrent name replacement.
        set_name(replacement);
    }
    return result;
}

int main(void) {
    CFStringRef expected = CFSTR("Original dynamically allocated audio box name retained for the reader");
    CFStringRef original = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, expected);
    CHECK(original != NULL);
    replacement = CFStringCreateMutableCopy(kCFAllocatorDefault, 0,
        CFSTR("Replacement dynamically allocated audio box name owned by the driver"));
    CHECK(replacement != NULL);
    set_name(original);
    CFRelease(original);
    replaceAfterUnlock = true;
    AudioObjectPropertyAddress address = {
        kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    CFStringRef returned = NULL;
    UInt32 size = 0;
    CHECK(BlackHole_GetBoxPropertyData(gAudioServerPlugInDriverRef, kObjectID_Box,
        0, &address, 0, NULL, sizeof(returned), &size, &returned) == noErr);
    CHECK(!replaceAfterUnlock && size == sizeof(returned));
    CHECK(returned != NULL && CFEqual(returned, expected));
    CFRelease(returned);
    CFRelease(replacement);
    set_name(NULL);
    puts("Box-name readers retain their snapshot across concurrent replacement.");
    return 0;
}
