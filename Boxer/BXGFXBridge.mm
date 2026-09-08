/*
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


// BXGFXBridge is Boxer's implementation of DOSBox Staging's frontend interface.
//
// Up to 0.78, Boxer got its frames by #defining DOSBox's GFX_* calls to its own
// boxer_* hooks (see the retired block in BXCoalface.h). 0.83 replaced that
// frontend with two things:
//
//   * an abstract `RenderBackend` (gui/render/render_backend.h) that owns the
//     framebuffer, the shader pipeline and presentation, and
//   * a small set of free `GFX_*` functions (gui/common.h and
//     gui/private/common.h) covering the window, the event pump, the mouse and
//     display metrics.
//
// Upstream supplies both from gui/sdl_gui.cpp, which Boxer does not compile
// because Boxer *is* the frontend. So Boxer supplies them here instead:
// `BoxerRenderBackend` below implements `RenderBackend` against BXVideoHandler,
// and the `GFX_*` functions answer from Boxer's own window and input handling.
//
// The parts that are deliberately inert, and why, are recorded in FINDINGS.md
// under "Register: dropped, degraded and deferred functionality". In short:
// Boxer draws DOS frames into its own Cocoa/Metal view through BXVideoFrame and
// applies its own filtering with OpenEmuShaders, so upstream's GLSL shader
// pipeline, presentation timing, colour management and image adjustments have no
// work to do here -- and Boxer's own input controller owns the mouse cursor.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#import "BXEmulatorPrivate.h"
#import "BXVideoHandler.h"

#import "gui/common.h"
#import "gui/private/common.h"
#import "gui/render/render.h"
#import "gui/render/render_backend.h"
#import "gui/titlebar.h"
#import "hardware/input/mouse.h"
#import "misc/rendered_image.h"
#import "utils/rect.h"


#pragma mark - Helpers

static BXVideoHandler *_currentVideoHandler(void)
{
    return [BXEmulator currentEmulator].videoHandler;
}

/// The pixel-to-logical-unit ratio of the display Boxer's window is most likely
/// on. Upstream reads this from SDL, which Boxer does not use for its window;
/// the CoreGraphics display APIs are used instead because -- unlike NSScreen --
/// they are safe to call from DOSBox's emulation thread.
static float _mainDisplayScaleFactor(void)
{
    float scale = 1.0f;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID());
    if (mode)
    {
        const size_t widthInPixels = CGDisplayModeGetPixelWidth(mode);
        const size_t widthInPoints = CGDisplayModeGetWidth(mode);
        if (widthInPoints > 0)
            scale = (float)widthInPixels / (float)widthInPoints;
        CGDisplayModeRelease(mode);
    }
    return scale;
}


#pragma mark - BoxerRenderBackend

/// Boxer's RenderBackend. Everything to do with the DOS framebuffer is forwarded
/// to BXVideoHandler; everything to do with presenting it is Boxer's own business
/// and is inert here.
class BoxerRenderBackend final : public RenderBackend {
public:
    // MARK: The frame path -- this is the part that does real work.

    void NotifyRenderSizeChanged(const int new_render_width_px,
                                 const int new_render_height_px) override
    {
        const NSSize outputSize = NSMakeSize((CGFloat)new_render_width_px,
                                             (CGFloat)new_render_height_px);

        [_currentVideoHandler() prepareForOutputSize: outputSize
                                        withCallback: _callback];
    }

    void StartFrame(uint32_t*& pixels_out, int& pitch_out) override
    {
        void *buffer = NULL;
        int pitch = 0;

        // Unlike RenderBackend::StartFrame(), Boxer's video handler can decline
        // to start a frame (no framebuffer yet, or one already in progress).
        // GFX_StartUpdate() below treats a null buffer as that refusal, which is
        // exactly the condition upstream's GFX_StartUpdate() reports.
        if ([_currentVideoHandler() startFrameWithBuffer: &buffer pitch: &pitch])
        {
            pixels_out = (uint32_t *)buffer;
            pitch_out  = pitch;
        }
        else
        {
            pixels_out = nullptr;
            pitch_out  = 0;
        }
    }

    void EndFrame() override
    {
        [_currentVideoHandler() finishFrame];
    }

    uint32_t MakePixel(const uint8_t red, const uint8_t green,
                       const uint8_t blue) override
    {
        return (uint32_t)[_currentVideoHandler() paletteEntryWithRed: red
                                                              green: green
                                                               blue: blue];
    }

    DosBox::Rect GetCanvasSizeInPixels() override
    {
        // DOSBox's canvas is the whole area it may draw into. Boxer gives the
        // DOS output a view of its own with no chrome inside it, so the canvas
        // and the viewport are the same rectangle.
        BXEmulator *emulator = [BXEmulator currentEmulator];
        const NSSize size = [emulator.delegate viewportSizeForEmulator: emulator];

        return {(float)size.width, (float)size.height};
    }

    void NotifyVideoModeChanged(const VideoMode& video_mode) override
    {
        // Recorded for GetCurrent*() below; BXVideoHandler tracks the mode it
        // cares about (text vs. graphical) from vga.mode directly.
        _videoMode = video_mode;
    }

    // MARK: Presentation -- Boxer's own view decides when to draw.
    //
    // finishFrame publishes the completed BXVideoFrame to the session, which
    // redraws its DOS view. There is no GPU upload or swap for DOSBox to
    // schedule here, so preparing and presenting a frame are both no-ops.

    void PrepareFrame() override {}
    void PresentFrame() override {}
    void SetVsync(const bool /*is_enabled*/) override {}

    // MARK: Inert: Boxer renders through OpenEmuShaders, not DOSBox's pipeline.
    //
    // Boxer picks and applies its own shaders (see BXShadersModel and
    // BXVideoHandler's applyRenderingStrategy), so upstream's shader manager,
    // colour management and image adjustments are all bypassed. SetShader()
    // must still report success: render.cpp treats a shader failure as fatal
    // and would fall back or exit.

    SetShaderResult SetShader(const std::string& symbolic_shader_descriptor) override
    {
        _symbolicShaderDescriptor = symbolic_shader_descriptor;
        return SetShaderResult::Ok;
    }

    void ForceReloadCurrentShader() override {}

    ShaderInfo GetCurrentShaderInfo() override { return {}; }
    ShaderPreset GetCurrentShaderPreset() override { return {}; }
    ShaderDescriptor GetCurrentShaderDescriptor() override { return {}; }

    std::string GetCurrentSymbolicShaderDescriptor() override
    {
        // Echoed back so that render.cpp's write-back of the resolved 'shader'
        // setting round-trips to what was asked for, rather than to an
        // empty string.
        return _symbolicShaderDescriptor;
    }

    void SetColorSpace(const ColorSpace /*color_space*/) override {}
    void EnableImageAdjustments(const bool /*enable*/) override {}
    void SetImageAdjustmentSettings(const ImageAdjustmentSettings& /*settings*/) override {}
    void SetDeditheringStrength(const float /*strength*/) override {}

    // MARK: Inert: the window and post-shader readback are Boxer's.

    SDL_Window* GetWindow() override { return nullptr; }

    void NotifyViewportSizeChanged(const DosBox::Rect /*draw_rect_px*/) override {}

    RenderedImage ReadPixelsPostShader(const DosBox::Rect /*output_rect_px*/) override
    {
        // Post-shader capture reads back the frontend's own framebuffer, which
        // for Boxer is a Cocoa view it screenshots itself. Nothing compiled into
        // Boxer asks for this: upstream's only callers are the SDL and OpenGL
        // render backends, which Boxer does not build.
        return {};
    }

    // MARK: Frontend state owned by the free GFX_* functions below.

    void SetFrameCallback(GFX_Callback_t callback) { _callback = callback; }

