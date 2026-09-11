/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


// BoxerMidiDevice is Boxer's implementation of DOSBox Staging's MIDI device
// interface.
//
// Up to 0.78, Boxer took the MPU-401 stream by patching four call sites inside
// DOSBox's midi.cpp to call boxer_sendMIDIMessage()/boxer_sendMIDISysex()
// instead of the selected MidiHandler, and by calling boxer_suggestMIDIHandler()
// from the MIDI module's constructor to learn what the configuration had asked
// for. 0.83 replaced MidiHandler with an abstract `MidiDevice`
// (src/midi/private/midi_device.h) whose SendMidiMessage()/SendSysExMessage()
// are a 1:1 match for those two hooks, so Boxer supplies a device instead of
// patching the sites -- the same move BXGFXBridge.mm makes for rendering.
//
// midi.cpp builds this device for the `mididevice` values Boxer claims -- 'auto',
// 'default', 'generalmidi', 'mt32' and 'coremidi' -- and keeps its own devices
// for 'port' and 'coreaudio'. See FINDINGS.md, D1, D38 and D50.

#import <Foundation/Foundation.h>
#import "BXEmulatorPrivate.h"
#import "BXCoalfaceAudio.h"
#import <CoreFoundation/CFByteOrder.h>

#import "midi/midi.h"
#import "midi/private/midi_device.h"

#include <cctype>
#include <cstdlib>
#include <memory>
#include <string>


//MIDI message lengths indexed by status code.
//Copypasta from midi.cpp, modified with fixes of our own:
//only undefined status codes are marked as having a length of 0.
//
//0.83 has a table of its own (MIDI_message_len_by_status, which is what its own
//devices index with), but it still marks 0xf0 and 0xf7 as zero-length and it
//drops System Reset (0xff) too, so we keep using ours: a message we score as
//zero-length is one we deliberately do not pass on.
static const uint8_t BXMIDIMessageLength[256] = {
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,  // 0x00
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,  // 0x10
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,  // 0x20
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,  // 0x30
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,  // 0x40
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,  // 0x50
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,  // 0x60
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,  // 0x70
    
    3,3,3,3, 3,3,3,3, 3,3,3,3, 3,3,3,3,  // 0x80
    3,3,3,3, 3,3,3,3, 3,3,3,3, 3,3,3,3,  // 0x90
    3,3,3,3, 3,3,3,3, 3,3,3,3, 3,3,3,3,  // 0xa0
    3,3,3,3, 3,3,3,3, 3,3,3,3, 3,3,3,3,  // 0xb0
    
    2,2,2,2, 2,2,2,2, 2,2,2,2, 2,2,2,2,  // 0xc0
    2,2,2,2, 2,2,2,2, 2,2,2,2, 2,2,2,2,  // 0xd0
    
    3,3,3,3, 3,3,3,3, 3,3,3,3, 3,3,3,3,  // 0xe0
    1,2,3,2, 0,0,1,1, 1,0,1,1, 1,0,1,1   // 0xf0
};


#pragma mark - Diagnostics

/// Set BOXER_LOG_MIDI to log what the MPU-401 emulation is actually sending.
/// A value of 1 logs SysEx only (which is what MT-32 autodetection turns on);
/// 2 logs every channel message as well, which is a lot of output.
static int _midiLogLevel(void)
{
    static int level = -1;
    if (level < 0)
    {
        const char *env = getenv("BOXER_LOG_MIDI");
        level = (env && *env) ? atoi(env) : 0;
    }
    return level;
}

#pragma mark - Device description

