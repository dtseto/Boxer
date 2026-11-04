/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "keyboard.h"
#import "BXCoalface.h"
#import "render.h"
#import "vga.h"
#define BXDOSBOX_BRIDGE_IMPLEMENTATION 1
#import "../DOSBox-Staging/include/BXDOSBoxBridgeRegistration.h"
#undef BXDOSBOX_BRIDGE_IMPLEMENTATION
#import "BXEmulatorPrivate.h"
#import "BXVideoHandler.h"
#import "Rendering/BXVideoFrame.h"
#import "setup.h"
#import "control.h"
#import "mapper.h"
#import "joystick.h"
#import "mouse.h"
#import "cross.h"
#import "shell.h"
#import "cpu.h"
#import "regs.h"
#import "callback.h"
#import "drives.h"
#import "src/dos/dos_keyboard_layout.h"
#import "src/hardware/parport/printer_charmaps.h"
#import "ADBFilesystem.h"

#include <chrono>
#include <atomic>
#include <pthread.h>
#include <sched.h>
#include <sys/qos.h>
#include <thread>

#if (C_DYNAMIC_X86)
void CPU_Core_Dyn_X86_Cache_Init(bool enable_cache);
void CPU_Core_Dyn_X86_SetFPUMode(bool dh_fpu);
#elif (C_DYNREC)
void CPU_Core_Dynrec_Cache_Init(bool enable_cache);
#endif

extern const char *RunningProgram;

static bool BXTicksLocked = false;

static CommandLine *BXDOSBoxCommandLine;

static uintptr_t boxer_configurationCreate(void)
{
    char const *argv[0];
    BXDOSBoxCommandLine = new CommandLine(0, argv);
    control.reset(new Config(BXDOSBoxCommandLine));
    return (uintptr_t)control.get();
}

static void boxer_configurationInitializeConfigDirectory(void)
{
    InitConfigDir();
}

static void boxer_configurationInitializeDOSBox(void)
{
    DOSBOX_Init();
}

static void boxer_configurationParseConfigFile(uintptr_t configuration, const char *path)
{
    ((Config *)configuration)->ParseConfigFile("custom", path);
}

static void boxer_configurationInitialize(uintptr_t configuration)
{
    ((Config *)configuration)->Init();
}

static void boxer_configurationStartUp(uintptr_t configuration)
{
    ((Config *)configuration)->StartUp();
}

static void boxer_configurationDestroy(uintptr_t configuration)
{
    (void)configuration;
    control.reset();
    delete BXDOSBoxCommandLine;
    BXDOSBoxCommandLine = NULL;
}

static bool boxer_configurationShutdownRequested(void)
{
    return shutdown_requested;
}

static void boxer_configurationRequestShutdown(void)
{
    shutdown_requested = true;
}

static int boxer_cpuControlCycleMaximum(void)
{
    return CPU_CycleMax;
}

static void boxer_cpuControlSetCycleMaximum(int value)
{
    CPU_CycleMax = value;
}

static bool boxer_cpuControlCycleAutoAdjust(void)
{
    return CPU_CycleAutoAdjust;
}

static void boxer_cpuControlSetCycleAutoAdjust(bool enabled)
{
    CPU_CycleAutoAdjust = enabled;
}

static void boxer_cpuControlSetCyclePercentageUsed(int value)
{
    CPU_CyclePercUsed = value;
}

static void boxer_cpuControlResetCycleCounters(void)
{
    CPU_CycleLeft = 0;
    CPU_Cycles = 0;
}

static uint8_t boxer_cpuControlCoreMode(void)
{
    if (cpudecoder == &CPU_Core_Normal_Run || cpudecoder == &CPU_Core_Normal_Trap_Run)
        return 0;
#if (C_DYNAMIC_X86)
    if (cpudecoder == &CPU_Core_Dyn_X86_Run || cpudecoder == &CPU_Core_Dyn_X86_Trap_Run)
        return 1;
#endif
#if (C_DYNREC)
    if (cpudecoder == &CPU_Core_Dynrec_Run || cpudecoder == &CPU_Core_Dynrec_Trap_Run)
        return 1;
#endif
    if (cpudecoder == &CPU_Core_Simple_Run)
        return 2;
    if (cpudecoder == &CPU_Core_Full_Run)
        return 3;
    return UINT8_MAX;
}

extern "C" uint8_t boxer_cpuCurrentCoreMode(void)
{
    return boxer_cpuControlCoreMode();
}

static bool boxer_cpuControlSetCoreMode(uint8_t mode)
{
    switch (mode)
    {
        case 0:
            cpudecoder = &CPU_Core_Normal_Run;
            break;
        case 1:
#if (C_DYNAMIC_X86)
            CPU_Core_Dyn_X86_Cache_Init(true);
            CPU_Core_Dyn_X86_SetFPUMode(true);
            cpudecoder = &CPU_Core_Dyn_X86_Run;
#elif (C_DYNREC)
            CPU_Core_Dynrec_Cache_Init(true);
            cpudecoder = &CPU_Core_Dynrec_Run;
#else
            return false;
#endif
            break;
        case 2:
            cpudecoder = &CPU_Core_Simple_Run;
            break;
        case 3:
            cpudecoder = &CPU_Core_Full_Run;
            break;
        default:
            return false;
    }
    boxer_cpuControlResetCycleCounters();
    return true;
}

static bool boxer_cpuControlTicksLocked(void)
{
    return BXTicksLocked;
}

static void boxer_cpuControlSetTicksLocked(bool locked)
{
    BXTicksLocked = locked;
}

static BXDOSBoxConfigurationBridgeCallbacks BXDOSBoxConfigurationCallbacks = {
    boxer_configurationCreate,
    boxer_configurationInitializeConfigDirectory,
    boxer_configurationInitializeDOSBox,
    boxer_configurationParseConfigFile,
    boxer_configurationInitialize,
    boxer_configurationStartUp,
    boxer_configurationDestroy,
    boxer_configurationShutdownRequested,
    boxer_configurationRequestShutdown
};

static bool BXDOSBoxConfigurationCallbacksRegistered = false;

void boxer_registerDOSBoxConfigurationBridge(const BXDOSBoxConfigurationBridgeCallbacks *callbacks)
{
    if (callbacks)
    {
        BXDOSBoxConfigurationCallbacks = *callbacks;
        BXDOSBoxConfigurationCallbacksRegistered = true;
    }
}

const BXDOSBoxConfigurationBridgeCallbacks *boxer_registeredDOSBoxConfigurationBridge(void)
{
    if (!BXDOSBoxConfigurationCallbacksRegistered)
    {
        boxer_registerDOSBoxConfigurationBridge(&BXDOSBoxConfigurationCallbacks);
    }
    return &BXDOSBoxConfigurationCallbacks;
}

static BXDOSBoxCPUControlBridgeCallbacks BXDOSBoxCPUControlCallbacks = {
    boxer_cpuControlCycleMaximum,
    boxer_cpuControlSetCycleMaximum,
    boxer_cpuControlCycleAutoAdjust,
    boxer_cpuControlSetCycleAutoAdjust,
    boxer_cpuControlSetCyclePercentageUsed,
    boxer_cpuControlResetCycleCounters,
    boxer_cpuControlCoreMode,
    boxer_cpuControlSetCoreMode,
    boxer_cpuControlTicksLocked,
    boxer_cpuControlSetTicksLocked
};

const BXDOSBoxCPUControlBridgeCallbacks *boxer_registeredDOSBoxCPUControlBridge(void)
{
    return &BXDOSBoxCPUControlCallbacks;
}

#pragma mark - Runloop state functions

/// This is called in place of DOSBox's GFX_Events to allow us to process events when the DOSBox
/// core runloop gives us time.
bool boxer_processEvents()
{
	boxer_audioTimingBeginPhase(BXAdapterTimingEvents);
	[[BXEmulator currentEmulator] _processEvents];
	const bool result = !shutdown_requested && boxer_runLoopShouldContinue();
	boxer_audioTimingEndPhase(BXAdapterTimingEvents);
	return result;
}

/*
 static void UpdateFramePeriod()
 {
     assert(sdl.window);
     SDL_DisplayMode display_mode;
     SDL_GetWindowDisplayMode(sdl.window, &display_mode);
     const int refresh_rate = display_mode.refresh_rate > 0
                                      ? display_mode.refresh_rate
                                      : 60;
     frame_period = std::chrono::nanoseconds(1'000'000'000 / refresh_rate);
 }

 */

