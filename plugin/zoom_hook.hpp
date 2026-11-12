// zoom_hook.hpp — installs the hook on Hyprland's detached-camera function.
#pragma once

#include "hyprland_includes.hpp"

#include <optional>
#include <string>
#include <vector>

namespace hyprzoom {

/// Substring of the mangled symbol that identifies the hooked function.
constexpr const char* kHookedSymbolName = "zoomWithDetachedCamera";
/// Demangled name the single match must contain, so an unrelated symbol is never hooked.
constexpr const char* kHookedDemangledName = "CMonitorZoomController::zoomWithDetachedCamera";

/// Picks the one acceptable function address out of the symbol search results.
/// @param matches Result of HyprlandAPI::findFunctionsByName.
/// @return The unique address; std::nullopt (with `error` filled) for zero or several matches.
std::optional<void*> selectHookTarget(const std::vector<SFunctionMatch>& matches, std::string& error);

/// Hooks CMonitorZoomController::zoomWithDetachedCamera.
/// @param handle Plugin handle.
/// @return std::nullopt on success, otherwise a human-readable reason (nothing was hooked).
std::optional<std::string> installZoomHook(HANDLE handle);

/// Removes the hook again; safe to call when it was never installed.
/// @param handle Plugin handle.
void removeZoomHook(HANDLE handle);

} // namespace hyprzoom