private:
    GFX_Callback_t _callback = nullptr;
    VideoMode _videoMode     = {};
    std::string _symbolicShaderDescriptor = {};
};

static BoxerRenderBackend& _boxerRenderBackend(void)
{
    // Upstream constructs its backend in GFX_InitAndStartGui(), which also
    // creates the SDL window. Boxer's window is created by the session long
    // before DOSBox starts and outlives it, so the backend has no window to own
    // and no lifecycle of its own -- it is pure forwarding, and a singleton.
    static BoxerRenderBackend backend;
    return backend;
}

RenderBackend* GFX_GetRenderer()
{
    return &_boxerRenderBackend();
}

RenderBackendType GFX_GetRenderBackendType()
{
    // Boxer is neither of upstream's backends. `Sdl` is the honest answer of the
    // two: it means "a plain texture blit, no GLSL shader pipeline", which is
    // what DOSBox is doing as far as it can tell. Reporting `OpenGl` would send
    // render.cpp looking to upstream's shader presets for scan-doubling and
    // integer-scaling decisions that Boxer makes for itself.
    return RenderBackendType::Sdl;
}

TextureFilterMode GFX_GetTextureFilterMode()
{
    // Read by RENDER_SetScanAndPixelDoubling(): nearest-neighbour output would
    // suppress VGA scan doubling and pixel doubling, because they would be
    // visible as hard-edged duplicated pixels. Boxer filters its own output, so
    // it wants DOSBox's normal doubling behaviour -- which is what the 0.78 fork
    // got too.
    return TextureFilterMode::Bilinear;
}


