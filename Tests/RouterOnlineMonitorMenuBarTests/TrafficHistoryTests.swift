import XCTest
import CoreGraphics
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

    func testChartInterpolationCreatesCurveSegmentsBetweenSamples() {
        let points = [
            CGPoint(x: 0, y: 10),
            CGPoint(x: 10, y: 4),
            CGPoint(x: 20, y: 8),
        ]

        let segments = TrafficChartInterpolation.curveSegments(through: points)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, points[0])
        XCTAssertEqual(segments[0].end, points[1])
        XCTAssertEqual(segments[1].start, points[1])
        XCTAssertEqual(segments[1].end, points[2])

        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.control1.x, segment.start.x)
            XCTAssertLessThanOrEqual(segment.control1.x, segment.end.x)
            XCTAssertGreaterThanOrEqual(segment.control2.x, segment.start.x)
            XCTAssertLessThanOrEqual(segment.control2.x, segment.end.x)

            let minimumY = min(segment.start.y, segment.end.y)
            let maximumY = max(segment.start.y, segment.end.y)
            XCTAssertGreaterThanOrEqual(segment.control1.y, minimumY)
            XCTAssertLessThanOrEqual(segment.control1.y, maximumY)
            XCTAssertGreaterThanOrEqual(segment.control2.y, minimumY)
            XCTAssertLessThanOrEqual(segment.control2.y, maximumY)
        }
    }

    func testChartInterpolationFallsBackToStraightSegmentsForDuplicateXValues() {
        let points = [
            CGPoint(x: 0, y: 10),
            CGPoint(x: 0, y: 4),
            CGPoint(x: 10, y: 8),
        ]

        let segments = TrafficChartInterpolation.curveSegments(through: points)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].control1, points[0])
        XCTAssertEqual(segments[0].control2, points[1])
        XCTAssertEqual(segments[1].control1, points[1])
        XCTAssertEqual(segments[1].control2, points[2])
    }

    private func sample(at date: Date) -> TrafficSample {
        TrafficSample(
            recordedAt: date,
            uploadBitsPerSecond: 1,
            downloadBitsPerSecond: 2
        )
    }
}
