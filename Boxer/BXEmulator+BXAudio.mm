/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import "BXEmulatorPrivate.h"
#import "BXEmulatedMT32.h"
#import "BXExternalMIDIDevice.h"
#import "BXExternalMT32+BXMT32Sysexes.h"
#import "BXMIDISynth.h"
#import "BXAudioSource.h"
#import "BXDrive.h"

#import <SDL2/SDL.h>
#import "audio/mixer.h"


static const char *BXMIDIChannelName = "MIDI";

//DOSBox used to hand every mixer channel a shared `MixTemp` scratch buffer to
//render into. 0.83's channels each do their own conversion and the buffer is
//gone, so Boxer supplies its own. These are only ever touched from DOSBox's
//mixer thread, which is the sole caller of a channel's handler.
static uint8_t BXMixerScratchBuffer[MixerBufferByteSize];

//The widest frame we can be handed is 32-bit stereo, so this is the largest
//number of frames the scratch buffer can hold. (The mixer asks for about a
//millisecond at a time — 48 frames at 48kHz — so this is never the limit in
//practice, but 0.78 had no bound here at all.)
static const NSUInteger BXMixerScratchMaxFrames = MixerBufferByteSize / (sizeof(int32_t) * 2);

//0.83 kept only a handful of AddSamples_* entry points: unsigned 8-bit mono,
//signed 16-bit mono and stereo, float mono and stereo, and a byte-swapped
//16-bit pair. Every other combination 0.78 accepted — signed 8-bit, unsigned
//8-bit stereo, unsigned 16-bit, and 32-bit — has to be converted here first.
static int16_t BXMixerConversionBuffer[BXMixerScratchMaxFrames * 2];
static float BXMixerFloatBuffer[BXMixerScratchMaxFrames * 2];

NSString * const BXEmulatorDidDisplayMT32MessageNotification = @"BXEmulatorDidDisplayMT32MessageNotification";

NSString * const BXMIDIMusicTypeKey                 = @"MIDI Music Type";
NSString * const BXMIDIPreferExternalKey            = @"Prefer External MIDI Device";
NSString * const BXMIDIExternalDeviceIndexKey       = @"External Device Index";
NSString * const BXMIDIExternalDeviceUniqueIDKey    = @"External Device Unique ID";
NSString * const BXMIDIExternalDeviceNeedsMT32SysexDelaysKey = @"Needs MT-32 Sysex Delays";


@implementation BXEmulator (BXAudio)

- (void) emulatedMT32: (BXEmulatedMT32 *)MT32 didDisplayMessage: (NSString *)message
{
    [self _postNotificationName: BXEmulatorDidDisplayMT32MessageNotification
               delegateSelector: @selector(emulatorDidDisplayMT32Message:)
                       userInfo: @{ @"message": message }];
}

- (void) sendMT32LCDMessage: (NSString *)message
{
    NSData *sysex = [BXExternalMT32 sysexWithLCDMessage: message];
    [self sendMIDISysex: sysex];
}


# pragma mark -
# pragma mark MIDI output handling

- (BXMIDIMusicType) musicType
{
    return BXMIDIMusicType([[self.requestedMIDIDeviceDescription objectForKey: BXMIDIMusicTypeKey] integerValue]);
}

- (id <BXMIDIDevice>) attachMIDIDeviceForDescription: (NSDictionary *)description
{
    id <BXMIDIDevice> device = [self.delegate MIDIDeviceForEmulator: self
                                                 meetingDescription: description];
    
    if (device && device != self.activeMIDIDevice)
    {
        self.activeMIDIDevice = device;
        self.activeMIDIDevice.volume = self.masterVolume;
    }
    return device;
}

- (void) sendMIDIMessage: (NSData *)message
{
    //Connect to our requested MIDI device the first time we need one.
    [self _attachRequestedMIDIDeviceIfNeeded];
    
    if (self.activeMIDIDevice)
    {
        //If we're not ready to send yet, wait until we are.
        [self _waitUntilActiveMIDIDeviceIsReady];
        [self.activeMIDIDevice handleMessage: message];
    }
}

