// native_equivalence_test.cpp — proves camera_math.hpp at margin 0.05 equals Hyprland's maths.
//
// `nativeFrame` is a transcription of Hyprland v0.56.2's
// `CMonitorZoomController::zoomWithDetachedCamera` (src/output/MonitorZoomController.cpp) on
// hyprutils' real CBox; only the comments differ. Random pointer/zoom sequences must give the
// same camera in both implementations; this catches transcription slips that the hand-computed
// unit tests cannot.
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

/// The anchor part of Hyprland's function: re-anchor the camera after a zoom change.
/// @param state Native camera state, updated in place.
/// @param MOUSE Zoom anchor.
/// @param monitorSize Logical monitor size.
/// @param ZOOM Zoom factor.
void nativeReanchor(NativeState& state, const Vector2D& MOUSE, const Vector2D& monitorSize,
                    float ZOOM) {
    // A pending reset restarts the camera from the whole monitor.
    if (state.resetCameraState) {
        state.resetCameraState = false;
        state.camera           = CBox(0, 0, monitorSize.x, monitorSize.y);
        state.lastZoomLevel    = 1.0F;
    }
    // Pointer position as a screen fraction, and the world point below it (all float, as native).
    const CBox old          = state.camera;
    const float mx          = MOUSE.x / monitorSize.x;
    const float my          = MOUSE.y / monitorSize.y;
    const float mouseWorldX = old.x + (mx * old.w);
    const float mouseWorldY = old.y + (my * old.h);
    // New view size and the origin that keeps the world point under the pointer.
    const auto CAMERAW = monitorSize.x / ZOOM;
    const auto CAMERAH = monitorSize.y / ZOOM;
    const float newX   = mouseWorldX - (mx * CAMERAW);
    const float newY   = mouseWorldY - (my * CAMERAH);
    state.camera       = CBox(newX, newY, CAMERAW, CAMERAH);
    // Anti-jerk: a zoom step that strands the pointer outside the 0.9 box disables padding.
    if (!state.camera.copy().scaleFromCenter(.9).containsPoint(MOUSE))
        state.padCamEdges = false;
    state.lastZoomLevel = ZOOM;
}

/// Hyprland's zoomWithDetachedCamera (camera part only; the projection is compared separately).
/// @param state Native camera state, updated in place.
/// @param MOUSE Zoom anchor.
/// @param monitorSize Logical monitor size.
/// @param ZOOM Zoom factor.
/// @param rigid Value of cursor:zoom_rigid.
void nativeFrame(NativeState& state, const Vector2D& MOUSE, const Vector2D& monitorSize, float ZOOM,
                 bool rigid) {
    // Only a zoom change re-anchors the camera.
    if (state.lastZoomLevel != ZOOM)
        nativeReanchor(state, MOUSE, monitorSize, ZOOM);

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
        // Bottom and right overshoots pan the other way.
        if (MOUSE.y > smallerbox.y + smallerbox.h)
            state.camera.y += MOUSE.y - (smallerbox.y + smallerbox.h);
        if (MOUSE.x > smallerbox.x + smallerbox.w)
            state.camera.x += MOUSE.x - (smallerbox.x + smallerbox.w);
    }
}

/// Largest absolute difference between the two cameras' four numbers.
/// @param native Camera from Hyprland's code.
/// @param ours Camera from camera_math.hpp.
/// @return Maximum component difference in pixels.
double maxDifference(const CBox& native, const hyprzoom::Box& ours) {
    // Compare position and size separately, then take the worst of the four numbers.
    const double position = std::fmax(std::fabs(native.x - ours.x), std::fabs(native.y - ours.y));
    const double size     = std::fmax(std::fabs(native.w - ours.w), std::fabs(native.h - ours.h));
    return std::fmax(position, size);
}

/// Replays one random session through both implementations.
/// @param random Random generator (seeded by the caller for reproducibility).
/// @param session Session index; selects zoom levels and rigid mode.
/// @return Worst camera difference seen in the session.
double replaySession(std::mt19937& random, int session) {
    std::uniform_real_distribution<double> unit(0.0, 1.0);
    const float zoomLevels[] = {1.5F, 2.0F, 3.0F, 5.0F};
    NativeState native;
    hyprzoom::CameraState ours;
    double worst = 0.0;
    for (int step = 0; step < 60; ++step) {
        // A random pointer inside a 1920x1080 monitor.
        const Vector2D pointer{unit(random) * 1920.0, unit(random) * 1080.0};
        // The zoom changes every ~10 frames; every 7th session is rigid.
        const float zoom = zoomLevels[(session + step / 10) % 4];
        const bool rigid = (session % 7) == 0;
        nativeFrame(native, pointer, {1920.0, 1080.0}, zoom, rigid);
        // The same frame through camera_math.hpp at the native margin.
        hyprzoom::CameraInput input;
        input.pointer     = {pointer.x, pointer.y};
        input.monitorSize = {1920.0, 1080.0};
        input.zoom        = zoom;
        input.edgeMargin  = hyprzoom::kNativeEdgeMargin;
        input.rigid       = rigid;
        hyprzoom::updateCamera(ours, input);
        worst = std::fmax(worst, maxDifference(native.camera, ours.camera));
    }
    return worst;
}

} // namespace

/// Replays 200 random sessions through both versions; exit code 1 on any divergence.
int main() {
    // A fixed seed makes failures reproducible.
    std::mt19937 random(12345);
    double worst = 0.0;
    for (int session = 0; session < 200; ++session)
        worst = std::fmax(worst, replaySession(random, session));
    std::printf("%d frames compared, worst camera difference %.9f px\n", 200 * 60, worst);
    // Both sides use float anchor maths, so anything above rounding noise is a real divergence.
    return worst < 1e-3 ? 0 : 1;
}
