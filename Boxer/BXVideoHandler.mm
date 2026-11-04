/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXVideoHandler.h"
#import "BXEmulatorCore.h"
#import "BXEmulatorPrivate.h"
#import "BXVideoFrame.h"
#import "ADBGeometry.h"
#import "BXFilterDefinitions.h"
#import "BXVerificationInstrumentation.h"
#import "BXCoalface.h"
#include <cstring>

#if defined(BOXER_VERIFICATION_INSTRUMENTATION)
#import <mach/mach_time.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>
#endif

typedef void (*BXVideoCallback)(NSInteger function);
static NSInteger const BXVideoCallbackReset = 0;
static NSInteger const BXVideoCallbackStop = 1;
#if defined(BOXER_VERIFICATION_INSTRUMENTATION)

static constexpr uint32_t BXVerificationRingCapacity = 8192;
static constexpr uint32_t BXVerificationRingMask = BXVerificationRingCapacity - 1;
static constexpr uint32_t BXVerificationSummaryCapacity = 1048576;

struct BXVerificationSampleRing {
	std::atomic<uint32_t> write = 0;
	std::atomic<uint32_t> read = 0;
	std::atomic<uint64_t> dropped = 0;
	uint64_t samples[BXVerificationRingCapacity] = {};
};

struct BXVerificationSummaryStorage {
	uint64_t *values = nullptr;
	std::atomic<uint32_t> count = 0;
};

struct BXVerificationRuntime {
	std::atomic<bool> running = false;
	std::atomic<uint64_t> counters[BXVerificationCounterCount] = {};
	std::atomic<uint64_t> finalSlots[4] = {};
	BXVerificationSampleRing rings[BXVerificationMetricCount];
	BXVerificationSummaryStorage summaries[BXVerificationMetricCount];
	std::thread reporter;
	FILE *csv = nullptr;
	NSString *csvPath = nil;
	NSDate *runStart = nil;
	NSDateFormatter *dateFormatter = nil;
	uint64_t previousReportTime = 0;
	uint64_t totalSeconds = 0;
	uint64_t totalHALC = 0;
	uint64_t previousCounters[BXVerificationCounterCount] = {};
};

static BXVerificationRuntime gBXVerification;
static mach_timebase_info_data_t gBXVerificationTimebase = {};

uint64_t BXVerificationNow(void)
{
	return mach_absolute_time();
}

uint64_t BXVerificationMicroseconds(uint64_t start, uint64_t end)
{
	if (end < start)
		return 0;
	uint64_t nanos = (end - start) * gBXVerificationTimebase.numer /
			gBXVerificationTimebase.denom;
	return nanos / 1000;
}

static void BXVerificationWriteSample(BXVerificationMetric metric, uint64_t sample)
{
	BXVerificationSampleRing &ring = gBXVerification.rings[metric];
	uint32_t write = ring.write.load(std::memory_order_relaxed);
	uint32_t read = ring.read.load(std::memory_order_acquire);
	if (write - read >= BXVerificationRingCapacity)
	{
		ring.dropped.fetch_add(1, std::memory_order_relaxed);
		gBXVerification.counters[BXVerificationCounterDroppedSample].fetch_add(1, std::memory_order_relaxed);
		return;
	}
	ring.samples[write & BXVerificationRingMask] = sample;
	ring.write.store(write + 1, std::memory_order_release);
}

static uint64_t BXVerificationEnvUInt64(const char *name, const char *fallback)
{
	const char *value = getenv(name);
	return value ? strtoull(value, nullptr, 10) : strtoull(fallback, nullptr, 10);
}

static NSString *BXVerificationEnvString(const char *name, NSString *fallback)
{
	const char *value = getenv(name);
	return value ? [NSString stringWithUTF8String:value] : fallback;
}

static NSUInteger BXVerificationPollHALC(NSDate *start, NSDate *end)
{
	NSTask *task = [[NSTask alloc] init];
	task.launchPath = @"/usr/bin/log";
	task.arguments = @[@"show", @"--style", @"syslog",
		@"--predicate", @"process == \"Boxer\"",
		@"--start", [gBXVerification.dateFormatter stringFromDate:start],
		@"--end", [gBXVerification.dateFormatter stringFromDate:end]];
	 NSPipe *pipe = [NSPipe pipe];
	task.standardOutput = pipe;
	task.standardError = [NSPipe pipe];
	[task launch];
	[task waitUntilExit];
	NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
	NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	NSUInteger count = 0;
	NSRange searchRange = NSMakeRange(0, output.length);
	NSString *needle = @"HALC_ProxyIOContext::IOWorkLoop: skipping cycle";
	while (searchRange.length)
	{
		NSRange found = [output rangeOfString:needle options:0 range:searchRange];
		if (found.location == NSNotFound)
			break;
		count++;
		NSUInteger next = NSMaxRange(found);
		searchRange = NSMakeRange(next, output.length - next);
	}
	return count;
}

