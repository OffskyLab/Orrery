import XCTest
@testable import OrreryCore

final class SpecProgressLogTests: XCTestCase {

    // Use a per-test temp file to avoid cross-test pollution.
    private var tmpPath: String!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-progress-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tmpPath = dir.appendingPathComponent("\(UUID().uuidString).jsonl").path
    }

    override func tearDown() {
        if let p = tmpPath { try? FileManager.default.removeItem(atPath: p) }
        super.tearDown()
    }

    private func event(
        _ ts: String, _ step: String, _ kind: String, note: String? = nil
    ) -> SpecProgressLog.Event {
        SpecProgressLog.Event(ts: ts, step: step, event: kind, note: note)
    }

    // MARK: - append + read round-trip

    func testAppend_createsFile_whenMissing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpPath))
        try SpecProgressLog.append(
            path: tmpPath,
            event: event("2026-04-20T12:00:00Z", "step-1", "start", note: "first")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpPath))
    }

    func testAppend_appendsMultipleLines() throws {
        try SpecProgressLog.append(path: tmpPath, event: event("2026-04-20T12:00:00Z", "step-1", "start"))
        try SpecProgressLog.append(path: tmpPath, event: event("2026-04-20T12:01:00Z", "step-1", "done"))
        try SpecProgressLog.append(path: tmpPath, event: event("2026-04-20T12:02:00Z", "step-2", "start"))

        let events = try SpecProgressLog.read(path: tmpPath)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].step, "step-1")
        XCTAssertEqual(events[0].event, "start")
        XCTAssertEqual(events[1].event, "done")
        XCTAssertEqual(events[2].step, "step-2")
    }

    func testRead_missingFile_returnsEmpty() throws {
        let events = try SpecProgressLog.read(path: "/nonexistent/\(UUID().uuidString).jsonl")
        XCTAssertEqual(events, [])
    }

    func testRead_badLinesSkipped_goodLinesReturned() throws {
        // Manually write a mix of valid JSON and garbage
        let content = """
        {"ts":"2026-04-20T12:00:00Z","step":"step-1","event":"start"}
        this is not json
        {"ts":"2026-04-20T12:01:00Z","step":"step-1","event":"done"}
        {"malformed": "missing required fields"}
        {"ts":"2026-04-20T12:02:00Z","step":"step-2","event":"start","note":"ok"}

        """
        try content.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        let events = try SpecProgressLog.read(path: tmpPath)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.step), ["step-1", "step-1", "step-2"])
    }

    // MARK: - inferFailedStep

    func testInferFailedStep_allMatched_returnsNil() {
        let events = [
            event("t1", "step-1", "start"),
            event("t2", "step-1", "done"),
            event("t3", "step-2", "start"),
            event("t4", "step-2", "done")
        ]
        XCTAssertNil(SpecProgressLog.inferFailedStep(events: events))
    }

    func testInferFailedStep_skipAlsoCounts_asClosedStep() {
        let events = [
            event("t1", "step-1", "start"),
            event("t2", "step-1", "skip", note: "n/a")
        ]
        XCTAssertNil(SpecProgressLog.inferFailedStep(events: events))
    }

    func testInferFailedStep_unclosedStart_returnsStep() {
        let events = [
            event("t1", "step-1", "start"),
            event("t2", "step-1", "done"),
            event("t3", "step-2", "start")  // never done / skip
        ]
        XCTAssertEqual(SpecProgressLog.inferFailedStep(events: events), "step-2")
    }

    func testInferFailedStep_nestedSameStep_latestUnclosedWins() {
        // step-1 gets restarted without being closed first; in our state-machine
        // sense the last `start` defines the open step.
        let events = [
            event("t1", "step-1", "start"),
            event("t2", "step-1", "done"),
            event("t3", "step-1", "start")  // restarted, never closed
        ]
        XCTAssertEqual(SpecProgressLog.inferFailedStep(events: events), "step-1")
    }

    func testInferFailedStep_mismatchedCompletion_doesNotClose() {
        let events = [
            event("t1", "step-1", "start"),
            event("t2", "step-99", "done")  // wrong step name
        ]
        XCTAssertEqual(SpecProgressLog.inferFailedStep(events: events), "step-1")
    }

    func testInferFailedStep_emptyList_returnsNil() {
        XCTAssertNil(SpecProgressLog.inferFailedStep(events: []))
    }

    // MARK: - completedSteps

    func testCompletedSteps_returnsDoneStepsInOrder() {
        let events = [
            event("t1", "step-a", "start"),
            event("t2", "step-a", "done"),
            event("t3", "step-b", "start"),
            event("t4", "step-b", "done"),
            event("t5", "step-c", "start"),
            event("t6", "step-c", "skip")   // skip should NOT count as done
        ]
        XCTAssertEqual(SpecProgressLog.completedSteps(events: events), ["step-a", "step-b"])
    }

    func testCompletedSteps_emptyList() {
        XCTAssertEqual(SpecProgressLog.completedSteps(events: []), [])
    }

    // MARK: - tail

    private func writeFixtureForTail() throws {
        let content = """
        {"ts":"2026-04-20T12:00:00Z","step":"step-1","event":"start"}
        {"ts":"2026-04-20T12:01:00Z","step":"step-1","event":"done"}
        {"ts":"2026-04-20T12:02:00Z","step":"step-2","event":"start"}
        {"ts":"2026-04-20T12:03:00Z","step":"step-2","event":"done"}
        {"ts":"2026-04-20T12:04:00Z","step":"step-3","event":"start"}
        """
        try content.write(toFile: tmpPath, atomically: true, encoding: .utf8)
    }

    func testTail_returnsLastNLines() throws {
        try writeFixtureForTail()
        let result = try SpecProgressLog.tail(path: tmpPath, lines: 2, since: nil)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].contains("\"step-2\""))
        XCTAssertTrue(result[1].contains("\"step-3\""))
    }

    func testTail_sinceFiltersOutOlderEvents() throws {
        try writeFixtureForTail()
        let result = try SpecProgressLog.tail(
            path: tmpPath, lines: 100, since: "2026-04-20T12:02:30Z"
        )
        // Only events with ts > 2026-04-20T12:02:30Z survive: step-2 done + step-3 start
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].contains("\"step-2\"") && result[0].contains("\"done\""))
        XCTAssertTrue(result[1].contains("\"step-3\"") && result[1].contains("\"start\""))
    }

    func testTail_sinceAndLineLimit_combine() throws {
        try writeFixtureForTail()
        let result = try SpecProgressLog.tail(
            path: tmpPath, lines: 1, since: "2026-04-20T12:00:30Z"
        )
        // filtered = 4 events after 12:00:30; take last 1 → step-3 start
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].contains("\"step-3\""))
    }

    func testTail_missingFile_returnsEmpty() throws {
        let result = try SpecProgressLog.tail(
            path: "/nonexistent/\(UUID().uuidString).jsonl", lines: 10, since: nil
        )
        XCTAssertEqual(result, [])
    }

    func testTail_zeroLines_returnsEmpty() throws {
        try writeFixtureForTail()
        let result = try SpecProgressLog.tail(path: tmpPath, lines: 0, since: nil)
        XCTAssertEqual(result, [])
    }

    func testTail_badLinesSkipped_duringSinceFilter() throws {
        let content = """
        {"ts":"2026-04-20T12:00:00Z","step":"step-1","event":"start"}
        not json at all
        {"ts":"2026-04-20T12:05:00Z","step":"step-2","event":"done"}
        """
        try content.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        let result = try SpecProgressLog.tail(
            path: tmpPath, lines: 10, since: "2026-04-20T11:00:00Z"
        )
        // bad line skipped even though since filter would otherwise include it
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.contains("\"step-") })
    }
}