- (void) sendMIDISysex: (NSData *)message
{
    //Connect to our requested MIDI device the first time we need one.
    [self _attachRequestedMIDIDeviceIfNeeded];
    
    //Autodetect if the music we're receiving would be suitable for an MT-32:
    //If so, and our current device can't play MT-32 music, try switching to one that can.
    if (self.autodetectsMT32 && !self.activeMIDIDevice.supportsMT32Music)
    {
        //Check if the message we've received was intended for an MT-32,
        //and if so, how 'conclusive' it is that the game is playing MT-32 music.
        BOOL supportConfirmed, isMT32Sysex = [BXExternalMT32 isMT32Sysex: message
                                                       confirmingSupport: &supportConfirmed];
        if (isMT32Sysex)
        {
            //If this sysex conclusively indicates that the game is playing MT-32 music,
            //then try to swap in an MT-32-supporting device immediately.
            if (supportConfirmed)
            {
#if BOXER_DEBUG
                NSLog(@"Conclusive MT-32 sysex: %@ total length: %lu",
                      [BXExternalMT32 dataInSysex: message includingAddress: YES],
                      (unsigned long)message.length);
#endif
                
                id device = [self attachMIDIDeviceForDescription: @{ BXMIDIMusicTypeKey: @(BXMIDIMusicMT32) }];
                
                //If the new device does indeed support the MT-32 (i.e., we didn't fail
                //to create one and fall back on something else) then send it the MT-32
                //messages it missed.
                if ([device supportsMT32Music])
                {
                    [self _flushPendingSysexMessages];
                }
                //If we couldn't attach an MT-32-supporting MIDI device, then disable
                //autodetection so we don't keep trying.
                else
                {
                    self.autodetectsMT32 = NO;
                    [self _clearPendingSysexMessages];
                }
            }
            //If we couldn't yet confirm that the game is playing MT-32 music, queue up
            //the MT-32 sysex we received so that we can deliver it to an MT-32 device
            //later. This ensures it won't miss out on any startup commands.
            else
            {
#if BOXER_DEBUG
                NSLog(@"Inconclusive MT-32 sysex: %@", [BXExternalMT32 dataInSysex: message includingAddress: YES]);
#endif
                [self _queueSysexMessage: message];
            }
        }
    }

    if (self.activeMIDIDevice)
    {
        //If we're not ready to send yet, wait until we are.
        [self _waitUntilActiveMIDIDeviceIsReady];
        [self.activeMIDIDevice handleSysex: message];
    }
}




#pragma mark -
#pragma mark Private methods

- (void) _suspendAudio
{
    //SDL_PauseAudio() only ever addressed SDL 1.2's single implicit audio
    //device. 0.83's mixer opens its own device with SDL_OpenAudioDevice() and
    //drives it from a dedicated mixer thread, so pausing the legacy device
    //silences nothing. MIXER_Mute() is the supported equivalent: it stops the
    //mixer emitting frames, drops whatever is already queued, and mutes MIDI.
    //
    //Don't touch the mixer if the user muted it themselves, or resuming would
    //silently undo their mute.
    _audioMutedForPause = !MIXER_IsManuallyMuted();
    if (_audioMutedForPause)
        MIXER_Mute();
    
    //The SDL_CDStatus()/SDL_CDPause() pair that used to live here was SDL 1.2's
    //physical CD-ROM API, which SDL2 does not have; it survived only because it
    //sat behind a `#if !defined(C_SDL2)` guard and 0.83 no longer defines
    //C_SDL2. There is nothing to port it to: 0.83 has no physical CD support,
    //and CD audio from disc images is mixed through the CDAUDIO mixer channel
    //like everything else, so the mute above already covers it.
    
    [self.activeMIDIDevice pause];
}

- (void) _resumeAudio
{
    if (_audioMutedForPause)
    {
        MIXER_Unmute();
        _audioMutedForPause = NO;
    }
    
    [self.activeMIDIDevice resume];
}


//Called periodically by our MIDI channel to fill its buffer with audio data.
//MIXER_Handler is now a std::function<void(int)>, so this takes a plain int.
static void _renderMIDIOutput(const int numFrames)
{
    //We need to look up the corresponding channel for this because DOSBox's
    //mixer doesn't pass any context with its callbacks.
    MixerChannel *channel = MIXER_FindChannel(BXMIDIChannelName).get();
    if (channel && numFrames > 0)
        [[BXEmulator currentEmulator] _renderMIDIOutputToChannel: channel
                                                          frames: (NSUInteger)numFrames];
}


- (MixerChannel *) _MIDIMixerChannel
{
    return MIXER_FindChannel(BXMIDIChannelName).get();
}

