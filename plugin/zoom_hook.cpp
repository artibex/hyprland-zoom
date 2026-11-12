// zoom_hook.cpp — the replacement for CMonitorZoomController::zoomWithDetachedCamera.
//
// All camera maths lives in camera_math.hpp; this file only translates between Hyprland's
// objects and the plain structs of the maths, and decides when the original code runs.
#include "zoom_hook.hpp"

#include "camera_math.hpp"
#include "hook_target.hpp"
#include "plugin_state.hpp"

namespace hyprzoom {

namespace {

using Monitor::CMonitorZoomController;

/// Signature of the hooked member function with `this` spelled out as the first argument.
using ZoomFunction = void (*)(CMonitorZoomController*, CBox&, const Render::SRenderData&);

/// Copies Hyprland's private camera members into the plain state of the maths.
/// @param controller Per-monitor zoom controller.
/// @return Equivalent CameraState.
CameraState readCameraState(const CMonitorZoomController& controller) {
    CameraState state;
    // Field by field, because the two structs are deliberately independent types.
    const CBox& camera = controller.m_camera;
    state.camera       = Box{camera.x, camera.y, camera.w, camera.h};
    // The three scalars have identical meaning in Hyprland and in the maths.
    state.lastZoomLevel    = controller.m_lastZoomLevel;
    state.resetCameraState = controller.m_resetCameraState;
    // The anti-jerk flag must survive hook on/off switches, so it is copied too.
    state.padCamEdges = controller.m_padCamEdges;
    return state;
}

/// Writes the advanced camera state back into Hyprland's private members.
/// @param state Result of updateCamera.
/// @param controller Per-monitor zoom controller, updated in place.
void writeCameraState(const CameraState& state, CMonitorZoomController& controller) {
    // Hyprland reads these members again next frame, so they must stay in sync.
    const Box& camera   = state.camera;
    controller.m_camera = CBox(camera.x, camera.y, camera.w, camera.h);
    // The scalars follow the same rule as the box.
    controller.m_lastZoomLevel    = state.lastZoomLevel;
    controller.m_resetCameraState = state.resetCameraState;
    controller.m_padCamEdges      = state.padCamEdges;
}

/// Reads `plugin:hyprzoom:edge_margin`, falling back to the native margin without a value.
/// @return Margin as stored (the maths clamps it).
double configuredEdgeMargin() {
    // A missing value object only happens during teardown; native behaviour is the safe default.
    const auto& value = pluginState().edgeMargin;
    return value ? static_cast<double>(value->value()) : kNativeEdgeMargin;
}

/// Reads `plugin:hyprzoom:enabled`; an unregistered value counts as enabled.
/// @return False when the user switched the plugin off.
bool pluginEnabled() {
    // Same teardown reasoning as for the margin: only an explicit `false` disables the plugin.
    const auto& value = pluginState().enabled;
    return value ? value->value() : true;
}

/// Runs Hyprland's own implementation (trampoline to the unpatched code).
/// @param controller Per-monitor zoom controller.
/// @param result Output box, filled by the original code.
/// @param renderData Current render data.
void callOriginal(CMonitorZoomController* controller, CBox& result,
                  const Render::SRenderData& renderData) {
    // m_original points at the relocated first instructions followed by a jump back.
    const auto original = reinterpret_cast<ZoomFunction>(pluginState().zoomHook->m_original);
    // The trampoline takes the same arguments as the hooked member function.
    original(controller, result, renderData);
}

/// Collects the per-frame inputs of the maths from Hyprland's state and the config.
/// @param controller Per-monitor zoom controller (provides the anchor).
/// @param renderData Current render data (monitor).
/// @return The frame input for updateCamera.
CameraInput readFrameInput(CMonitorZoomController& controller,
                           const Render::SRenderData& renderData) {
    // Hyprland reads this option the same way; the static binds the lookup once.
    static auto zoomRigid = CConfigValue<Config::INTEGER>("cursor:zoom_rigid");
    // The anchor is the pointer position (or the pinned anchor of a gesture) in the monitor.
    const auto monitor = renderData.pMonitor;
    const auto anchor  = controller.getAnchor(monitor);
    // Translate Hyprland's vector types into the plain structs.
    CameraInput input;
    input.pointer     = {anchor.x, anchor.y};
    input.monitorSize = {monitor->m_size.x, monitor->m_size.y};
    // The zoom factor of the frame being rendered, as Hyprland's own code reads it.
    input.zoom = g_pHyprRenderer->m_renderData.mouseZoomFactor;
    // The user's margin, read fresh so config changes apply on the next frame.
    input.edgeMargin = configuredEdgeMargin();
    input.rigid      = *zoomRigid != 0;
    return input;
}

/// Replacement function: same maths as Hyprland with an adjustable safe-box margin.
/// @param controller Per-monitor zoom controller (the hooked member function's `this`).
/// @param result Output box the monitor texture is drawn into.
/// @param renderData Current render data (monitor, zoom factor).
void hookedZoomWithDetachedCamera(CMonitorZoomController* controller, CBox& result,
                                  const Render::SRenderData& renderData) {
    // Without a monitor or while switched off, the unmodified Hyprland code must run.
    if (!pluginEnabled() || !renderData.pMonitor) {
        callOriginal(controller, result, renderData);
        return;
    }
    // Hyprland state in, plain structs through the maths, Hyprland state out.
    const CameraInput input = readFrameInput(*controller, renderData);
    CameraState state       = readCameraState(*controller);
    updateCamera(state, input);
    // Persist the result so the next frame (and the original code, if re-enabled) continue here.
    writeCameraState(state, *controller);
    // Project the camera like Hyprland does; its caller applies the final monitor clamp.
    const Box box =
        cameraToMonitorBox(state, input.monitorSize, input.zoom, renderData.pMonitor->m_scale);
    result = CBox(box.x, box.y, box.w, box.h);
}

} // namespace

std::optional<std::string> installZoomHook(HANDLE handle) {
    // The search shells out to `nm`; it finds nothing when the symbol is gone or nm is absent.
    std::string error;
    const auto matches = HyprlandAPI::findFunctionsByName(handle, kHookedSymbolName);
    // Exactly one verified match is required, otherwise nothing is hooked.
    const auto target = selectHookTarget(matches, error);
    if (!target)
        return error;
    // Hyprland builds the trampoline; our function receives the calls from then on.
    auto* hook = HyprlandAPI::createFunctionHook(
        handle, *target, reinterpret_cast<void*>(&hookedZoomWithDetachedCamera));
    // hook() patches the function entry; it fails when the prologue cannot be relocated safely.
    if (!hook || !hook->hook())
        return "could not patch the function entry (unsupported prologue?)";
    // Keep the hook: the hook function needs m_original, and removeZoomHook needs the pointer.
    pluginState().zoomHook = hook;
    return std::nullopt;
}

void removeZoomHook(HANDLE handle) {
    // Unhooking restores the original bytes, so the native camera code runs again.
    if (pluginState().zoomHook)
        HyprlandAPI::removeFunctionHook(handle, pluginState().zoomHook);
    // Clear the pointer so a second call (or a late frame) cannot use a dead hook.
    pluginState().zoomHook = nullptr;
}

} // namespace hyprzoom
