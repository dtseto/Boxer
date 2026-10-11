#ifndef BXEmulatorCoreAudio_h
#define BXEmulatorCoreAudio_h

/*
 Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0.
 */

#import "BXDOSBoxBridgeRegistration.h"
#include <cstdint>
#include <string>

typedef BXDOSBoxAudioChannel BXAudioChannel;

enum {
    BXLeftChannel = BXDOSBoxAudioChannelLeft,
    BXRightChannel = BXDOSBoxAudioChannelRight
};

/// Audio and MIDI callbacks used by DOSBox-Staging's opaque bridge.
void boxer_suggestMIDIHandler(std::string const &handlerName, const char *configParams);
bool boxer_MIDIAvailable(void);
void boxer_sendMIDIMessage(uint8_t *msg);
void boxer_sendMIDISysex(uint8_t *msg, size_t len);
float boxer_masterVolume(BXAudioChannel channel);
void boxer_updateVolumes(void);

#endif /* BXEmulatorCoreAudio_h */