#pragma mark - Frame lifecycle

/// Whether DOSBox has told us the render size at least once, and so whether
/// there is a framebuffer to draw into. Upstream keeps this as
/// `sdl.draw.active`, toggled by GFX_Start()/GFX_Stop().
static bool _drawActive = false;

/// Whether a frame is currently open. Upstream's `sdl.draw.updating_framebuffer`:
/// GFX_EndUpdate() is called at the emulated DOS rate whether or not the frame
/// changed, and must only publish frames that were actually started.
static bool _updatingFramebuffer = false;

void GFX_SetSize(const int render_width_px, const int render_height_px,
                 const Fraction& render_pixel_aspect_ratio,
                 const bool double_width, const bool double_height,
                 const VideoMode& video_mode, GFX_Callback_t callback)
{
    if (_updatingFramebuffer)
        GFX_EndUpdate();

    _drawActive = false;

    // The pixel aspect ratio and the doubling flags are DOSBox's advice on how
    // the frame should be displayed. Boxer does its own aspect correction from
    // the frame's base resolution (BXVideoFrame.baseResolution, set from
    // render.src), which is the same information in the form Boxer already uses,
    // so the advice is not consumed here.
    (void)render_pixel_aspect_ratio;
    (void)double_width;
    (void)double_height;
    (void)video_mode;

    BoxerRenderBackend& backend = _boxerRenderBackend();
    backend.SetFrameCallback(callback);
    backend.NotifyRenderSizeChanged(render_width_px, render_height_px);

    _drawActive = true;
}

bool GFX_StartUpdate(uint32_t*& pixels, int& pitch)
{
    if (!_drawActive || _updatingFramebuffer)
        return false;

    uint32_t *buffer = nullptr;
    int bufferPitch = 0;
    _boxerRenderBackend().StartFrame(buffer, bufferPitch);

    if (!buffer)
        return false;

    pixels = buffer;
    pitch  = bufferPitch;

    _updatingFramebuffer = true;
    return true;
}

void GFX_EndUpdate()
{
    // Called at the end of every emulated frame, changed or not; only the
    // changed ones were opened with GFX_StartUpdate() and have anything to
    // publish.
    if (_updatingFramebuffer)
        _boxerRenderBackend().EndFrame();

    _updatingFramebuffer = false;
}

uint32_t GFX_MakePixel(const uint8_t red, const uint8_t green, const uint8_t blue)
{
    return _boxerRenderBackend().MakePixel(red, green, blue);
}

PresentationMode GFX_GetPresentationMode()
{
    // Boxer hands each completed frame straight to its view, so frames are
    // presented at the emulated DOS rate. Claiming host-rate presentation would
    // make dosbox.cpp's run loop poll GFX_MaybePresentFrame() several times per
    // emulated millisecond for a present that never happens.
    return PresentationMode::DosRate;
}

void GFX_MaybePresentFrame()
{
    // No-op: see PresentFrame() above. Reached from GFX_EndUpdate() in DOS-rate
    // presentation mode.
}


#pragma mark - Display metrics

DosBox::Rect GFX_GetViewportSizeInPixels()
{
    // Upstream restricts the viewport within the canvas according to the
    // 'viewport' and 'integer_scaling' settings. Boxer fits and scales the DOS
    // output itself, in its view, so the unrestricted canvas is the answer.
    return _boxerRenderBackend().GetCanvasSizeInPixels();
}

DosBox::Rect GFX_GetDesktopSize()
{
    // In logical units, like SDL_GetDisplayBounds(); GFX_GetDpiScaleFactor()
    // converts to pixels. Unlike upstream we do not deduct window decorations:
    // Boxer's window is not DOSBox's to size.
    const CGRect bounds = CGDisplayBounds(CGMainDisplayID());

    return {(float)bounds.size.width, (float)bounds.size.height};
}

float GFX_GetDpiScaleFactor()
{
    return _mainDisplayScaleFactor();
}

double GFX_GetHostRefreshRate()
{
    // Only consulted when 'dos_rate' is set to 'host', which Boxer does not set.
    // The 0.78 hook this replaces returned a hardcoded 60; asking CoreGraphics
    // is both cheap and correct.
    constexpr double DefaultRefreshRateHz = 60.0;

    double refreshRate = 0.0;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID());
    if (mode)
    {
        refreshRate = CGDisplayModeGetRefreshRate(mode);
        CGDisplayModeRelease(mode);
    }

    // Built-in displays report 0 Hz through this API.
    return (refreshRate > 0.0) ? refreshRate : DefaultRefreshRateHz;
}