static void BXVerificationWriteSummary(void)
{
	NSString *summaryPath = [gBXVerification.csvPath stringByReplacingOccurrencesOfString:@".csv"
														withString:@"-summary.json"];
	FILE *file = fopen(summaryPath.fileSystemRepresentation, "w");
	if (!file)
		return;

	fprintf(file, "{\n  \"timestamp\": \"");
	fprintf(file, "%s", gBXVerification.dateFormatter ? [gBXVerification.dateFormatter stringFromDate:gBXVerification.runStart].UTF8String : "unknown");
	fprintf(file, "\",\n  \"seconds\": ");
	fprintf(file, "%llu", (unsigned long long)gBXVerification.totalSeconds);
	fprintf(file, ",\n  \"csv\": \"");
	fprintf(file, "%s", gBXVerification.csvPath.fileSystemRepresentation);
	fprintf(file, "\",\n  \"staging_commit\": \"");
	fprintf(file, "%s", BXVerificationEnvString("BOXER_VERIFICATION_STAGING_COMMIT", @"unknown").UTF8String);
	fprintf(file, "\",\n  \"configuration\": {\n");
	fprintf(file, "    \"blocksize\": %llu,\n", BXVerificationEnvUInt64("BOXER_VERIFICATION_BLOCKSIZE", "1000"));
	fprintf(file, "    \"max_inflight\": %llu,\n", BXVerificationEnvUInt64("BOXER_VERIFICATION_MAX_INFLIGHT", "1"));
	fprintf(file, "    \"cpu_cycles\": %llu,\n", BXVerificationEnvUInt64("BOXER_VERIFICATION_CPU_CYCLES", "0"));
	fprintf(file, "    \"cpu_cycles_protected\": %llu,\n", BXVerificationEnvUInt64("BOXER_VERIFICATION_CPU_CYCLES_PROTECTED", "0"));
	fprintf(file, "    \"core\": \"");
	fprintf(file, "%s", BXVerificationEnvString("BOXER_VERIFICATION_CORE", @"unknown").UTF8String);
	fprintf(file, "\",\n    \"cputype\": \"");
	fprintf(file, "%s", BXVerificationEnvString("BOXER_VERIFICATION_CPUTYPE", @"unknown").UTF8String);
	fprintf(file, "\",\n    \"output\": \"");
	fprintf(file, "%s", BXVerificationEnvString("BOXER_VERIFICATION_OUTPUT", @"unknown").UTF8String);
	fprintf(file, "\"\n  },\n  \"counters\": {\n");
	const char *counterNames[BXVerificationCounterCount] = {
		"finish_frame_count", "finish_frame_fail_count", "start_frame_success_count", "start_frame_fail_count", "presentation_task_count",
		"gpu_completion_count", "texture_creation_count", "frame_presented_count",
		"frame_dropped_semaphore_count", "frame_dropped_nodrawable_count",
		"frame_dropped_stale_generation_count", "frame_dropped_coalesced_count", "slot_free_count", "slot_rendering_count",
		"slot_ready_count", "slot_presenting_count", "committed_transition_failure_count",
		"committed_completion_transition_failure_count", "premature_committed_free_count",
		"semaphore_drop_on_committed_frame_count", "dropped_sample_count"
	};
	for (NSUInteger i = 0; i < BXVerificationCounterCount; i++)
	{
		fprintf(file, "    \"%s\": %llu%s\n", counterNames[i],
				(unsigned long long)gBXVerification.counters[i].load(std::memory_order_relaxed),
				i + 1 == BXVerificationCounterCount ? "" : ",");
	}
	fprintf(file, "  },\n  \"durations_us\": {\n");
	const char *metricNames[BXVerificationMetricCount] = {
		"start_frame_scan", "finish_frame", "finish_dirty_copy", "finish_publish",
		"finish_schedule", "presentation_task", "apply_dirty_regions", "did_finish_frame",
		"update_with_frame", "replace_region",
		"next_drawable", "command_encode", "command_buffer_commit", "gpu_completion"
	};
	for (NSUInteger metric = 0; metric < BXVerificationMetricCount; metric++)
	{
		BXVerificationSummaryStorage &storage = gBXVerification.summaries[metric];
		uint32_t count = std::min(storage.count.load(std::memory_order_relaxed), BXVerificationSummaryCapacity);
		if (count == 0)
		{
			fprintf(file, "    \"%s\": {\"count\": 0}%s\n", metricNames[metric],
					metric + 1 == BXVerificationMetricCount ? "" : ",");
			continue;
		}
		std::sort(storage.values, storage.values + count);
		auto percentile = [values = storage.values, count](double p) {
			return values[(size_t)((count - 1) * p)];
		};
		fprintf(file, "    \"%s\": {\"count\": %u, \"min\": %llu, \"median\": %llu, \"p95\": %llu, \"p99\": %llu, \"max\": %llu}%s\n",
				metricNames[metric], count,
				(unsigned long long)storage.values[0],
				(unsigned long long)percentile(0.50),
				(unsigned long long)percentile(0.95),
				(unsigned long long)percentile(0.99),
				(unsigned long long)storage.values[count - 1],
				metric + 1 == BXVerificationMetricCount ? "" : ",");
	}
	fprintf(file, "  },\n  \"halc_message_count\": %llu,\n  \"slot_occupancy_final\": {\"free\": %llu, \"rendering\": %llu, \"ready\": %llu, \"presenting\": %llu}\n}\n",
			(unsigned long long)gBXVerification.totalHALC,
			(unsigned long long)gBXVerification.finalSlots[0].load(std::memory_order_relaxed),
			(unsigned long long)gBXVerification.finalSlots[1].load(std::memory_order_relaxed),
			(unsigned long long)gBXVerification.finalSlots[2].load(std::memory_order_relaxed),
			(unsigned long long)gBXVerification.finalSlots[3].load(std::memory_order_relaxed));
	fclose(file);
}

