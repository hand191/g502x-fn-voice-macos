import G502XFnHIDCore
import Testing

@Test func fnReportsHaveExpectedShape() {
    let down = [UInt8](AppleFnKeyboard.inputReport(fnPressed: true))
    let up = [UInt8](AppleFnKeyboard.inputReport(fnPressed: false))

    #expect(down.count == AppleFnKeyboard.reportLength)
    #expect(up.count == AppleFnKeyboard.reportLength)
    #expect(down.dropLast().allSatisfy { $0 == 0 })
    #expect(down.last == 1)
    #expect(up.allSatisfy { $0 == 0 })
}

@Test func descriptorDeclaresVendorFnField() {
    let descriptor = [UInt8](AppleFnKeyboard.reportDescriptor)
    let fnField: [UInt8] = [
        0x05, 0xff, 0x09, 0x03, 0x75, 0x08,
        0x95, 0x01, 0x81, 0x02,
    ]

    let containsFnField = descriptor.indices.contains { start in
        let end = start + fnField.count
        guard end <= descriptor.count else { return false }
        return Array(descriptor[start..<end]) == fnField
    }
    #expect(containsFnField)
}