bool GFX_HaveDesktopEnvironment()
{
    // Upstream's check is for BSD/Linux consoles with no window manager.
    return true;
}


#pragma mark - Event loop and shutdown

bool GFX_PollAndHandleEvents()
{
    // Boxer pumps its own Cocoa event queue and decides whether emulation should
    // continue; this was GFX_Events (and GFX_MaybeProcessEvents) up to 0.78.
    return boxer_processEvents();
}

void GFX_RequestExit(const bool pressed)
{
    if (pressed)
        DOSBOX_RequestShutdown();
}


#pragma mark - Mouse
//
// 0.83's MOUSE_NotifyStateChanged() pushes the mouse state it wants onto the
// frontend through these five calls. Boxer's BXInputController owns the cursor
// instead: it decides when to hide, lock and warp it based on what the session
// window is doing, which is more than DOSBox can know. So these are inert.
//
// This is not a regression: the equivalent 0.78 hook (Mouse_AutoLock ->
// boxer_setMouseActive) was declared but never called from anywhere in the fork
// either. See D22 in FINDINGS.md.

void GFX_SetMouseCapture(const bool /*requested_capture*/) {}
void GFX_SetMouseVisibility(const bool /*requested_visible*/) {}
void GFX_SetMouseRawInput(const bool /*requested_raw_input*/) {}
void GFX_SetMouseHint(const MouseHint /*requested_hint_id*/) {}
void GFX_CenterMouse() {}


#pragma mark - Title bar
//
// DOSBox used to keep its window title up to date by calling GFX_SetTitle,
// which Boxer remapped to boxer_handleDOSBoxTitleChange to learn that the
// emulation speed or the running program had changed. 0.83 moved all of that
// into gui/titlebar.cpp, which Boxer does not compile -- but the notifications
// themselves come from cpu.cpp, dos_execute.cpp, mixer.cpp and the capture
// module, all of which Boxer does build. So Boxer answers them here.
//
// Only two of them tell Boxer something it does not already know: the cycles
// changing behind its back, and the name of the program that is running.
// Everything else is state Boxer initiated itself and already reflects in its
// own UI.

/// The 8-character MCB name of the program currently in the foreground.
///
/// Up to 0.78 this was a global in dos_execute.cpp that Boxer read directly
/// whenever the emulation state changed. 0.83 deleted the global and pushes the
/// name to the frontend instead, so the frontend keeps it -- preserving both
/// the symbol BXEmulator reads and its pull-based timing.
///
/// TODO: now that this arrives as a notification rather than a poll, Boxer could
/// update BXEmulator.processName the moment the program changes, instead of
/// waiting for the next emulation-state change to notice.
static char _runningProgramName[9] = "DOSBOX";
const char *RunningProgram = _runningProgramName;

void TITLEBAR_NotifyProgramName(const std::string& segment_name,
                                const std::string& canonical_name)
{
    // The canonical (full path) name is new in 0.83 and has no consumer in
    // Boxer: BXEmulator tracks launched programs through its own shell hooks,
    // which know the path already.
    (void)canonical_name;

    strlcpy(_runningProgramName, segment_name.c_str(), sizeof(_runningProgramName));
}

void TITLEBAR_NotifyCyclesChanged()
{
    // The successor to GFX_SetTitle for Boxer's purposes: DOSBox has changed
    // the CPU speed or core by itself (auto-cycles adjusting, a protected-mode
    // program starting), so Boxer's speed controls need to re-read it.
    [[BXEmulator currentEmulator] _didChangeEmulationState];
}

void TITLEBAR_RefreshTitle()
{
    // Means "the title's contents changed"; for Boxer that is the same event.
    [[BXEmulator currentEmulator] _didChangeEmulationState];
}

// The rest are notifications about state Boxer itself initiated, and already
// shows in its own interface: it drives audio and video capture through
// BXSession, and mutes the mixer itself when the session pauses (see B2 in
// FINDINGS.md).

void TITLEBAR_NotifyBooting() {}
void TITLEBAR_NotifyAudioCaptureStatus(const bool /*is_capturing*/) {}
void TITLEBAR_NotifyVideoCaptureStatus(const bool /*is_capturing*/) {}
void TITLEBAR_NotifyAudioMutedStatus(const bool /*is_muted*/) {}
