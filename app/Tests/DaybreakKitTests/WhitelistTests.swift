import Testing
@testable import DaybreakKit

@Suite struct WhitelistTests {
    @Test(arguments: [
        ("com.jetbrains.*", "com.jetbrains.intellij", true),
        ("com.jetbrains.*", "com.jetbrains.", true),
        ("com.jetbrains.*", "com.JetBrains.intellij", false),  // case-sensitive
        ("com.jetbrains.*", "org.com.jetbrains.x", false),     // anchored
        ("com.google.Chrome", "com.google.Chrome", true),
        ("com.google.Chrome", "com.google.Chrome.canary", false),
        ("com.google.Chrome", "com.google.chrome", false),
        ("com.?xample.A", "com.example.A", true),
        ("com.example.[AB]", "com.example.B", true),
        ("com.example.[!AB]", "com.example.B", false),
        ("com.example.[!AB]", "com.example.C", true),
        ("*.Slack", "com.tinyspeck.Slack", true),
        ("com.example.*.helper", "com.example.a.b.helper", true),
    ])
    func matching(pattern: String, bundleID: String, expected: Bool) {
        #expect(Whitelist.matches(pattern: pattern, bundleID: bundleID) == expected)
    }

    @Test func firstMatch() {
        #expect(Whitelist.firstMatch(in: ["com.a.*", "com.b.*"], bundleID: "com.b.x") == "com.b.*")
        #expect(Whitelist.firstMatch(in: [], bundleID: "com.b.x") == nil)
    }

    @Test func validation() {
        #expect(Whitelist.validationError(for: "") != nil)
        #expect(Whitelist.validationError(for: "   ") != nil)
        #expect(Whitelist.validationError(for: "com.example App") != nil)
        #expect(Whitelist.validationError(for: "*") != nil)
        #expect(Whitelist.validationError(for: "com.example.*") == nil)
        #expect(Whitelist.isGlob("com.example.*"))
        #expect(!Whitelist.isGlob("com.example.A"))
    }
}
