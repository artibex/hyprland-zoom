// native_equivalence_test.cpp — proves camera_math.hpp at margin 0.05 equals Hyprland's maths.
//
// `nativeFrame` is a verbatim transcription of Hyprland v0.56.2's
// `CMonitorZoomController::zoomWithDetachedCamera` (src/output/MonitorZoomController.cpp) on
// hyprutils' real CBox. Random pointer/zoom sequences must give the same camera in both
// implementations; this catches transcription slips the hand-computed unit tests cannot.
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
    CBox  camera;
    float lastZoomLevel    = 1.0F;
    bool  resetCameraState = true;
    bool  padCamEdges      = true;
};

/// Hyprland's zoomWithDetachedCamera, copied line for line (comments dropped).
/// @param state Native camera state, updated in place.
/// @param mouse Zoom anchor.
/// @param monitorSize Logical monitor size.
/// @param zoom Zoom factor.
/// @param rigid Value of cursor:zoom_rigid.
void nativeFrame(NativeState& state, const Vector2D& mouse, const Vector2D& monitorSize, float zoom,
                 bool rigid) {
    const auto MOUSE = mouse;
    const auto ZOOM  = zoom;
    auto       monbox = CBox(0, 0, monitorSize.x, monitorSize.y);

    if (state.lastZoomLevel != ZOOM) {
        if (state.resetCameraState) {
            state.resetCameraState = false;
            state.camera           = CBox(0, 0, monitorSize.x, monitorSize.y);
            state.lastZoomLevel    = 1.0F;
        }
        const CBox  old         = state.camera;
        const float mx          = MOUSE.x / monitorSize.x;
        const float my          = MOUSE.y / monitorSize.y;
        const float mouseWorldX = old.x + (mx * old.w);
        const float mouseWorldY = old.y + (my * old.h);
        const auto  CAMERAW     = monbox.w / ZOOM;
        const auto  CAMERAH     = monbox.h / ZOOM;
        const float newX        = mouseWorldX - (mx * CAMERAW);
        const float newY        = mouseWorldY - (my * CAMERAH);
        state.camera            = CBox(newX, newY, CAMERAW, CAMERAH);
        if (!state.camera.copy().scaleFromCenter(.9).containsPoint(MOUSE))
            state.padCamEdges = false;
        state.lastZoomLevel = ZOOM;
    }

    auto smallerbox = state.camera;
    if (!state.padCamEdges)
        if (smallerbox.copy().scaleFromCenter(.9).containsPoint(MOUSE))
            state.padCamEdges = true;
    if (state.padCamEdges)
        smallerbox.scaleFromCenter(.9);
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
}

/// Largest absolute difference between the two cameras' four numbers.
/// @param native Camera from Hyprland's code.
/// @param ours Camera from camera_math.hpp.
/// @return Maximum component difference in pixels.
double maxDifference(const CBox& native, const hyprzoom::Box& ours) {
    return std::fmax(std::fmax(std::fabs(native.x - ours.x), std::fabs(native.y - ours.y)),
                     std::fmax(std::fabs(native.w - ours.w), std::fabs(native.h - ours.h)));
}

} // namespace

/// Replays random sessions (zoom steps, pointer moves, rigid on/off) through both versions.
int main() {
    std::mt19937                           random(12345);
    std::uniform_real_distribution<double> pointerDist(0.0, 1.0);
    const float                            zoomLevels[] = {1.5F, 2.0F, 3.0F, 5.0F, 1.0F};
    double                                 worst        = 0.0;
    int                                    frames       = 0;

    for (int session = 0; session < 200; ++session) {
        NativeState          native;
        hyprzoom::CameraState ours;
        for (int step = 0; step < 60; ++step) {
            const Vector2D pointer{pointerDist(random) * 1920.0, pointerDist(random) * 1080.0};
            // A new zoom level every ~10 frames; the native code never runs at zoom 1.0.
            const float zoom  = zoomLevels[(session + step / 10) % 4];
            const bool  rigid = (session % 7) == 0;

            nativeFrame(native, pointer, {1920.0, 1080.0}, zoom, rigid);

            hyprzoom::CameraInput input;
            input.pointer     = {pointer.x, pointer.y};
            input.monitorSize = {1920.0, 1080.0};
            input.zoom        = zoom;
            input.edgeMargin  = hyprzoom::kNativeEdgeMargin;
            input.rigid       = rigid;
            hyprzoom::updateCamera(ours, input);

            worst = std::fmax(worst, maxDifference(native.camera, ours.camera));
            ++frames;
        }
    }
    std::printf("%d frames compared, worst camera difference %.9f px\n", frames, worst);
    // Both sides use float anchor maths, so anything above rounding noise is a real divergence.
    return worst < 1e-3 ? 0 : 1;
}
