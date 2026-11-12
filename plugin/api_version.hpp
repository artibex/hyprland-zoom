// api_version.hpp — which Hyprland plugin API generations hyprzoom supports (no Hyprland types).
//
// Hyprland announces its plugin API as a string macro (`HYPRLAND_API_VERSION`) in
// `plugins/PluginAPI.hpp`. The two supported generations differ in the signature of the hooked
// function, so the plugin must know which one it is compiled for and must refuse to build on any
// other API instead of hooking with a wrong ABI. This header holds the pure decision so unit
// tests can run it without Hyprland headers.
#pragma once

#include <string_view>

namespace hyprzoom {

/// The Hyprland generations whose `zoomWithDetachedCamera` signature the plugin knows.
enum class ApiGeneration {
    Hyprland056 = 1, ///< Hyprland 0.56.x, plugin API "0.1": `(CBox&, const SRenderData&)`.
    Hyprland057 = 2, ///< Hyprland 0.57.x, plugin API "0.2": `(CRenderContext&, CBox&)`.
};

/// Plugin API version string announced by Hyprland 0.56.x.
constexpr std::string_view kApiVersion056 = "0.1";
/// Plugin API version string announced by Hyprland 0.57.x.
constexpr std::string_view kApiVersion057 = "0.2";

/// Human-readable supported range, used in the compile error and in the docs.
constexpr const char* kSupportedRange = "Hyprland 0.56.x (plugin API 0.1) and 0.57.x (API 0.2)";

/// Names the plugin API version a generation was verified against.
/// @param generation The generation the sources were selected for.
/// @return The matching `HYPRLAND_API_VERSION` string.
constexpr std::string_view expectedApiVersion(ApiGeneration generation) {
    // One string per generation; anything else cannot occur (enum class).
    return generation == ApiGeneration::Hyprland057 ? kApiVersion057 : kApiVersion056;
}

/// Tells whether the headers' API version belongs to the generation the sources were chosen for.
/// @param generation Generation picked from the header layout.
/// @param announced The `HYPRLAND_API_VERSION` of the headers being compiled against.
/// @return True when they agree; false means a Hyprland the plugin has not been ported to.
constexpr bool apiVersionMatches(ApiGeneration generation, std::string_view announced) {
    // Exact comparison: a new API version may change signatures again, so it must not pass.
    return announced == expectedApiVersion(generation);
}

} // namespace hyprzoom