static void BXVerificationReporterLoop(void)
{
	std::array<uint64_t, BXVerificationRingCapacity> samples = {};
	NSDate *lastDate = gBXVerification.runStart;
	while (true)
	{
		std::this_thread::sleep_for(std::chrono::milliseconds(1000));
		NSDate *reportDate = [NSDate date];
		gBXVerification.totalSeconds++;
		uint64_t counters[BXVerificationCounterCount] = {};
		for (NSUInteger i = 0; i < BXVerificationCounterCount; i++)
			counters[i] = gBXVerification.counters[i].load(std::memory_order_relaxed);

		uint64_t durationStats[BXVerificationMetricCount][5] = {};
		for (NSUInteger metric = 0; metric < BXVerificationMetricCount; metric++)
		{
			BXVerificationSampleRing &ring = gBXVerification.rings[metric];
			uint32_t read = ring.read.load(std::memory_order_relaxed);
			uint32_t write = ring.write.load(std::memory_order_acquire);
			uint32_t count = std::min(write - read, BXVerificationRingCapacity);
			for (uint32_t i = 0; i < count; i++)
			{
				uint64_t value = ring.samples[(read + i) & BXVerificationRingMask];
				samples[i] = value;
				BXVerificationSummaryStorage &summary = gBXVerification.summaries[metric];
				uint32_t summaryIndex = summary.count.fetch_add(1, std::memory_order_relaxed);
				if (summaryIndex < BXVerificationSummaryCapacity)
					summary.values[summaryIndex] = value;
			}
			ring.read.store(read + count, std::memory_order_release);
			if (count)
			{
				std::sort(samples.begin(), samples.begin() + count);
				durationStats[metric][0] = count;
				durationStats[metric][1] = samples[(size_t)((count - 1) * 0.50)];
				durationStats[metric][2] = samples[(size_t)((count - 1) * 0.95)];
				durationStats[metric][3] = samples[(size_t)((count - 1) * 0.99)];
				durationStats[metric][4] = samples[count - 1];
			}
		}

		for (NSUInteger i = 0; i < BXVerificationCounterCount; i++)
		{
			uint64_t delta = counters[i] - gBXVerification.previousCounters[i];
			gBXVerification.previousCounters[i] = counters[i];
				counters[i] = delta;
			}
			NSLog(@"[Boxer verification] committed_transition_failure_count=%llu committed_completion_transition_failure_count=%llu premature_committed_free_count=%llu semaphore_drop_on_committed_frame_count=%llu",
				(unsigned long long)counters[BXVerificationCounterCommittedTransitionFailure],
				(unsigned long long)counters[BXVerificationCounterCommittedCompletionTransitionFailure],
				(unsigned long long)counters[BXVerificationCounterPrematureCommittedFree],
				(unsigned long long)counters[BXVerificationCounterSemaphoreDropOnCommittedFrame]);
			NSUInteger halc = BXVerificationPollHALC(lastDate, reportDate);
		gBXVerification.totalHALC += halc;
		auto csvValue = [](uint64_t value) {
			fprintf(gBXVerification.csv, "%llu,", (unsigned long long)value);
		};
		csvValue(gBXVerification.totalSeconds);
		csvValue(counters[BXVerificationCounterFinishFrame]);
		csvValue(counters[BXVerificationCounterFinishFrameFailure]);
		for (NSUInteger i = 0; i < 5; i++) csvValue(durationStats[BXVerificationMetricFinishFrame][i]);
		csvValue(counters[BXVerificationCounterPresentationTask]);
		for (NSUInteger i = 0; i < 5; i++) csvValue(durationStats[BXVerificationMetricPresentationTask][i]);
		for (NSUInteger metric : {BXVerificationMetricUpdateWithFrame, BXVerificationMetricReplaceRegion,
				BXVerificationMetricNextDrawable, BXVerificationMetricCommandBufferCommit})
			for (NSUInteger i = 1; i < 5; i++) csvValue(durationStats[metric][i]);
		csvValue(counters[BXVerificationCounterGPUCompletion]);
		for (NSUInteger i = 0; i < 5; i++) csvValue(durationStats[BXVerificationMetricGPUCompletion][i]);
		csvValue(counters[BXVerificationCounterTextureCreation]);
		csvValue(counters[BXVerificationCounterFramePresented]);
		csvValue(counters[BXVerificationCounterFrameDroppedSemaphore]);
		csvValue(counters[BXVerificationCounterFrameDroppedNoDrawable]);
		csvValue(counters[BXVerificationCounterFrameDroppedStaleGeneration]);
		csvValue(counters[BXVerificationCounterFrameDroppedCoalesced]);
		csvValue(counters[BXVerificationCounterSlotFree]);
		csvValue(counters[BXVerificationCounterSlotRendering]);
			csvValue(counters[BXVerificationCounterSlotReady]);
			csvValue(counters[BXVerificationCounterSlotPresenting]);
			csvValue(counters[BXVerificationCounterCommittedTransitionFailure]);
			csvValue(counters[BXVerificationCounterCommittedCompletionTransitionFailure]);
			csvValue(counters[BXVerificationCounterPrematureCommittedFree]);
			csvValue(counters[BXVerificationCounterSemaphoreDropOnCommittedFrame]);
			csvValue(halc);
		fprintf(gBXVerification.csv, "%llu\n", (unsigned long long)counters[BXVerificationCounterDroppedSample]);
		fflush(gBXVerification.csv);
		lastDate = reportDate;
		if (!gBXVerification.running.load(std::memory_order_acquire))
			break;
	}
}

