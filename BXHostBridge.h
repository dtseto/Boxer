/*
 * Host-facing declarations for Boxer callbacks used outside the DOSBox core.
 * This header intentionally contains no DOSBox implementation types.
 */

#ifndef BXHostBridge_h
#define BXHostBridge_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uintptr_t boxer_keyboardBufferRemaining(void);
bool boxer_keyboardLayoutSupported(const char *code);
bool boxer_keyboardLayoutLoaded(void);
const char *boxer_keyboardLayoutName(void);
bool boxer_keyboardLayoutActive(void);
void boxer_setKeyboardLayoutActive(bool active);

#ifdef __cplusplus
}
#endif

#endif /* BXHostBridge_h */