/// Translate the `mididevice` and `midiconfig` values DOSBox was configured with
/// into the device description Boxer's delegate answers with an actual MIDI
/// device.
///
/// This is what boxer_suggestMIDIHandler() used to do from inside midi.cpp's
/// constructor, and it keeps that function's reading of `midiconfig` for
/// 'coremidi' (D50). What has changed with D38 is only the names: 'auto' and
/// 'default' mean the same as they always did, 'generalmidi' replaces the
/// 'coreaudio' spelling (which is now upstream's own CoreAudio synth), and
/// 'port' never reaches here at all.
static NSDictionary *_descriptionForMidiDeviceName(const std::string &deviceName,
                                                   const std::string &config)
{
    NSString *name = [[NSString stringWithCString: deviceName.c_str()
                                         encoding: BXDirectStringEncoding]
                      lowercaseString];
    
    NSMutableDictionary *description = [NSMutableDictionary dictionaryWithCapacity: 4];
    BXMIDIMusicType musicType = BXMIDIMusicAutodetect;
    
    if ([name isEqualToString: @"mt32"])
    {
        musicType = BXMIDIMusicMT32;
    }
    else if ([name isEqualToString: @"generalmidi"])
    {
        musicType = BXMIDIMusicGeneralMIDI;
    }
    else if ([name isEqualToString: @"coremidi"])
    {
        //Send to a MIDI device attached to the Mac. The music type is left as
        //autodetect deliberately, as it was in the 0.78 hook: whatever is
        //plugged in is assumed to suit whatever the game plays.
        description[BXMIDIPreferExternalKey] = @YES;
        
        //If the parameter string starts with a number, that is the destination
        //index. (0.78 matched this with a regex; the leading-digits rule is the
        //same, and upstream's own device reads the same field the same way.)
        const char *params = config.c_str();
        while (*params == ' ' || *params == '\t') params++;
        
        if (isdigit((unsigned char)*params))
            description[BXMIDIExternalDeviceIndexKey] = @(strtol(params, NULL, 10));
        
        //'delaysysex' means the device needs the SysEx spacing an older MT-32
        //requires. Note DOSBox has a `delaysysex` implementation of its own,
        //which midi.cpp deliberately leaves switched off when Boxer owns the
        //device: Boxer does the spacing in BXExternalMT32 instead, and DOSBox's
        //version blocks the emulation thread with Delay().
        if (config.find("delaysysex") != std::string::npos)
            description[BXMIDIExternalDeviceNeedsMT32SysexDelaysKey] = @YES;
    }
    
    description[BXMIDIMusicTypeKey] = @(musicType);
    
    return description;
}


#pragma mark - BoxerMidiDevice

/// Boxer's MidiDevice. Every message DOSBox's MPU-401 emulation produces is
/// handed straight to BXEmulator, which owns device selection, MT-32
/// autodetection, sysex delays and volume.
class BoxerMidiDevice final : public MidiDevice {
public:
    BoxerMidiDevice(const std::string &name, const std::string &config)
        : _name(name)
    {
        BXEmulator *emulator = [BXEmulator currentEmulator];
        NSDictionary *description = _descriptionForMidiDeviceName(name, config);
        
        //Tell Boxer what kind of music this configuration expects. Boxer
        //attaches the actual device lazily, the first time a message arrives,
        //so that a session which never plays MIDI never opens a synth.
        emulator.requestedMIDIDeviceDescription = description;
        
        //Unless one is attached already. We are built afresh every time the
        //`mididevice` setting changes -- including from a game's own
        //`CONFIG -set "mididevice=..."`, which is how Dune and others pick
        //their music device at launch -- and by then Boxer may well have
        //attached a device for the *previous* setting. Changing the requested
        //description alone would not dislodge it, so re-run the choice: the
        //delegate hands back the same device if it still fits the new
        //description, and a different one if it does not.
        if (emulator.activeMIDIDevice)
            [emulator attachMIDIDeviceForDescription: description];
    }
    
    std::string GetName() const override { return _name; }
    
