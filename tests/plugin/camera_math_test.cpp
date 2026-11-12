// camera_math_test.cpp — unit tests for plugin/camera_math.hpp (plain g++, no Hyprland).
//
// Expected numbers come from the S1 spike (Hyprland 0.56.2, 1280x720, zoom 2): native edge-push
// leaves the camera at x=492,y=258 for a pointer at (1100,600). Larger margins are derived by
// hand in the comments next to each case. Once the view has panned, the pointer rests on the
// safe-box border, so camera = pointer - (1 - margin) * view size on each far edge.
#include "../../plugin/camera_math.hpp"
#include "mini_test.hpp"

#include <cmath>
#include <string>
#include <vector>

using namespace hyprzoom;
using minitest::check;
using minitest::checkNear;

namespace {

/// Builds the standard 1280x720, zoom 2 input used by the S1 measurements.
/// @param pointer Pointer position inside the monitor.
/// @param margin Edge margin under test.
/// @return Ready-to-use frame input.
CameraInput inputAt(Vec2 pointer, double margin) {
    CameraInput input;
    // The pointer and the monitor geometry are fixed per measurement.
    input.pointer     = pointer;
    input.monitorSize = {1280.0, 720.0};
    // Zoom and margin are the parameters under test; everything else keeps its default.
    input.zoom       = 2.0F;
    input.edgeMargin = margin;
    return input;
}

/// Anchors a fresh camera at (300,200) like the S1 probe does right after zooming in.
/// @param margin Edge margin under test.
/// @return Camera state after the first frame.
CameraState zoomedInAtAnchor(double margin) {
    CameraState state;
    // The first frame re-anchors: the world point under the pointer stays under it.
    updateCamera(state, inputAt({300.0, 200.0}, margin));
    return state;
}

/// Anchors a fresh camera at the monitor centre, where every margin starts out padded.
/// @param margin Edge margin under test.
/// @return Camera state after the first frame.
CameraState zoomedInAtCentre(double margin) {
    CameraState state;
    // At the centre the pointer is inside every safe box, so the margin is active at once.
    updateCamera(state, inputAt({640.0, 360.0}, margin));
    return state;
}

/// Moves the pointer on an existing camera and runs one frame.
/// @param state Camera to advance.
/// @param pointer New pointer position.
/// @param margin Edge margin under test.
void movePointer(CameraState& state, Vec2 pointer, double margin) {
    // The zoom stays at 2.0, so no re-anchoring happens, only panning.
    updateCamera(state, inputAt(pointer, margin));
}

/// Case: the first zoom frame anchors the camera at the pointer.
void testAnchor() {
    const CameraState state = zoomedInAtAnchor(0.05);
    // The view is 640x360; the pointer sits at 300/1280 and 200/720 of it.
    checkNear(state.camera.x, 150.0, "camera.x");
    checkNear(state.camera.y, 100.0, "camera.y");
    // The size is the monitor divided by the zoom.
    checkNear(state.camera.w, 640.0, "camera.w");
    checkNear(state.camera.h, 360.0, "camera.h");
}

/// Case: margin 0.05 gives the numbers measured on native Hyprland.
void testNativeNumbers() {
    CameraState state = zoomedInAtAnchor(0.05);
    movePointer(state, {640.0, 360.0}, 0.05);
    // (640,360) is inside the 0.9 box x 182..758, y 118..442: no pan.
    checkNear(state.camera.x, 150.0, "camera.x at centre");
    checkNear(state.camera.y, 100.0, "camera.y at centre");
    movePointer(state, {1100.0, 600.0}, 0.05);
    // Overshoot 1100-758 = 342 and 600-442 = 158 -> 492 / 258, the measured native values.
    checkNear(state.camera.x, 492.0, "camera.x at (1100,600)");
    checkNear(state.camera.y, 258.0, "camera.y at (1100,600)");
}

/// Case: a larger margin makes the camera follow earlier than native.
void testLargerMarginPansEarlier() {
    // Anchored at the monitor centre the camera is x 320..960, y 180..540.
    CameraState wide   = zoomedInAtCentre(0.05);
    CameraState narrow = zoomedInAtCentre(0.30);
    // Both cameras see the same pointer move to the right.
    movePointer(wide, {800.0, 360.0}, 0.05);
    movePointer(narrow, {800.0, 360.0}, 0.30);
    // Native safe box reaches x=928: no pan. The 0.30 box ends at 768: pans by 32.
    checkNear(wide.camera.x, 320.0, "native camera.x");
    checkNear(narrow.camera.x, 352.0, "margin 0.30 camera.x");
    // A far move to the bottom right pans the narrow camera on both axes.
    movePointer(narrow, {1100.0, 600.0}, 0.30);
    // After a pan the pointer rests on the safe-box rim: camera = pointer - 0.7 * view.
    checkNear(narrow.camera.x, 652.0, "camera.x at (1100,600)");
    checkNear(narrow.camera.y, 348.0, "camera.y at (1100,600)");
}

/// Case: margin 0.45 keeps the pointer within 10 % of the view centre.
void testMaximumMarginIsNearlyCentred() {
    CameraState state = zoomedInAtCentre(0.45);
    movePointer(state, {1100.0, 600.0}, 0.45);
    // Safe box is 64x36: the pointer ends on its bottom-right corner, 32/18 from the centre.
    checkNear(1100.0 - (state.camera.x + state.camera.w / 2.0), 32.0, "pointer offset x");
    checkNear(600.0 - (state.camera.y + state.camera.h / 2.0), 18.0, "pointer offset y");
}

/// Case: the pointer-to-centre distance shrinks monotonically with the margin.
void testMonotonicInMargin() {
    double previousDistance = 1.0e9;
    for (double margin : {0.0, 0.05, 0.15, 0.30, 0.45}) {
        CameraState state = zoomedInAtCentre(margin);
        movePointer(state, {1100.0, 600.0}, margin);
        // Distance of the pointer from the horizontal view centre after panning.
        const double distance = std::fabs(1100.0 - (state.camera.x + state.camera.w / 2.0));
        check(distance < previousDistance,
              "distance must shrink at margin " + std::to_string(margin));
        previousDistance = distance;
    }
}

/// Case: zooming in away from the centre defers the margin (anti-jerk), then engages it.
void testAntiJerkAtAnchor() {
    CameraState state = zoomedInAtAnchor(0.30);
    // The anchor (300,200) lies outside the 0.30 safe box, so the padded box stays off.
    check(!state.padCamEdges, "padding must start disabled");
    // Moving to the screen centre must not pan the camera.
    movePointer(state, {640.0, 360.0}, 0.30);
    checkNear(state.camera.x, 150.0, "camera.x does not jerk");
    // The camera centre (470,280) is inside the safe box: padding engages, no pan yet.
    movePointer(state, {470.0, 280.0}, 0.30);
    check(state.padCamEdges, "padding must engage inside the safe box");
    // From now on the margin applies in full.
    movePointer(state, {1100.0, 600.0}, 0.30);
    checkNear(state.camera.x, 652.0, "camera.x once padded");
}

/// Case: margin 0 pans only when the pointer would leave the view.
void testZeroMargin() {
    CameraState state = zoomedInAtAnchor(0.0);
    movePointer(state, {1000.0, 360.0}, 0.0);
    // View spans x 150..790 and y 100..460; x=1000 overshoots by exactly 210.
    checkNear(state.camera.x, 360.0, "camera.x");
    checkNear(state.camera.y, 100.0, "camera.y untouched");
}

/// Case: out-of-range margins are clamped and NaN means native.
void testClamping() {
    checkNear(clampEdgeMargin(-1.0), 0.0, "negative");
    checkNear(clampEdgeMargin(0.9), 0.45, "too large");
    // In-range values pass through untouched.
    checkNear(clampEdgeMargin(0.2), 0.2, "in range");
    checkNear(clampEdgeMargin(std::nan("")), 0.05, "NaN");
    // The native margin must map to exactly Hyprland's literal 0.9.
    checkNear(safeBoxScale(0.05), 0.9, "native box scale", 1e-12);
}

/// Case: rigid mode (cursor:zoom_rigid) freezes the camera at the anchor.
void testRigidNeverPans() {
    // Anchor the camera in rigid mode.
    CameraState state;
    CameraInput input = inputAt({300.0, 200.0}, 0.30);
    input.rigid       = true;
    updateCamera(state, input);
    // Moving far away must not move the camera in rigid mode.
    input.pointer = {1100.0, 600.0};
    updateCamera(state, input);
    checkNear(state.camera.x, 150.0, "camera.x");
    checkNear(state.camera.y, 100.0, "camera.y");
}

/// Case: a zoom step that strands the pointer does not pan until the pointer returns.
void testAntiJerkAfterZoomStep() {
    // Pan to the bottom right first, so the next zoom step re-anchors near the monitor corner.
    CameraState state = zoomedInAtAnchor(0.05);
    movePointer(state, {1100.0, 600.0}, 0.05);
    // Zoom 2 -> 4 re-anchors on the pointer, which lands on the camera box rim.
    CameraInput zoomed = inputAt({1275.0, 715.0}, 0.05);
    zoomed.zoom        = 4.0F;
    updateCamera(state, zoomed);
    check(!state.padCamEdges, "padded box must be disabled after a stranding zoom step");
    const Box before = state.camera;
    // The pointer sits outside the padded box but inside the camera: no pan, no jerk.
    updateCamera(state, zoomed);
    checkNear(state.camera.x, before.x, "camera.x stays");
    checkNear(state.camera.y, before.y, "camera.y stays");
    // Moving it back inside the safe box re-enables the padding.
    zoomed.pointer = {before.x + before.w / 2.0, before.y + before.h / 2.0};
    updateCamera(state, zoomed);
    check(state.padCamEdges, "padding returns once the pointer is inside the safe box");
}

/// Case: the projection equals Hyprland's `monbox.scale(z).translate(-cam * z)`.
void testProjection() {
    const CameraState state = zoomedInAtAnchor(0.05);
    const Box box           = cameraToMonitorBox(state, {1280.0, 720.0}, 2.0F, 1.0F);
    // The camera origin (150,100) times zoom 2, negated, is where the texture starts.
    checkNear(box.x, -300.0, "box.x");
    checkNear(box.y, -200.0, "box.y");
    // The texture is drawn at twice the monitor size.
    checkNear(box.w, 2560.0, "box.w");
    checkNear(box.h, 1440.0, "box.h");
}

/// Case: the safe box includes its left/top edge and excludes its right/bottom edge.
void testContainsPointIsHalfOpen() {
    const Box box{10.0, 20.0, 100.0, 50.0};
    // Left and top edges are inside, like CBox::containsPoint.
    check(containsPoint(box, {10.0, 20.0}), "top-left corner is inside");
    check(containsPoint(box, {10.0, 69.9}), "left edge is inside");
    // The right edge (x = 110) and the bottom edge (y = 70) are outside.
    check(!containsPoint(box, {110.0, 30.0}), "right edge is outside");
    check(!containsPoint(box, {50.0, 70.0}), "bottom edge is outside");
}

/// Case: a pointer exactly on the safe box's right edge does not re-enable the padding.
void testPaddingNeedsThePointerStrictlyInside() {
    // A stranding zoom step switches the padding off (see the anti-jerk cases).
    CameraState state = zoomedInAtAnchor(0.30);
    check(!state.padCamEdges, "padding starts disabled");
    // The camera is x 150..790, y 100..460; the 0.30 safe box spans x 342..598 (exclusive end).
    movePointer(state, {598.0, 280.0}, 0.30);
    check(!state.padCamEdges, "a pointer ON the right edge is outside the safe box");
    // One pixel further in, the padding engages.
    movePointer(state, {597.0, 280.0}, 0.30);
    check(state.padCamEdges, "a pointer inside the safe box engages the padding");
}

/// Case: the camera pans left and up as well (the mirror of the right/down cases).
void testPansLeftAndUp() {
    CameraState state = zoomedInAtCentre(0.30);
    // The camera is x 320..960, y 180..540; the 0.30 safe box is x 512..768, y 288..432.
    movePointer(state, {100.0, 50.0}, 0.30);
    // Overshoot 512-100 = 412 to the left and 288-50 = 238 upwards.
    checkNear(state.camera.x, -92.0, "camera.x pans left");
    checkNear(state.camera.y, -58.0, "camera.y pans up");
}

/// All test cases, in the order they are reported.
std::vector<minitest::TestCase> buildCases() {
    return {
        {"anchor: zoom-in keeps the pointer's world point under the pointer", testAnchor},
        {"margin 0.05 reproduces native edge-push numbers (S1 Q7)", testNativeNumbers},
        {"margin 0.30 pans earlier than native", testLargerMarginPansEarlier},
        {"margin 0.45 keeps the pointer within 10 % of the view centre",
         testMaximumMarginIsNearlyCentred},
        {"larger margin always keeps the pointer nearer the view centre", testMonotonicInMargin},
        {"anti-jerk: off-centre zoom-in defers the margin until the pointer enters it",
         testAntiJerkAtAnchor},
        {"margin 0.00 pans only when the pointer leaves the view", testZeroMargin},
        {"margin is clamped to 0.00..0.45 and NaN means native", testClamping},
        {"rigid mode never pans", testRigidNeverPans},
        {"anti-jerk: a stranding zoom step does not pan until the pointer returns",
         testAntiJerkAfterZoomStep},
        {"projection matches Hyprland's monbox.scale(z).translate(-cam*z)", testProjection},
        {"containsPoint is half-open: left/top in, right/bottom out", testContainsPointIsHalfOpen},
        {"padding re-engages only for a pointer strictly inside the safe box",
         testPaddingNeedsThePointerStrictlyInside},
        {"the camera pans left and up", testPansLeftAndUp},
    };
}

} // namespace

/// Runs every case; exit code 1 when anything failed.
int main() {
    return minitest::runAll(buildCases());
}
