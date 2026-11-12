// zoom_hook.cpp — the replacement for CMonitorZoomController::zoomWithDetachedCamera.
// Hyprland 0.56 and 0.57 pass different arguments to that function; the two hook entry points
// below only differ in how they obtain the monitor and the zoom factor (FrameView).
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

/// What the hook needs to know about the frame being rendered, independent of the Hyprland
/// generation (0.56 passes SRenderData, 0.57 a CRenderContext).
struct FrameView {
    decltype(Render::SRenderData::pMonitor) monitor; ///< Monitor the frame is drawn for.
    float zoom;                                      ///< Zoom factor of the frame.
};

#if HYPRZOOM_API_GENERATION == 2
/// Signature of the hooked member function in Hyprland 0.57.x, `this` spelled out.
using ZoomFunction = void (*)(CMonitorZoomController*, Render::CRenderContext&, CBox&);
#else
/// Signature of the hooked member function in Hyprland 0.56.x, `this` spelled out.
using ZoomFunction = void (*)(CMonitorZoomController*, CBox&, const Render::SRenderData&);
#endif

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

/// The trampoline to Hyprland's unpatched function, typed for this generation.
/// @return Function pointer that runs the original code.
ZoomFunction originalFunction() {
    // m_original points at the relocated first instructions followed by a jump back.
    return reinterpret_cast<ZoomFunction>(pluginState().zoomHook->m_original);
}

/// Collects the per-frame inputs of the maths from Hyprland's state and the config.
/// @param controller Per-monitor zoom controller (provides the anchor).
/// @param frame Monitor and zoom factor of the frame being rendered.
/// @return The frame input for updateCamera.
CameraInput readFrameInput(CMonitorZoomController& controller, const FrameView& frame) {
    // Hyprland reads this option the same way; the static binds the lookup once.
    static auto zoomRigid = CConfigValue<Config::INTEGER>("cursor:zoom_rigid");
    // The anchor is the pointer position (or the pinned anchor of a gesture) in the monitor.
    const auto monitor = frame.monitor;
    const auto anchor  = controller.getAnchor(monitor);
    // Translate Hyprland's vector types into the plain structs.
    CameraInput input;
    input.pointer     = {anchor.x, anchor.y};
    input.monitorSize = {monitor->m_size.x, monitor->m_size.y};
    // The zoom factor of the frame being rendered, as Hyprland's own code reads it.
    input.zoom = frame.zoom;
    // The user's margin, read fresh so config changes apply on the next frame.
    input.edgeMargin = configuredEdgeMargin();
    input.rigid      = *zoomRigid != 0;
    return input;
}

/// Replacement for the camera part: same maths as Hyprland with an adjustable safe-box margin.
/// @param controller Per-monitor zoom controller (the hooked member function's `this`).
/// @param result Output box the monitor texture is drawn into.
/// @param frame Monitor and zoom factor of the frame being rendered.
void updateAndProject(CMonitorZoomController& controller, CBox& result, const FrameView& frame) {
    // Hyprland state in, plain structs through the maths, Hyprland state out.
    const CameraInput input = readFrameInput(controller, frame);
    CameraState state       = readCameraState(controller);
    updateCamera(state, input);
    // Persist the result so the next frame (and the original code, if re-enabled) continue here.
    writeCameraState(state, controller);
    // Project the camera like Hyprland does; its caller applies the final monitor clamp.
    const Box box = cameraToMonitorBox(state, input.monitorSize, input.zoom, frame.monitor->m_scale);
    result        = CBox(box.x, box.y, box.w, box.h);
}

/// Tells whether the hook must hand the frame to Hyprland's own code.
/// @param frame Monitor and zoom factor of the frame.
/// @return True while switched off or without a monitor.
bool useNativeCamera(const FrameView& frame) {
    // Without a monitor or while switched off, the unmodified Hyprland code must run.
    return !pluginEnabled() || !frame.monitor;
}

#if HYPRZOOM_API_GENERATION == 2
/// Hook for Hyprland 0.57.x: `zoomWithDetachedCamera(CRenderContext&, CBox&)`.
/// @param controller Per-monitor zoom controller (the hooked member function's `this`).
/// @param context Render context of the frame; its `m_data` holds monitor and zoom factor.
/// @param result Output box the monitor texture is drawn into.
void hookedZoomWithDetachedCamera(CMonitorZoomController* controller,
                                  Render::CRenderContext& context, CBox& result) {
    // 0.57 keeps the per-frame data in the context that is passed in.
    const FrameView frame{context.m_data.pMonitor, context.m_data.mouseZoomFactor};
    if (useNativeCamera(frame)) {
        originalFunction()(controller, context, result);
        return;
    }
    updateAndProject(*controller, result, frame);
}
#else
/// Hook for Hyprland 0.56.x: `zoomWithDetachedCamera(CBox&, const SRenderData&)`.
/// @param controller Per-monitor zoom controller (the hooked member function's `this`).
/// @param result Output box the monitor texture is drawn into.
/// @param renderData Current render data (monitor).
void hookedZoomWithDetachedCamera(CMonitorZoomController* controller, CBox& result,
                                  const Render::SRenderData& renderData) {
    // 0.56 reads the zoom factor from the renderer's own data, as Hyprland's function does.
    const FrameView frame{renderData.pMonitor, g_pHyprRenderer->m_renderData.mouseZoomFactor};
    if (useNativeCamera(frame)) {
        originalFunction()(controller, result, renderData);
        return;
    }
    updateAndProject(*controller, result, frame);
}
#endif

} // namespace

/// Hooks CMonitorZoomController::zoomWithDetachedCamera for the Hyprland generation built for.
/// @param handle Plugin handle.
/// @return std::nullopt on success, otherwise the reason (nothing was hooked).
std::optional<std::string> installZoomHook(HANDLE handle) {
    // The search shells out to `nm`; it finds nothing when the symbol is gone or nm is absent.
    std::string error;
    const auto matches = HyprlandAPI::findFunctionsByName(handle, kHookedSymbolName);
    // Exactly one verified match is required, otherwise nothing is hooked.
    const auto target = selectHookTarget(matches, kBuiltFor, error);
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

/// Removes the hook again; safe to call when it was never installed.
/// @param handle Plugin handle.
void removeZoomHook(HANDLE handle) {
    // Unhooking restores the original bytes, so the native camera code runs again.
    if (pluginState().zoomHook)
        HyprlandAPI::removeFunctionHook(handle, pluginState().zoomHook);
    // Clear the pointer so a second call (or a late frame) cannot use a dead hook.
    pluginState().zoomHook = nullptr;
}

} // namespace hyprzoom