void BXVerificationStart(void)
{
	if (gBXVerification.running.exchange(true, std::memory_order_acq_rel))
		return;
	mach_timebase_info(&gBXVerificationTimebase);
	for (NSUInteger i = 0; i < BXVerificationCounterCount; i++)
		gBXVerification.counters[i].store(0, std::memory_order_relaxed);
	for (NSUInteger i = 0; i < 4; i++)
		gBXVerification.finalSlots[i].store(0, std::memory_order_relaxed);
	for (NSUInteger i = 0; i < BXVerificationMetricCount; i++)
	{
		gBXVerification.rings[i].write.store(0, std::memory_order_relaxed);
		gBXVerification.rings[i].read.store(0, std::memory_order_relaxed);
		gBXVerification.rings[i].dropped.store(0, std::memory_order_relaxed);
		gBXVerification.summaries[i].count.store(0, std::memory_order_relaxed);
	}
	gBXVerification.totalSeconds = 0;
	gBXVerification.totalHALC = 0;
	memset(gBXVerification.previousCounters, 0, sizeof(gBXVerification.previousCounters));
	gBXVerification.runStart = [NSDate date];
	gBXVerification.dateFormatter = [[NSDateFormatter alloc] init];
	gBXVerification.dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
	gBXVerification.dateFormatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
	NSString *defaultPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Boxer/verification"];
	NSString *directory = BXVerificationEnvString("BOXER_VERIFICATION_DIRECTORY", defaultPath);
	NSString *configuredPath = BXVerificationEnvString("BOXER_VERIFICATION_CSV", nil);
	if (!configuredPath.length)
	{
		NSString *stamp = [gBXVerification.dateFormatter stringFromDate:gBXVerification.runStart];
		configuredPath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"run-%@.csv", stamp]];
	}
	gBXVerification.csvPath = configuredPath;
	[[NSFileManager defaultManager] createDirectoryAtPath:gBXVerification.csvPath.stringByDeletingLastPathComponent
										withIntermediateDirectories:YES attributes:nil error:NULL];
	for (NSUInteger metric = 0; metric < BXVerificationMetricCount; metric++)
		gBXVerification.summaries[metric].values = (uint64_t *)calloc(BXVerificationSummaryCapacity, sizeof(uint64_t));
	gBXVerification.csv = fopen(gBXVerification.csvPath.fileSystemRepresentation, "w");
	if (!gBXVerification.csv)
	{
		gBXVerification.running.store(false, std::memory_order_release);
		return;
	}
		fprintf(gBXVerification.csv, "second,finish_frame_count,finish_frame_fail_count,finish_frame_us_count,finish_frame_us_p50,finish_frame_us_p95,finish_frame_us_p99,finish_frame_us_max,presentation_task_count,presentation_task_us_count,presentation_task_us_p50,presentation_task_us_p95,presentation_task_us_p99,presentation_task_us_max,update_with_frame_us_p50,update_with_frame_us_p95,update_with_frame_us_p99,update_with_frame_us_max,replace_region_us_p50,replace_region_us_p95,replace_region_us_p99,replace_region_us_max,next_drawable_us_p50,next_drawable_us_p95,next_drawable_us_p99,next_drawable_us_max,command_buffer_commit_us_p50,command_buffer_commit_us_p95,command_buffer_commit_us_p99,command_buffer_commit_us_max,gpu_completion_count,gpu_completion_us_count,gpu_completion_us_p50,gpu_completion_us_p95,gpu_completion_us_p99,gpu_completion_us_max,texture_creation_count,frame_presented_count,frame_dropped_semaphore_count,frame_dropped_nodrawable_count,frame_dropped_stale_generation_count,frame_dropped_coalesced_count,slot_free_count,slot_rendering_count,slot_ready_count,slot_presenting_count,committed_transition_failure_count,committed_completion_transition_failure_count,premature_committed_free_count,semaphore_drop_on_committed_frame_count,halc_message_count,dropped_sample_count\n");
	gBXVerification.reporter = std::thread(BXVerificationReporterLoop);
}

void BXVerificationStop(void)
{
	if (!gBXVerification.running.exchange(false, std::memory_order_acq_rel))
		return;
	if (gBXVerification.reporter.joinable())
		gBXVerification.reporter.join();
	if (gBXVerification.csv)
		fclose(gBXVerification.csv);
	BXVerificationWriteSummary();
	for (NSUInteger metric = 0; metric < BXVerificationMetricCount; metric++)
	{
		free(gBXVerification.summaries[metric].values);
		gBXVerification.summaries[metric].values = nullptr;
	}
}

void BXVerificationCount(BXVerificationCounter counter)
{
	gBXVerification.counters[counter].fetch_add(1, std::memory_order_relaxed);
}

void BXVerificationSample(BXVerificationMetric metric, uint64_t start, uint64_t end)
{
	BXVerificationWriteSample(metric, BXVerificationMicroseconds(start, end));
}

