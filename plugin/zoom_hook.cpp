// zoom_hook.cpp — the replacement for CMonitorZoomController::zoomWithDetachedCamera.
//
// All camera maths lives in camera_math.hpp; this file only translates between Hyprland's
// objects and the plain structs of the maths, and decides when the original code runs.
#include "zoom_hook.hpp"

#include "camera_math.hpp"
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
    state.camera           = Box{controller.m_camera.x, controller.m_camera.y,
                                 controller.m_camera.w, controller.m_camera.h};
    state.lastZoomLevel    = controller.m_lastZoomLevel;
    state.resetCameraState = controller.m_resetCameraState;
    state.padCamEdges      = controller.m_padCamEdges;
    return state;
}

/// Writes the advanced camera state back into Hyprland's private members.
/// @param state Result of updateCamera.
/// @param controller Per-monitor zoom controller, updated in place.
void writeCameraState(const CameraState& state, CMonitorZoomController& controller) {
    // The native code reads these members again next frame, so they must stay in sync.
    controller.m_camera           = CBox(state.camera.x, state.camera.y, state.camera.w, state.camera.h);
    controller.m_lastZoomLevel    = state.lastZoomLevel;
    controller.m_resetCameraState = state.resetCameraState;
    controller.m_padCamEdges      = state.padCamEdges;
}

/// Reads `plugin:hyprzoom:edge_margin`, falling back to the native margin without a value.
/// @return Margin as stored (the maths clamps it).
double configuredEdgeMargin() {
    const auto& value = pluginState().edgeMargin;
    return value ? static_cast<double>(value->value()) : kNativeEdgeMargin;
}

/// Reads `plugin:hyprzoom:enabled`; an unregistered value counts as enabled.
/// @return False when the user switched the plugin off.
bool pluginEnabled() {
    const auto& value = pluginState().enabled;
    return value ? value->value() : true;
}

/// Runs Hyprland's own implementation (trampoline to the unpatched code).
/// @param controller Per-monitor zoom controller.
/// @param result Output box, filled by the original code.
/// @param renderData Current render data.
void callOriginal(CMonitorZoomController* controller, CBox& result, const Render::SRenderData& renderData) {
    // m_original points at the relocated first instructions followed by a jump back.
    const auto original = reinterpret_cast<ZoomFunction>(pluginState().zoomHook->m_original);
    original(controller, result, renderData);
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
    static auto zoomRigid = CConfigValue<Config::INTEGER>("cursor:zoom_rigid");

    const auto  monitor = renderData.pMonitor;
    const auto  anchor  = controller->getAnchor(monitor);
    CameraInput input;
    input.pointer     = {anchor.x, anchor.y};
    input.monitorSize = {monitor->m_size.x, monitor->m_size.y};
    input.zoom        = g_pHyprRenderer->m_renderData.mouseZoomFactor;
    input.edgeMargin  = configuredEdgeMargin();
    input.rigid       = *zoomRigid != 0;

    CameraState state = readCameraState(*controller);
    updateCamera(state, input);
    writeCameraState(state, *controller);

    const Box box = cameraToMonitorBox(state, input.monitorSize, input.zoom, monitor->m_scale);
    result        = CBox(box.x, box.y, box.w, box.h);
}

} // namespace

std::optional<void*> selectHookTarget(const std::vector<SFunctionMatch>& matches, std::string& error) {
    // More than one candidate means the symbol table changed shape: refuse rather than guess.
    if (matches.size() != 1) {
        error = std::format("expected exactly one '{}' symbol in Hyprland, found {}", kHookedSymbolName,
                            matches.size());
        return std::nullopt;
    }
    // The substring search is loose; the demangled name proves it is the intended member function.
    if (!matches.front().demangled.contains(kHookedDemangledName)) {
        error = std::format("symbol '{}' is not {}", matches.front().demangled, kHookedDemangledName);
        return std::nullopt;
    }
    return matches.front().address;
}

std::optional<std::string> installZoomHook(HANDLE handle) {
    std::string error;
    // The search shells out to `nm`; it returns nothing when the symbol is missing or nm is absent.
    const auto  target = selectHookTarget(HyprlandAPI::findFunctionsByName(handle, kHookedSymbolName), error);
    if (!target)
        return error;

    auto* hook = HyprlandAPI::createFunctionHook(handle, *target, reinterpret_cast<void*>(&hookedZoomWithDetachedCamera));
    // hook() patches the function entry; it fails when the prologue cannot be relocated safely.
    if (!hook || !hook->hook())
        return "could not patch the function entry (unsupported prologue?)";
    pluginState().zoomHook = hook;
    return std::nullopt;
}

void removeZoomHook(HANDLE handle) {
    // Unhooking restores the original bytes, so the native camera code runs again.
    if (pluginState().zoomHook)
        HyprlandAPI::removeFunctionHook(handle, pluginState().zoomHook);
    pluginState().zoomHook = nullptr;
}

} // namespace hyprzoom
