// hook_target_test.cpp — unit tests for plugin/hook_target.hpp (the "hook exactly one" rule).
#include "../../plugin/hook_target.hpp"
#include "mini_test.hpp"

#include <string>
#include <vector>

using minitest::check;

namespace {

/// Stand-in for Hyprland's SFunctionMatch (same two fields the selection reads).
struct FakeMatch {
    void* address = nullptr; ///< Where the function lives.
    std::string demangled;   ///< Demangled signature.
};

/// Target of the legitimate fake match; only its address matters.
int g_marker = 0;

/// The demangled signature as `nm --demangle` prints it for Hyprland 0.56.
const char* const kRealSignature =
    "Monitor::CMonitorZoomController::zoomWithDetachedCamera(Hyprutils::Math::CBox&, "
    "Render::SRenderData const&)";

/// Runs the selection on a list of fake matches.
/// @param matches Fake search result.
/// @param error Receives the refusal reason.
/// @return The selected address or std::nullopt.
std::optional<void*> select(const std::vector<FakeMatch>& matches, std::string& error) {
    // A thin wrapper keeps the cases below readable.
    return hyprzoom::selectHookTarget(matches, error);
}

/// All cases of this file.
std::vector<minitest::TestCase> buildCases() {
    std::vector<minitest::TestCase> cases;

    cases.push_back({"exactly one matching symbol is accepted", [] {
                         // The happy path: one match whose demangled name is the expected one.
                         std::string error;
                         const auto target = select({{&g_marker, kRealSignature}}, error);
                         check(target.has_value(), "must accept the single legitimate match");
                         // The address must come back unchanged, it is what gets patched.
                         check(target.value_or(nullptr) == &g_marker, "must return its address");
                     }});

    cases.push_back({"no match is refused with a message", [] {
                         // Symbol gone (or nm missing): the plugin must not hook anything.
                         std::string error;
                         const auto target = select({}, error);
                         check(!target.has_value(), "must refuse an empty result");
                         // The message goes into a notification, so the count must be in it.
                         check(error.find("found 0") != std::string::npos, "message has count");
                     }});

    cases.push_back({"several matches are refused", [] {
                         // Two candidates are ambiguous even if both look right.
                         std::string error;
                         const auto target = select(
                             {{&g_marker, kRealSignature}, {&g_marker, kRealSignature}}, error);
                         check(!target.has_value(), "must refuse ambiguity");
                         check(error.find("found 2") != std::string::npos, "message has count");
                     }});

    cases.push_back({"a single match with a foreign demangled name is refused", [] {
                         // The mangled-name search is a substring match; the demangled name
                         // decides.
                         std::string error;
                         const auto target =
                             select({{&g_marker, "Other::zoomWithDetachedCamera(int)"}}, error);
                         check(!target.has_value(), "must refuse an unrelated symbol");
                         // The offending symbol is named, which tells users what Hyprland changed.
                         check(error.find("Other::zoomWithDetachedCamera") != std::string::npos,
                               "message names the symbol");
                     }});

    return cases;
}

} // namespace

/// Runs the cases; exit code 0 when all pass.
int main() {
    return minitest::runAll(buildCases());
}