void BXVerificationRecordSlotOccupancy(NSUInteger freeCount,
										  NSUInteger renderingCount,
										  NSUInteger readyCount,
										  NSUInteger presentingCount)
{
	for (NSUInteger i = 0; i < freeCount; i++) BXVerificationCount(BXVerificationCounterSlotFree);
	for (NSUInteger i = 0; i < renderingCount; i++) BXVerificationCount(BXVerificationCounterSlotRendering);
	for (NSUInteger i = 0; i < readyCount; i++) BXVerificationCount(BXVerificationCounterSlotReady);
	for (NSUInteger i = 0; i < presentingCount; i++) BXVerificationCount(BXVerificationCounterSlotPresenting);
	gBXVerification.finalSlots[0].store(freeCount, std::memory_order_relaxed);
	gBXVerification.finalSlots[1].store(renderingCount, std::memory_order_relaxed);
	gBXVerification.finalSlots[2].store(readyCount, std::memory_order_relaxed);
	gBXVerification.finalSlots[3].store(presentingCount, std::memory_order_relaxed);
}

#endif


#pragma mark -
#pragma mark Really genuinely private functions

// Diagnostic escape hatch for isolating emulation-thread stalls caused by the
// host video handoff. Normal presentation remains enabled unless this
// environment variable is explicitly set to a non-zero value.
static BOOL BXVideoPresentationDisabledForDiagnostic(void)
{
    static int disabled = -1;
    if (disabled < 0)
    {
        const char *value = getenv("BOXER_DISABLE_VIDEO_FRAME_HANDOFF");
        disabled = (value && value[0] != '\0' && strcmp(value, "0") != 0) ? 1 : 0;
    }
    return disabled != 0;
}

@interface BXVideoHandler ()

- (const BXFilterDefinition *) _paramsForFilterType: (BXFilterType)filterType;

- (BOOL) _shouldApplyFilterType: (BXFilterType)type
				 fromResolution: (NSSize)resolution
					 toViewport: (NSSize)viewportSize 
					 isTextMode: (BOOL)isTextMode;

- (NSUInteger) _filterScaleForType: (BXFilterType)type
                    fromResolution: (NSSize)resolution
                        toViewport: (NSSize)viewportSize
                        isTextMode: (BOOL)isTextMode;

- (NSUInteger) _maxFilterScaleForResolution: (NSSize)resolution;

- (void) _syncHerculesTint;
- (void) _syncCGAHueAdjustment;
- (void) _syncCGAComposite;
- (BOOL) _applyOutputConfiguration: (NSSize)outputSize
							atScale: (NSSize)scale
						withCallback: (void *)newCallback
							 textMode: (BOOL)textMode;

@end


@implementation BXVideoHandler
@synthesize currentFrame = _currentFrame;
@synthesize emulator = _emulator;
@synthesize filterType = _filterType;
@synthesize herculesTint = _herculesTint;
@synthesize CGAHueAdjustment = _CGAHueAdjustment;

- (id) init
{
    self = [super init];
	if (self)
	{
		_currentVideoMode = NO;
        _herculesTint = BXHerculesWhiteTint;
        _CGAComposite = BXCGACompositeAuto;
        _CGAHueAdjustment = 0.0;
		atomic_init(&_latestFrame, nil);
		atomic_init(&_presentationScheduled, false);
		_frameCapacity = NSZeroSize;
		BXVerificationStart();
	}
	return self;
}

- (NSSize) resolution
{
	NSSize size = NSZeroSize;
	if (self.emulator.isExecuting)
	{
		size = [BXEmulatorCore currentVideoResolution];
	}
	return size;
}

//Returns whether the emulator is currently rendering in a text-only graphics mode.
- (BOOL) isInTextMode
{
	BOOL textMode = NO;
	if (self.emulator.isExecuting)
	{
		textMode = _currentVideoMode;
	}
	return textMode;
}

+ (NSSet *) keyPathsForValuesAffectingInHerculesMode
{
    return [NSSet setWithObject: @"emulator.initialized"];
}

- (BOOL) isInHerculesMode
{
    if (self.emulator.isInitialized)
    {
        return [BXEmulatorCore currentMachineIsHercules];
    }
    else
    {
        return NO;
    }
}

+ (NSSet *) keyPathsForValuesAffectingInCGAMode
{
    return [NSSet setWithObject: @"emulator.initialized"];
}

- (BOOL) isInCGAMode
{
    if (self.emulator.isInitialized)
        return [BXEmulatorCore currentMachineIsCGA];
    else return NO;
}

- (NSUInteger) frameskip
{
	return 0;
}

- (void) setFrameskip: (NSUInteger)frameskip
{
	(void)frameskip;
}

//Chooses the specified filter, and resets the renderer to apply the change immediately.
- (void) setFilterType: (BXFilterType)type
{
	if (type != _filterType)
	{
		NSAssert1(type <= BXMaxFilters, @"Invalid filter type provided to setFilterType: %li", (unsigned long)type);
				
		_filterType = type;
		[self reset];
	}
}

//Returns whether the chosen filter is actually being rendered.
- (BOOL) filterIsActive
{
	BOOL isActive = NO;
	if (self.emulator.isInitialized)
	{
        isActive = (self.filterType == BXFilterNormal);
	}
	return isActive;
}

- (void) setHerculesTint: (BXHerculesTintMode)tint
{
    if (tint != _herculesTint)
    {
        _herculesTint = tint;
        [self _syncHerculesTint];
    }
}

- (void) _syncHerculesTint
{
    if (self.emulator.isInitialized)
    {
        [BXEmulatorCore setHerculesTintMode:(uint8_t)self.herculesTint];
    }
}

@synthesize CGAComposite=_CGAComposite;