- (MixerChannel *) _addMIDIMixerChannelWithSampleRate: (NSUInteger)sampleRate
{
    MixerChannelPtr channel = MIXER_FindChannel(BXMIDIChannelName);
    
    if (channel)
    {
        //SetFreq() was renamed SetSampleRate() when the mixer gained real
        //resampling; the units (Hz) are unchanged.
        channel->SetSampleRate((int)sampleRate);
    }
    else
    {
        //0.83 requires a channel's features to be declared up front: they
        //decide whether it gets a stereo lineout and how the MIXER command
        //presents it. Boxer's MIDI devices render stereo synthesizer output.
        //ChannelFeature::Sleep is deliberately omitted — it lets an idle
        //channel disable itself, and Boxer adds and removes this channel
        //explicitly instead.
        channel = MIXER_AddChannel(_renderMIDIOutput,
                                   (int)sampleRate,
                                   BXMIDIChannelName,
                                   {ChannelFeature::Stereo,
                                    ChannelFeature::Synthesizer});
        
        //Match what upstream's own MIDI devices ask for: proper band-limited
        //resampling rather than the mixer's default lerp-or-resample.
        channel->SetResampleMethod(ResampleMethod::Resample);
    }
    channel->Enable(true);
    return channel.get();
}

- (void) _removeMIDIMixerChannel
{
    //MIXER_DelChannel(name) became MIXER_DeregisterChannel(ptr): the mixer owns
    //its channels as shared_ptrs now and matches them by identity, not by name.
    MixerChannelPtr channel = MIXER_FindChannel(BXMIDIChannelName);
    if (channel)
    {
        channel->Enable(false);
        MIXER_DeregisterChannel(channel);
    }
}

- (void) _renderMIDIOutputToChannel: (MixerChannel *)channel frames: (NSUInteger)numFrames
{
    id <BXAudioSource> source = (id <BXAudioSource>)self.activeMIDIDevice;
    
    NSAssert1([source conformsToProtocol: @protocol(BXAudioSource)], @"_renderMIDIOutputToChannel:length: called for MIDI device that does not implement BXAudioSource: %@", source);
    
    [self _renderOutputFromSource: source toChannel: channel frames: numFrames];
}

- (void) _renderOutputFromSource: (id <BXAudioSource>)source
                       toChannel: (MixerChannel *)channel
                          frames: (NSUInteger)numFrames
{
    NSUInteger sampleRate = 0;
    BXAudioFormat format = BXAudioFormatAny;
    
    //Never render more than our scratch buffer can hold. Any shortfall is
    //made up with silence below, which is how upstream's own channel helpers
    //handle an under-filled request.
    NSUInteger framesToRender = MIN(numFrames, BXMixerScratchMaxFrames);
    
    BOOL audioRendered = [source renderOutputToBuffer: (void *)BXMixerScratchBuffer
                                               frames: framesToRender
                                           sampleRate: &sampleRate
                                               format: &format];
    
    if (audioRendered)
    {
        [self _renderBuffer: BXMixerScratchBuffer
                  toChannel: channel
                     frames: framesToRender
                     format: format];
    }
    
    if (!audioRendered || framesToRender < numFrames)
    {
        //AddSilence() tops the channel up to the frame count it asked for,
        //so it is correct both for "nothing rendered" and for a short read.
        channel->AddSilence();
    }
}

