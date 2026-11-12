// hyprland_includes.hpp — the ONE place where Hyprland's private members are opened up.
//
// `CMonitorZoomController` keeps its camera state and `getAnchor` private and non-virtual, and
// the hook has to read and write exactly that state. The usual plugin technique is to compile
// the Hyprland headers with `private` turned into `public`: GCC and Clang lay members out
// independent of access, so the object layout and the mangled symbols stay identical to the
// ones inside the Hyprland binary.
//
// The macro also touches every standard header that is included afterwards, so the whole
// standard library is pulled in first (include guards then make the later includes no-ops).
// Nothing else in the plugin may define `private`.
#pragma once

// Pull in the standard library before the macro exists (see above).
#include <bits/stdc++.h>

#include "api_version.hpp"

// Which Hyprland generation are we compiling against? 0.57 introduced `render/Context.hpp`
// (the CRenderContext the hooked function now receives); 0.56 has no such header.
#if __has_include(<hyprland/src/render/Context.hpp>)
#define HYPRZOOM_API_GENERATION 2
#else
#define HYPRZOOM_API_GENERATION 1
#endif

// Open up the private members of every Hyprland header included below.
#define private public
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/config/values/types/BoolValue.hpp>
#include <hyprland/src/config/values/types/FloatValue.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/output/MonitorZoomController.hpp>
#include <hyprland/src/render/Renderer.hpp>
#if HYPRZOOM_API_GENERATION == 2
#include <hyprland/src/render/Context.hpp>
#endif
#undef private

namespace hyprzoom {

/// The generation the sources were selected for by the header layout above.
constexpr ApiGeneration kBuiltFor =
    HYPRZOOM_API_GENERATION == 2 ? ApiGeneration::Hyprland057 : ApiGeneration::Hyprland056;

} // namespace hyprzoom

// Compile-time guard: a Hyprland whose plugin API is neither 0.1 nor 0.2 may have changed the
// hooked function again, so the build stops here instead of producing a plugin that could crash.
static_assert(hyprzoom::apiVersionMatches(hyprzoom::kBuiltFor, HYPRLAND_API_VERSION),
              "hyprzoom supports Hyprland 0.56.x (plugin API 0.1) and 0.57.x (plugin API 0.2) "
              "only. These headers announce a different plugin API: the plugin has to be "
              "ported first. Without the plugin hyprland-zoom keeps working (tracking 'margin' "
              "falls back to 'edge').");