//TODO: move to BXEmulator
//! The frame-period holds the current duration for which a single host
//! video-frame is displayed. This is kept up-to-date when the video mode is set.
//! A sane starting value is used, which is based on a 60-Hz monitor.
auto frame_period = std::chrono::nanoseconds(1'000'000'000 / 60);
static thread_local std::chrono::steady_clock::time_point boxer_loop_started_at;

namespace {

constexpr uint32_t BXAdapterTimingHistogramBuckets = 1001;
constexpr uint64_t BXAdapterTimingSlowIterationUs = 20000;

struct BXAdapterTimingWindow {
	uint64_t count = 0;
	uint64_t sum = 0;
	uint64_t minimum = UINT64_MAX;
	uint64_t maximum = 0;
	uint32_t histogram[BXAdapterTimingHistogramBuckets] = {};
};

static thread_local BXAdapterTimingWindow boxer_timing_windows[5];
static thread_local std::chrono::steady_clock::time_point boxer_phase_started[3];
static thread_local uint64_t boxer_phase_totals[3] = {};
static thread_local std::chrono::steady_clock::time_point boxer_timing_window_started;
static thread_local bool boxer_timing_loop_active = false;
static thread_local uint64_t boxer_last_slow_log = 0;
static thread_local std::chrono::steady_clock::time_point boxer_machine_call_started_at;
static thread_local bool boxer_machine_call_active = false;
static thread_local std::chrono::steady_clock::time_point boxer_last_machine_call_finished_at;
static thread_local uint64_t boxer_last_machine_entry_log_ticks = 0;
static thread_local uint64_t boxer_machine_call_count = 0;
static thread_local uint64_t boxer_machine_call_total_us = 0;
// The first completed machine call may include process-start accounting. Begin
// the reported duty window after that startup sample has been discarded.
static thread_local bool boxer_machine_duty_window_started = false;
static thread_local uint64_t boxer_last_machine_summary_ticks = 0;
static std::atomic<bool> boxer_thread_info_logged = false;
static std::atomic<uint64_t> boxer_last_sleep_log_ticks = 0;

static const char *boxer_qosName(const qos_class_t qos)
{
	switch (qos) {
	case QOS_CLASS_USER_INTERACTIVE: return "USER_INTERACTIVE";
	case QOS_CLASS_USER_INITIATED: return "USER_INITIATED";
	case QOS_CLASS_DEFAULT: return "DEFAULT";
	case QOS_CLASS_UTILITY: return "UTILITY";
	case QOS_CLASS_BACKGROUND: return "BACKGROUND";
	default: return "UNSPECIFIED";
	}
}

static uint64_t boxer_timingMicroseconds(const std::chrono::steady_clock::duration duration)
{
	return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(duration).count());
}

static void boxer_recordTiming(BXAdapterTimingWindow &window, const uint64_t microseconds)
{
	window.count++;
	window.sum += microseconds;
	window.minimum = std::min(window.minimum, microseconds);
	window.maximum = std::max(window.maximum, microseconds);
	window.histogram[std::min<uint64_t>(microseconds, BXAdapterTimingHistogramBuckets - 1)]++;
}

static uint64_t boxer_timingPercentile(const BXAdapterTimingWindow &window, const double percentile)
{
	if (!window.count)
		return 0;
	const uint64_t target = static_cast<uint64_t>((window.count - 1) * percentile);
	uint64_t seen = 0;
	for (uint32_t bucket = 0; bucket < BXAdapterTimingHistogramBuckets; bucket++) {
		seen += window.histogram[bucket];
		if (seen > target)
			return bucket;
	}
	return window.maximum;
}

static void boxer_reportTimingWindow(void)
{
	static const char *names[] = {"total", "events", "video", "delegate", "residual"};
	for (NSUInteger index = 0; index < 5; index++) {
		const BXAdapterTimingWindow &window = boxer_timing_windows[index];
		if (!window.count)
			continue;
		LOG_MSG("BOXER:AUDIO timing phase=%s count=%llu min=%llu median=%llu p95=%llu max=%llu avg=%llu us thread=%zu",
		        names[index],
		        static_cast<unsigned long long>(window.count),
		        static_cast<unsigned long long>(window.minimum),
		        static_cast<unsigned long long>(boxer_timingPercentile(window, 0.50)),
		        static_cast<unsigned long long>(boxer_timingPercentile(window, 0.95)),
		        static_cast<unsigned long long>(window.maximum),
		        static_cast<unsigned long long>(window.sum / window.count),
		        std::hash<std::thread::id>{}(std::this_thread::get_id()));
	}
	for (BXAdapterTimingWindow &window : boxer_timing_windows)
		window = BXAdapterTimingWindow{};
}

}

void boxer_audioTimingBeginLoop()
{
	boxer_audioTimingLogThreadInfoOnce();
	boxer_loop_started_at = std::chrono::steady_clock::now();
	memset(boxer_phase_totals, 0, sizeof(boxer_phase_totals));
	boxer_timing_loop_active = true;
	if (boxer_timing_window_started == std::chrono::steady_clock::time_point{})
		boxer_timing_window_started = boxer_loop_started_at;
}

void boxer_audioTimingEndLoop()
{
	if (!boxer_timing_loop_active)
		return;
	const auto now = std::chrono::steady_clock::now();
	const uint64_t total_us = boxer_timingMicroseconds(now - boxer_loop_started_at);
	uint64_t accounted_us = 0;
	for (uint64_t duration : boxer_phase_totals)
		accounted_us += duration;
	const uint64_t residual_us = total_us > accounted_us ? total_us - accounted_us : 0;
	boxer_recordTiming(boxer_timing_windows[0], total_us);
	boxer_recordTiming(boxer_timing_windows[3], boxer_phase_totals[BXAdapterTimingDelegate]);
	boxer_recordTiming(boxer_timing_windows[2], boxer_phase_totals[BXAdapterTimingVideoHandoff]);
	boxer_recordTiming(boxer_timing_windows[1], boxer_phase_totals[BXAdapterTimingEvents]);
	boxer_recordTiming(boxer_timing_windows[4], residual_us);
	const uint64_t now_ticks = now.time_since_epoch().count();
	const uint64_t slow_log_interval = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::milliseconds(100)).count();
	if (total_us >= BXAdapterTimingSlowIterationUs &&
	    (boxer_last_slow_log == 0 || now_ticks - boxer_last_slow_log >= slow_log_interval)) {
		const bool first_in_burst = boxer_last_slow_log == 0 || now_ticks - boxer_last_slow_log >= 250000000ULL;
		boxer_last_slow_log = now_ticks;
		LOG_MSG("BOXER:AUDIO slow-loop total=%llu events=%llu video=%llu delegate=%llu residual=%llu us thread=%zu%s",
		        static_cast<unsigned long long>(total_us),
		        static_cast<unsigned long long>(boxer_phase_totals[BXAdapterTimingEvents]),
		        static_cast<unsigned long long>(boxer_phase_totals[BXAdapterTimingVideoHandoff]),
		        static_cast<unsigned long long>(boxer_phase_totals[BXAdapterTimingDelegate]),
		        static_cast<unsigned long long>(residual_us),
		        std::hash<std::thread::id>{}(std::this_thread::get_id()),
		        first_in_burst ? " first-in-burst" : "");
	}
	boxer_timing_loop_active = false;
	if (now - boxer_timing_window_started >= std::chrono::seconds(1)) {
		boxer_reportTimingWindow();
		boxer_timing_window_started = now;
	}
}

void boxer_audioTimingLogThreadInfoOnce()
{
	bool expected = false;
	if (!boxer_thread_info_logged.compare_exchange_strong(expected, true))
		return;

	char thread_name[64] = {};
	pthread_getname_np(pthread_self(), thread_name, sizeof(thread_name));
	int policy = 0;
	struct sched_param scheduling = {};
	pthread_getschedparam(pthread_self(), &policy, &scheduling);
	const qos_class_t qos = qos_class_self();

	LOG_MSG("BOXER:AUDIO thread-info pthread=%llu name=%s qos=%s "
	        "policy=%d sched-priority=%d",
	        static_cast<unsigned long long>(pthread_mach_thread_np(pthread_self())),
	        thread_name[0] ? thread_name : "(unnamed)",
	        boxer_qosName(qos),
	        policy,
	        scheduling.sched_priority);
}

void boxer_audioTimingMachineCallWillStart()
{
	boxer_audioTimingLogThreadInfoOnce();
	const auto now = std::chrono::steady_clock::now();
	if (boxer_last_machine_call_finished_at != std::chrono::steady_clock::time_point{}) {
		const uint64_t gap_us = boxer_timingMicroseconds(now - boxer_last_machine_call_finished_at);
		const uint64_t now_ticks = now.time_since_epoch().count();
		const uint64_t log_interval =
		        std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::milliseconds(100)).count();
		if (gap_us > 5000 &&
		    (boxer_last_machine_entry_log_ticks == 0 ||
		     now_ticks - boxer_last_machine_entry_log_ticks >= log_interval)) {
			boxer_last_machine_entry_log_ticks = now_ticks;
			LOG_MSG("BOXER:AUDIO machine-entry gap=%llu us "
			        "caller_wait_before_next_entry=%llu us thread=%zu",
			        static_cast<unsigned long long>(gap_us),
			        static_cast<unsigned long long>(gap_us),
			        std::hash<std::thread::id>{}(std::this_thread::get_id()));
		}
	}
	boxer_machine_call_started_at = now;
	boxer_machine_call_active = true;
}

void boxer_audioTimingMachineCallDidFinish()
{
	if (!boxer_machine_call_active)
		return;

	const auto now = std::chrono::steady_clock::now();
	const uint64_t duration_us = boxer_timingMicroseconds(now - boxer_machine_call_started_at);
	boxer_machine_call_count++;
	boxer_machine_call_total_us += duration_us;
	static thread_local uint64_t last_log_ticks = 0;
	const uint64_t now_ticks = now.time_since_epoch().count();
	const uint64_t log_interval =
	        std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::milliseconds(100)).count();
	if (duration_us >= BXAdapterTimingSlowIterationUs &&
	    (last_log_ticks == 0 || now_ticks - last_log_ticks >= log_interval)) {
		last_log_ticks = now_ticks;
		LOG_MSG("BOXER:AUDIO machine-call body=%llu us thread=%zu",
		        static_cast<unsigned long long>(duration_us),
		        std::hash<std::thread::id>{}(std::this_thread::get_id()));
	}
	const uint64_t summary_interval =
	        std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::seconds(1)).count();
	if (!boxer_machine_duty_window_started) {
		// Do not present process-start accounting as the first steady-state sample.
		boxer_machine_duty_window_started = true;
		boxer_machine_call_count = 0;
		boxer_machine_call_total_us = 0;
		boxer_last_machine_summary_ticks = now_ticks;
	} else if (now_ticks - boxer_last_machine_summary_ticks >= summary_interval) {
		boxer_last_machine_summary_ticks = now_ticks;
		LOG_MSG("BOXER:AUDIO machine-duty calls=%llu inside=%llu us thread=%zu",
		        static_cast<unsigned long long>(boxer_machine_call_count),
		        static_cast<unsigned long long>(boxer_machine_call_total_us),
		        std::hash<std::thread::id>{}(std::this_thread::get_id()));
		boxer_machine_call_count = 0;
		boxer_machine_call_total_us = 0;
	}
	boxer_last_machine_call_finished_at = now;
	boxer_machine_call_active = false;
}

void boxer_audioTimingReportSleep(const uint64_t requestedMicroseconds,
                                  const uint64_t actualMicroseconds)
{
	if (actualMicroseconds <= requestedMicroseconds + 1000)
		return;

	const auto now = std::chrono::steady_clock::now();
	const uint64_t now_ticks = now.time_since_epoch().count();
	const uint64_t log_interval =
	        std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::milliseconds(100)).count();
	uint64_t expected_ticks = boxer_last_sleep_log_ticks.load();
	if (expected_ticks != 0 && now_ticks - expected_ticks < log_interval)
		return;
	if (!boxer_last_sleep_log_ticks.compare_exchange_strong(expected_ticks, now_ticks))
		return;

	LOG_MSG("BOXER:AUDIO timing-sleep requested=%llu actual=%llu us thread=%zu",
	        static_cast<unsigned long long>(requestedMicroseconds),
	        static_cast<unsigned long long>(actualMicroseconds),
	        std::hash<std::thread::id>{}(std::this_thread::get_id()));
}

