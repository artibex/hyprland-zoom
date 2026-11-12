// camera_math_test.cpp — unit tests for plugin/camera_math.hpp (plain g++, no Hyprland).
//
// Expected numbers come from the S1 spike (Hyprland 0.56.2, 1280x720, zoom 2): native edge-push
// leaves the camera at x=492,y=258 for a pointer at (1100,600). Larger margins are derived by
// hand in the comments next to each case.
#include "../../plugin/camera_math.hpp"

#include <cmath>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

using namespace hyprzoom;

namespace {

/// One registered test case.
struct TestCase {
    std::string           name; ///< Shown in the report.
    std::function<void()> body; ///< Throws via check() on the first failed expectation.
};

/// Number of failed expectations in the running case.
int g_failures = 0;

/// Records a failed expectation without aborting the run, so one report lists all problems.
/// @param condition Expectation result.
/// @param message Text printed when the expectation fails.
void check(bool condition, const std::string& message) {
    // Print the failure at once; the summary only needs the counter.
    if (!condition) {
        std::printf("    FAIL: %s\n", message.c_str());
        ++g_failures;
    }
}

/// Compares two doubles with a tolerance and reports both values on mismatch.
/// @param actual Computed value.
/// @param expected Value the contract demands.
/// @param label What is being compared.
/// @param tolerance Allowed absolute difference.
void checkNear(double actual, double expected, const std::string& label, double tolerance = 0.01) {
    const bool close = std::fabs(actual - expected) <= tolerance;
    check(close, label + ": got " + std::to_string(actual) + ", expected " + std::to_string(expected));
}

/// Builds the standard 1280x720, zoom 2 input used by the S1 measurements.
/// @param pointer Pointer position inside the monitor.
/// @param margin Edge margin under test.
/// @return Ready-to-use frame input.
CameraInput inputAt(Vec2 pointer, double margin) {
    CameraInput input;
    input.pointer     = pointer;
    input.monitorSize = {1280.0, 720.0};
    input.zoom        = 2.0F;
    input.edgeMargin  = margin;
    return input;
}

/// Anchors a fresh camera at (300,200) like the S1 probe does right after zooming in.
/// @param margin Edge margin under test.
/// @return Camera state after the first frame.
CameraState zoomedInAtAnchor(double margin) {
    CameraState state;
    updateCamera(state, inputAt({300.0, 200.0}, margin));
    return state;
}

/// Anchors a fresh camera at the monitor centre, where every margin starts out padded.
/// @param margin Edge margin under test.
/// @return Camera state after the first frame.
CameraState zoomedInAtCentre(double margin) {
    CameraState state;
    updateCamera(state, inputAt({640.0, 360.0}, margin));
    return state;
}

/// Moves the pointer on an existing camera and runs one frame.
/// @param state Camera to advance.
/// @param pointer New pointer position.
/// @param margin Edge margin under test.
void movePointer(CameraState& state, Vec2 pointer, double margin) {
    updateCamera(state, inputAt(pointer, margin));
}

/// All test cases, in the order they are reported.
std::vector<TestCase> buildCases() {
    std::vector<TestCase> cases;

    cases.push_back({"anchor: zoom-in keeps the pointer's world point under the pointer", [] {
        const CameraState state = zoomedInAtAnchor(0.05);
        // The view is 640x360; the pointer sits at 300/1280 and 200/720 of it.
        checkNear(state.camera.x, 150.0, "camera.x");
        checkNear(state.camera.y, 100.0, "camera.y");
        checkNear(state.camera.w, 640.0, "camera.w");
        checkNear(state.camera.h, 360.0, "camera.h");
    }});

    cases.push_back({"margin 0.05 reproduces native edge-push numbers (S1 Q7)", [] {
        CameraState state = zoomedInAtAnchor(0.05);
        movePointer(state, {640.0, 360.0}, 0.05);
        // (640,360) is inside the 0.9 box x 182..758, y 118..442: no pan.
        checkNear(state.camera.x, 150.0, "camera.x at centre");
        checkNear(state.camera.y, 100.0, "camera.y at centre");
        movePointer(state, {1100.0, 600.0}, 0.05);
        // Overshoot 1100-758 = 342 and 600-442 = 158 -> 492 / 258, the measured native values.
        checkNear(state.camera.x, 492.0, "camera.x at (1100,600)");
        checkNear(state.camera.y, 258.0, "camera.y at (1100,600)");
    }});

    cases.push_back({"margin 0.30 pans earlier than native", [] {
        // Anchored at the monitor centre the camera is x 320..960, y 180..540.
        CameraState wide   = zoomedInAtCentre(0.05);
        CameraState narrow = zoomedInAtCentre(0.30);
        movePointer(wide, {800.0, 360.0}, 0.05);
        movePointer(narrow, {800.0, 360.0}, 0.30);
        // Native safe box reaches x=928: no pan. The 0.30 box ends at 768: pans by 32.
        checkNear(wide.camera.x, 320.0, "native camera.x");
        checkNear(narrow.camera.x, 352.0, "margin 0.30 camera.x");
        movePointer(narrow, {1100.0, 600.0}, 0.30);
        // After a pan the pointer rests on the safe-box rim: camera = pointer - 0.7 * view.
        checkNear(narrow.camera.x, 652.0, "camera.x at (1100,600)");
        checkNear(narrow.camera.y, 348.0, "camera.y at (1100,600)");
    }});

    cases.push_back({"margin 0.45 keeps the pointer within 10 % of the view centre", [] {
        CameraState state = zoomedInAtCentre(0.45);
        movePointer(state, {1100.0, 600.0}, 0.45);
        // Safe box is 64x36: the pointer ends on its bottom-right corner, 32/18 from the centre.
        checkNear(1100.0 - (state.camera.x + state.camera.w / 2.0), 32.0, "pointer offset x");
        checkNear(600.0 - (state.camera.y + state.camera.h / 2.0), 18.0, "pointer offset y");
    }});

    cases.push_back({"larger margin always keeps the pointer nearer the view centre", [] {
        double previousDistance = 1.0e9;
        for (double margin : {0.0, 0.05, 0.15, 0.30, 0.45}) {
            CameraState state = zoomedInAtCentre(margin);
            movePointer(state, {1100.0, 600.0}, margin);
            const double distance = std::fabs(1100.0 - (state.camera.x + state.camera.w / 2.0));
            check(distance < previousDistance, "distance must shrink at margin " + std::to_string(margin));
            previousDistance = distance;
        }
    }});

    cases.push_back({"anti-jerk: zooming in off-centre defers the margin until the pointer enters it", [] {
        CameraState state = zoomedInAtAnchor(0.30);
        // The anchor (300,200) lies outside the 0.30 safe box, so the padded box stays off.
        check(!state.padCamEdges, "padding must start disabled");
        movePointer(state, {640.0, 360.0}, 0.30);
        checkNear(state.camera.x, 150.0, "camera.x does not jerk");
        // The camera centre (470,280) is inside the safe box: padding engages, no pan yet.
        movePointer(state, {470.0, 280.0}, 0.30);
        check(state.padCamEdges, "padding must engage inside the safe box");
        movePointer(state, {1100.0, 600.0}, 0.30);
        checkNear(state.camera.x, 652.0, "camera.x once padded");
    }});

    cases.push_back({"margin 0.00 pans only when the pointer leaves the view", [] {
        CameraState state = zoomedInAtAnchor(0.0);
        movePointer(state, {1000.0, 360.0}, 0.0);
        // View spans x 150..790 and y 100..460; x=1000 overshoots by exactly 210.
        checkNear(state.camera.x, 360.0, "camera.x");
        checkNear(state.camera.y, 100.0, "camera.y untouched");
    }});

    cases.push_back({"margin is clamped to 0.00..0.45 and NaN means native", [] {
        checkNear(clampEdgeMargin(-1.0), 0.0, "negative");
        checkNear(clampEdgeMargin(0.9), 0.45, "too large");
        checkNear(clampEdgeMargin(0.2), 0.2, "in range");
        checkNear(clampEdgeMargin(std::nan("")), 0.05, "NaN");
        checkNear(safeBoxScale(0.05), 0.9, "native box scale", 1e-12);
    }});

    cases.push_back({"rigid mode never pans", [] {
        CameraState state;
        CameraInput input = inputAt({300.0, 200.0}, 0.30);
        input.rigid       = true;
        updateCamera(state, input);
        input.pointer = {1100.0, 600.0};
        updateCamera(state, input);
        checkNear(state.camera.x, 150.0, "camera.x");
        checkNear(state.camera.y, 100.0, "camera.y");
    }});

    cases.push_back({"anti-jerk: a zoom step that strands the pointer does not pan until it returns", [] {
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
    }});

    cases.push_back({"projection matches Hyprland's monbox.scale(z).translate(-cam*z)", [] {
        const CameraState state = zoomedInAtAnchor(0.05);
        const Box         box   = cameraToMonitorBox(state, {1280.0, 720.0}, 2.0F, 1.0F);
        checkNear(box.x, -300.0, "box.x");
        checkNear(box.y, -200.0, "box.y");
        checkNear(box.w, 2560.0, "box.w");
        checkNear(box.h, 1440.0, "box.h");
    }});

    return cases;
}

} // namespace

/// Runs every case and prints a summary; exit code 1 when anything failed.
int main() {
    int failedCases = 0;
    const auto cases = buildCases();
    for (const auto& testCase : cases) {
        // Count failures per case so the report can name the culprit.
        const int failuresBefore = g_failures;
        testCase.body();
        const bool passed = g_failures == failuresBefore;
        std::printf("%s %s\n", passed ? "ok  " : "FAIL", testCase.name.c_str());
        failedCases += passed ? 0 : 1;
    }
    std::printf("%zu cases, %d failed\n", cases.size(), failedCases);
    return failedCases == 0 ? 0 : 1;
}
