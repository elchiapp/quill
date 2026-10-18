import Foundation
import Testing
@testable import dropsift

private func stubQVACRuntime() throws -> (QVACRuntime, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
    import json, sys, time
    for line in sys.stdin:
        request = json.loads(line)
        if request['method'] == 'unicode':
            value = ('__DROPSIFT_QVAC__' + json.dumps({
                'id': request['id'], 'type': 'result', 'text': 'Caffè Müller — résumé'
            }, ensure_ascii=False) + '\\n').encode('utf-8')
            boundary = value.index(bytes([0xc3])) + 1
            sys.stdout.buffer.write(value[:boundary])
            sys.stdout.buffer.flush()
            time.sleep(0.05)
            sys.stdout.buffer.write(value[boundary:])
            sys.stdout.buffer.flush()
            continue
        if request['method'] == 'slow':
            time.sleep(10)
        if request['method'] == 'shutdown':
            continue
        print('__DROPSIFT_QVAC__' + json.dumps({
            'id': request['id'], 'type': 'result', 'text': 'ok'
        }), flush=True)
    """
    try Data(script.utf8).write(to: root.appendingPathComponent("bootstrap.cjs"))
    return (QVACRuntime(
        runtimeRoot: root, cacheRoot: root.appendingPathComponent("cache"),
        executable: URL(fileURLWithPath: "/usr/bin/python3")
    ), root)
}

@Test
func qvacQueuedRequestCancellationDoesNotWaitForBusyEngine() async throws {
    let (runtime, root) = try stubQVACRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let active = Task { try await runtime.request("slow") }
    try await Task.sleep(for: .milliseconds(100))
    let queued = Task { try await runtime.request("ping") }
    try await Task.sleep(for: .milliseconds(30))
    let started = ContinuousClock.now
    queued.cancel()
    do { _ = try await queued.value; Issue.record("Cancelled queued request succeeded") }
    catch { #expect(error is CancellationError) }
    #expect(started.duration(to: .now) < .seconds(1))
    await runtime.shutdown(gracePeriod: .milliseconds(50))
    _ = await active.result
}

@Test
func qvacShutdownIsBoundedEvenWhenAnInferenceRequestIsStuck() async throws {
    let (runtime, root) = try stubQVACRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let active = Task { try await runtime.request("slow") }
    try await Task.sleep(for: .milliseconds(100))
    let started = ContinuousClock.now
    await runtime.shutdown(gracePeriod: .milliseconds(50))
    #expect(started.duration(to: .now) < .seconds(2))
    _ = await active.result
    let recovered = try await runtime.request("ping", timeout: .seconds(2))
    #expect(recovered.text == "ok")
    await runtime.shutdown(gracePeriod: .milliseconds(50))
}

@Test
func qvacTimedOutRequestsReleaseTheGateAndCanRestart() async throws {
    let (runtime, root) = try stubQVACRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let started = ContinuousClock.now
    do {
        _ = try await runtime.request("slow", timeout: .milliseconds(100))
        Issue.record("A stuck engine request did not time out")
    } catch QVACRuntime.RuntimeError.requestTimedOut {
        #expect(started.duration(to: .now) < .seconds(1))
    }
    await runtime.restart()
    let response = try await runtime.request("ping", timeout: .seconds(2))
    #expect(response.text == "ok")
    await runtime.shutdown(gracePeriod: .milliseconds(50))
}

@Test
func qvacPreservesUTF8WhenPipeReadsSplitAnAccentedCharacter() async throws {
    let (runtime, root) = try stubQVACRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let response = try await runtime.request("unicode", timeout: .seconds(2))
    #expect(response.text == "Caffè Müller — résumé")
    await runtime.shutdown(gracePeriod: .milliseconds(50))
}
