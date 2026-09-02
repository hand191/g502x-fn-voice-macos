import G502XFnVoiceCore
import Testing

@Test func selectionPolicyAllowsInsertionPointsAndReplacementSelections() {
    #expect(TextSelectionPolicy.allows(location: 0, length: 0))
    #expect(TextSelectionPolicy.allows(location: 17, length: 0))
    #expect(TextSelectionPolicy.allows(location: 0, length: 1))
    #expect(TextSelectionPolicy.allows(location: 11, length: 7))
    #expect(TextSelectionPolicy.allows(location: Int.max - 1, length: 1))
}

@Test func selectionPolicyRejectsInvalidOrOverflowingRanges() {
    #expect(!TextSelectionPolicy.allows(location: -1, length: 0))
    #expect(!TextSelectionPolicy.allows(location: 0, length: -1))
    #expect(!TextSelectionPolicy.allows(location: Int.max, length: 1))
}
