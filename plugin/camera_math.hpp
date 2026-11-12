// camera_math.hpp — pure camera maths of the hyprzoom plugin (no Hyprland types).
//
// This is a re-implementation of Hyprland 0.56's
// `CMonitorZoomController::zoomWithDetachedCamera` in which the hard-coded 0.9 "safe box"
// factor is replaced by `1 - 2 * edgeMargin`. Keeping it free of Hyprland headers lets the unit
// tests compile it with a plain g++ and keeps the plugin glue tiny.
#pragma once

#include <algorithm>

namespace hyprzoom {

/// Margin (fraction of the zoomed view, per side) that reproduces Hyprland's native 0.9 box.
constexpr double kNativeEdgeMargin = 0.05;
/// Smallest accepted margin: the camera only pans once the pointer touches the view edge.
constexpr double kMinEdgeMargin = 0.0;
/// Largest accepted margin: the safe box shrinks to 10 % of the view, i.e. nearly centred.
constexpr double kMaxEdgeMargin = 0.45;

/// A point or size in world / monitor coordinates.
struct Vec2 {
    double x = 0.0; ///< Horizontal component.
    double y = 0.0; ///< Vertical component.
};

/// An axis-aligned rectangle, top-left origin (same convention as Hyprland's CBox).
struct Box {
    double x = 0.0; ///< Left edge.
    double y = 0.0; ///< Top edge.
    double w = 0.0; ///< Width.
    double h = 0.0; ///< Height.
};

/// Persistent per-monitor camera state; mirrors the private members of CMonitorZoomController.
struct CameraState {
    Box camera;                   ///< World-space box currently shown on the monitor.
    float lastZoomLevel   = 1.0F; ///< Zoom level the camera was last anchored for.
    bool resetCameraState = true; ///< Re-anchor from the full monitor on the next zoom change.
    bool padCamEdges      = true; ///< False while a zoom step left the pointer outside the box.
};

/// Everything the camera needs to know about the current frame.
struct CameraInput {
    Vec2 pointer;                          ///< Zoom anchor (pointer position inside the monitor).
    Vec2 monitorSize;                      ///< Logical monitor size.
    float zoom        = 1.0F;              ///< Current zoom factor (> 1 while zoomed).
    double edgeMargin = kNativeEdgeMargin; ///< Requested margin; clamped before use.
    bool rigid        = false;             ///< Mirrors `cursor:zoom_rigid`: never pan.
};

/// Clamps a user supplied margin into [kMinEdgeMargin, kMaxEdgeMargin].
/// @param margin Raw configuration value; NaN counts as "native".
/// @return The usable margin.
inline double clampEdgeMargin(double margin) {
    // NaN fails every comparison, so test it first to fall back to the native behaviour.
    if (margin != margin)
        return kNativeEdgeMargin;
    // Everything else is a plain range clamp.
    return std::clamp(margin, kMinEdgeMargin, kMaxEdgeMargin);
}

/// Scale factor of the safe box for a margin (native margin 0.05 gives the literal 0.9).
/// @param margin Clamped margin per side.
/// @return Fraction of the view that the pointer may roam in without moving the camera.
inline double safeBoxScale(double margin) {
    // A margin applies to both sides of an axis, hence the factor two.
    return 1.0 - 2.0 * margin;
}

/// Shrinks or grows a box around its centre (same maths as CBox::scaleFromCenter).
/// @param box Box to scale.
/// @param factor Scale factor; 0.9 keeps 90 % of each side.
/// @return The scaled box.
inline Box scaleFromCenter(Box box, double factor) {
    // Remember the old size to know how far the origin has to move.
    const double oldWidth  = box.w;
    const double oldHeight = box.h;
    // Scale the size first; the origin is corrected below.
    box.w *= factor;
    box.h *= factor;
    // Moving the origin by half of the size change keeps the centre where it was.
    box.x -= (box.w - oldWidth) / 2.0;
    box.y -= (box.h - oldHeight) / 2.0;
    return box;
}

/// Half-open containment test, identical to Hyprland's (right and bottom edge are outside).
/// @param box Rectangle to test against.
/// @param point Point to test.
/// @return True when the point lies inside the box.
inline bool containsPoint(const Box& box, const Vec2& point) {
    // Left/top edges count as inside, right/bottom edges as outside, like CBox::containsPoint.
    return point.x >= box.x && point.x < box.x + box.w && point.y >= box.y &&
           point.y < box.y + box.h;
}

/// Re-anchors the camera after a zoom change so the world point under the pointer stays put.
/// @param state Camera state, updated in place.
/// @param input Frame input (pointer, monitor size, zoom, margin).
/// @param boxScale Safe-box scale derived from the clamped margin.
inline void reanchorCamera(CameraState& state, const CameraInput& input, double boxScale) {
    // A pending reset means zoom 1.0 was rendered since the last session: start from scratch.
    if (state.resetCameraState) {
        state.resetCameraState = false;
        // The whole monitor is the camera of an unzoomed view, and level 1.0 its zoom.
        state.camera        = Box{0.0, 0.0, input.monitorSize.x, input.monitorSize.y};
        state.lastZoomLevel = 1.0F;
    }
    // The previous camera is the frame of reference for the pointer's world position.
    const Box oldCamera = state.camera;
    // Floats on purpose: Hyprland computes the anchor in float, and margin 0.05 must match it.
    const float fractionX = static_cast<float>(input.pointer.x / input.monitorSize.x);
    const float fractionY = static_cast<float>(input.pointer.y / input.monitorSize.y);
    // World-space point currently under the pointer.
    const float worldX = static_cast<float>(oldCamera.x + (fractionX * oldCamera.w));
    const float worldY = static_cast<float>(oldCamera.y + (fractionY * oldCamera.h));
    // The new view is the monitor divided by the zoom.
    const double newWidth  = input.monitorSize.x / input.zoom;
    const double newHeight = input.monitorSize.y / input.zoom;
    // Same world point under the same screen fraction, with the new (smaller) view size.
    const float newX = static_cast<float>(worldX - (fractionX * newWidth));
    const float newY = static_cast<float>(worldY - (fractionY * newHeight));
    state.camera     = Box{newX, newY, newWidth, newHeight};
    // A zoom step that already strands the pointer outside the safe box must not make it jerk.
    if (!containsPoint(scaleFromCenter(state.camera, boxScale), input.pointer))
        state.padCamEdges = false;
    // Remember the level so the next frame only re-anchors when the zoom changes again.
    state.lastZoomLevel = input.zoom;
}

/// Pans the camera just far enough that the pointer is back inside the safe box.
/// @param state Camera state, updated in place.
/// @param pointer Zoom anchor (pointer position inside the monitor).
/// @param safeBox The camera box shrunk by the margin; the pointer is pulled into it.
inline void panTowardsPointer(CameraState& state, const Vec2& pointer, const Box& safeBox) {
    // Each axis moves by exactly the overshoot, so the pointer ends on the safe-box border.
    if (pointer.x < safeBox.x)
        state.camera.x -= safeBox.x - pointer.x;
    if (pointer.y < safeBox.y)
        state.camera.y -= safeBox.y - pointer.y;
    // Bottom and right overshoots move the camera the other way.
    if (pointer.y > safeBox.y + safeBox.h)
        state.camera.y += pointer.y - (safeBox.y + safeBox.h);
    if (pointer.x > safeBox.x + safeBox.w)
        state.camera.x += pointer.x - (safeBox.x + safeBox.w);
}

/// Advances the camera for one frame (the replacement for zoomWithDetachedCamera's maths).
/// @param state Camera state, updated in place.
/// @param input Frame input (pointer, monitor size, zoom, margin).
inline void updateCamera(CameraState& state, const CameraInput& input) {
    // The safe-box scale is the one place where the margin enters the maths.
    const double boxScale = safeBoxScale(clampEdgeMargin(input.edgeMargin));
    // Only a zoom change re-anchors; otherwise the camera keeps its position.
    if (state.lastZoomLevel != input.zoom)
        reanchorCamera(state, input, boxScale);

    // Start from the full camera and shrink it to the safe box below.
    Box safeBox = state.camera;
    // Re-enable the padded box only once the pointer is inside it, so a zoom step cannot jerk.
    if (!state.padCamEdges && containsPoint(scaleFromCenter(safeBox, boxScale), input.pointer))
        state.padCamEdges = true;
    // While padding is off, the pointer may roam the whole camera.
    if (state.padCamEdges)
        safeBox = scaleFromCenter(safeBox, boxScale);
    // Rigid mode freezes the camera at the anchor instead of following the pointer.
    if (!input.rigid && !containsPoint(safeBox, input.pointer))
        panTowardsPointer(state, input.pointer, safeBox);
}

/// Projects the camera onto the monitor like Hyprland does before its final edge clamp.
/// @param state Camera state after updateCamera.
/// @param monitorSize Logical monitor size.
/// @param zoom Zoom factor.
/// @param monitorScale Output scale (HiDPI factor); Hyprland multiplies it into the zoom.
/// @return The box the monitor texture is drawn into.
inline Box cameraToMonitorBox(const CameraState& state, const Vec2& monitorSize, float zoom,
                              float monitorScale) {
    // Float product like Hyprland's `ZOOM * m->m_scale`, so HiDPI outputs match bit for bit.
    const double scaledZoom = static_cast<double>(zoom * monitorScale);
    // Scale the monitor box by the zoom, then shift it so the camera origin lands at (0,0).
    return Box{-state.camera.x * scaledZoom, -state.camera.y * scaledZoom,
               monitorSize.x * scaledZoom, monitorSize.y * scaledZoom};
}

} // namespace hyprzoom