void boxer_audioTimingReportInternalLoop(const uint64_t totalMicroseconds,
                                         const uint64_t picMicroseconds,
                                         const uint64_t cpuMicroseconds,
                                         const uint64_t timerMicroseconds,
                                         const uint64_t eventsMicroseconds,
                                         const int64_t cpuCycles,
                                         const int64_t cpuCycleLeft,
                                         const int64_t cpuCycleMax,
                                         const bool cpuAutoAdjust,
                                         const int64_t cpuPercentUsed,
                                         const uint8_t cpuCoreMode,
                                         const int64_t ticksRemain,
                                         const int64_t ticksScheduled,
                                         const int64_t ticksDone)
{
	if (totalMicroseconds < BXAdapterTimingSlowIterationUs)
		return;

	static thread_local uint64_t last_log_ticks = 0;
	const auto now = std::chrono::steady_clock::now();
	const uint64_t now_ticks = now.time_since_epoch().count();
	const uint64_t log_interval =
	        std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::milliseconds(100)).count();
	if (last_log_ticks != 0 && now_ticks - last_log_ticks < log_interval)
		return;
	last_log_ticks = now_ticks;

	const char *core_name = "unknown";
	switch (cpuCoreMode) {
	case 0: core_name = "normal"; break;
	case 1: core_name = "dynamic"; break;
	case 2: core_name = "simple"; break;
	case 3: core_name = "full"; break;
	default: break;
	}

	LOG_MSG("BOXER:AUDIO internal-loop total=%llu pic=%llu cpu=%llu timer=%llu "
	        "events=%llu cpu-cycles=%lld cpu-cycle-left=%lld cpu-cycle-max=%lld "
	        "cpu-auto-adjust=%s cpu-percent-used=%lld cpu-core=%s "
	        "ticks-remain=%lld ticks-scheduled=%lld ticks-done=%lld thread=%zu",
	        static_cast<unsigned long long>(totalMicroseconds),
	        static_cast<unsigned long long>(picMicroseconds),
	        static_cast<unsigned long long>(cpuMicroseconds),
	        static_cast<unsigned long long>(timerMicroseconds),
	        static_cast<unsigned long long>(eventsMicroseconds),
	        static_cast<long long>(cpuCycles),
	        static_cast<long long>(cpuCycleLeft),
	        static_cast<long long>(cpuCycleMax),
	        cpuAutoAdjust ? "true" : "false",
	        static_cast<long long>(cpuPercentUsed),
	        core_name,
	        static_cast<long long>(ticksRemain),
	        static_cast<long long>(ticksScheduled),
	        static_cast<long long>(ticksDone),
	        std::hash<std::thread::id>{}(std::this_thread::get_id()));
}

void boxer_audioTimingBeginPhase(const BXAdapterTimingPhase phase)
{
	if (boxer_timing_loop_active && phase >= BXAdapterTimingEvents && phase <= BXAdapterTimingDelegate)
		boxer_phase_started[phase] = std::chrono::steady_clock::now();
}

void boxer_audioTimingEndPhase(const BXAdapterTimingPhase phase)
{
	if (boxer_timing_loop_active && phase >= BXAdapterTimingEvents && phase <= BXAdapterTimingDelegate)
		boxer_phase_totals[phase] += boxer_timingMicroseconds(std::chrono::steady_clock::now() - boxer_phase_started[phase]);
}

bool boxer_MaybeProcessEvents()
{
    // Process SDL's event queue at 200 Hz
    constexpr auto ps2_poll_period = std::chrono::nanoseconds(1'000'000'000 / 200);

    // SDL maintainers recommend processing the SDL's event queue before
    // each frame. For now, simply ensure that the PS/2 polling period is
    // quicker than the video frame period. If a time comes when common
    // displays update faster than 200 Hz, then update this code to pick the
    // quicker of the two.
    assert(ps2_poll_period <= frame_period);

    static auto next_process_at = std::chrono::steady_clock::now() + ps2_poll_period;
    const auto checked_at = std::chrono::steady_clock::now();
    if (checked_at < next_process_at)
        return true;

    const bool process_result = boxer_processEvents();

#if defined(REPORT_EVENT_LAG)
    const auto host_lag = std::chrono::steady_clock::now() - checked_at;
    if (host_lag > std::chrono::milliseconds(3)) {
        const std::chrono::duration<double, std::milli> lag_ms = host_lag;
        LOG_MSG("SDL: Processing SDL's event queue took %5.2f ms",
                lag_ms.count());
    }
#endif

    next_process_at = checked_at + ps2_poll_period;
    return process_result;
}

/// Called at the start and end of every iteration of DOSBOX_RunMachine.
void boxer_runLoopWillStartWithContextInfo(void **contextInfo)
{
	// DOSBox-Staging's timer/PIC callbacks, including GUS production, are
	// driven by this emulation thread. Keep timing diagnostics at the Boxer
	// adapter boundary so the Staging sources remain upstream-compatible.
	boxer_audioTimingBeginLoop();
	const auto callback_started_at = std::chrono::steady_clock::now();
	[[BXEmulator currentEmulator] _runLoopWillStartWithContextInfo: contextInfo];
	const uint64_t callback_us = boxer_timingMicroseconds(std::chrono::steady_clock::now() - callback_started_at);
	if (callback_us >= BXAdapterTimingSlowIterationUs)
		LOG_MSG("BOXER:AUDIO callback-phase=will-start duration=%llu us thread=%zu",
		        static_cast<unsigned long long>(callback_us),
		        std::hash<std::thread::id>{}(std::this_thread::get_id()));
}

void boxer_runLoopDidFinishWithContextInfo(void *contextInfo)
{
	const auto callback_started_at = std::chrono::steady_clock::now();
	[[BXEmulator currentEmulator] _runLoopDidFinishWithContextInfo: contextInfo];
	const uint64_t callback_us = boxer_timingMicroseconds(std::chrono::steady_clock::now() - callback_started_at);
	if (callback_us >= BXAdapterTimingSlowIterationUs)
		LOG_MSG("BOXER:AUDIO callback-phase=did-finish duration=%llu us thread=%zu",
		        static_cast<unsigned long long>(callback_us),
		        std::hash<std::thread::id>{}(std::this_thread::get_id()));
	boxer_audioTimingEndLoop();
}

/// This is called at the start of DOSBox_NormalLoop, and
/// allows us to short-circuit the current run loop if needed.
bool boxer_runLoopShouldContinue()
{
	return [[BXEmulator currentEmulator] _runLoopShouldContinue];
}

static bool boxer_runLoopBridgeShouldContinue(void) { return boxer_runLoopShouldContinue(); }
static void boxer_runLoopBridgeWillStartWithContextInfo(void **contextInfo) { boxer_runLoopWillStartWithContextInfo(contextInfo); }
static void boxer_runLoopBridgeDidFinishWithContextInfo(void *contextInfo) { boxer_runLoopDidFinishWithContextInfo(contextInfo); }

static BXDOSBoxRunLoopBridgeCallbacks BXDOSBoxRunLoopCallbacks;
static bool BXDOSBoxRunLoopCallbacksRegistered = false;

void boxer_registerDOSBoxRunLoopBridge(const BXDOSBoxRunLoopBridgeCallbacks *callbacks)
{
    if (callbacks)
    {
        BXDOSBoxRunLoopCallbacks = *callbacks;
        BXDOSBoxRunLoopCallbacksRegistered = true;
    }
}

const BXDOSBoxRunLoopBridgeCallbacks *boxer_registeredDOSBoxRunLoopBridge(void)
{
    if (!BXDOSBoxRunLoopCallbacksRegistered)
    {
        const BXDOSBoxRunLoopBridgeCallbacks callbacks = {
            boxer_runLoopBridgeShouldContinue,
            boxer_runLoopBridgeWillStartWithContextInfo,
            boxer_runLoopBridgeDidFinishWithContextInfo
        };
        boxer_registerDOSBoxRunLoopBridge(&callbacks);
    }
    return BXDOSBoxRunLoopCallbacksRegistered ? &BXDOSBoxRunLoopCallbacks : NULL;
}

static bool boxer_eventBridgeProcessEvents(void) { return boxer_processEvents(); }
static void boxer_eventBridgeHandleTitleChange(int32_t cycles, bool paused)
{
    boxer_handleDOSBoxTitleChange(cycles, paused);
}
static void boxer_eventBridgeRefreshTitle(void) { boxer_refreshDOSBoxTitle(); }
static void boxer_eventBridgeSetMouseHint(uintptr_t hint)
{
    boxer_setMouseHint((MouseHint)hint);
}
static void boxer_eventBridgeSetMouseCapture(bool captured) { boxer_setMouseCapture(captured); }
static void boxer_eventBridgeSetMouseRawInput(bool rawInput) { boxer_setMouseRawInput(rawInput); }
static void boxer_eventBridgeSetMouseVisibility(bool visible) { boxer_setMouseVisibility(visible); }
static bool boxer_eventBridgeHasDesktopEnvironment(void) { return boxer_hasDesktopEnvironment(); }
static void boxer_eventBridgeCenterMouse(void) { boxer_centerMouse(); }

static BXDOSBoxEventBridgeCallbacks BXDOSBoxEventCallbacks;
static bool BXDOSBoxEventCallbacksRegistered = false;

void boxer_registerDOSBoxEventBridge(const BXDOSBoxEventBridgeCallbacks *callbacks)
{
    if (callbacks)
    {
        BXDOSBoxEventCallbacks = *callbacks;
        BXDOSBoxEventCallbacksRegistered = true;
    }
}

const BXDOSBoxEventBridgeCallbacks *boxer_registeredDOSBoxEventBridge(void)
{
    if (!BXDOSBoxEventCallbacksRegistered)
    {
        const BXDOSBoxEventBridgeCallbacks callbacks = {
            boxer_eventBridgeProcessEvents,
            boxer_eventBridgeHandleTitleChange,
            boxer_eventBridgeRefreshTitle,
            boxer_eventBridgeSetMouseHint,
            boxer_eventBridgeSetMouseCapture,
            boxer_eventBridgeSetMouseRawInput,
            boxer_eventBridgeSetMouseVisibility,
            boxer_eventBridgeHasDesktopEnvironment,
            boxer_eventBridgeCenterMouse
        };
        boxer_registerDOSBoxEventBridge(&callbacks);
    }
    return BXDOSBoxEventCallbacksRegistered ? &BXDOSBoxEventCallbacks : NULL;
}

/// Notifies Boxer of changes to title and speed settings
void boxer_handleDOSBoxTitleChange(int32_t newCycles, bool newPaused)
{
    (void)newCycles;
    (void)newPaused;
    BXEmulator *emulator = [BXEmulator currentEmulator];
    [emulator _didChangeEmulationState];
}

void boxer_refreshDOSBoxTitle(void)
{
    boxer_handleDOSBoxTitleChange(-1, false);
}

void boxer_setMouseHint(MouseHint hint)
{
    (void)hint;
}

void boxer_setMouseCapture(bool captured)
{
    // DOSBox's capture state controls the host cursor, not whether the current
    // DOS program should receive mouse input. Boxer owns cursor locking and
    // detects program activity through its shell lifecycle.
    (void)captured;
}

void boxer_setMouseRawInput(bool rawInput)
{
    (void)rawInput;
}

void boxer_setMouseVisibility(bool visible)
{
    (void)visible;
}

bool boxer_hasDesktopEnvironment(void)
{
    // Boxer performs its own cursor locking and decides which mouse events to
    // forward. Treat its bridge as an always-captured host from DOSBox's point
    // of view so the core does not discard Boxer's already-filtered events.
    return false;
}

void boxer_centerMouse(void)
{
    // Boxer synchronizes the host cursor when its input controller unlocks it.
}


#pragma mark - Rendering functions

void boxer_applyRenderingStrategy()
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	[[emulator videoHandler] applyRenderingStrategy];
}

