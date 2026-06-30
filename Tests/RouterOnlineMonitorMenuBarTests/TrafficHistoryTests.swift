import XCTest
@testable import RouterOnlineMonitorMenuBar

final class TrafficHistoryTests: XCTestCase {
    func testRecentSliceKeepsOnlySamplesAtOrAfterCutoff() {
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let oldSample = sample(at: cutoff.addingTimeInterval(-1))
        let boundarySample = sample(at: cutoff)
        let recentSample = sample(at: cutoff.addingTimeInterval(1))

        let recentSamples = Array(TrafficSampleSeries.recentSlice(
            from: [oldSample, boundarySample, recentSample],
            since: cutoff
        ))

        XCTAssertEqual(recentSamples.map(\.recordedAt), [
            boundarySample.recordedAt,
            recentSample.recordedAt,
        ])
    }

    func testRecentSliceReturnsEmptyWhenAllSamplesAreOlderThanCutoff() {
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let recentSamples = TrafficSampleSeries.recentSlice(
            from: [
                sample(at: cutoff.addingTimeInterval(-2)),
                sample(at: cutoff.addingTimeInterval(-1)),
            ],
            since: cutoff
        )

        XCTAssertTrue(recentSamples.isEmpty)
    }

    func testSampleStorageDropsExpiredSamplesAndCapsLoadedHistory() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }

        let expiredSample = sample(at: now.addingTimeInterval(-TrafficHistoryPolicy.retentionDuration - 1))
        let retainedSamples = (0..<(TrafficHistoryPolicy.maximumStoredSamples + 5)).map { index in
            sample(at: now.addingTimeInterval(TimeInterval(index)))
        }
        let allSamples = [expiredSample] + retainedSamples
        try JSONEncoder().encode(allSamples).write(to: url)

        let loadedSamples = SampleStorage(url: url, now: { now }).load()

        XCTAssertEqual(loadedSamples.count, TrafficHistoryPolicy.maximumStoredSamples)
        XCTAssertEqual(loadedSamples.first?.recordedAt, retainedSamples[5].recordedAt)
        XCTAssertEqual(loadedSamples.last?.recordedAt, retainedSamples.last?.recordedAt)
        XCTAssertFalse(loadedSamples.contains { $0.recordedAt == expiredSample.recordedAt })
    }

    func testChartScaleUsesReadableUpperBounds() {
        XCTAssertEqual(TrafficChartScale.niceUpperBound(0), 1)
        XCTAssertEqual(TrafficChartScale.niceUpperBound(2.4), 3)
        XCTAssertEqual(TrafficChartScale.niceUpperBound(52), 60)
        XCTAssertEqual(TrafficChartScale.niceUpperBound(87), 90)
    }

    func testChartScaleUsesLargestDirection() {
        let samples = [
            TrafficSample(
                recordedAt: Date(timeIntervalSince1970: 1),
                uploadBitsPerSecond: 3_000_000,
                downloadBitsPerSecond: 12_000_000
            ),
            TrafficSample(
                recordedAt: Date(timeIntervalSince1970: 2),
                uploadBitsPerSecond: 52_000_000,
                downloadBitsPerSecond: 6_000_000
            ),
        ]

        XCTAssertEqual(TrafficChartScale.upperBound(for: samples), 60)
    }

    private func sample(at date: Date) -> TrafficSample {
        TrafficSample(
            recordedAt: date,
            uploadBitsPerSecond: 1,
            downloadBitsPerSecond: 2
        )
    }
}
