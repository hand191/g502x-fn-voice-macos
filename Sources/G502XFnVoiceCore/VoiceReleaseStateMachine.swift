public struct VoiceReleaseStateMachine: Sendable {
    public static let settlementMilliseconds: UInt64 = 800

    public enum Phase: Equatable, Sendable {
        case idle
        case held
        case clickPending(UInt64)
        case settling(UInt64)
        case blockedUntilPhysicalUp
    }

    public enum Event: Equatable, Sendable {
        case g6Down
        case g6Up
        case clickFinished(token: UInt64, succeeded: Bool)
        case settlementExpired(token: UInt64)
        case forceCleanup
    }

    public enum Effect: Equatable, Sendable {
        case sendFnDown
        case sendStopClick(token: UInt64)
        case scheduleFnCleanup(token: UInt64, milliseconds: UInt64)
        case cancelFnCleanup
        case sendFnUp
        case rejectG6Press
        case reportStopFailure
    }

    public private(set) var phase: Phase = .idle
    public private(set) var isPhysicalG6Down = false

    private var nextToken: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .g6Down:
            return handleG6Down()

        case .g6Up:
            return handleG6Up()

        case .clickFinished(let token, let succeeded):
            guard phase == .clickPending(token) else { return [] }

            if succeeded {
                phase = .settling(token)
                return [
                    .scheduleFnCleanup(
                        token: token,
                        milliseconds: Self.settlementMilliseconds
                    ),
                ]
            }

            phase = isPhysicalG6Down ? .blockedUntilPhysicalUp : .idle
            return [.sendFnUp, .reportStopFailure]

        case .settlementExpired(let token):
            guard phase == .settling(token) else { return [] }

            phase = isPhysicalG6Down ? .blockedUntilPhysicalUp : .idle
            return [.sendFnUp]

        case .forceCleanup:
            invalidateOutstandingToken()
            phase = .idle
            isPhysicalG6Down = false
            return [.cancelFnCleanup, .sendFnUp]
        }
    }

    private mutating func handleG6Down() -> [Effect] {
        guard !isPhysicalG6Down else { return [] }
        isPhysicalG6Down = true

        switch phase {
        case .idle:
            phase = .held
            return [.sendFnDown]

        case .held:
            return []

        case .clickPending, .settling, .blockedUntilPhysicalUp:
            return [.rejectG6Press]
        }
    }

    private mutating func handleG6Up() -> [Effect] {
        guard isPhysicalG6Down else { return [] }
        isPhysicalG6Down = false

        switch phase {
        case .held:
            let token = makeToken()
            phase = .clickPending(token)
            return [.sendStopClick(token: token)]

        case .blockedUntilPhysicalUp:
            phase = .idle
            return []

        case .idle, .clickPending, .settling:
            return []
        }
    }

    private mutating func makeToken() -> UInt64 {
        nextToken &+= 1
        if nextToken == 0 {
            nextToken = 1
        }
        return nextToken
    }

    private mutating func invalidateOutstandingToken() {
        _ = makeToken()
    }
}