void boxer_setShader(const char* src) {
    //TODO: implement!
}

Bitu boxer_prepareForFrameSize(Bitu width, Bitu height, Bitu gfx_flags, double scalex, double scaley, GFX_CallBack_t callback, double pixel_aspect)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];

    // The SDL frontend normally sends these notifications during startup and
    // focus changes. Boxer replaces that frontend and gates input itself.
    MOUSE_NotifyReadyGFX();
    MOUSE_NotifyHasFocus(true);

	NSSize outputSize	= NSMakeSize((CGFloat)width, (CGFloat)height);
	NSSize scale		= NSMakeSize((CGFloat)scalex, (CGFloat)scaley);
	[[emulator videoHandler] prepareForOutputSize: outputSize atScale: scale withCallback: (void *)(uintptr_t)callback];
	
	return GFX_CAN_32;
}

extern "C" void boxer_getCanvasSizeInPixels(int *width, int *height)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	BXVideoHandler *videoHandler = [emulator videoHandler];
	NSSize size = videoHandler.currentFrame.size;
	if (NSEqualSizes(size, NSZeroSize))
		size = videoHandler.resolution;
	if (width) *width = (int)size.width;
	if (height) *height = (int)size.height;
}

Bitu boxer_idealOutputMode(Bitu flags)
{
	//Originally this tested various bit depths to find the most appropriate mode for the chosen scaler.
	//Because OS X always uses a 32bpp context and Boxer always uses RGBA-capable scalers, we ignore the
	//original function's behaviour altogether and just return something that will keep DOSBox happy.
	return GFX_CAN_32;
}

bool boxer_startFrame(uint8_t * &frameBuffer, int & pitch)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	if (!emulator)
	{
		frameBuffer = NULL;
		pitch = 0;
		return false;
	}
	return [[emulator videoHandler] startFrameWithBuffer: (void **)&frameBuffer pitch: &pitch];
}

void boxer_finishFrame(const uint16_t *dirtyBlocks)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	if (!emulator)
		return;
	[[emulator videoHandler] finishFrameWithChanges: dirtyBlocks];	
}

Bitu boxer_getRGBPaletteEntry(uint8_t red, uint8_t green, uint8_t blue)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	return [[emulator videoHandler] paletteEntryWithRed: red green: green blue: blue];
}

static void boxer_renderingBridgeApplyStrategy(void) { boxer_applyRenderingStrategy(); }
static uintptr_t boxer_renderingBridgePrepareForFrameSize(uintptr_t width, uintptr_t height,
                                                           uintptr_t flags, double scaleX,
                                                           double scaleY, uintptr_t callback,
                                                           double pixelAspect)
{
    return boxer_prepareForFrameSize((Bitu)width, (Bitu)height, (Bitu)flags, scaleX, scaleY,
                                     (GFX_CallBack_t)callback, pixelAspect);
}
static uintptr_t boxer_renderingBridgeIdealOutputMode(uintptr_t flags) { return boxer_idealOutputMode((Bitu)flags); }
static bool boxer_renderingBridgeStartFrame(uint8_t **pixels, int *pitch) { return boxer_startFrame(*pixels, *pitch); }
static void boxer_renderingBridgeFinishFrame(const uint16_t *dirtyBlocks) { boxer_finishFrame(dirtyBlocks); }
static uintptr_t boxer_renderingBridgeGetRGBPaletteEntry(uint8_t red, uint8_t green, uint8_t blue)
{
    return boxer_getRGBPaletteEntry(red, green, blue);
}
static void boxer_renderingBridgeSetShader(const char *source) { boxer_setShader(source); }
static uint8_t boxer_renderingBridgeHerculesTintMode(void) { return boxer_herculesTintMode(); }
static void boxer_renderingBridgeSetHerculesTintMode(uint8_t mode) { boxer_setHerculesTintMode(mode); }
static double boxer_renderingBridgeCGACompositeHueOffset(void) { return boxer_CGACompositeHueOffset(); }
static void boxer_renderingBridgeSetCGACompositeHueOffset(double offset) { boxer_setCGACompositeHueOffset(offset); }
static uint8_t boxer_renderingBridgeCGAComponentMode(void) { return boxer_CGAComponentMode(); }
static void boxer_renderingBridgeSetCGAComponentMode(uint8_t mode) { boxer_setCGAComponentMode(mode); }
static int boxer_renderingBridgeGetDisplayRefreshRate(void) { return boxer_GetDisplayRefreshRate(); }
static uintptr_t boxer_renderingBridgeCurrentVideoWidth(void) { return (uintptr_t)render.src.width; }
static uintptr_t boxer_renderingBridgeCurrentVideoHeight(void) { return (uintptr_t)render.src.height; }
static bool boxer_renderingBridgeCurrentVideoModeIsText(void)
{
    return vga.mode == M_TEXT || vga.mode == M_TANDY_TEXT || vga.mode == M_HERC_TEXT;
}
static bool boxer_renderingBridgeCurrentMachineIsHercules(void) { return machine == MCH_HERC; }
static bool boxer_renderingBridgeCurrentMachineIsCGA(void) { return machine == MCH_CGA; }
static void boxer_renderingBridgeSetRenderScale(uintptr_t scale) { render.scale.size = (Bitu)scale; }

static BXDOSBoxRenderingBridgeCallbacks BXDOSBoxRenderingCallbacks;
static bool BXDOSBoxRenderingCallbacksRegistered = false;

void boxer_registerDOSBoxRenderingBridge(const BXDOSBoxRenderingBridgeCallbacks *callbacks)
{
    if (callbacks)
    {
        BXDOSBoxRenderingCallbacks = *callbacks;
        BXDOSBoxRenderingCallbacksRegistered = true;
    }
}

const BXDOSBoxRenderingBridgeCallbacks *boxer_registeredDOSBoxRenderingBridge(void)
{
    if (!BXDOSBoxRenderingCallbacksRegistered)
    {
        const BXDOSBoxRenderingBridgeCallbacks callbacks = {
            boxer_renderingBridgeApplyStrategy,
            boxer_renderingBridgePrepareForFrameSize,
            boxer_renderingBridgeIdealOutputMode,
            boxer_renderingBridgeStartFrame,
            boxer_renderingBridgeFinishFrame,
            boxer_renderingBridgeGetRGBPaletteEntry,
            boxer_renderingBridgeSetShader,
            boxer_renderingBridgeHerculesTintMode,
            boxer_renderingBridgeSetHerculesTintMode,
            boxer_renderingBridgeCGACompositeHueOffset,
            boxer_renderingBridgeSetCGACompositeHueOffset,
            boxer_renderingBridgeCGAComponentMode,
            boxer_renderingBridgeSetCGAComponentMode,
            boxer_renderingBridgeGetDisplayRefreshRate,
            boxer_renderingBridgeCurrentVideoWidth,
            boxer_renderingBridgeCurrentVideoHeight,
            boxer_renderingBridgeCurrentVideoModeIsText,
            boxer_renderingBridgeCurrentMachineIsHercules,
            boxer_renderingBridgeCurrentMachineIsCGA,
            boxer_renderingBridgeSetRenderScale
        };
        boxer_registerDOSBoxRenderingBridge(&callbacks);
    }
    return BXDOSBoxRenderingCallbacksRegistered ? &BXDOSBoxRenderingCallbacks : NULL;
}


#pragma mark - Shell-related functions

void boxer_shellWillStart(DOS_Shell *shell)
{
	[[BXEmulator currentEmulator] _shellWillStart: (uintptr_t)shell];
}

void boxer_shellDidFinish(DOS_Shell *shell)
{
	[[BXEmulator currentEmulator] _shellDidFinish: (uintptr_t)shell];
}

bool boxer_shellShouldContinue(DOS_Shell *shell)
{
	return ![BXEmulator currentEmulator].isCancelled;
}

//Catch shell input and send it to our own shell controller - returns YES if we've handled the command,
//NO if we want to let it go through
//This is called by DOS_Shell::DoCommand in DOSBox's shell/shell_cmds.cpp, to allow us to hook into what
//goes on in the shell
bool boxer_shellShouldRunCommand(DOS_Shell *shell, char* cmd, char* args)
{
	NSString *command			= [NSString stringWithCString: cmd	encoding: BXDirectStringEncoding];
	NSString *argumentString	= [NSString stringWithCString: args	encoding: BXDirectStringEncoding];
	
	BXEmulator *emulator = [BXEmulator currentEmulator];
	bool handledInternally = [emulator _handleCommand: command withArgumentString: argumentString];
    return !handledInternally;
}

bool boxer_handleShellCommandInput(DOS_Shell *shell, char *cmd, Bitu *cursorPosition, bool *executeImmediately)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
    NSString *inOutCommand = [NSString stringWithCString: cmd encoding: BXDirectStringEncoding];
	
    if ([emulator _handleCommandInput: &inOutCommand
                       cursorPosition: (NSUInteger *)cursorPosition
                       executeCommand: (BOOL *)executeImmediately])
	{
		const char *newcmd = [inOutCommand cStringUsingEncoding: BXDirectStringEncoding];
		if (newcmd)
		{
            strlcpy(cmd, newcmd, CMD_MAXLINE);
            return true;
		}
		else return false;
	}
	return false;
}

