// zoom_hook.hpp — installs the hook on Hyprland's detached-camera function.
#pragma once

#include "hyprland_includes.hpp"

#include <optional>
#include <string>

namespace hyprzoom {

/// Hooks CMonitorZoomController::zoomWithDetachedCamera.
/// @param handle Plugin handle.
/// @return std::nullopt on success, otherwise a human-readable reason (nothing was hooked).
std::optional<std::string> installZoomHook(HANDLE handle);

/// Removes the hook again; safe to call when it was never installed.
/// @param handle Plugin handle.
void removeZoomHook(HANDLE handle);

} // namespace hyprzoom
