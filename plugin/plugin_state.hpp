// plugin_state.hpp — the plugin's only mutable state, reachable through one accessor.
//
// Hyprland calls the hook as a plain function pointer, so the hook cannot receive context by
// parameter. Keeping the handle, the config values and the hook in one struct behind one
// function makes the global state explicit and easy to reset.
#pragma once

#include "hyprland_includes.hpp"

namespace hyprzoom {

/// Everything the hook needs from the plugin at frame time.
struct PluginState {
    HANDLE                           handle     = nullptr; ///< Plugin handle given by Hyprland.
    SP<Config::Values::CFloatValue>  edgeMargin;           ///< `plugin:hyprzoom:edge_margin`.
    SP<Config::Values::CBoolValue>   enabled;              ///< `plugin:hyprzoom:enabled`.
    CFunctionHook*                   zoomHook   = nullptr; ///< Trampoline hook, owned by Hyprland.
};

/// Accessor for the single plugin state instance.
/// @return Mutable reference; lives until the plugin is unloaded.
inline PluginState& pluginState() {
    // A function-local static avoids static-initialisation-order problems at dlopen time.
    static PluginState state;
    return state;
}

} // namespace hyprzoom