bool boxer_executeNextPendingCommandForShell(DOS_Shell *shell)
{
    BXEmulator *emulator = [BXEmulator currentEmulator];
	return [emulator _executeNextPendingCommand];
}

bool boxer_hasPendingCommandsForShell(DOS_Shell *shell)
{
    BXEmulator *emulator = [BXEmulator currentEmulator];
	return emulator.commandQueue.count > 0;
}

void boxer_shellWillReadCommandInputFromHandle(DOS_Shell *shell, uint16_t handle)
{
    if (handle == STDIN)
    {
        BXEmulator *emulator = [BXEmulator currentEmulator];
        emulator.waitingForCommandInput = YES;
    }
}
void boxer_shellDidReadCommandInputFromHandle(DOS_Shell *shell, uint16_t handle)
{
    if (handle == STDIN)
    {
        BXEmulator *emulator = [BXEmulator currentEmulator];
        emulator.waitingForCommandInput = NO;
    }
}

void boxer_didReturnToShell(DOS_Shell *shell)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	[emulator _didReturnToShell];
}

void boxer_shellWillStartAutoexec(DOS_Shell *shell)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	[emulator _willRunStartupCommands];
}

void boxer_shellWillExecuteFileAtDOSPath(DOS_Shell *shell, const char *path, const char *arguments)
{	
    BXEmulator *emulator = [BXEmulator currentEmulator];
    [emulator _willExecuteFileAtDOSPath: path withArguments: arguments isBatchFile: NO];
}

void boxer_shellDidExecuteFileAtDOSPath(DOS_Shell *shell, const char *path)
{
    BXEmulator *emulator = [BXEmulator currentEmulator];
    [emulator _didExecuteFileAtDOSPath: path];
}

void boxer_shellWillBeginBatchFile(DOS_Shell *shell, const char *path, const char *arguments)
{
    BXEmulator *emulator = [BXEmulator currentEmulator];
    [emulator _willExecuteFileAtDOSPath: path withArguments: arguments isBatchFile: YES];
}

void boxer_shellDidEndBatchFile(DOS_Shell *shell, const char *canonicalPath)
{
    BXEmulator *emulator = [BXEmulator currentEmulator];
    [emulator _didExecuteFileAtDOSPath: canonicalPath];
}

bool boxer_shellShouldDisplayStartupMessages(DOS_Shell *shell)
{
    BXEmulator *emulator = [BXEmulator currentEmulator];
    return [emulator _shouldDisplayStartupMessagesForShell: (uintptr_t)shell];
}


#pragma mark - Filesystem functions

FILE *boxer_openCaptureFile(const char *typeDescription, const char *fileExtension)
{
    BXEmulator *emulator = [BXEmulator currentEmulator];
    return [emulator _openFileForCaptureOfType:typeDescription extension: fileExtension];
}

//Whether to include a file with the specified name in DOSBox directory listings
bool boxer_shouldShowFileWithName(const char *name)
{
	NSString *fileName = [NSString stringWithCString: name encoding: BXDirectStringEncoding];
	BXEmulator *emulator = [BXEmulator currentEmulator];
	return [emulator _shouldShowFileWithName: fileName];
}

//Whether to allow write access to the file at the specified path on the local filesystem
bool boxer_shouldAllowWriteAccessToPath(const char *path, DOS_Drive *dosboxDrive)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	return [emulator _shouldAllowWriteAccessToLocalPath: path onDOSBoxDrive: (uintptr_t)dosboxDrive];
}

//Tells Boxer to resync its cached drives - called by DOSBox functions that add/remove drives
void boxer_driveDidMount(uint8_t driveIndex)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	[emulator _syncDriveCache];
}

void boxer_driveDidUnmount(uint8_t driveIndex)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	[emulator _syncDriveCache];
}

void boxer_didCreateLocalFile(const char *path, DOS_Drive *dosboxDrive)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	[emulator _didCreateFileAtLocalPath: path onDOSBoxDrive: (uintptr_t)dosboxDrive];
}

void boxer_didRemoveLocalFile(const char *path, DOS_Drive *dosboxDrive)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	[emulator _didRemoveFileAtLocalPath: path onDOSBoxDrive: (uintptr_t)dosboxDrive];
}



bool boxer_createLocalDir(const char *path, DOS_Drive *drive)
{
    NSLog(@"BOXER:HD mkdir-callback-enter api=legacy path=%s dosboxDrive=%p",
          path ?: "(null)",
          (void *)drive);

    BXEmulator *emulator = [BXEmulator currentEmulator];
    bool created = [emulator _createDirectoryAtLocalPath: path onDOSBoxDrive: (uintptr_t)drive];

    NSLog(@"BOXER:HD mkdir-callback-result api=legacy created=%d path=%s dosboxDrive=%p",
          created,
          path ?: "(null)",
          (void *)drive);
    return created;
}

static bool boxer_filesystemBridgeShouldShowFileWithName(const char *name) { return boxer_shouldShowFileWithName(name); }
static bool boxer_filesystemBridgeShouldAllowWriteAccessToPath(const char *path, uintptr_t drive) {
    NSLog(@"BOXER:HD write-check-enter path=%s dosboxDrive=%p",
          path ?: "(null)",
          (void *)drive);

    bool allowed = [[BXEmulator currentEmulator] _shouldAllowWriteAccessToLocalPath:path onDOSBoxDrive:drive];

    NSLog(@"BOXER:HD write-check-result allowed=%d path=%s dosboxDrive=%p",
          allowed,
          path ?: "(null)",
          (void *)drive);
    return allowed;
}
static void boxer_filesystemBridgeDidCreateLocalFile(const char *path, uintptr_t drive) {
    [[BXEmulator currentEmulator] _didCreateFileAtLocalPath:path onDOSBoxDrive:drive];
}
static void boxer_filesystemBridgeDidRemoveLocalFile(const char *path, uintptr_t drive) {
    [[BXEmulator currentEmulator] _didRemoveFileAtLocalPath:path onDOSBoxDrive:drive];
}
static bool boxer_filesystemBridgeCreateLocalDir(const char *path, uintptr_t drive) {
    NSLog(@"BOXER:HD mkdir-callback-enter api=filesystem path=%s dosboxDrive=%p",
          path ?: "(null)",
          (void *)drive);

    bool created = [[BXEmulator currentEmulator] _createDirectoryAtLocalPath:path onDOSBoxDrive:drive];

    NSLog(@"BOXER:HD mkdir-callback-result api=filesystem created=%d path=%s dosboxDrive=%p",
          created,
          path ?: "(null)",
          (void *)drive);
    return created;
}
static void boxer_filesystemBridgeDriveDidMount(uint8_t driveIndex) { boxer_driveDidMount(driveIndex); }
static void boxer_filesystemBridgeDriveDidUnmount(uint8_t driveIndex) { boxer_driveDidUnmount(driveIndex); }

static BXDOSBoxFilesystemBridgeCallbacks BXDOSBoxFilesystemCallbacks;
static bool BXDOSBoxFilesystemCallbacksRegistered = false;

void boxer_registerDOSBoxFilesystemBridge(const BXDOSBoxFilesystemBridgeCallbacks *callbacks)
{
    if (callbacks)
    {
        BXDOSBoxFilesystemCallbacks = *callbacks;
        BXDOSBoxFilesystemCallbacksRegistered = true;
    }
}

const BXDOSBoxFilesystemBridgeCallbacks *boxer_registeredDOSBoxFilesystemBridge(void)
{
    if (!BXDOSBoxFilesystemCallbacksRegistered)
    {
        const BXDOSBoxFilesystemBridgeCallbacks callbacks = {
            boxer_filesystemBridgeShouldShowFileWithName,
            boxer_filesystemBridgeShouldAllowWriteAccessToPath,
            boxer_filesystemBridgeDidCreateLocalFile,
            boxer_filesystemBridgeDidRemoveLocalFile,
            boxer_filesystemBridgeCreateLocalDir,
            boxer_filesystemBridgeDriveDidMount,
            boxer_filesystemBridgeDriveDidUnmount
        };
        boxer_registerDOSBoxFilesystemBridge(&callbacks);
    }
    return BXDOSBoxFilesystemCallbacksRegistered ? &BXDOSBoxFilesystemCallbacks : NULL;
}

static uintptr_t boxer_filesystemControlDriveCount(void)
{
    return DOS_DRIVES;
}

static uint8_t boxer_filesystemControlDefaultDriveIndex(void)
{
    return DOS_GetDefaultDrive();
}

static uintptr_t boxer_filesystemControlMaximumPathLength(void)
{
    return DOS_PATHLENGTH;
}

static bool boxer_filesystemControlMakeName(const char *dosPath, char *outPath,
                                            uintptr_t outPathLength, uint8_t *outDriveIndex)
{
    if (!dosPath || !outPath || !outDriveIndex || outPathLength < DOS_PATHLENGTH)
        return false;
    return DOS_MakeName(dosPath, outPath, outDriveIndex);
}

static uintptr_t boxer_filesystemControlDriveAtIndex(uint8_t driveIndex)
{
    if (driveIndex >= DOS_DRIVES || !Drives[driveIndex])
        return 0;
    return (uintptr_t)Drives[driveIndex].get();
}

static uint8_t boxer_filesystemControlDriveType(uintptr_t drive)
{
    DOS_Drive *dosDrive = (DOS_Drive *)drive;
    if (!dosDrive) return 0;
    if (dynamic_cast<Virtual_Drive *>(dosDrive)) return 1;
    if (dynamic_cast<isoDrive *>(dosDrive) || dynamic_cast<cdromDrive *>(dosDrive)) return 2;
    if (dosDrive->GetMediaByte() == 0xF0) return 3;
    return 4;
}

static const char *boxer_filesystemControlDriveSystemPath(uintptr_t drive)
{
    return drive ? ((DOS_Drive *)drive)->getSystemPath() : NULL;
}

static const char *boxer_filesystemControlDriveCurrentDirectory(uintptr_t drive)
{
    return drive ? ((DOS_Drive *)drive)->curdir : NULL;
}

static bool boxer_filesystemControlDriveFileExists(uintptr_t drive, const char *path)
{
    return drive && path && ((DOS_Drive *)drive)->FileExists(path);
}

static bool boxer_filesystemControlDriveTestDirectory(uintptr_t drive, const char *path)
{
    return drive && path && ((DOS_Drive *)drive)->TestDir((char *)path);
}

