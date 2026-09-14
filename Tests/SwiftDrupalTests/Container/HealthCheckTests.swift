import Foundation
import Testing
@testable import SwiftDrupal

private let spec = ContainerSpec(id: "site-web", role: .web, imageReference: "img", hostname: "site.drupal")

@Suite struct HealthCheckTests {
    @Test func returnsImmediatelyWhenProbePassesFirstTime() async throws {
        let service = MockContainerService()
        await service.seed(spec, state: .running)
        let clock = TestHealthCheckClock()
        let checker = HealthChecker(timeout: .seconds(10), pollInterval: .seconds(1), clock: clock)

        let status = try await checker.waitUntilHealthy(service: service, id: "site-web", probe: .running)
        #expect(status.state == .running)
        #expect(clock.sleeps.isEmpty)
    }

    @Test func pollsUntilProbeSucceeds() async throws {
        let service = MockContainerService()
        await service.seed(spec, state: .running)
        let attempts = Counter()
        let probe = HealthProbe(name: "third time") { _, _ in
            attempts.increment() >= 3
        }
        let clock = TestHealthCheckClock()
        let checker = HealthChecker(timeout: .seconds(10), pollInterval: .milliseconds(250), clock: clock)

        try await checker.waitUntilHealthy(service: service, id: "site-web", probe: probe)
        #expect(attempts.value == 3)
        #expect(clock.sleeps == [.milliseconds(250), .milliseconds(250)])
    }

    @Test func waitsThroughCreatedStateBeforeProbing() async throws {
        let service = MockContainerService()
        await service.seed(spec, state: .running)
        await service.scriptInspectStates("site-web", [.created, .created])
        let probed = Counter()
        let probe = HealthProbe(name: "count") { _, _ in probed.increment(); return true }
        let clock = TestHealthCheckClock()

        try await HealthChecker(timeout: .seconds(5), pollInterval: .seconds(1), clock: clock)
            .waitUntilHealthy(service: service, id: "site-web", probe: probe)
        #expect(probed.value == 1)
        #expect(clock.sleeps.count == 2)
    }

    @Test func timesOutWithHealthCheckTimeoutExitCode() async throws {
        let service = MockContainerService()
        await service.seed(spec, state: .running)
        let never = HealthProbe(name: "never") { _, _ in false }
        let clock = TestHealthCheckClock()
        let checker = HealthChecker(timeout: .seconds(3), pollInterval: .seconds(1), clock: clock)

        do {
            try await checker.waitUntilHealthy(service: service, id: "site-web", probe: never)
            Issue.record("expected timeout")
        } catch let error as DrupalError {
            guard case .healthCheckTimeout(let message) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(error.exitCode == .healthCheckTimeout)
            #expect(error.exitCode.rawValue == 13)
            #expect(message.contains("site-web"))
            #expect(message.contains("never"))
        }
        // Polls at t=0,1,2,3 then gives up; never sleeps past the deadline.
        #expect(clock.sleeps == [.seconds(1), .seconds(1), .seconds(1)])
        #expect(clock.now() == .seconds(3))
    }

