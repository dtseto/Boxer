/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import <Foundation/Foundation.h>


NS_ASSUME_NONNULL_BEGIN

/// How long keyPressed: should pretend to hold the specified key down before releasing.
#define BXKeyPressDurationDefault 0.25

/// How long typeCharacters should wait in between bursts of simulated typing.
/// This needs to be high enough that we don't overload a DOS program's own keyboard handling.
#define BXTypingBurstIntervalDefault 1.0

/// How long to wait after finishing a batch of simulated typing, before returning the keyboard state to normal.
#define BXTypingCleanupDelay 0.5

/// When simulating typing, this many slots will be reserved in the emulated keyboard buffer to avoid flooding.
#define BXTypingKeyboardBufferReserve 3

// This is the Boxer-facing keyboard key contract. The values intentionally
// match DOSBox's legacy key ordering because the adapter converts them to the
// DOSBox key type at the Coalface boundary. Keeping the compatibility names
// avoids changing persisted/input-profile values while removing DOSBox's
// keyboard header from Boxer's public headers.
#ifndef DOSBOX_KEYBOARD_H
typedef enum BXDOSKeyCode {
    KBD_NONE,

    KBD_1, KBD_2, KBD_3, KBD_4, KBD_5, KBD_6, KBD_7, KBD_8, KBD_9, KBD_0,
    KBD_q, KBD_w, KBD_e, KBD_r, KBD_t, KBD_y, KBD_u, KBD_i, KBD_o, KBD_p,
    KBD_a, KBD_s, KBD_d, KBD_f, KBD_g, KBD_h, KBD_j, KBD_k, KBD_l,
    KBD_z, KBD_x, KBD_c, KBD_v, KBD_b, KBD_n, KBD_m,

    KBD_f1, KBD_f2, KBD_f3, KBD_f4, KBD_f5, KBD_f6,
    KBD_f7, KBD_f8, KBD_f9, KBD_f10, KBD_f11, KBD_f12,

    KBD_esc, KBD_tab, KBD_backspace, KBD_enter, KBD_space,

    KBD_leftalt, KBD_rightalt,
    KBD_leftctrl, KBD_rightctrl,
    KBD_leftgui, KBD_rightgui,
    KBD_leftshift, KBD_rightshift,

    KBD_capslock, KBD_scrolllock, KBD_numlock,

    KBD_grave, KBD_minus, KBD_equals, KBD_backslash,
    KBD_leftbracket, KBD_rightbracket,
    KBD_semicolon, KBD_quote,
    KBD_oem102,
    KBD_extra_lt_gt = KBD_oem102,
    KBD_period, KBD_comma, KBD_slash, KBD_abnt1,

    KBD_printscreen, KBD_pause,

    KBD_insert, KBD_home, KBD_pageup,
    KBD_delete, KBD_end, KBD_pagedown,

    KBD_left, KBD_up, KBD_down, KBD_right,

    KBD_kp1, KBD_kp2, KBD_kp3, KBD_kp4, KBD_kp5,
    KBD_kp6, KBD_kp7, KBD_kp8, KBD_kp9, KBD_kp0,
    KBD_kpdivide, KBD_kpmultiply, KBD_kpminus, KBD_kpplus,
    KBD_kpenter, KBD_kpperiod,

    KBD_LAST,
} BXDOSKeyCode;
#else
typedef KBD_KEYS BXDOSKeyCode;
#endif

/// \c BXEmulatedKeyboard represents the DOS PC's keyboard hardware, and offers an API for sending
/// emulated key events and setting keyboard layout.
@interface BXEmulatedKeyboard : NSObject

/// NOTE: these are only readwrite for the sake of BXCoalface.
/// They should not be modified by code outside BXEmulator.
@property (nonatomic) BOOL capsLockEnabled;
@property (nonatomic) BOOL numLockEnabled;
@property (nonatomic) BOOL scrollLockEnabled;

/// The DOS keyboard layout that is currently in use.
@property (copy, nonatomic, nullable) NSString *activeLayout;

/// Whether to map keyboard input through the active keyboard layout.
/// If NO, input will be mapped according to a standard US keyboard layout instead.
@property (nonatomic) BOOL usesActiveLayout;

/// The DOS keyboard layout that will be applied once emulation has started up.
/// Set whenever activeLayout is changed.
@property (copy, nonatomic, nullable) NSString *preferredLayout;

/// Returns \c YES if the emulated keyboard buffer is full, meaning further key events will be ignored.
@property (readonly, nonatomic) BOOL keyboardBufferFull;

/// Whether we are currently typing text into the keyboard. Will be \c YES while the input from
/// \c typeCharacters: is being processed.
@property (readonly, nonatomic) BOOL isTyping;


#pragma mark -
#pragma mark Keyboard input

/// Press the specified key.
- (void) keyDown: (BXDOSKeyCode)key;
/// Release the specified key.
- (void) keyUp: (BXDOSKeyCode)key;

/// Release all currently-pressed keys, as if the user took their hands off the keyboard.
- (void) clearInput;

/// Release all current presses of the specified key, regardless of how many times \c keyDown:
/// has been called on it.
- (void) clearKey: (BXDOSKeyCode)key;

/// Imitate the key being pressed and then released after the default/specified duration.
- (void) keyPressed: (BXDOSKeyCode)key;
- (void) keyPressed: (BXDOSKeyCode)key forDuration: (NSTimeInterval)duration;

/// Returns whether the specified key is currently pressed.
- (BOOL) keyIsDown: (BXDOSKeyCode)key;

/// Simulate typing the specified characters into the keyboard.
/// To avoid flooding the keyboard buffer, characters will be sent
/// in bursts with the specified interval between bursts.
- (void) typeCharacters: (NSString *)characters burstInterval: (NSTimeInterval)interval;
- (void) typeCharacters: (NSString *)characters;

/// Cancel any pending keydown events and empty the queue.
- (void) cancelTyping;



#pragma mark -
#pragma mark 

/// The default DOS keyboard layout that should be used if no more specific one can be found.
+ (NSString *)defaultKeyboardLayout;

@end

NS_ASSUME_NONNULL_END
