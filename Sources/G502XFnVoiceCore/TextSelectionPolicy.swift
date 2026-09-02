public enum TextSelectionPolicy: Sendable {
    /// A zero-length range is an insertion point. A non-empty range is also
    /// valid: the input method should replace that selection with its result.
    public static func allows(location: Int, length: Int) -> Bool {
        guard location >= 0, length >= 0 else { return false }
        return !location.addingReportingOverflow(length).overflow
    }
}
