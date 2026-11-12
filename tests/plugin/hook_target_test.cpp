// hook_target_test.cpp — unit tests for plugin/hook_target.hpp and plugin/api_version.hpp.
//
// The plugin hooks one function only if its FULL demangled signature equals the one verified for
// the Hyprland generation (0.56 or 0.57) the plugin was built for. These cases feed fake symbol
// matches to the selection and test the API version guard, without any Hyprland header.
#include "../../plugin/api_version.hpp"
#include "../../plugin/hook_target.hpp"
#include "mini_test.hpp"

#include <string>
#include <vector>

using hyprzoom::ApiGeneration;
using minitest::check;

namespace {

/// Stand-in for Hyprland's SFunctionMatch (same two fields the selection reads).
struct FakeMatch {
    void* address = nullptr; ///< Where the function lives.
    std::string demangled;   ///< Demangled signature.
};

/// Target of the legitimate fake match; only its address matters.
int g_marker = 0;

/// Runs the selection on a list of fake matches.
/// @param matches Fake search result.
/// @param generation Generation the plugin pretends to be built for.
/// @param error Receives the refusal reason.
/// @return The selected address or std::nullopt.
std::optional<void*> select(const std::vector<FakeMatch>& matches, ApiGeneration generation,
                            std::string& error) {
    // A thin wrapper keeps the cases below readable.
    return hyprzoom::selectHookTarget(matches, generation, error);
}

/// Case: the verified signature of each generation is accepted for that generation.
void testAcceptsTheVerifiedSignature() {
    // The happy path for 0.56 and for 0.57: one match whose signature is the expected one.
    for (const auto generation : {ApiGeneration::Hyprland056, ApiGeneration::Hyprland057}) {
        std::string error;
        const char* signature = hyprzoom::expectedSignature(generation);
        // One fake match carrying exactly that signature.
        const auto target = select({{&g_marker, signature}}, generation, error);
        check(target.has_value(), std::string{"must accept "} + signature);
        // The address must come back unchanged, it is what gets patched.
        check(target.value_or(nullptr) == &g_marker, "must return its address");
    }
}

/// Case: no match is refused with a message that carries the count.
void testRefusesNoMatch() {
    // Symbol gone (or nm missing): the plugin must not hook anything.
    std::string error;
    const auto target = select({}, ApiGeneration::Hyprland056, error);
    check(!target.has_value(), "must refuse an empty result");
    // The message goes into a notification, so the count must be in it.
    check(error.find("found 0") != std::string::npos, "message has count");
}

/// Case: several matches are refused even when each looks right.
void testRefusesSeveralMatches() {
    // Two candidates are ambiguous, whatever their signature.
    std::string error;
    const char* signature = hyprzoom::kSignature056;
    // The same legitimate match twice.
    const auto target =
        select({{&g_marker, signature}, {&g_marker, signature}}, ApiGeneration::Hyprland056, error);
    check(!target.has_value(), "must refuse ambiguity");
    // The message names how many candidates were found.
    check(error.find("found 2") != std::string::npos, "message has count");
}

/// Case: a foreign symbol is refused and named.
void testRefusesForeignSymbol() {
    // The mangled-name search is a substring match; the demangled signature decides.
    std::string error;
    const auto target = select({{&g_marker, "Other::zoomWithDetachedCamera(int)"}},
                               ApiGeneration::Hyprland056, error);
    check(!target.has_value(), "must refuse an unrelated symbol");
    // The offending symbol is named, which tells users what Hyprland changed.
    check(error.find("Other::zoomWithDetachedCamera") != std::string::npos,
          "message names the symbol");
}

/// Case: same class and function name with other arguments is refused (R-P3-02).
void testRefusesSameNameOtherArguments() {
    // This is exactly how 0.57 differs from 0.56: hooking it with the 0.56 ABI would crash.
    std::string error;
    check(!select({{&g_marker, hyprzoom::kSignature057}}, ApiGeneration::Hyprland056, error)
               .has_value(),
          "a 0.57 symbol must not be hooked by a 0.56 build");
    // And the other way round.
    check(!select({{&g_marker, hyprzoom::kSignature056}}, ApiGeneration::Hyprland057, error)
               .has_value(),
          "a 0.56 symbol must not be hooked by a 0.57 build");
    // A future signature with an extra parameter is refused as well.
    const std::string future = std::string{hyprzoom::kSignature057}.insert(
        std::string{hyprzoom::kSignature057}.size() - 1, ", int");
    check(!select({{&g_marker, future}}, ApiGeneration::Hyprland057, error).has_value(),
          "an unknown parameter list must be refused");
}

/// Case: the compile-time guard accepts exactly the API version of the selected generation.
void testApiVersionGuard() {
    using hyprzoom::apiVersionMatches;
    // The announced versions of the two supported generations.
    check(apiVersionMatches(ApiGeneration::Hyprland056, "0.1"), "0.56 expects API 0.1");
    check(apiVersionMatches(ApiGeneration::Hyprland057, "0.2"), "0.57 expects API 0.2");
    // Mixed-up versions must stop the build.
    check(!apiVersionMatches(ApiGeneration::Hyprland056, "0.2"), "0.56 sources reject API 0.2");
    check(!apiVersionMatches(ApiGeneration::Hyprland057, "0.1"), "0.57 sources reject API 0.1");
    // Unknown versions as well: a future API may change the signature again.
    check(!apiVersionMatches(ApiGeneration::Hyprland057, "0.3"), "a future API is rejected");
    check(!apiVersionMatches(ApiGeneration::Hyprland056, ""), "an empty version is rejected");
}

/// All cases of this file.
std::vector<minitest::TestCase> buildCases() {
    return {
        {"the verified signature of each generation is accepted", testAcceptsTheVerifiedSignature},
        {"no match is refused with a message", testRefusesNoMatch},
        {"several matches are refused", testRefusesSeveralMatches},
        {"a single match with a foreign demangled name is refused", testRefusesForeignSymbol},
        {"same name with other arguments is refused (full signature)",
         testRefusesSameNameOtherArguments},
        {"the API version guard accepts only the matching version", testApiVersionGuard},
    };
}

} // namespace

/// Runs the cases; exit code 0 when all pass.
int main() {
    return minitest::runAll(buildCases());
}