- (void) _renderBuffer: (void *)buffer
             toChannel: (MixerChannel *)channel
                frames: (NSUInteger)numFrames
                format: (BXAudioFormat)format
{
    NSUInteger size = format & BXAudioFormatSizeMask;
    BOOL isSigned = !!(format & BXAudioFormatSigned);
    BOOL isStereo = !!(format & BXAudioFormatStereo);
    
    const int frames = (int)numFrames;
    const NSUInteger numSamples = numFrames * (isStereo ? 2 : 1);
    
    if (frames <= 0) return;
    
    switch (size)
    {
        case BXAudioFormat8Bit:
            //Unsigned 8-bit mono is the only 8-bit form 0.83 still takes
            //directly; AddSamples_s8s/_m8s/_s8 are gone.
            if (!isSigned && !isStereo)
            {
                channel->AddSamples_m8(frames, (const uint8_t *)buffer);
            }
            //lut_u8to16/lut_s8to16 are the very tables the mixer used to widen
            //8-bit samples with internally, so going through them here is
            //bit-identical to what those entry points did.
            else if (isSigned)
            {
                const int8_t *samples = (const int8_t *)buffer;
                for (NSUInteger i = 0; i < numSamples; i++)
                    BXMixerConversionBuffer[i] = lut_s8to16[samples[i]];
                
                if (isStereo)   channel->AddSamples_s16(frames, BXMixerConversionBuffer);
                else            channel->AddSamples_m16(frames, BXMixerConversionBuffer);
            }
            else
            {
                const uint8_t *samples = (const uint8_t *)buffer;
                for (NSUInteger i = 0; i < numSamples; i++)
                    BXMixerConversionBuffer[i] = lut_u8to16[samples[i]];
                
                channel->AddSamples_s16(frames, BXMixerConversionBuffer);
            }
            break;
        
        case BXAudioFormat16Bit:
            if (isSigned)
            {
                if (isStereo)   channel->AddSamples_s16(frames, (const int16_t *)buffer);
                else            channel->AddSamples_m16(frames, (const int16_t *)buffer);
            }
            else
            {
                //AddSamples_s16u/_m16u are gone, so rebias to signed ourselves.
                const uint16_t *samples = (const uint16_t *)buffer;
                for (NSUInteger i = 0; i < numSamples; i++)
                    BXMixerConversionBuffer[i] = (int16_t)((int32_t)samples[i] - 32768);
                
                if (isStereo)   channel->AddSamples_s16(frames, BXMixerConversionBuffer);
                else            channel->AddSamples_m16(frames, BXMixerConversionBuffer);
            }
            break;
            
        case BXAudioFormat32Bit:
        {
            //AddSamples_s32/_m32 are gone too. They never treated their input
            //as full-range 32-bit audio: DOSBox's converter cast each int32
            //straight into the mixer's internal float scale, which is 16-bit
            //(+/-32768) — the comment in mixer.cpp still reads "16bit and 32bit
            //both contain 16bit data internally". The float entry points use
            //that same scale, so a plain cast preserves the old behaviour.
            //
            //Nothing in Boxer produces 32-bit audio today: the only
            //BXAudioSource in the tree is BXEmulatedMT32, which renders signed
            //16-bit stereo. This path is untested.
            const int32_t *samples = (const int32_t *)buffer;
            for (NSUInteger i = 0; i < numSamples; i++)
                BXMixerFloatBuffer[i] = (float)samples[i];
            
            if (isStereo)   channel->AddSamples_sfloat(frames, BXMixerFloatBuffer);
            else            channel->AddSamples_mfloat(frames, BXMixerFloatBuffer);
            break;
        }
    }
}

- (void) _resetMIDIDevice
{
    [self _clearPendingSysexMessages];
    
    //Clear the active MIDI device so that we can redetect it next time
    if (self.autodetectsMT32)
    {
        self.activeMIDIDevice = nil;
    }
}

- (void) _queueSysexMessage: (NSData *)message
{
    //Copy the message before queuing, as it may be backed by a buffer we don't own.
    [_pendingSysexMessages addObject: [message copy]];
}

- (void) _flushPendingSysexMessages
{
    if (self.activeMIDIDevice)
    {
        for (NSData *message in _pendingSysexMessages)
        {
            //If we're not ready to send yet, wait until we are.
            [self _waitUntilActiveMIDIDeviceIsReady];
            [self.activeMIDIDevice handleSysex: message];
        }
    }
    [self _clearPendingSysexMessages];
}

- (void) _clearPendingSysexMessages
{
    [_pendingSysexMessages removeAllObjects];
}

- (void) _waitUntilActiveMIDIDeviceIsReady
{
    id <BXMIDIDevice> device = self.activeMIDIDevice;
    BOOL askDelegate = [self.delegate respondsToSelector: @selector(emulator:shouldWaitForMIDIDevice:untilDate:)];
    
    while (device.isProcessing)
    {
        NSDate *date = device.dateWhenReady;
        BOOL keepWaiting = YES;
        
        if (askDelegate) keepWaiting = [self.delegate emulator: self
                                       shouldWaitForMIDIDevice: device
                                                     untilDate: date];
        
        //Block by running the thread's loop until the time is up or we've been cancelled
        if (keepWaiting)
        {
            while (!self.isCancelled && [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                                                                 beforeDate: date]);
        }
    }
}

- (void) _attachRequestedMIDIDeviceIfNeeded
{
    if (!self.activeMIDIDevice)
    {
        [self attachMIDIDeviceForDescription: self.requestedMIDIDeviceDescription];
    }
}


#pragma mark -
#pragma mark Volume and muting

- (void) _syncVolume
{
    //0.78's mixer called back into boxer_masterVolume() for every channel on
    //every volume change, which is why Boxer had to patch mixer.cpp at all.
    //0.83 has a real master gain, so Boxer just sets it and the hook — along
    //with its boxer_updateVolumes() counterpart inside mixer.cpp — is retired.
    //
    //Note that we can only do this once the mixer subsystem has initialized,
    //and won't need to do it before then anyway.
    if (self.isInitialized)
    {
        const float volume = self.masterVolume;
        MIXER_SetMasterVolume(AudioFrame(volume, volume));
    }
    
    //Also update the volume of our current MIDI device.
    if (self.activeMIDIDevice)
    {
        self.activeMIDIDevice.volume = self.masterVolume;
    }
}

@end
