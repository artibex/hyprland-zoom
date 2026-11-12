// native_equivalence_test.cpp — proves camera_math.hpp at margin 0.05 equals Hyprland's maths.
//
// `native056` and `native057` are transcriptions of `CMonitorZoomController::zoomWithDetachedCamera`
// as it is in Hyprland v0.56.2 and v0.57.2 (src/output/MonitorZoomController.cpp), written on
// hyprutils' real CBox. Comparing the two versions line by line showed that the camera maths is
// identical; only how the function reaches the monitor, the zoom factor and the pointer differs
// (0.56: SRenderData parameter + g_pHyprRenderer, 0.57: CRenderContext parameter). Each version
// therefore has its own transcription with its own accessors, so a future change in either one
// is a visible diff here. Random pointer/zoom sequences must give the same camera AND the same
// projected monitor box (including the output scale) in the transcription and in the plugin's
// maths; this catches slips that the hand-computed unit tests cannot.
#include "../../plugin/camera_math.hpp"

#include <hyprutils/math/Box.hpp>
#include <hyprutils/math/Vector2D.hpp>

#include <cmath>
#include <cstdio>
#include <random>

using Hyprutils::Math::CBox;
using Hyprutils::Math::Vector2D;

namespace {

/// The private members of CMonitorZoomController, as a plain struct.
struct NativeState {
    CBox camera;                  ///< m_camera
    float lastZoomLevel   = 1.0F; ///< m_lastZoomLevel
    bool resetCameraState = true; ///< m_resetCameraState
    bool padCamEdges      = true; ///< m_padCamEdges
};

/// The monitor fields the native function reads.
struct FakeMonitor {
    Vector2D size;      ///< m->m_size (logical size).
    float scale = 1.0F; ///< m->m_scale (output scale).
};

/// Hyprland's SRenderData as far as the function uses it.
struct FakeRenderData {
    const FakeMonitor* pMonitor = nullptr; ///< Monitor of the frame.
    float mouseZoomFactor       = 1.0F;    ///< Zoom factor of the frame (0.57 reads it here).
};

/// Hyprland 0.57's CRenderContext as far as the function uses it.
struct FakeRenderContext {
    FakeRenderData m_data; ///< ctx.m_data
};

/// The body shared by both transcriptions (identical in v0.56.2 and v0.57.2).
/// @param state Native camera state, updated in place.
/// @param m The monitor (m->m_size, m->m_scale).
/// @param ZOOM Zoom factor of the frame.
/// @param MOUSE Zoom anchor.
/// @param rigid Value of cursor:zoom_rigid.
/// @return The projected monitor box (`monbox` at the end of the function).
CBox nativeBody(NativeState& state, const FakeMonitor& m, float ZOOM, const Vector2D& MOUSE,
                bool rigid) {
    auto monbox = CBox(0, 0, m.size.x, m.size.y);
    // Only a zoom change re-anchors the camera.
    if (state.lastZoomLevel != ZOOM) {
        // A pending reset restarts the camera from the whole monitor.
        if (state.resetCameraState) {
            state.resetCameraState = false;
            state.camera           = CBox(0, 0, m.size.x, m.size.y);
            state.lastZoomLevel    = 1.0f;
        }
        const CBox old = state.camera;

        // Pointer position as a screen fraction, and the world point below it (float, as native).
        const float mx          = MOUSE.x / m.size.x;
        const float my          = MOUSE.y / m.size.y;
        const float mouseWorldX = old.x + (mx * old.w);
        const float mouseWorldY = old.y + (my * old.h);

        // New view size and the origin that keeps the world point under the pointer.
        const auto CAMERAW = monbox.w / ZOOM;
        const auto CAMERAH = monbox.h / ZOOM;
        const float newX   = mouseWorldX - (mx * CAMERAW);
        const float newY   = mouseWorldY - (my * CAMERAH);

        // Anti-jerk: a zoom step that strands the pointer outside the 0.9 box disables padding.
        state.camera = CBox(newX, newY, CAMERAW, CAMERAH);
        if (!state.camera.copy().scaleFromCenter(.9).containsPoint(MOUSE))
            state.padCamEdges = false;
        state.lastZoomLevel = ZOOM;
    }

    // Keep the mouse inside the camera view, using the 0.9 "safe" box while padding is on.
    auto smallerbox = state.camera;
    if (!state.padCamEdges)
        if (smallerbox.copy().scaleFromCenter(.9).containsPoint(MOUSE))
            state.padCamEdges = true;
    if (state.padCamEdges)
        smallerbox.scaleFromCenter(.9);
    // Rigid mode locks the camera at the anchor instead of panning.
    if (!rigid && !smallerbox.containsPoint(MOUSE)) {
        if (MOUSE.x < smallerbox.x)
            state.camera.x -= smallerbox.x - MOUSE.x;
        if (MOUSE.y < smallerbox.y)
            state.camera.y -= smallerbox.y - MOUSE.y;
        if (MOUSE.y > smallerbox.y + smallerbox.h)
            state.camera.y += MOUSE.y - (smallerbox.y + smallerbox.h);
        if (MOUSE.x > smallerbox.x + smallerbox.w)
            state.camera.x += MOUSE.x - (smallerbox.x + smallerbox.w);
    }

    // The projection: the last lines of the native function.
    auto z = ZOOM * m.scale;
    monbox.scale(z).translate(-state.camera.pos() * z);
    return monbox;
}

/// Transcription of Hyprland v0.56.2:
/// `zoomWithDetachedCamera(CBox& result, const Render::SRenderData& m_renderData)`.
/// @param state Native camera state, updated in place.
/// @param renderData The render data parameter (monitor).
/// @param rendererZoom `g_pHyprRenderer->m_renderData.mouseZoomFactor`, where 0.56 reads the zoom.
/// @param MOUSE `getAnchor(m)`.
/// @param rigid `cursor:zoom_rigid`.
/// @return `result`, the box written by the function.
CBox native056(NativeState& state, const FakeRenderData& renderData, float rendererZoom,
               const Vector2D& MOUSE, bool rigid) {
    // 0.56: monitor from the parameter, zoom from the renderer's own data.
    const auto m    = renderData.pMonitor;
    const auto ZOOM = rendererZoom;
    return nativeBody(state, *m, ZOOM, MOUSE, rigid);
}

/// Transcription of Hyprland v0.57.2:
/// `zoomWithDetachedCamera(Render::CRenderContext& ctx, CBox& result)`.
/// @param state Native camera state, updated in place.
/// @param ctx The render context parameter (monitor and zoom factor).
/// @param MOUSE `getAnchor(m)`.
/// @param rigid `cursor:zoom_rigid`.
/// @return `result`, the box written by the function.
CBox native057(NativeState& state, const FakeRenderContext& ctx, const Vector2D& MOUSE,
               bool rigid) {
    // 0.57: both come from the context that is passed in.
    const auto m    = ctx.m_data.pMonitor;
    const auto ZOOM = ctx.m_data.mouseZoomFactor;
    return nativeBody(state, *m, ZOOM, MOUSE, rigid);
}

/// Largest absolute difference between a native box and ours (camera or projected box).
/// @param native Box from Hyprland's code.
/// @param ours Box from camera_math.hpp.
/// @return Maximum component difference in pixels.
double boxDifference(const CBox& native, const hyprzoom::Box& ours) {
    // Compare position and size separately, then take the worst of the four numbers.
    const double position = std::fmax(std::fabs(native.x - ours.x), std::fabs(native.y - ours.y));
    const double size     = std::fmax(std::fabs(native.w - ours.w), std::fabs(native.h - ours.h));
    return std::fmax(position, size);
}

/// Which transcription a session replays.
enum class Version { V056, V057 };

/// Replays one random session through the native transcription and the plugin maths.
/// @param version Which transcription to use.
/// @param monitor Monitor geometry of the session.
/// @param random Random generator (seeded by the caller for reproducibility).
/// @param session Session index; selects zoom levels and rigid mode.
/// @return Worst camera or projection difference seen in the session.
double replaySession(Version version, const FakeMonitor& monitor, std::mt19937& random,
                     int session) {
    std::uniform_real_distribution<double> unit(0.0, 1.0);
    const float zoomLevels[] = {1.5F, 2.0F, 3.0F, 5.0F};
    NativeState native;
    hyprzoom::CameraState ours;
    double worst = 0.0;
    for (int step = 0; step < 60; ++step) {
        // A random pointer inside the monitor.
        const Vector2D pointer{unit(random) * monitor.size.x, unit(random) * monitor.size.y};
        // The zoom changes every ~10 frames; every 7th session is rigid.
        const float zoom = zoomLevels[(session + step / 10) % 4];
        const bool rigid = (session % 7) == 0;
        // The native frame in the chosen version's calling convention.
        const FakeRenderData data{&monitor, zoom};
        const CBox nativeBox = version == Version::V056
                                   ? native056(native, data, zoom, pointer, rigid)
                                   : native057(native, FakeRenderContext{data}, pointer, rigid);
        // The same frame through camera_math.hpp at the native margin.
        hyprzoom::CameraInput input;
        input.pointer     = {pointer.x, pointer.y};
        input.monitorSize = {monitor.size.x, monitor.size.y};
        input.zoom        = zoom;
        input.edgeMargin  = hyprzoom::kNativeEdgeMargin;
        input.rigid       = rigid;
        hyprzoom::updateCamera(ours, input);
        // Both the camera and the projected box (which includes the output scale) must agree.
        worst = std::fmax(worst, boxDifference(native.camera, ours.camera));
        const hyprzoom::Box box =
            hyprzoom::cameraToMonitorBox(ours, input.monitorSize, zoom, monitor.scale);
        worst = std::fmax(worst, boxDifference(nativeBox, box));
    }
    return worst;
}

} // namespace

/// Replays random sessions for both versions and three monitors; exit code 1 on divergence.
int main() {
    // Logical size and output scale: plain 1080p, a 1.5x scaled laptop panel, a 2x panel.
    const FakeMonitor monitors[] = {
        {{1920.0, 1080.0}, 1.0F}, {{1280.0, 720.0}, 1.5F}, {{1280.0, 720.0}, 2.0F}};
    // A fixed seed makes failures reproducible.
    std::mt19937 random(12345);
    double worst = 0.0;
    int frames   = 0;
    for (const auto version : {Version::V056, Version::V057}) {
        for (const auto& monitor : monitors) {
            for (int session = 0; session < 70; ++session) {
                worst = std::fmax(worst, replaySession(version, monitor, random, session));
                frames += 60;
            }
        }
    }
    std::printf("%d frames compared (0.56 + 0.57 transcriptions, 3 monitors), worst difference "
                "%.9f px\n",
                frames, worst);
    // Both sides use float anchor maths, so anything above rounding noise is a real divergence.
    return worst < 1e-3 ? 0 : 1;
}