- (void)setCGAComposite:(BXCGACompositeMode)composite
{
    _CGAComposite = composite;
    [self _syncCGAComposite];
}

- (void) _syncCGAComposite
{
    if (self.emulator.isInitialized)
    {
        [BXEmulatorCore setCGAComponentMode:(uint8_t)self.CGAComposite];
    }
}

- (void) setCGAHueAdjustment: (double)hue
{
    _CGAHueAdjustment = hue;
    [self _syncCGAHueAdjustment];
}

- (void) _syncCGAHueAdjustment
{
    if (self.emulator.isInitialized)
    {
        [BXEmulatorCore setCGACompositeHueOffset:self.CGAHueAdjustment];
    }
}


//Reinitialises DOSBox's graphical subsystem and redraws the render region.
//This is called after resizing the session window or toggling rendering options.
- (void) reset
{
	if (self.emulator.isInitialized)
	{
        if (self.emulator.emulationThread != [NSThread currentThread])
        {
            [self performSelector: _cmd
                         onThread: self.emulator.emulationThread
                       withObject: nil
                    waitUntilDone: NO];
        }
        else
        {
            if (_frameInProgress) [self finishFrameWithChanges: NULL];
            
            if (_callback) ((BXVideoCallback)_callback)(BXVideoCallbackReset);
            //CPU_Reset_AutoAdjust();
        }
	}
}

- (void) shutdown
{
	[self finishFrameWithChanges: 0];
	if (_callback) ((BXVideoCallback)_callback)(BXVideoCallbackStop);
	BXVerificationStop();
}


#pragma mark -
#pragma mark DOSBox callbacks

- (void) prepareForOutputSize: (NSSize)outputSize
                      atScale: (NSSize)scale
                 withCallback: (void *)newCallback
{
	//Synchronise our record of the current video mode with the new video mode
	BOOL wasTextMode = self.isInTextMode;
	BOOL currentVideoModeIsText = [BXEmulatorCore currentVideoModeIsText];
	if (_currentVideoMode != currentVideoModeIsText)
	{
		[self willChangeValueForKey: @"inTextMode"];
		_currentVideoMode = currentVideoModeIsText;
		[self didChangeValueForKey: @"inTextMode"];
	}
	BOOL nowTextMode = self.isInTextMode;
	
	//A mode change is normally delivered between frames. If it arrives while
	//Staging is writing, defer the configuration until that frame is published;
	//the producer never changes the storage or metadata of a RENDERING slot.
	if (_frameInProgress || (_currentFrame && ![_currentFrame isFree]))
	{
		_pendingOutputSize = outputSize;
		_pendingScale = scale;
		_pendingCallbackValue = newCallback;
		_hasPendingOutputConfiguration = YES;
	}
	else
	{
		if (![self _applyOutputConfiguration: outputSize
								atScale: scale
							withCallback: newCallback
								 textMode: nowTextMode])
		{
			_pendingOutputSize = outputSize;
			_pendingScale = scale;
			_pendingCallbackValue = newCallback;
			_hasPendingOutputConfiguration = YES;
		}
	}
	
	//Send notifications if the display mode has changed
	
	if (wasTextMode && !nowTextMode)
		[self.emulator _postNotificationName: BXEmulatorDidBeginGraphicalContextNotification
                            delegateSelector: @selector(emulatorDidBeginGraphicalContext:)
                                    userInfo: nil];
	
	else if (!wasTextMode && nowTextMode)
		[self.emulator _postNotificationName: BXEmulatorDidFinishGraphicalContextNotification
                            delegateSelector: @selector(emulatorDidFinishGraphicalContext:)
                                    userInfo: nil];
}

- (BOOL) startFrameWithBuffer: (void **)buffer pitch: (int *)pitch
{
	uint64_t scanStart = BXVerificationNow();
	if (!buffer || !pitch)
	{
		BXVerificationCount(BXVerificationCounterStartFrameFailure);
		return NO;
	}

	if (_frameInProgress) 
	{
		BXVerificationCount(BXVerificationCounterStartFrameFailure);
		return NO;
	}

	if (_hasPendingOutputConfiguration &&
		(!_currentFrame || [_currentFrame isFree]))
	{
		if ([self _applyOutputConfiguration: _pendingOutputSize
									atScale: _pendingScale
								withCallback: _pendingCallbackValue
									 textMode: [BXEmulatorCore currentVideoModeIsText]])
			_hasPendingOutputConfiguration = NO;
	}

	BXVideoFrame *frame = _currentFrame;
	if (!frame || ![frame tryBeginRendering])
	{
		*buffer = NULL;
		*pitch = 0;
		BXVerificationCount(BXVerificationCounterStartFrameFailure);
		BXVerificationSample(BXVerificationMetricStartFrameScan, scanStart, BXVerificationNow());
		return NO;
	}

		frame.baseResolution = _preparedBaseResolution;
		frame.containsText = _preparedTextMode;
		[frame configureForLogicalSize: _preparedOutputSize];

	[frame clearDirtyRegions];
	_producerFrame = frame;
	_currentFrame = frame;
	*buffer = frame.mutableBytes;
	*pitch = (int)frame.pitch;
	_frameInProgress = YES;
	BXVerificationCount(BXVerificationCounterStartFrameSuccess);
	BXVerificationSample(BXVerificationMetricStartFrameScan, scanStart, BXVerificationNow());
	return YES;
}