static uintptr_t boxer_filesystemControlMaximumShortNameLength(void)
{
    return CROSS_LEN;
}

static bool boxer_filesystemControlDriveGetShortName(uintptr_t drive, const char *directory,
                                                     const char *name, char *outName,
                                                     uintptr_t outNameLength)
{
    if (!drive || !directory || !name || !outName || outNameLength < CROSS_LEN)
        return false;
    return ((DOS_Drive *)drive)->getShortName(directory, name, outName);
}

static uintptr_t boxer_filesystemControlMaximumHostPathLength(void)
{
    return PATH_MAX;
}

static bool boxer_filesystemControlDriveMapDOSPath(uintptr_t drive, const char *dosPath,
                                                   char *outPath, uintptr_t outPathLength)
{
    if (!drive || !dosPath || !outPath || !outPathLength)
        return false;
    const std::string path = ((localDrive *)drive)->MapDosToHostFilename(dosPath);
    if (path.size() + 1 > outPathLength)
        return false;
    memcpy(outPath, path.c_str(), path.size() + 1);
    return true;
}

static void boxer_filesystemControlEmptyDriveCache(uintptr_t drive)
{
    if (drive)
        ((DOS_Drive *)drive)->EmptyCache();
}

static bool boxer_filesystemControlAddDrive(uintptr_t drive, uint8_t driveIndex, uint8_t mediaByte)
{
    if (driveIndex >= DOS_DRIVES || !drive || Drives[driveIndex])
        return false;
    DOS_Drive *dosDrive = (DOS_Drive *)drive;
    Drives[driveIndex] = std::shared_ptr<DOS_Drive>(dosDrive);
    mem_writeb(RealToPhysical(dos.tables.mediaid) + ((PhysPt)driveIndex) * 2, mediaByte);
    return true;
}

static int32_t boxer_filesystemControlUnmountDrive(uint8_t driveIndex)
{
    if (driveIndex >= DOS_DRIVES || !Drives[driveIndex])
        return -1;
    return (int32_t)DriveManager::UnmountDrive((int)driveIndex);
}

static void boxer_filesystemControlCloseFiles(uint8_t driveIndex)
{
    for (int i = 0; i < DOS_FILES; i++)
    {
        if (Files[i] && Files[i]->GetDrive() == driveIndex)
        {
            DOS_File *file = Files[i].get();
            if (driveIndex == 0 && file->IsName("CON")) continue;
            file->willBecomeUnavailable();
        }
    }
}

static bool boxer_filesystemControlDriveInUse(uint8_t driveIndex)
{
    if (driveIndex >= DOS_DRIVES)
        return false;
    for (int i = 0; i < DOS_FILES; i++)
    {
        if (Files[i] && Files[i]->GetDrive() == driveIndex)
        {
            DOS_File *file = Files[i].get();
            if (driveIndex == 0 && file->IsName("CON")) continue;
            if (file->IsOpen()) return true;
        }
    }
    return false;
}

static void boxer_filesystemControlDestroyDrive(uintptr_t drive)
{
    delete (DOS_Drive *)drive;
}

static void boxer_filesystemControlSetDriveLabel(uintptr_t drive, const char *label, bool isCDROM)
{
    if (drive && label)
        ((DOS_Drive *)drive)->SetLabel(label, isCDROM, false);
}

static const char *boxer_filesystemControlDriveLabel(uintptr_t drive)
{
    return drive ? ((DOS_Drive *)drive)->GetLabel() : NULL;
}

static uintptr_t boxer_filesystemControlCreateCDROMImage(const char *path, uint8_t driveIndex,
                                                         uint8_t mediaByte, int32_t *outErrorCode)
{
    int errorCode = BXDOSBoxMountUnknownError;
    isoDrive *drive = new isoDrive((char)(driveIndex + 'A'), path, mediaByte, errorCode);
    if (errorCode == BXDOSBoxMountSuccess || errorCode == BXDOSBoxMountSuccessCDROMLimited)
    {
        if (outErrorCode) *outErrorCode = errorCode;
        return (uintptr_t)drive;
    }
    delete drive;
    if (errorCode == BXDOSBoxMountCouldNotReadSource)
        errorCode = BXDOSBoxMountInvalidImageFormat;
    if (outErrorCode) *outErrorCode = errorCode;
    return 0;
}

static uintptr_t boxer_filesystemControlCreateFloppyImage(const char *path, int32_t *outErrorCode)
{
    fatDrive *drive = new fatDrive(path, 0, 0, 0, 0, false);
    if (drive && drive->created_successfully)
    {
        if (outErrorCode) *outErrorCode = BXDOSBoxMountSuccess;
        return (uintptr_t)drive;
    }
    delete drive;
    if (outErrorCode) *outErrorCode = BXDOSBoxMountInvalidImageFormat;
    return 0;
}

static uintptr_t boxer_filesystemControlCreateCDROMDirectory(const char *path, uint8_t driveIndex,
                                                             bool useAudio, const uint16_t *geometry,
                                                             uint8_t mediaByte, int32_t *outErrorCode)
{
    (void)useAudio;
    int errorCode = BXDOSBoxMountUnknownError;
    cdromDrive *drive = new cdromDrive((char)(driveIndex + 'A'), path,
                                       geometry[0], (uint8_t)geometry[1], geometry[2], geometry[3],
                                       mediaByte, errorCode);
    if (errorCode == BXDOSBoxMountSuccess || errorCode == BXDOSBoxMountSuccessCDROMLimited)
    {
        if (outErrorCode) *outErrorCode = errorCode;
        return (uintptr_t)drive;
    }
    delete drive;
    if (outErrorCode) *outErrorCode = errorCode;
    return 0;
}

static uintptr_t boxer_filesystemControlCreateLocalDirectory(const char *path, const char *shadowPath,
                                                             int64_t freeSpace, const uint16_t *geometry,
                                                             uint8_t mediaByte, int32_t *outErrorCode)
{
    uint16_t freeClusters = geometry[3];
    if (freeSpace >= 0)
    {
        const uint32_t bytesPerCluster = (uint32_t)geometry[0] * geometry[1];
        freeClusters = (uint16_t)((uint64_t)freeSpace / bytesPerCluster);
    }

    if (shadowPath && shadowPath[0])
    {
        uint8_t errorCode = 0;
        Overlay_Drive *drive = new Overlay_Drive(path, shadowPath, geometry[0], (uint8_t)geometry[1],
                                                 geometry[2], freeClusters, mediaByte, errorCode);
        if (errorCode == 0)
        {
            if (outErrorCode) *outErrorCode = BXDOSBoxMountSuccess;
            return (uintptr_t)drive;
        }
        delete drive;
        if (outErrorCode) *outErrorCode = errorCode;
        return 0;
    }

    if (outErrorCode) *outErrorCode = BXDOSBoxMountSuccess;
    return (uintptr_t)new localDrive(path, geometry[0], (uint8_t)geometry[1], geometry[2],
                                     freeClusters, mediaByte, false);
}

static uintptr_t boxer_filesystemControlCreateFloppyDirectory(const char *path, int64_t freeSpace,
                                                              const uint16_t *geometry, uint8_t mediaByte,
                                                              int32_t *outErrorCode)
{
    uint16_t freeClusters = geometry[3];
    if (freeSpace >= 0)
    {
        const uint32_t bytesPerCluster = (uint32_t)geometry[0] * geometry[1];
        freeClusters = (uint16_t)((uint64_t)freeSpace / bytesPerCluster);
    }
    if (outErrorCode) *outErrorCode = BXDOSBoxMountSuccess;
    return (uintptr_t)new localDrive(path, geometry[0], (uint8_t)geometry[1], geometry[2],
                                     freeClusters, mediaByte, false);
}

static BXDOSBoxFilesystemControlBridgeCallbacks BXDOSBoxFilesystemControlCallbacks = {
    boxer_filesystemControlDriveCount,
    boxer_filesystemControlDefaultDriveIndex,
    boxer_filesystemControlMaximumPathLength,
    boxer_filesystemControlMakeName,
    boxer_filesystemControlDriveAtIndex,
    boxer_filesystemControlDriveType,
    boxer_filesystemControlDriveSystemPath,
    boxer_filesystemControlDriveCurrentDirectory,
    boxer_filesystemControlDriveFileExists,
    boxer_filesystemControlDriveTestDirectory,
    boxer_filesystemControlMaximumShortNameLength,
    boxer_filesystemControlDriveGetShortName,
    boxer_filesystemControlMaximumHostPathLength,
    boxer_filesystemControlDriveMapDOSPath,
    boxer_filesystemControlEmptyDriveCache,
    boxer_filesystemControlAddDrive,
    boxer_filesystemControlUnmountDrive,
    boxer_filesystemControlCloseFiles,
    boxer_filesystemControlDriveInUse,
    boxer_filesystemControlDestroyDrive,
    boxer_filesystemControlSetDriveLabel,
    boxer_filesystemControlDriveLabel,
    boxer_filesystemControlCreateCDROMImage,
    boxer_filesystemControlCreateFloppyImage,
    boxer_filesystemControlCreateCDROMDirectory,
    boxer_filesystemControlCreateLocalDirectory,
    boxer_filesystemControlCreateFloppyDirectory
};

static bool BXDOSBoxFilesystemControlCallbacksRegistered = false;

void boxer_registerDOSBoxFilesystemControlBridge(const BXDOSBoxFilesystemControlBridgeCallbacks *callbacks)
{
    if (callbacks)
    {
        BXDOSBoxFilesystemControlCallbacks = *callbacks;
        BXDOSBoxFilesystemControlCallbacksRegistered = true;
    }
}

const BXDOSBoxFilesystemControlBridgeCallbacks *boxer_registeredDOSBoxFilesystemControlBridge(void)
{
    if (!BXDOSBoxFilesystemControlCallbacksRegistered)
        boxer_registerDOSBoxFilesystemControlBridge(&BXDOSBoxFilesystemControlCallbacks);
    return &BXDOSBoxFilesystemControlCallbacks;
}

#pragma mark - Input functions

const char * boxer_preferredKeyboardLayout()
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	NSString *layoutCode = emulator.keyboard.preferredLayout;
    
    if (layoutCode)
        return [layoutCode cStringUsingEncoding: BXDirectStringEncoding];
    else return NULL;
}

Bitu boxer_numKeyCodesInPasteBuffer()
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
    return emulator.keyBuffer.count;
}

