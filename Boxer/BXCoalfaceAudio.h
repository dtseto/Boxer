/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import "BXCoalface.h"

// Boxer's MIDI output is no longer a set of hooks patched into DOSBox's
// midi.cpp: 0.83 has an abstract MidiDevice, and Boxer implements one.
// BXCoalfaceAudio.mm defines `BoxerMidiDevice` and the factory midi.cpp calls
// to build it (`BOXER_CreateMidiDevice()`, declared in DOSBox's
// src/midi/private/midi_device.h). Nothing in Boxer needs to see either, so
// this header no longer declares anything -- it is kept because
// BXEmulatorPrivate.h imports it and because the audio coalface is where the
// next audio-side hook will go.
//
// The four hooks it used to declare -- boxer_suggestMIDIHandler,
// boxer_MIDIAvailable, boxer_sendMIDIMessage and boxer_sendMIDISysex -- are
// retired; see FINDINGS.md, "Retired hooks".
