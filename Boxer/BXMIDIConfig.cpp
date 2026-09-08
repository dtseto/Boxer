//
//  BXMIDIConfig.cpp
//  Boxer
//
//  Created by C.W. Betts on 2/10/21.
//  Copyright © 2021 Alun Bestor and contributors. All rights reserved.
//

#include "BXMIDIConfig.hpp"
#include <string>
#include <vector>

#include "utils/string_utils.h"


static void init_mt32_dosbox_settings(SectionProp &sec_prop)
{
    const std::vector<std::string> mt32ReverseStereo = {"off", "on"};
    PropString *Pstring = sec_prop.AddString("ReverseStereo",Property::Changeable::WhenIdle,"off");
    Pstring->SetValues(mt32ReverseStereo);
    Pstring->SetHelp("Reverse stereo channels for MT-32 output");

    const std::vector<std::string> mt32DACModes = {"0", "1", "2", "3", "auto"};
    Pstring = sec_prop.AddString("DAC",Property::Changeable::WhenIdle,"auto");
    Pstring->SetValues(mt32DACModes);
    Pstring->SetHelp("MT-32 DAC input mode\n"
                      "Nice = 0 - default\n"
                      "Produces samples at double the volume, without tricks.\n"
                      "Higher quality than the real devices\n\n"
                      
                      "Pure = 1\n"
                      "Produces samples that exactly match the bits output from the emulated LA32.\n"
                      "Nicer overdrive characteristics than the DAC hacks (it simply clips samples within range)\n"
                      "Much less likely to overdrive than any other mode.\n"
                      "Half the volume of any of the other modes, meaning its volume relative to the reverb\n"
                      "output when mixed together directly will sound wrong. So, reverb level must be lowered.\n"
                      "Perfect for developers while debugging :)\n\n"
                      
                      "GENERATION1 = 2\n"
                      "Re-orders the LA32 output bits as in early generation MT-32s (according to Wikipedia).\n"
                      "Bit order at DAC (where each number represents the original LA32 output bit number, and XX means the bit is always low):\n"
                      "15 13 12 11 10 09 08 07 06 05 04 03 02 01 00 XX\n\n"
                      
                      "GENERATION2 = 3\n"
                      "Re-orders the LA32 output bits as in later generations (personally confirmed on my CM-32L - KG).\n"
                      "Bit order at DAC (where each number represents the original LA32 output bit number):\n"
                      "15 13 12 11 10 09 08 07 06 05 04 03 02 01 00 14\n\n");
    const std::vector<std::string> mt32reverbModes = {"0", "1", "2", "3", "auto"};
    Pstring = sec_prop.AddString("reverbmode",Property::Changeable::WhenIdle,"auto");
    Pstring->SetValues(mt32reverbModes);
    Pstring->SetHelp("MT-32 reverb mode");

    const std::vector<std::string> mt32reverbTimes = {"0", "1", "2", "3", "4", "5", "6", "7"};
    PropInt *Pint = sec_prop.AddInt("reverbtime",Property::Changeable::WhenIdle,5);
    Pint->SetValues(mt32reverbTimes);
    Pint->SetHelp("MT-32 reverb time");

    const std::vector<std::string> mt32reverbLevels = {"0", "1", "2", "3", "4", "5", "6", "7"};
    Pint = sec_prop.AddInt("reverblevel",Property::Changeable::WhenIdle,3);
    Pint->SetValues(mt32reverbLevels);
    Pint->SetHelp("MT-32 reverb level");
}

void BXMIDIMT32_AddConfigSection(const ConfigPtr& conf)
{
    assert(conf);
    SectionProp* sec_prop = conf->AddSection("mt32");
    assert(sec_prop);
    init_mt32_dosbox_settings(*sec_prop);
}