bool boxer_continueListeningForKeyEvents()
{
    BXEmulator *emulator = [BXEmulator currentEmulator];
    if (emulator.isCancelled || (emulator.isWaitingForCommandInput && emulator.commandQueue.count))
    {
        return false;
    }
    return true;
}

bool boxer_getNextKeyCodeInPasteBuffer(uint16_t *outKeyCode, bool consumeKey)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
    
    [emulator _polledBIOSKeyBuffer];
    
    UInt16 keyCode = (consumeKey) ? emulator.keyBuffer.nextKey : emulator.keyBuffer.currentKey;
    if (keyCode != BXNoKey)
    {
        *outKeyCode = keyCode;
        return true;
    }
    else return false;
}

void boxer_setMouseActive(bool mouseActive)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	emulator.mouse.active = mouseActive;
}

void boxer_setJoystickActive(bool joystickActive)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
	emulator.joystickActive = joystickActive;
}

void boxer_mouseMovedToPoint(float x, float y)
{
	NSPoint point = NSMakePoint((CGFloat)x, (CGFloat)y);
	BXEmulator *emulator = [BXEmulator currentEmulator];
	emulator.mouse.position = point;
}

void boxer_setCapsLockActive(bool active)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
    emulator.keyboard.capsLockEnabled = active;
}

void boxer_setNumLockActive(bool active)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
    emulator.keyboard.numLockEnabled = active;
}

void boxer_setScrollLockActive(bool active)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
    emulator.keyboard.scrollLockEnabled = active;
}

static void boxer_inputBridgeMouseMoved(float deltaX, float deltaY,
                                        int32_t absoluteX, int32_t absoluteY)
{
    MOUSE_EventMoved(deltaX, deltaY, absoluteX, absoluteY);
}

static void boxer_inputBridgeMouseButton(uint8_t button, bool pressed)
{
    MOUSE_EventButton(static_cast<MouseButtonId>(button), pressed);
}

static void boxer_inputBridgeSwitchKeyboardLayout(const char *layout, int32_t codepage)
{
    int32_t triedCodepage = codepage;
    DOS_SwitchKeyboardLayout(layout, triedCodepage);
}

static void boxer_inputBridgeKeyboardKey(uint16_t key, bool pressed)
{
    KEYBOARD_AddKey((KBD_KEYS)key, pressed);
}

static void boxer_inputBridgeKeyboardClearBuffer(void)
{
    KEYBOARD_ClrBuffer();
}


static BXDOSBoxInputBridgeCallbacks BXDOSBoxInputCallbacks;
static bool BXDOSBoxInputCallbacksRegistered = false;

void boxer_registerDOSBoxInputBridge(const BXDOSBoxInputBridgeCallbacks *callbacks)
{
    if (callbacks)
    {
        BXDOSBoxInputCallbacks = *callbacks;
        BXDOSBoxInputCallbacksRegistered = true;
    }
}

const BXDOSBoxInputBridgeCallbacks *boxer_registeredDOSBoxInputBridge(void)
{
    if (!BXDOSBoxInputCallbacksRegistered)
    {
        const BXDOSBoxInputBridgeCallbacks callbacks = {
            boxer_numKeyCodesInPasteBuffer,
            boxer_continueListeningForKeyEvents,
            boxer_getNextKeyCodeInPasteBuffer,
            boxer_preferredKeyboardLayout,
            boxer_setCapsLockActive,
            boxer_setNumLockActive,
            boxer_setScrollLockActive,
            boxer_inputBridgeSwitchKeyboardLayout,
            boxer_inputBridgeMouseMoved,
            boxer_inputBridgeMouseButton,
            boxer_inputBridgeKeyboardKey,
            boxer_inputBridgeKeyboardClearBuffer
        };
        boxer_registerDOSBoxInputBridge(&callbacks);
    }
    return BXDOSBoxInputCallbacksRegistered ? &BXDOSBoxInputCallbacks : NULL;
}

static BXDOSBoxJoystickBridgeCallbacks BXDOSBoxJoystickCallbacks;
static bool BXDOSBoxJoystickCallbacksRegistered = false;

static void boxer_joystickBridgeEnable(uint8_t which, bool enabled)
{
    JOYSTICK_Enable(which, enabled);
}

static void boxer_joystickBridgeSetButton(uint8_t which, uint8_t button, bool pressed)
{
    JOYSTICK_Button(which, button, pressed);
}

static void boxer_joystickBridgeMoveX(uint8_t which, int16_t value)
{
    JOYSTICK_Move_X(which, value);
}

static void boxer_joystickBridgeMoveY(uint8_t which, int16_t value)
{
    JOYSTICK_Move_Y(which, value);
}

static bool boxer_joystickBridgeIsAccessible(uint8_t which)
{
    return JOYSTICK_IsAccessible(which);
}

static bool boxer_joystickBridgeGetButton(uint8_t which, uint8_t button)
{
    return JOYSTICK_GetButton(which, button);
}

static double boxer_joystickBridgeGetMoveX(uint8_t which)
{
    return JOYSTICK_GetMove_X(which);
}

static double boxer_joystickBridgeGetMoveY(uint8_t which)
{
    return JOYSTICK_GetMove_Y(which);
}

static uint8_t boxer_joystickBridgeGameportTimingMode(void)
{
    return gameport_timed ? 1 : 0;
}

static void boxer_joystickBridgeSetGameportTimingMode(uint8_t mode)
{
    gameport_timed = mode != 0;
}

static uint8_t boxer_joystickBridgeSupportLevel(void)
{
    switch (joytype)
    {
        case JOY_DISABLED:
        case JOY_NONE_FOUND:
        case JOY_ONLY_FOR_MAPPING:
            return 0;
        case JOY_2AXIS:
            return 1;
        default:
            return 2;
    }
}

void boxer_registerDOSBoxJoystickBridge(const BXDOSBoxJoystickBridgeCallbacks *callbacks)
{
    if (callbacks)
    {
        BXDOSBoxJoystickCallbacks = *callbacks;
        BXDOSBoxJoystickCallbacksRegistered = true;
    }
}

const BXDOSBoxJoystickBridgeCallbacks *boxer_registeredDOSBoxJoystickBridge(void)
{
    if (!BXDOSBoxJoystickCallbacksRegistered)
    {
        const BXDOSBoxJoystickBridgeCallbacks callbacks = {
            boxer_setJoystickActive,
            boxer_joystickBridgeEnable,
            boxer_joystickBridgeSetButton,
            boxer_joystickBridgeMoveX,
            boxer_joystickBridgeMoveY,
            boxer_joystickBridgeIsAccessible,
            boxer_joystickBridgeGetButton,
            boxer_joystickBridgeGetMoveX,
            boxer_joystickBridgeGetMoveY,
            boxer_joystickBridgeGameportTimingMode,
            boxer_joystickBridgeSetGameportTimingMode,
            boxer_joystickBridgeSupportLevel
        };
        boxer_registerDOSBoxJoystickBridge(&callbacks);
    }
    return BXDOSBoxJoystickCallbacksRegistered ? &BXDOSBoxJoystickCallbacks : NULL;
}

static void boxer_shellBridgeWillStart(uintptr_t shell) { boxer_shellWillStart((DOS_Shell *)shell); }
static void boxer_shellBridgeDidFinish(uintptr_t shell) { boxer_shellDidFinish((DOS_Shell *)shell); }
static bool boxer_shellBridgeShouldContinue(uintptr_t shell) { return boxer_shellShouldContinue((DOS_Shell *)shell); }
static bool boxer_shellBridgeShouldRunCommand(uintptr_t shell, char *command, char *arguments) { return boxer_shellShouldRunCommand((DOS_Shell *)shell, command, arguments); }
static bool boxer_shellBridgeHandleCommandInput(uintptr_t shell, char *line, uintptr_t *cursorPosition, bool *executeImmediately)
{
    return boxer_handleShellCommandInput((DOS_Shell *)shell, line, (Bitu *)cursorPosition, executeImmediately);
}
static bool boxer_shellBridgeHasPendingCommands(uintptr_t shell) { return boxer_hasPendingCommandsForShell((DOS_Shell *)shell); }
static bool boxer_shellBridgeExecuteNextPendingCommand(uintptr_t shell) { return boxer_executeNextPendingCommandForShell((DOS_Shell *)shell); }
static void boxer_shellBridgeDidReturnToShell(uintptr_t shell) { boxer_didReturnToShell((DOS_Shell *)shell); }
static void boxer_shellBridgeWillStartAutoexec(uintptr_t shell) { boxer_shellWillStartAutoexec((DOS_Shell *)shell); }
static bool boxer_shellBridgeShouldDisplayStartupMessages(uintptr_t shell) { return boxer_shellShouldDisplayStartupMessages((DOS_Shell *)shell); }
static void boxer_shellBridgeWillReadCommandInput(uintptr_t shell, uint16_t handle) { boxer_shellWillReadCommandInputFromHandle((DOS_Shell *)shell, handle); }
static void boxer_shellBridgeDidReadCommandInput(uintptr_t shell, uint16_t handle) { boxer_shellDidReadCommandInputFromHandle((DOS_Shell *)shell, handle); }
static void boxer_shellBridgeWillExecuteFile(uintptr_t shell, const char *path, const char *arguments) { boxer_shellWillExecuteFileAtDOSPath((DOS_Shell *)shell, path, arguments); }
static void boxer_shellBridgeDidExecuteFile(uintptr_t shell, const char *path) { boxer_shellDidExecuteFileAtDOSPath((DOS_Shell *)shell, path); }
static void boxer_shellBridgeWillBeginBatch(uintptr_t shell, const char *path, const char *arguments) { boxer_shellWillBeginBatchFile((DOS_Shell *)shell, path, arguments); }
static void boxer_shellBridgeDidEndBatch(uintptr_t shell, const char *path) { boxer_shellDidEndBatchFile((DOS_Shell *)shell, path); }

static BXDOSBoxShellBridgeCallbacks BXDOSBoxShellCallbacks;
static bool BXDOSBoxShellCallbacksRegistered = false;

void boxer_registerDOSBoxShellBridge(const BXDOSBoxShellBridgeCallbacks *callbacks)
{
    if (callbacks)
    {
        BXDOSBoxShellCallbacks = *callbacks;
        BXDOSBoxShellCallbacksRegistered = true;
    }
}

