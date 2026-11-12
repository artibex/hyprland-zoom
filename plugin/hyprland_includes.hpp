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
#undef private
