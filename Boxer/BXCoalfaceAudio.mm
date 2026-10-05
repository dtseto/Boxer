/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import <Foundation/Foundation.h>
#define BXDOSBOX_BRIDGE_IMPLEMENTATION 1
#import "BXEmulatorPrivate.h"
#import "BXCoalfaceAudio.h"
#undef BXDOSBOX_BRIDGE_IMPLEMENTATION
#import "RegexKitLite.h"
#import <CoreFoundation/CFByteOrder.h>

static BXDOSBoxAudioBridgeCallbacks BXDOSBoxAudioCallbacks;
static bool BXDOSBoxAudioCallbacksRegistered = false;

static void boxer_registerDefaultDOSBoxAudioBridge(void);

void boxer_registerDOSBoxAudioBridge(const BXDOSBoxAudioBridgeCallbacks *callbacks)
{
    if (callbacks)
    {
        BXDOSBoxAudioCallbacks = *callbacks;
        BXDOSBoxAudioCallbacksRegistered = true;
    }
}

const BXDOSBoxAudioBridgeCallbacks *boxer_registeredDOSBoxAudioBridge(void)
{
    if (!BXDOSBoxAudioCallbacksRegistered)
        boxer_registerDefaultDOSBoxAudioBridge();
    return BXDOSBoxAudioCallbacksRegistered ? &BXDOSBoxAudioCallbacks : NULL;
}

//MIDI message lengths indexed by status code.
//Copypasta from midi.cpp, modified with fixes of our own:
//only undefined status codes are marked as having a length of 0.
uint8_t BXMIDIMessageLength[256] = {
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

void boxer_suggestMIDIHandler(std::string const &handlerName, const char *configParams)
{
    NSString *name = [[[NSString stringWithCString: handlerName.c_str() encoding: BXDirectStringEncoding]
                       stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]] lowercaseString];
    NSString *params = [[NSString stringWithCString: configParams encoding: BXDirectStringEncoding]
                        stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
    
    
    NSMutableDictionary *description = [[NSMutableDictionary alloc] initWithCapacity: 3];
    BXMIDIMusicType musicType = BXMIDIMusicAutodetect;
    
    if ([name isEqualToString: @"none"])
    {
        musicType = BXMIDIMusicDisabled;
    }
    if ([name isEqualToString: @"mt32"])
    {
        musicType = BXMIDIMusicMT32;
    }
    else if ([name isEqualToString: @"coreaudio"])
    {
        musicType = BXMIDIMusicGeneralMIDI;
    }
    else if ([name isEqualToString: @"coremidi"])
    {
        description[BXMIDIPreferExternalKey] = @YES;
        
        //If the configuration parameter string starts with a number,
        //grab that as the destination index.
        if ([params isMatchedByRegex: @"^\\d+"])
        {
            NSString *indexString = [[params componentsMatchedByRegex: @"^(\\d+)" capture: 1] objectAtIndex: 0];
            NSInteger destinationIndex = [indexString integerValue];
            
            description[BXMIDIExternalDeviceIndexKey] = @(destinationIndex);
        }
        
        //Check for the delaysysex flag, which indicates we need to use
        //sysex delays suitable for older MT-32s when talking to the device.
        if ([params isMatchedByRegex: @"delaysysex"])
        {
            description[BXMIDIExternalDeviceNeedsMT32SysexDelaysKey] = @YES;
        }
    }
    
    description[BXMIDIMusicTypeKey] = @(musicType);
    
    [[BXEmulator currentEmulator] setRequestedMIDIDeviceDescription: description];
}

bool boxer_MIDIAvailable()
{
    //Always treat MIDI as available, even if we're using a dummy MIDI handler.
    //(This actually matches DOSBox's behaviour.)
    return YES;
}

static float boxer_audioBridgeMasterVolume(BXDOSBoxAudioChannel channel)
{
    return boxer_masterVolume((BXAudioChannel)channel);
}

static void boxer_audioBridgeSuggestMIDIHandler(const char *handlerName, const char *configParams)
{
    boxer_suggestMIDIHandler(std::string(handlerName), configParams);
}

static void boxer_registerDefaultDOSBoxAudioBridge(void)
{
    BXDOSBoxAudioBridgeCallbacks callbacks = {};
    callbacks.midiAvailable = boxer_MIDIAvailable;
    callbacks.sendMIDIMessage = boxer_sendMIDIMessage;
    callbacks.sendMIDISysex = boxer_sendMIDISysex;
    callbacks.masterVolume = boxer_audioBridgeMasterVolume;
    callbacks.updateVolumes = boxer_updateVolumes;
    callbacks.suggestMIDIHandler = boxer_audioBridgeSuggestMIDIHandler;
    boxer_registerDOSBoxAudioBridge(&callbacks);
}

void boxer_sendMIDIMessage(uint8_t *msg)
{
    //Look up how long the total message is expected to be, based on the status code.
    uint8_t status = msg[0];
    NSUInteger len = (NSUInteger)BXMIDIMessageLength[status];
    
    if (len)
    {
        [[BXEmulator currentEmulator] sendMIDIMessage: [NSData dataWithBytesNoCopy: msg length: len freeWhenDone: NO]];
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

void boxer_sendMIDISysex(uint8_t *msg, size_t len)
{
    [[BXEmulator currentEmulator] sendMIDISysex: [NSData dataWithBytesNoCopy: msg length: len freeWhenDone: NO]];
}

float boxer_masterVolume(BXAudioChannel channel)
{
    //We don't use separate left and right volumes.
    return [BXEmulator currentEmulator].masterVolume;
}