const BXDOSBoxShellBridgeCallbacks *boxer_registeredDOSBoxShellBridge(void)
{
    if (!BXDOSBoxShellCallbacksRegistered)
    {
        const BXDOSBoxShellBridgeCallbacks callbacks = {
            boxer_shellBridgeWillStart,
            boxer_shellBridgeDidFinish,
            boxer_shellBridgeShouldContinue,
            boxer_shellBridgeShouldRunCommand,
            boxer_shellBridgeHandleCommandInput,
            boxer_shellBridgeHasPendingCommands,
            boxer_shellBridgeExecuteNextPendingCommand,
            boxer_shellBridgeDidReturnToShell,
            boxer_shellBridgeWillStartAutoexec,
            boxer_shellBridgeShouldDisplayStartupMessages,
            boxer_shellBridgeWillReadCommandInput,
            boxer_shellBridgeDidReadCommandInput,
            boxer_shellBridgeWillExecuteFile,
            boxer_shellBridgeDidExecuteFile,
            boxer_shellBridgeWillBeginBatch,
            boxer_shellBridgeDidEndBatch
        };
        boxer_registerDOSBoxShellBridge(&callbacks);
    }
    return BXDOSBoxShellCallbacksRegistered ? &BXDOSBoxShellCallbacks : NULL;
}

static uintptr_t boxer_shellControlCurrentShell(void)
{
    return (uintptr_t)currentShell;
}

static const char *boxer_shellControlCurrentRunningProgram(void)
{
    return RunningProgram;
}

static void boxer_shellControlWriteOutput(uintptr_t shell, const char *text)
{
    ((DOS_Shell *)shell)->WriteOut_NoParsing(text);
}

static bool boxer_shellControlEchoEnabled(uintptr_t shell)
{
    return ((DOS_Shell *)shell)->echo;
}

static bool boxer_shellControlHasNoBatchFiles(uintptr_t shell)
{
    return ((DOS_Shell *)shell)->hasNoBatchFiles();
}

static void boxer_shellControlShowPrompt(uintptr_t shell)
{
    ((DOS_Shell *)shell)->ShowPrompt();
}

static void boxer_shellControlParseLine(uintptr_t shell, char *line)
{
    ((DOS_Shell *)shell)->ParseLine(line);
}

static void boxer_shellControlDoCommand(uintptr_t shell, char *command)
{
    ((DOS_Shell *)shell)->DoCommand(command);
}

static bool boxer_shellControlChangeDirectory(const char *path)
{
    return DOS_ChangeDir(path);
}

static bool boxer_shellControlSetDrive(uint8_t driveIndex)
{
    return DOS_SetDrive(driveIndex);
}

static uintptr_t boxer_shellControlMaximumCommandLineLength(void)
{
    return CMD_MAXLINE;
}

static void boxer_shellControlClearScreen(void)
{
    reg_ax = 0x0003;
    CALLBACK_RunRealInt(0x10);
}

static BXDOSBoxShellControlBridgeCallbacks BXDOSBoxShellControlCallbacks = {
    boxer_shellControlCurrentShell,
    boxer_shellControlCurrentRunningProgram,
    boxer_shellControlWriteOutput,
    boxer_shellControlEchoEnabled,
    boxer_shellControlHasNoBatchFiles,
    boxer_shellControlShowPrompt,
    boxer_shellControlParseLine,
    boxer_shellControlDoCommand,
    boxer_shellControlChangeDirectory,
    boxer_shellControlSetDrive,
    boxer_shellControlMaximumCommandLineLength,
    boxer_shellControlClearScreen
};

static bool BXDOSBoxShellControlCallbacksRegistered = false;

void boxer_registerDOSBoxShellControlBridge(const BXDOSBoxShellControlBridgeCallbacks *callbacks)
{
    if (callbacks)
    {
        BXDOSBoxShellControlCallbacks = *callbacks;
        BXDOSBoxShellControlCallbacksRegistered = true;
    }
}

const BXDOSBoxShellControlBridgeCallbacks *boxer_registeredDOSBoxShellControlBridge(void)
{
    if (!BXDOSBoxShellControlCallbacksRegistered)
        boxer_registerDOSBoxShellControlBridge(&BXDOSBoxShellControlCallbacks);
    return &BXDOSBoxShellControlCallbacks;
}


#pragma mark - Printer functions

static BXDOSBoxPrinterBridgeCallbacks BXDOSBoxPrinterCallbacks;
static bool BXDOSBoxPrinterCallbacksRegistered = false;

static const uint16_t *boxer_printerCharmapForCodepage(uint32_t codepage)
{
    for (size_t index = 0; charmap[index].codepage != 0; index++)
    {
        if (charmap[index].codepage == codepage)
            return charmap[index].map;
    }
    return NULL;
}

static const uint16_t *boxer_printerInternationalCharset(uint32_t index)
{
    return index < 15 ? intCharSets[index] : NULL;
}

static uint32_t boxer_printerCodepageAtIndex(uint32_t index)
{
    return index < 15 ? codepages[index] : 0;
}

void boxer_registerDOSBoxPrinterBridge(const BXDOSBoxPrinterBridgeCallbacks *callbacks)
{
    if (callbacks)
    {
        BXDOSBoxPrinterCallbacks = *callbacks;
        BXDOSBoxPrinterCallbacksRegistered = true;
    }
}

const BXDOSBoxPrinterBridgeCallbacks *boxer_registeredDOSBoxPrinterBridge(void)
{
    if (!BXDOSBoxPrinterCallbacksRegistered)
    {
        const BXDOSBoxPrinterBridgeCallbacks callbacks = {
            boxer_PRINTER_isInited,
            boxer_PRINTER_readdata,
            boxer_PRINTER_readcontrol,
            boxer_PRINTER_readstatus,
            boxer_PRINTER_writedata,
            boxer_PRINTER_writecontrol,
            boxer_printerCharmapForCodepage,
            boxer_printerInternationalCharset,
            boxer_printerCodepageAtIndex
        };
        boxer_registerDOSBoxPrinterBridge(&callbacks);
    }
    return BXDOSBoxPrinterCallbacksRegistered ? &BXDOSBoxPrinterCallbacks : NULL;
}

Bitu boxer_PRINTER_readdata(Bitu port,Bitu iolen)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
    return emulator.printer.dataRegister;
}

void boxer_PRINTER_writedata(Bitu port,Bitu val,Bitu iolen)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
    emulator.printer.dataRegister = val;
}

Bitu boxer_PRINTER_readstatus(Bitu port,Bitu iolen)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
    return emulator.printer.statusRegister;
}

void boxer_PRINTER_writecontrol(Bitu port,Bitu val, Bitu iolen)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
    emulator.printer.controlRegister = val;
}

Bitu boxer_PRINTER_readcontrol(Bitu port,Bitu iolen)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
    return emulator.printer.controlRegister;
}

bool boxer_PRINTER_isInited(Bitu port)
{
	BXEmulator *emulator = [BXEmulator currentEmulator];
    //Tell the emulator we actually want a printer
    [emulator _didRequestPrinterOnLPTPort: port];
    return emulator.printer != nil;
}

#pragma mark - Helper functions

//Return a localized string for the given DOSBox translation key
//This is called by MSG_Get in DOSBox's misc/messages.cpp, instead of retrieving strings from its own localisation system
const char * boxer_localizedStringForKey(char const *keyStr)
{
	NSString *theKey			= [NSString stringWithCString: keyStr encoding: BXDirectStringEncoding];
	NSString *localizedString	= [[NSBundle mainBundle]
								   localizedStringForKey: theKey
								   value: @"" //If the key isn't found, display nothing
								   table: @"DOSBox"];
	
	return [localizedString cStringUsingEncoding: BXDisplayStringEncoding];
}

void boxer_log(char const* format,...)
{
#ifdef BOXER_DEBUG
	//Copypasta from sdlmain.cpp
	char buf[512];
	va_list msg;
	va_start(msg,format);
	vsnprintf(buf,sizeof(buf)-1,format,msg);
	strcat(buf,"\n");
	va_end(msg);
	printf("%s",buf);
#endif
}

void boxer_die(const char *functionName, const char *fileName, int lineNumber, const char * format,...)
{
    char errorReason[1024];
	va_list params;
	va_start(params, format);
	vsnprintf(errorReason, sizeof(errorReason), format, params);
	va_end(params);
    
    throw boxer_emulatorException(errorReason, fileName, functionName, lineNumber);
}

static const char *boxer_diagnosticsBridgeLocalizedStringForKey(const char *key)
{
    return boxer_localizedStringForKey(key);
}

static void boxer_diagnosticsBridgeLogMessage(const char *message)
{
    boxer_log("%s", message);
}

static void boxer_diagnosticsBridgeFatalError(const char *functionName,
                                               const char *fileName,
                                               int lineNumber,
                                               const char *message)
{
    boxer_die(functionName, fileName, lineNumber, "%s", message);
}

static BXDOSBoxDiagnosticsBridgeCallbacks BXDOSBoxDiagnosticsCallbacks;
static bool BXDOSBoxDiagnosticsCallbacksRegistered = false;

void boxer_registerDOSBoxDiagnosticsBridge(const BXDOSBoxDiagnosticsBridgeCallbacks *callbacks)
{
    if (callbacks)
    {
        BXDOSBoxDiagnosticsCallbacks = *callbacks;
        BXDOSBoxDiagnosticsCallbacksRegistered = true;
    }
}

const BXDOSBoxDiagnosticsBridgeCallbacks *boxer_registeredDOSBoxDiagnosticsBridge(void)
{
    if (!BXDOSBoxDiagnosticsCallbacksRegistered)
    {
        const BXDOSBoxDiagnosticsBridgeCallbacks callbacks = {
            boxer_diagnosticsBridgeLocalizedStringForKey,
            boxer_diagnosticsBridgeLogMessage,
            boxer_diagnosticsBridgeFatalError
        };
        boxer_registerDOSBoxDiagnosticsBridge(&callbacks);
    }
    return BXDOSBoxDiagnosticsCallbacksRegistered ? &BXDOSBoxDiagnosticsCallbacks : NULL;
}

void restart_program(std::vector<std::string> & parameters) {
    // TODO: re-write?
    boxer_die(__PRETTY_FUNCTION__, __FILE__, __LINE__, "Restarting not implemented!");
}

#pragma mark - No-ops

// Boxer owns mouse capture and focus state instead of DOSBox's SDL frontend.
bool mouse_is_captured = false;

void GFX_UpdateMouseState()
{
	// AppKit's input controller applies capture changes directly.
}

void MAPPER_AutoTypeStopImmediately()
{
	// Boxer does not use the SDL mapper's auto-typing queue.
}
