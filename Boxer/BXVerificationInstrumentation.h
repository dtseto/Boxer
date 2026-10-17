#import <Foundation/Foundation.h>

typedef enum : NSUInteger {
    BXVerificationMetricStartFrameScan = 0,
    BXVerificationMetricFinishFrame,
    BXVerificationMetricFinishDirtyCopy,
    BXVerificationMetricFinishPublish,
    BXVerificationMetricFinishSchedule,
    BXVerificationMetricPresentationTask,
    BXVerificationMetricApplyDirtyRegions,
    BXVerificationMetricDidFinishFrame,
    BXVerificationMetricUpdateWithFrame,
    BXVerificationMetricReplaceRegion,
    BXVerificationMetricNextDrawable,
    BXVerificationMetricCommandEncode,
    BXVerificationMetricCommandBufferCommit,
    BXVerificationMetricGPUCompletion,
    BXVerificationMetricCount
} BXVerificationMetric;

typedef enum : NSUInteger {
    BXVerificationCounterFinishFrame = 0,
    BXVerificationCounterFinishFrameFailure,
    BXVerificationCounterStartFrameSuccess,
    BXVerificationCounterStartFrameFailure,
    BXVerificationCounterPresentationTask,
    BXVerificationCounterGPUCompletion,
    BXVerificationCounterTextureCreation,
    BXVerificationCounterFramePresented,
    BXVerificationCounterFrameDroppedSemaphore,
    BXVerificationCounterFrameDroppedNoDrawable,
    BXVerificationCounterFrameDroppedStaleGeneration,
    BXVerificationCounterFrameDroppedCoalesced,
    BXVerificationCounterSlotFree,
    BXVerificationCounterSlotRendering,
    BXVerificationCounterSlotReady,
    BXVerificationCounterSlotPresenting,
    BXVerificationCounterCommittedTransitionFailure,
    BXVerificationCounterCommittedCompletionTransitionFailure,
    BXVerificationCounterPrematureCommittedFree,
    BXVerificationCounterSemaphoreDropOnCommittedFrame,
    BXVerificationCounterDroppedSample,
    BXVerificationCounterCount
} BXVerificationCounter;

#if defined(BOXER_VERIFICATION_INSTRUMENTATION)

FOUNDATION_EXPORT void BXVerificationStart(void);
FOUNDATION_EXPORT void BXVerificationStop(void);
FOUNDATION_EXPORT void BXVerificationCount(BXVerificationCounter counter);
FOUNDATION_EXPORT void BXVerificationSample(BXVerificationMetric metric,
                                             uint64_t start,
                                             uint64_t end);
FOUNDATION_EXPORT uint64_t BXVerificationNow(void);
FOUNDATION_EXPORT uint64_t BXVerificationMicroseconds(uint64_t start,
                                                       uint64_t end);
FOUNDATION_EXPORT void BXVerificationRecordSlotOccupancy(NSUInteger freeCount,
                                                          NSUInteger renderingCount,
                                                          NSUInteger readyCount,
                                                          NSUInteger presentingCount);

#else

#define BXVerificationStart() ((void)0)
#define BXVerificationStop() ((void)0)
#define BXVerificationCount(counter) do { (void)(counter); } while (0)
#define BXVerificationSample(metric, start, end) do { (void)(metric); (void)(start); (void)(end); } while (0)
#define BXVerificationNow() 0ULL
#define BXVerificationMicroseconds(start, end) 0ULL
#define BXVerificationRecordSlotOccupancy(freeCount, renderingCount, readyCount, presentingCount) do { \
	(void)(freeCount); (void)(renderingCount); (void)(readyCount); (void)(presentingCount); \
} while (0)

#endif
