// mini_test.hpp — a tiny assert-based test runner shared by the plugin unit tests.
//
// No framework is available on every CI image, and the plugin tests only need named cases,
// non-aborting checks and a summary, so this header provides exactly that.
#pragma once

#include <cmath>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

namespace minitest {

/// One registered test case.
struct TestCase {
    std::string name;           ///< Shown in the report.
    std::function<void()> body; ///< Calls check()/checkNear(); never throws on a failed check.
};

/// Number of failed checks so far (process-wide; only differences between cases matter).
inline int& failureCounter() {
    // A function-local static keeps the counter in one place without a namespace-scope global.
    static int failures = 0;
    return failures;
}

/// Records a failed expectation without aborting, so one run lists every problem.
/// @param condition Expectation result.
/// @param message Text printed when the expectation fails.
inline void check(bool condition, const std::string& message) {
    // Print at once; the summary only needs the counter.
    if (!condition) {
        std::printf("    FAIL: %s\n", message.c_str());
        ++failureCounter();
    }
}

/// Compares two doubles with a tolerance and reports both values on mismatch.
/// @param actual Computed value.
/// @param expected Value the contract demands.
/// @param label What is being compared.
/// @param tolerance Allowed absolute difference.
inline void checkNear(double actual, double expected, const std::string& label,
                      double tolerance = 0.01) {
    // fabs of the difference is symmetric, so the argument order cannot matter.
    const bool close = std::fabs(actual - expected) <= tolerance;
    // Both numbers go into the message: a failing check must be diagnosable from the log alone.
    check(close,
          label + ": got " + std::to_string(actual) + ", expected " + std::to_string(expected));
}

/// Runs every case, prints one line per case and a summary.
/// @param cases Cases in report order.
/// @return Process exit code: 0 when every check passed, 1 otherwise.
inline int runAll(const std::vector<TestCase>& cases) {
    int failedCases = 0;
    for (const auto& testCase : cases) {
        // Count failures per case so the report can name the culprit.
        const int failuresBefore = failureCounter();
        testCase.body();
        // A case passed when its body added no failures.
        const bool passed = failureCounter() == failuresBefore;
        std::printf("%s %s\n", passed ? "ok  " : "FAIL", testCase.name.c_str());
        failedCases += passed ? 0 : 1;
    }
    // The summary line is what run.sh greps for in CI logs.
    std::printf("%zu cases, %d failed\n", cases.size(), failedCases);
    return failedCases == 0 ? 0 : 1;
}

} // namespace minitest
