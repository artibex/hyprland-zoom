// camera_predict.cpp — prints the camera the plugin's maths predicts for a pointer path.
//
// The nested-Hyprland test measures the real camera from screenshots and compares it with this
// tool's output, so the live result is tied to the very header the plugin is built from.
//
// Usage: camera_predict <margin> <zoom> <width> <height> <scale> <x,y> <x,y>...
//   width/height are the LOGICAL monitor size, scale the output scale (1 for a plain output).
//   The first pointer position is where the zoom-in happens (anchor); every further position
//   is a pointer move at constant zoom. Output: one "x y" line per further position, the
//   camera's top-left in monitor pixels after Hyprland's final keep-inside-the-monitor clamp.
#include "../../plugin/camera_math.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <string>

using namespace hyprzoom;

namespace {

/// Index of the first pointer argument (after program name, margin, zoom, width, height, scale).
constexpr int kFirstPointerArg = 6;

/// Parses "x,y" into a point; exits with a usage error on malformed input.
/// @param text Argument such as "900,500".
/// @return The parsed point.
Vec2 parsePoint(const std::string& text) {
    const auto comma = text.find(',');
    // A missing comma is a caller bug worth failing loudly on.
    if (comma == std::string::npos) {
        std::fprintf(stderr, "camera_predict: '%s' is not x,y\n", text.c_str());
        std::exit(2);
    }
    // Split at the comma and convert both halves.
    const double x = std::atof(text.substr(0, comma).c_str());
    // The second half is everything after the comma.
    const double y = std::atof(text.substr(comma + 1).c_str());
    return Vec2{x, y};
}

/// Applies Hyprland's final clamp (applyZoomTransform) and converts back to a camera origin.
/// @param state Camera after updateCamera.
/// @param input Frame input of the same frame.
/// @param scale Output scale (physical pixels per logical pixel).
/// @return Camera top-left that is actually visible on screen, in logical monitor pixels.
Vec2 visibleCameraOrigin(const CameraState& state, const CameraInput& input, float scale) {
    // The projected box is in physical pixels: the output scale is part of Hyprland's zoom.
    Box box = cameraToMonitorBox(state, input.monitorSize, input.zoom, scale);
    // The view may never leave the monitor: left/top edge at most 0 ...
    box.x = std::min(box.x, 0.0);
    box.y = std::min(box.y, 0.0);
    // ... and right/bottom edge at least at the monitor's (physical) size.
    box.x = std::max(box.x, input.monitorSize.x * scale - box.w);
    box.y = std::max(box.y, input.monitorSize.y * scale - box.h);
    // Back from texture offset to the camera origin in logical monitor pixels.
    const double physicalZoom = static_cast<double>(input.zoom * scale);
    return Vec2{-box.x / physicalZoom, -box.y / physicalZoom};
}

} // namespace

/// Entry point: anchors at the first point, then prints the camera after each further move.
int main(int argc, char** argv) {
    // The four numbers and at least the anchor are required.
    if (argc <= kFirstPointerArg) {
        std::fprintf(stderr, "usage: camera_predict margin zoom width height scale x,y x,y...\n");
        return 2;
    }
    CameraInput input;
    // Fixed parameters of the whole path, taken from the command line.
    input.edgeMargin  = std::atof(argv[1]);
    input.zoom        = static_cast<float>(std::atof(argv[2]));
    input.monitorSize = {std::atof(argv[3]), std::atof(argv[4])};
    // The output scale enters Hyprland's zoom product and the final clamp.
    const auto scale = static_cast<float>(std::atof(argv[5]));

    // One state for the whole path: the camera persists between frames, like in Hyprland.
    CameraState state;
    for (int index = kFirstPointerArg; index < argc; ++index) {
        // One frame per pointer position; the anchor frame sets the camera up.
        input.pointer = parsePoint(argv[index]);
        updateCamera(state, input);
        // The anchor frame is only setup; every later frame is a measurable result.
        if (index > kFirstPointerArg) {
            const Vec2 origin = visibleCameraOrigin(state, input, scale);
            std::printf("%.2f %.2f\n", origin.x, origin.y);
        }
    }
    return 0;
}
