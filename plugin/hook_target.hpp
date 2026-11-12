// hook_target.hpp — decides which symbol the plugin may hook (no Hyprland types).
//
// Hyprland's `findFunctionsByName` returns every symbol whose mangled name contains a string.
// Hooking the wrong one would corrupt the compositor, so the plugin only accepts exactly one
// match whose FULL demangled signature (name AND parameter types) is the one verified for the
// Hyprland generation it was built for. A release that keeps the name but changes the arguments
// (as 0.57 did) is therefore refused instead of hooked with a wrong ABI. The logic is a
// template over the match type so unit tests can feed it fake matches without any Hyprland
// header.
#pragma once

#include "api_version.hpp"

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

/// Demangled signature in Hyprland 0.56.x (verified against v0.56.2 with `nm --demangle`).
constexpr const char* kSignature056 =
    "Monitor::CMonitorZoomController::zoomWithDetachedCamera(Hyprutils::Math::CBox&, "
    "Render::SRenderData const&)";
/// Demangled signature in Hyprland 0.57.x (from the v0.57.2 sources, `MonitorZoomController.hpp`).
constexpr const char* kSignature057 =
    "Monitor::CMonitorZoomController::zoomWithDetachedCamera(Render::CRenderContext&, "
    "Hyprutils::Math::CBox&)";

/// Picks the signature a generation must expose.
/// @param generation Generation the plugin was compiled for.
/// @return The complete demangled signature the single match has to equal.
constexpr const char* expectedSignature(ApiGeneration generation) {
    // One verified signature per generation; the ABI of each differs.
    return generation == ApiGeneration::Hyprland057 ? kSignature057 : kSignature056;
}

/// Picks the one acceptable function address out of the symbol search results.
/// @tparam Match Type with `void* address` and `std::string demangled` (SFunctionMatch).
/// @param matches Result of HyprlandAPI::findFunctionsByName.
/// @param generation Generation the plugin was compiled for (selects the signature).
/// @param error Receives the reason when nothing acceptable was found.
/// @return The unique address; std::nullopt for zero, several or an unexpected match.
template <typename Match>
std::optional<void*> selectHookTarget(const std::vector<Match>& matches, ApiGeneration generation,
                                      std::string& error) {
    // More than one candidate means the symbol table changed shape: refuse rather than guess.
    if (matches.size() != 1) {
        error = "expected exactly one '" + std::string{kHookedSymbolName} +
                "' symbol in Hyprland, found " + std::to_string(matches.size());
        return std::nullopt;
    }
    // The substring search is loose; the whole signature proves it is the intended function.
    if (matches.front().demangled != expectedSignature(generation)) {
        // Name the offender so the notification tells the user what changed in Hyprland.
        error =
            "symbol '" + matches.front().demangled + "' is not " + expectedSignature(generation);
        return std::nullopt;
    }
    // Exactly one verified match: this is the address to hook.
    return matches.front().address;
}

} // namespace hyprzoom