- (void) finishFrameWithChanges: (const uint16_t *)dirtyBlocks
{
	boxer_audioTimingBeginPhase(BXAdapterTimingVideoHandoff);
	uint64_t totalStart = BXVerificationNow();
	BXVideoFrame *frame = _producerFrame;
	if (!_frameInProgress || !frame)
	{
		BXVerificationCount(BXVerificationCounterFinishFrameFailure);
		BXVerificationSample(BXVerificationMetricFinishFrame, totalStart, BXVerificationNow());
		boxer_audioTimingEndPhase(BXAdapterTimingVideoHandoff);
		return;
	}

	uint64_t dirtyStart = BXVerificationNow();
	if (dirtyBlocks)
		[frame captureDirtyBlocks: dirtyBlocks];
	else
		[frame captureDirtyBlocks: NULL];
	BXVerificationSample(BXVerificationMetricFinishDirtyCopy, dirtyStart, BXVerificationNow());

	frame.timestamp = CFAbsoluteTimeGetCurrent();
	_frameInProgress = NO;
	_producerFrame = nil;

	if (BXVideoPresentationDisabledForDiagnostic())
	{
		// Complete the frame state transition so the producer slot can be reused,
		// but do not publish or schedule host presentation. This is intentionally
		// diagnostic-only and is enabled through BOXER_DISABLE_VIDEO_FRAME_HANDOFF.
		if ([frame publishForPresentation])
			[frame discardIfReady];
		boxer_audioTimingEndPhase(BXAdapterTimingVideoHandoff);
		return;
	}

	uint64_t publishStart = BXVerificationNow();
		if (![frame publishForPresentation])
	{
		BXVerificationCount(BXVerificationCounterFinishFrameFailure);
		BXVerificationSample(BXVerificationMetricFinishFrame, totalStart, BXVerificationNow());
		boxer_audioTimingEndPhase(BXAdapterTimingVideoHandoff);
			return;
		}
	BXVideoFrame *oldFrame = atomic_exchange_explicit(&_latestFrame, frame,
											 memory_order_acq_rel);
	if (oldFrame)
	{
		if ([oldFrame discardIfReady])
			BXVerificationCount(BXVerificationCounterFrameDroppedCoalesced);
	}

	NSUInteger occupancy[4] = {0, 0, 0, 0};
	int state = [_currentFrame presentationState];
	if (state >= 0 && state <= 3)
		occupancy[state] = 1;
	BXVerificationRecordSlotOccupancy(occupancy[0], occupancy[1], occupancy[2], occupancy[3]);
	BXVerificationSample(BXVerificationMetricFinishPublish, publishStart, BXVerificationNow());

	uint64_t scheduleStart = BXVerificationNow();
	if (!atomic_exchange_explicit(&_presentationScheduled, true,
											 memory_order_acq_rel))
	{
		__weak BXVideoHandler *weakSelf = self;
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf _presentLatestFrame];
		});
	}
	BXVerificationSample(BXVerificationMetricFinishSchedule, scheduleStart, BXVerificationNow());
	BXVerificationCount(BXVerificationCounterFinishFrame);
	BXVerificationSample(BXVerificationMetricFinishFrame, totalStart, BXVerificationNow());

	if (_hasPendingOutputConfiguration)
	{
		NSSize outputSize = _pendingOutputSize;
		NSSize scale = _pendingScale;
		void *callback = _pendingCallbackValue;
		BOOL textMode = [BXEmulatorCore currentVideoModeIsText];
		if ([self _applyOutputConfiguration: outputSize
								atScale: scale
							withCallback: callback
								 textMode: textMode])
			_hasPendingOutputConfiguration = NO;
	}
	boxer_audioTimingEndPhase(BXAdapterTimingVideoHandoff);
}

- (BOOL) _applyOutputConfiguration: (NSSize)outputSize
							atScale: (NSSize)scale
						withCallback: (void *)newCallback
							 textMode: (BOOL)textMode
{
	if (_currentFrame && ![_currentFrame isFree])
		return NO;

	NSUInteger requiredLength = outputSize.width * outputSize.height * 4;
	NSUInteger capacityLength = _frameCapacity.width * _frameCapacity.height * 4;
	if (!_currentFrame || requiredLength > capacityLength)
	{
		_frameCapacity = outputSize;
		_currentFrame = [[BXVideoFrame alloc] initWithCapacitySize: _frameCapacity
											logicalSize: outputSize
												 depth: 4];
		memset(_currentFrame.mutableBytes, 0, _currentFrame.frameData.length);
	}
	else
	{
		// The single slot is free here, so the producer can apply the new logical
		// size before the next frame begins.
	}

	_callback = newCallback;
	_preparedOutputSize = outputSize;
	_preparedScale = scale;
	_preparedBaseResolution = self.resolution;
	_preparedTextMode = textMode;
	return YES;
}

