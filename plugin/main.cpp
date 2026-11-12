// main.cpp — Hyprland plugin entry points of `hyprzoom`.
//
// hyprzoom makes the edge margin of Hyprland's detached zoom camera configurable
// (`plugin:hyprzoom:edge_margin`). See docs/plugin.md for the user documentation.
#include "camera_math.hpp"
#include "plugin_state.hpp"
#include "zoom_hook.hpp"

/// Plugin version, injected from the repository's VERSION file by the Makefile.
#ifndef HYPRZOOM_VERSION
#define HYPRZOOM_VERSION "unknown"
#endif

/// Version marker kept in the binary's read-only data so tools (and the repository tests) can
/// read the version out of the .so with `strings`; short std::string literals are built from
/// immediate values in the code and would not show up there.
extern "C" EXPORT const char hyprzoomVersionMarker[] = "hyprzoom-version=" HYPRZOOM_VERSION;

namespace {

/// Name under which the plugin is registered and the prefix of its config values.
constexpr const char* kPluginName = "hyprzoom";
/// How long error notifications stay on screen, in milliseconds.
constexpr float kNotificationMs = 10000.0F;

/// Shows a red error notification and logs it, so a refused hook is never silent.
/// @param handle Plugin handle.
/// @param message Reason shown to the user (prefixed with the plugin name).
void notifyError(HANDLE handle, const std::string& message) {
    // The notification is the user-facing signal; the exception that follows reaches the log.
    HyprlandAPI::addNotification(handle, std::format("[{}] {}", kPluginName, message),
                                 CHyprColor{1.0, 0.2, 0.2, 1.0}, kNotificationMs);
}

/// Aborts initialisation when the plugin was built against another Hyprland build.
/// @param handle Plugin handle.
/// @throws std::runtime_error on a hash mismatch (Hyprland then unloads the plugin).
void requireMatchingHyprland(HANDLE handle) {
    // The hash covers Hyprland and its libraries: the hook is only valid for the exact build.
    if (std::string{__hyprland_api_get_hash()} == std::string{__hyprland_api_get_client_hash()})
        return;
    notifyError(handle, "built for a different Hyprland version, run `hyprpm update`");
    throw std::runtime_error("[hyprzoom] version mismatch");
}

/// Registers `plugin:hyprzoom:edge_margin` and `plugin:hyprzoom:enabled`.
/// @param handle Plugin handle.
/// @throws std::runtime_error when Hyprland refuses a value.
void registerConfigValues(HANDLE handle) {
    // Both config values live in the shared plugin state, where the hook can read them.
    auto& state = hyprzoom::pluginState();
    // Range and default mirror config/settings.schema (ZOOM_EDGE_MARGIN) and contract C9.
    state.edgeMargin = makeShared<Config::Values::CFloatValue>(
        "plugin:hyprzoom:edge_margin",
        "Zoom edge margin: fraction of the zoomed view per side (0.00-0.45)",
        static_cast<Config::FLOAT>(hyprzoom::kNativeEdgeMargin),
        Config::Values::SFloatValueOptions{
            .min = static_cast<Config::FLOAT>(hyprzoom::kMinEdgeMargin),
            .max = static_cast<Config::FLOAT>(hyprzoom::kMaxEdgeMargin)});
    // The switch lets users fall back to Hyprland's camera without unloading the plugin.
    state.enabled = makeShared<Config::Values::CBoolValue>(
        "plugin:hyprzoom:enabled", "Use the adjustable margin (false: native camera)", true);

    // addConfigValueV2 also binds the value, so value() works right after this call.
    if (!HyprlandAPI::addConfigValueV2(handle, state.edgeMargin) ||
        !HyprlandAPI::addConfigValueV2(handle, state.enabled)) {
        notifyError(handle, "could not register the config values");
        throw std::runtime_error("[hyprzoom] config registration failed");
    }
}

} // namespace

/// Hyprland asks which plugin API the .so was built for; a mismatch ejects the plugin.
/// @return The API version string of the headers used for the build.
APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

/// Plugin entry point: verifies the build, registers the config and installs the hook.
/// @param handle Plugin handle, kept for later API calls.
/// @return Name, description, author and version shown by `hyprctl plugin list`.
APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    // The hook and the exit function need the handle later.
    hyprzoom::pluginState().handle = handle;
    // Fail early (and loudly) on a Hyprland build the plugin was not compiled for.
    requireMatchingHyprland(handle);
    // Register the options before hooking so the hook never sees an unbound value.
    registerConfigValues(handle);

    // Refuse to run (and say why) rather than hook something that is not the expected function.
    if (const auto reason = hyprzoom::installZoomHook(handle)) {
        notifyError(handle, std::format("not hooked: {}", *reason));
        throw std::runtime_error("[hyprzoom] hook refused: " + *reason);
    }
    // These strings show up in `hyprctl plugin list` and `hl.get_loaded_plugins()`.
    return {kPluginName, "Adjustable edge margin for the detached zoom camera", "artibex",
            HYPRZOOM_VERSION};
}

/// Plugin exit: restores Hyprland's own camera code before the .so is unloaded.
APICALL EXPORT void PLUGIN_EXIT() {
    // Hyprland removes hooks after exit anyway; doing it here keeps the order explicit.
    hyprzoom::removeZoomHook(hyprzoom::pluginState().handle);
}
