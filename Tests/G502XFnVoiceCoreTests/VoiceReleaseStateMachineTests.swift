import G502XFnVoiceCore
import Testing

private typealias Machine = VoiceReleaseStateMachine

private func stopClickToken(
    from effects: [Machine.Effect],
    sourceLocation: SourceLocation = #_sourceLocation
) -> UInt64? {
    guard case .sendStopClick(let token)? = effects.first else {
        Issue.record("Expected one stop-click effect, got \(effects)", sourceLocation: sourceLocation)
        return nil
    }
    #expect(effects.count == 1, sourceLocation: sourceLocation)
    return token
}

private func advanceToSettling(_ machine: inout Machine) -> UInt64? {
    #expect(machine.handle(.g6Down) == [.sendFnDown])
    guard let token = stopClickToken(from: machine.handle(.g6Up)) else { return nil }
    #expect(
        machine.handle(.clickFinished(token: token, succeeded: true)) == [
            .scheduleFnCleanup(
                token: token,
                milliseconds: Machine.settlementMilliseconds
            ),
        ]
    )
    return token
}

@Test func normalReleaseClicksBeforeOneDelayedFnUp() {
    var machine = Machine()

    #expect(machine.phase == .idle)
    #expect(machine.handle(.g6Down) == [.sendFnDown])
    #expect(machine.phase == .held)

    guard let token = stopClickToken(from: machine.handle(.g6Up)) else { return }
    #expect(machine.phase == .clickPending(token))

    #expect(
        machine.handle(.clickFinished(token: token, succeeded: true)) == [
            .scheduleFnCleanup(
                token: token,
                milliseconds: Machine.settlementMilliseconds
            ),
        ]
    )
    #expect(machine.phase == .settling(token))

    #expect(machine.handle(.settlementExpired(token: token)) == [.sendFnUp])
    #expect(machine.phase == .idle)
    #expect(machine.handle(.settlementExpired(token: token)).isEmpty)
}

@Test func clickFailureReleasesFnImmediatelyWithoutSchedulingCleanup() {
    var machine = Machine()

    #expect(machine.handle(.g6Down) == [.sendFnDown])
    guard let token = stopClickToken(from: machine.handle(.g6Up)) else { return }

    #expect(
        machine.handle(.clickFinished(token: token, succeeded: false)) == [
            .sendFnUp,
            .reportStopFailure,
        ]
    )
    #expect(machine.phase == .idle)
    #expect(machine.handle(.settlementExpired(token: token)).isEmpty)
}

@Test func duplicateSignalsProduceOnlyOneClickAndOneFnUp() {
    var machine = Machine()

    #expect(machine.handle(.g6Down) == [.sendFnDown])
    #expect(machine.handle(.g6Down).isEmpty)
    guard let token = stopClickToken(from: machine.handle(.g6Up)) else { return }
    #expect(machine.handle(.g6Up).isEmpty)

    let schedule = machine.handle(.clickFinished(token: token, succeeded: true))
    #expect(schedule.count == 1)
    #expect(machine.handle(.clickFinished(token: token, succeeded: true)).isEmpty)

    #expect(machine.handle(.settlementExpired(token: token)) == [.sendFnUp])
    #expect(machine.handle(.settlementExpired(token: token)).isEmpty)
}

@Test func pressDuringSettlementIsRejectedUntilItsPhysicalRelease() {
    var machine = Machine()
    guard let token = advanceToSettling(&machine) else { return }

    #expect(machine.handle(.g6Down) == [.rejectG6Press])
    #expect(machine.isPhysicalG6Down)
    #expect(machine.handle(.settlementExpired(token: token)) == [.sendFnUp])
    #expect(machine.phase == .blockedUntilPhysicalUp)

    #expect(machine.handle(.g6Down).isEmpty)
    #expect(machine.handle(.g6Up).isEmpty)
    #expect(machine.phase == .idle)
    #expect(machine.handle(.g6Down) == [.sendFnDown])
}

@Test func completeRejectedPressDuringSettlementDoesNotDelayCleanup() {
    var machine = Machine()
    guard let token = advanceToSettling(&machine) else { return }

    #expect(machine.handle(.g6Down) == [.rejectG6Press])
    #expect(machine.handle(.g6Up).isEmpty)
    #expect(machine.phase == .settling(token))

    #expect(machine.handle(.settlementExpired(token: token)) == [.sendFnUp])
    #expect(machine.phase == .idle)
    #expect(machine.handle(.g6Down) == [.sendFnDown])
}

@Test func staleTimerCannotReleaseANewerSession() {
    var machine = Machine()
    guard let oldToken = advanceToSettling(&machine) else { return }

    #expect(machine.handle(.forceCleanup) == [.cancelFnCleanup, .sendFnUp])
    #expect(machine.handle(.settlementExpired(token: oldToken)).isEmpty)

    guard let newToken = advanceToSettling(&machine) else { return }
    #expect(newToken != oldToken)
    #expect(machine.handle(.settlementExpired(token: oldToken)).isEmpty)
    #expect(machine.phase == .settling(newToken))
    #expect(machine.handle(.settlementExpired(token: newToken)) == [.sendFnUp])
}

@Test func staleClickCompletionIsIgnoredAfterForceCleanup() {
    var machine = Machine()

    #expect(machine.handle(.g6Down) == [.sendFnDown])
    guard let token = stopClickToken(from: machine.handle(.g6Up)) else { return }

    #expect(machine.handle(.forceCleanup) == [.cancelFnCleanup, .sendFnUp])
    #expect(machine.handle(.clickFinished(token: token, succeeded: true)).isEmpty)
    #expect(machine.handle(.settlementExpired(token: token)).isEmpty)
    #expect(machine.phase == .idle)
}

@Test func forceCleanupIsImmediateAndIdempotentFromEveryPhase() {
    var idle = Machine()

    var held = Machine()
    _ = held.handle(.g6Down)

    var clickPending = Machine()
    _ = clickPending.handle(.g6Down)
    _ = clickPending.handle(.g6Up)

    var settling = Machine()
    _ = advanceToSettling(&settling)

    var blocked = settling
    guard case .settling(let blockedToken) = blocked.phase else {
        Issue.record("Expected settling state")
        return
    }
    _ = blocked.handle(.g6Down)
    _ = blocked.handle(.settlementExpired(token: blockedToken))
    #expect(blocked.phase == .blockedUntilPhysicalUp)

    var machines = [idle, held, clickPending, settling, blocked]
    for index in machines.indices {
        #expect(
            machines[index].handle(.forceCleanup) == [
                .cancelFnCleanup,
                .sendFnUp,
            ]
        )
        #expect(machines[index].phase == .idle)
        #expect(!machines[index].isPhysicalG6Down)
    }

    #expect(idle.handle(.forceCleanup) == [.cancelFnCleanup, .sendFnUp])
    #expect(idle.handle(.forceCleanup) == [.cancelFnCleanup, .sendFnUp])
}