- (void) _presentLatestFrame
{
	NSAssert([NSThread isMainThread], @"Frame presentation must run on the main thread");
	uint64_t taskStart = BXVerificationNow();
	BXVerificationCount(BXVerificationCounterPresentationTask);
	BXVideoFrame *frame = atomic_exchange_explicit(&_latestFrame, nil,
											 memory_order_acq_rel);
	if (frame && [frame tryBeginPresentation])
	{
		uint64_t didFinishStart = BXVerificationNow();
		[self.emulator _didFinishFrame: frame];
		BXVerificationSample(BXVerificationMetricDidFinishFrame, didFinishStart, BXVerificationNow());
		BXVerificationCount(BXVerificationCounterFramePresented);
	}
	else if (frame)
	{
		if ([frame discardIfReady])
			BXVerificationCount(BXVerificationCounterFrameDroppedStaleGeneration);
	}
	BXVerificationSample(BXVerificationMetricPresentationTask, taskStart, BXVerificationNow());

	atomic_store_explicit(&_presentationScheduled, false, memory_order_release);
	if (atomic_load_explicit(&_latestFrame, memory_order_acquire) &&
		!atomic_exchange_explicit(&_presentationScheduled, true, memory_order_acq_rel))
	{
		__weak BXVideoHandler *weakSelf = self;
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf _presentLatestFrame];
		});
	}
}

- (NSUInteger) paletteEntryWithRed: (NSUInteger)red
							 green: (NSUInteger)green
							  blue: (NSUInteger)blue;
{
	//Copypasta straight from sdlmain.cpp.
	return ((blue << 0) | (green << 8) | (red << 16)) | (255U << 24);
}


#pragma mark -
#pragma mark Rendering strategy

- (void) applyRenderingStrategy
{
	//Work out how much we will need to scale the resolution to fit the viewport
	NSSize resolution			= self.resolution;	
	NSSize viewportSize			= [self.emulator.delegate viewportSizeForEmulator: self.emulator];
	
	BOOL isTextMode				= self.isInTextMode;
	NSUInteger maxFilterScale	= [self _maxFilterScaleForResolution: resolution];
	
	
	//Start off with a passthrough filter as the default
	BXFilterType activeType		= BXFilterNormal;
	NSUInteger filterScale		= 1;
	BXFilterType desiredType	= self.filterType;
	
	//Decide if we can use our selected filter at this scale, and if so at what scale
	if (desiredType != BXFilterNormal &&
		[self _shouldApplyFilterType: desiredType
					  fromResolution: resolution
						  toViewport: viewportSize
						  isTextMode: isTextMode])
	{
		activeType = desiredType;
		//Now decide on what operation size the scaler should use
		filterScale = [self _filterScaleForType: activeType
								 fromResolution: resolution
									 toViewport: viewportSize
									 isTextMode: isTextMode];
	}
	
	//Make sure we don't go over the maximum size imposed by the OpenGL hardware
	filterScale = MIN(filterScale, maxFilterScale);
	
	
	//Finally, apply the values to DOSBox
	// Aspect correction is handled by the Boxer rendering adapter.
    [BXEmulatorCore setVideoScale:filterScale];
    
    
    //While we're here, sync up the CGA and hercules color modes if appropriate
    [self _syncHerculesTint];
    [self _syncCGAHueAdjustment];
}

- (const BXFilterDefinition *) _paramsForFilterType: (BXFilterType)type
{
	NSAssert1(type <= BXMaxFilters, @"Invalid filter type provided to paramsForFilterType: %li", (long)type);
	
    return BXFilters[type];
}


//Return the appropriate filter size to scale the given resolution up to the specified viewport.
//This is usually the viewport height divided by the resolution height and rounded up, to ensure
//we're always rendering larger than we need so that the graphics are crisper when scaled down.
//However we finesse this for some filters that look like shit when scaled down too much.
//(We base this on height rather than width, so that we'll use the larger filter size for
//aspect-ratio corrected surfaces.)
- (NSUInteger) _filterScaleForType: (BXFilterType)type
                    fromResolution: (NSSize)resolution
                        toViewport: (NSSize)viewportSize
                        isTextMode: (BOOL) isTextMode
{
	const BXFilterDefinition *params = [self _paramsForFilterType: type];
	
	NSSize scale = NSMakeSize(viewportSize.width / resolution.width,
							  viewportSize.height / resolution.height);
	
	NSUInteger filterScale = (NSUInteger)ceilf(scale.height - params->outputScaleBias);
	if (filterScale < params->minFilterScale) filterScale = params->minFilterScale;
	if (filterScale > params->maxFilterScale) filterScale = params->maxFilterScale;
	
	return filterScale;
}

//Returns whether our selected filter should be applied for the specified transformation.
- (BOOL) _shouldApplyFilterType: (BXFilterType)type
				 fromResolution: (NSSize)resolution
					 toViewport: (NSSize)viewportSize
					 isTextMode: (BOOL)isTextMode
{
	const BXFilterDefinition *params = [self _paramsForFilterType: type];
	
	//Disable scalers for high-resolution graphics modes
	//(We leave them available for text modes)
	if (!isTextMode && !sizeFitsWithinSize(resolution, params->maxResolution)) return NO;
	
	NSSize scale = NSMakeSize(viewportSize.width / resolution.width,
							  viewportSize.height / resolution.height);
	
	//Scale is too small for filter to be applied
	if (scale.height < params->minOutputScale) return NO;
	
	//If we got this far, go for it!
	return YES;
}

- (NSUInteger) _maxFilterScaleForResolution: (NSSize)resolution
{
	NSSize maxFrameSize	= [self.emulator.delegate maxFrameSizeForEmulator: self.emulator];
	//Work out how big a filter operation size we can use, given the maximum output size
	NSUInteger maxScale	= floor(MIN(maxFrameSize.width / resolution.width,
                                    maxFrameSize.height / resolution.height));
	
	return maxScale;
}

@end
