// hook_target.hpp — decides which symbol the plugin may hook (no Hyprland types).
//
// Hyprland's `findFunctionsByName` returns every symbol whose mangled name contains a string.
// Hooking the wrong one would corrupt the compositor, so the plugin only accepts exactly one
// match whose demangled name is the expected member function. The logic is a template over
// the match type so unit tests can feed it fake matches without any Hyprland header.
#pragma once

#include <optional>
#include <string>
#include <vector>

/// Test-only knob: a test build may search for another symbol to exercise the refusal path.
#ifndef HYPRZOOM_HOOKED_SYMBOL
#define HYPRZOOM_HOOKED_SYMBOL "zoomWithDetachedCamera"
#endif

namespace hyprzoom {

/// Substring of the mangled symbol that identifies the hooked function.
constexpr const char* kHookedSymbolName = HYPRZOOM_HOOKED_SYMBOL;
/// Demangled name the single match must contain, so an unrelated symbol is never hooked.
constexpr const char* kHookedDemangledName = "CMonitorZoomController::zoomWithDetachedCamera";

/// Picks the one acceptable function address out of the symbol search results.
/// @tparam Match Type with `void* address` and `std::string demangled` (SFunctionMatch).
/// @param matches Result of HyprlandAPI::findFunctionsByName.
/// @param error Receives the reason when nothing acceptable was found.
/// @return The unique address; std::nullopt for zero, several or an unexpected match.
template <typename Match>
std::optional<void*> selectHookTarget(const std::vector<Match>& matches, std::string& error) {
    // More than one candidate means the symbol table changed shape: refuse rather than guess.
    if (matches.size() != 1) {
        error = "expected exactly one '" + std::string{kHookedSymbolName} +
                "' symbol in Hyprland, found " + std::to_string(matches.size());
        return std::nullopt;
    }
    // The substring search is loose; the demangled name proves it is the intended member function.
    if (matches.front().demangled.find(kHookedDemangledName) == std::string::npos) {
        // Name the offender so the notification tells the user what changed in Hyprland.
        error = "symbol '" + matches.front().demangled + "' is not " + kHookedDemangledName;
        return std::nullopt;
    }
    // Exactly one verified match: this is the address to hook.
    return matches.front().address;
}

} // namespace hyprzoom