    @Test func lastSleepIsClampedToDeadline() async throws {
        let service = MockContainerService()
        await service.seed(spec, state: .running)
        let clock = TestHealthCheckClock()
        let checker = HealthChecker(timeout: .milliseconds(2500), pollInterval: .seconds(1), clock: clock)

        await #expect(throws: DrupalError.self) {
            try await checker.waitUntilHealthy(service: service, id: "site-web", probe: HealthProbe(name: "no") { _, _ in false })
        }
        #expect(clock.sleeps == [.seconds(1), .seconds(1), .milliseconds(500)])
    }

    @Test func slowProbeCountsTowardTimeout() async throws {
        let service = MockContainerService()
        await service.seed(spec, state: .running)
        let clock = TestHealthCheckClock()
        let slow = HealthProbe(name: "slow") { _, _ in clock.advance(by: .seconds(5)); return false }
        let checker = HealthChecker(timeout: .seconds(4), pollInterval: .seconds(1), clock: clock)

        await #expect(throws: DrupalError.self) {
            try await checker.waitUntilHealthy(service: service, id: "site-web", probe: slow)
        }
        #expect(clock.sleeps.isEmpty)
    }

    @Test func probeErrorsAreTreatedAsNotReady() async throws {
        struct Boom: Error {}
        let service = MockContainerService()
        await service.seed(spec, state: .running)
        let attempts = Counter()
        let flaky = HealthProbe(name: "flaky") { _, _ in
            let n = attempts.increment()
            if n < 2 { throw Boom() }
            return true
        }
        try await HealthChecker(timeout: .seconds(5), pollInterval: .seconds(1), clock: TestHealthCheckClock())
            .waitUntilHealthy(service: service, id: "site-web", probe: flaky)
        #expect(attempts.value == 2)
    }

    @Test(arguments: [ContainerState.stopped, .errored, .notFound])
    func deadContainerFailsFastAsContainerFailedToStart(state: ContainerState) async throws {
        let service = MockContainerService()
        await service.seed(spec, state: state)
        let clock = TestHealthCheckClock()
        do {
            try await HealthChecker(timeout: .seconds(60), pollInterval: .seconds(1), clock: clock)
                .waitUntilHealthy(service: service, id: "site-web", probe: .running)
            Issue.record("expected failure")
        } catch let error as DrupalError {
            #expect(error.exitCode == .containerFailedToStart)
        }
        #expect(clock.sleeps.isEmpty)
    }

    @Test func ddevHealthcheckProbeExecsHealthcheckScript() async throws {
        let service = MockContainerService()
        await service.seed(spec, state: .running)
        let calls = Counter()
        await service.setExecHandler { _, _ in
            ExecResult(exitCode: calls.increment() < 2 ? 1 : 0)
        }
        try await HealthChecker(timeout: .seconds(5), pollInterval: .milliseconds(1), clock: TestHealthCheckClock())
            .waitUntilHealthy(service: service, id: "site-web")
        let requests = await service.execRequests
        #expect(requests.map(\.arguments) == [["/healthcheck.sh"], ["/healthcheck.sh"]])
        #expect(requests.allSatisfy { $0.id == "site-web" })
    }

    @Test func realClockDefaultsAreSensible() async throws {
        let checker = HealthChecker()
        #expect(checker.timeout == .seconds(120))
        #expect(checker.pollInterval == .milliseconds(500))
        // Tiny real-time smoke test of the system clock path.
        let service = MockContainerService()
        await service.seed(spec, state: .running)
        await #expect(throws: DrupalError.self) {
            try await HealthChecker(timeout: .milliseconds(20), pollInterval: .milliseconds(5))
                .waitUntilHealthy(service: service, id: "site-web", probe: HealthProbe(name: "no") { _, _ in false })
        }
    }
}

@Suite struct MockContainerServiceLifecycleTests {
    @Test func lifecycleThroughProtocolReportsIPAddress() async throws {
        let service: any ContainerService = MockContainerService()
        let web = try WebContainerSpecBuilder(
            projectName: "site",
            projectRoot: URL(filePath: "/p"),
            config: .default
        ).build()

        try await service.pullImage(web.imageReference)
        try await service.create(web)
        #expect(try await service.inspect(id: web.id).state == .created)
        try await service.start(id: web.id)
        let running = try await service.inspect(id: web.id)
        #expect(running.state == .running)
        #expect(running.ipAddress == "192.168.64.2")
        #expect(running.imageReference == web.imageReference)
        try await service.stop(id: web.id)
        #expect(try await service.inspect(id: web.id).state == .stopped)
        try await service.delete(id: web.id)
        #expect(try await service.inspect(id: web.id) == .notFound(web.id))
    }

    @Test func injectedFailureSurfacesOnce() async throws {
        let mock = MockContainerService()
        await mock.seed(spec, state: .created)
        await mock.failNext(.start, with: .containerFailedToStart("boom"))
        await #expect(throws: DrupalError.containerFailedToStart("boom")) {
            try await mock.start(id: spec.id)
        }
        try await mock.start(id: spec.id)
        #expect(await mock.calls == [.start("site-web"), .start("site-web")])
    }
}

@Suite struct LogBufferTests {
    @Test func splitsChunksIntoLinesPerStream() async throws {
        let buffer = LogBuffer(now: { Date(timeIntervalSince1970: 0) })
        buffer.append(Data("hel".utf8), stream: .stdout)
        buffer.append(Data("lo\nwor".utf8), stream: .stdout)
        buffer.append(Data("err line\r\n".utf8), stream: .stderr)
        buffer.append(Data("ld\n".utf8), stream: .stdout)
        buffer.finish()

        var lines: [LogLine] = []
        for try await line in buffer.stream(follow: true) { lines.append(line) }
        #expect(lines.map(\.message) == ["hello", "err line", "world"])
        #expect(lines.map(\.stream) == [.stdout, .stderr, .stdout])
    }

    @Test func finishFlushesPartialLineAndEndsFollowers() async throws {
        let buffer = LogBuffer()
        let stream = buffer.stream(follow: true)
        buffer.append(Data("a\npartial".utf8), stream: .stdout)
        buffer.finish()
        var messages: [String] = []
        for try await line in stream { messages.append(line.message) }
        #expect(messages == ["a", "partial"])
    }

    @Test func capacityDropsOldestLines() async throws {
        let buffer = LogBuffer(capacity: 2)
        buffer.append(Data("1\n2\n3\n".utf8), stream: .stdout)
        var messages: [String] = []
        for try await line in buffer.stream(follow: false) { messages.append(line.message) }
        #expect(messages == ["2", "3"])
    }
}