    /// Reported as Internal so that DOSBox leaves channel volumes alone.
    /// Type is consulted for one thing only: MIDI_Mute()/MIDI_Unmute() inject
    /// Channel Volume messages into the stream for external devices. Boxer
    /// already silences its own device when a session pauses (-[BXEmulator
    /// _suspendAudio] calls -pause on it, and BXExternalMIDIDevice sends All
    /// Notes Off from there), and it drives the device's volume itself from
    /// masterVolume -- so letting DOSBox write CC7 as well would fight it.
    Type GetType() const override { return Type::Internal; }
    
    void SendMidiMessage(const MidiMessage &msg) override
    {
        //Look up how long the total message is expected to be, based on the
        //status code. DOSBox knows the length it accumulated, but does not pass
        //it, and its own devices do exactly this lookup.
        const uint8_t status = msg.status();
        const NSUInteger len = (NSUInteger)BXMIDIMessageLength[status];
        
        if (len)
        {
            if (_midiLogLevel() >= 2)
                NSLog(@"MIDI: message %02x %02x %02x (%lu bytes)",
                      msg[0], msg[1], msg[2], (unsigned long)len);
            
            [[BXEmulator currentEmulator] sendMIDIMessage:
                [NSData dataWithBytes: msg.data.data() length: len]];
        }
#ifdef BOXER_DEBUG
        //DOSBox's MIDI event table declares undefined MIDI statuses as having 0 length.
        //Such messages should not be passed onwards, but should be logged.
        //q.v.: http://www.midi.org/techspecs/midimessages.php
        else
        {
            NSLog(@"Undefined MIDI message received: status code %0x", status);
        }
#endif
    }
    
    void SendSysExMessage(uint8_t *sysex, size_t len) override
    {
        if (_midiLogLevel() >= 1)
        {
            //The first bytes of a Roland SysEx are the manufacturer ID, the
            //device and model IDs and the command -- which is exactly what
            //Boxer's MT-32 autodetection matches on.
            NSLog(@"MIDI: sysex, %lu bytes, starting %02x %02x %02x %02x %02x %02x %02x %02x",
                  (unsigned long)len,
                  len > 0 ? sysex[0] : 0, len > 1 ? sysex[1] : 0,
                  len > 2 ? sysex[2] : 0, len > 3 ? sysex[3] : 0,
                  len > 4 ? sysex[4] : 0, len > 5 ? sysex[5] : 0,
                  len > 6 ? sysex[6] : 0, len > 7 ? sysex[7] : 0);
        }
        
        //No copy: this is DOSBox's own sysex buffer and it stays valid for the
        //duration of the call. Anything Boxer holds onto (the pending-sysex
        //queue used by MT-32 autodetection) copies it for itself.
        [[BXEmulator currentEmulator] sendMIDISysex:
            [NSData dataWithBytesNoCopy: sysex length: len freeWhenDone: NO]];
    }
    
private:
    std::string _name;
};


#pragma mark - The factory midi.cpp calls

std::unique_ptr<MidiDevice> BOXER_CreateMidiDevice(const std::string &name,
                                                   const std::string &config)
{
    using namespace MidiDeviceName;
    
    //CoreMidi is here because a literal `mididevice = coremidi` means Boxer's
    //own external-MIDI support; `mididevice = port`, which resolves to the same
    //device name inside DOSBox, does not and never reaches this function. See
    //midi.cpp's constructor, and D50.
    if (name == BoxerAuto || name == BoxerDefault || name == BoxerGeneralMidi ||
        name == Mt32 || name == CoreMidi)
        return std::make_unique<BoxerMidiDevice>(name, config);
    
    return {};
}

void BOXER_NotifyMidiDisabled()
{
    BXEmulator *emulator = [BXEmulator currentEmulator];
    
    emulator.requestedMIDIDeviceDescription = @{ BXMIDIMusicTypeKey: @(BXMIDIMusicDisabled) };
    
    //DOSBox stops calling us entirely when there is no device, so drop whatever
    //Boxer had attached: otherwise the previous configuration's synth stays
    //attached, keeps its mixer channel, and goes on rendering.
    emulator.activeMIDIDevice = nil;
}
