import XCTest
import CoreGraphics
import SwiftUI
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

    func testSmoothedRatesReduceBurstyCounterSawtoothForChartDisplay() {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = [
            sample(at: start, downloadBitsPerSecond: 108_000_000),
            sample(at: start.addingTimeInterval(5), downloadBitsPerSecond: 108_000_000),
            sample(at: start.addingTimeInterval(10), downloadBitsPerSecond: 59_000_000),
            sample(at: start.addingTimeInterval(15), downloadBitsPerSecond: 108_000_000),
        ]

        let smoothed = TrafficSampleSeries.smoothedRates(
            in: samples,
            window: TrafficSamplingPolicy.rateSmoothingWindow,
            maximumGap: TrafficSamplingPolicy.maximumContinuousSampleGap
        )

        XCTAssertEqual(smoothed.map { round($0.downloadBitsPerSecond / 1_000_000) }, [
            108,
            108,
            92,
            96,
        ])
    }

    func testSmoothedRatesDoNotCrossSleepSizedGaps() {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = [
            sample(at: start, downloadBitsPerSecond: 100_000_000),
            sample(at: start.addingTimeInterval(5), downloadBitsPerSecond: 50_000_000),
            sample(at: start.addingTimeInterval(65), downloadBitsPerSecond: 10_000_000),
        ]

        let smoothed = TrafficSampleSeries.smoothedRates(
            in: samples,
            window: TrafficSamplingPolicy.rateSmoothingWindow,
            maximumGap: TrafficSamplingPolicy.maximumContinuousSampleGap
        )

        XCTAssertEqual(smoothed.map(\.downloadBitsPerSecond), [
            100_000_000,
            75_000_000,
            10_000_000,
        ])
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

    func testChartScaleUsesTwentyPercentHeadroomWhenCapacityIsConfigured() {
        let samples = [
            TrafficSample(
                recordedAt: Date(timeIntervalSince1970: 1),
                uploadBitsPerSecond: 5_000_000,
                downloadBitsPerSecond: 230_000_000
            ),
        ]

        XCTAssertEqual(
            TrafficChartScale.upperBound(for: samples, configuredCapacityMbit: 108),
            129.6,
            accuracy: 0.001
        )
    }

    func testChartScaleUsesDirectionSpecificCapacityWhenConfigured() {
        let samples = [
            TrafficSample(
                recordedAt: Date(timeIntervalSince1970: 1),
                uploadBitsPerSecond: 80_000_000,
                downloadBitsPerSecond: 230_000_000
            ),
        ]

        XCTAssertEqual(
            TrafficChartScale.upperBound(
                for: samples,
                value: \.uploadBitsPerSecond,
                configuredCapacityMbit: 40
            ),
            48,
            accuracy: 0.001
        )
    }

    func testChartScaleReadsConfiguredCapacities() {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(108.187, forKey: "downstreamCapacityMbit")
        defaults.set(20.5, forKey: "upstreamCapacityMbit")

        let capacities = TrafficChartScale.configuredCapacitiesMbit(defaults: defaults)

        XCTAssertEqual(capacities.download ?? 0, 108.187, accuracy: 0.001)
        XCTAssertEqual(capacities.upload ?? 0, 20.5, accuracy: 0.001)
        XCTAssertEqual(TrafficChartScale.configuredCapacityUpperBoundMbit(defaults: defaults) ?? 0, 108.187, accuracy: 0.001)
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

    func testChartInterpolationAreaPathExtendsToBaseline() {
        let path = TrafficChartInterpolation.areaPath(
            through: [
                CGPoint(x: 0, y: 10),
                CGPoint(x: 10, y: 4),
                CGPoint(x: 20, y: 8),
            ],
            baselineY: 30
        )

        XCTAssertEqual(path.boundingRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.maxX, 20, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.minY, 4, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.maxY, 30, accuracy: 0.001)
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

    func testChartInterpolationSplitsRunsAtMinuteSizedGaps() {
        let start = Date(timeIntervalSince1970: 1_000)
        let points = [
            chartPoint(at: start, point: CGPoint(x: 0, y: 4)),
            chartPoint(at: start.addingTimeInterval(5), point: CGPoint(x: 5, y: 6)),
            chartPoint(at: start.addingTimeInterval(65), point: CGPoint(x: 65, y: 3)),
            chartPoint(at: start.addingTimeInterval(70), point: CGPoint(x: 70, y: 8)),
        ]

        let runs = TrafficChartInterpolation.contiguousRuns(
            in: points,
            maximumGap: TrafficSamplingPolicy.maximumContinuousSampleGap
        )

        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].map(\.point), [points[0].point, points[1].point])
        XCTAssertEqual(runs[1].map(\.point), [points[2].point, points[3].point])
    }

    func testChartInterpolationKeepsSubMinuteGapsInSameRun() {
        let start = Date(timeIntervalSince1970: 1_000)
        let points = [
            chartPoint(at: start, point: CGPoint(x: 0, y: 4)),
            chartPoint(at: start.addingTimeInterval(59.9), point: CGPoint(x: 59.9, y: 6)),
        ]

        let runs = TrafficChartInterpolation.contiguousRuns(
            in: points,
            maximumGap: TrafficSamplingPolicy.maximumContinuousSampleGap
        )

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].map(\.point), points.map(\.point))
    }

    func testChartInterpolationAddsMarkersAroundMinuteSizedGaps() {
        let start = Date(timeIntervalSince1970: 1_000)
        let points = [
            chartPoint(at: start, point: CGPoint(x: 0, y: 4)),
            chartPoint(at: start.addingTimeInterval(5), point: CGPoint(x: 5, y: 6)),
            chartPoint(at: start.addingTimeInterval(65), point: CGPoint(x: 65, y: 3)),
            chartPoint(at: start.addingTimeInterval(70), point: CGPoint(x: 70, y: 8)),
        ]

        let markerPoints = TrafficChartInterpolation.gapMarkerPoints(
            in: points,
            maximumGap: TrafficSamplingPolicy.maximumContinuousSampleGap
        )

        XCTAssertEqual(markerPoints, [points[1].point, points[2].point])
    }

    func testRateEstimatorUsesLongerWindowAfterWarmup() {
        let start = Date(timeIntervalSince1970: 1_000)
        let observations = [
            counterObservation(at: start, receivedBytes: bytes(forMbit: 0, seconds: 0)),
            counterObservation(at: start.addingTimeInterval(5), receivedBytes: bytes(forMbit: 108, seconds: 5)),
            counterObservation(at: start.addingTimeInterval(10), receivedBytes: bytes(forMbit: 108 + 108, seconds: 5)),
        ]
        let current = counterObservation(
            at: start.addingTimeInterval(15),
            receivedBytes: bytes(forMbit: 108 + 108 + 59, seconds: 5)
        )

        let sample = TrafficRateEstimator.sample(from: observations, to: current)

        XCTAssertEqual(sample?.downloadBitsPerSecond ?? 0, 91_666_666, accuracy: 1)
    }

    func testRateEstimatorSkipsSleepSizedGapsAndResetsObservationHistory() {
        let start = Date(timeIntervalSince1970: 1_000)
        let observations = [
            counterObservation(at: start, receivedBytes: 0),
            counterObservation(at: start.addingTimeInterval(5), receivedBytes: bytes(forMbit: 100, seconds: 5)),
        ]
        let current = counterObservation(
            at: start.addingTimeInterval(65),
            receivedBytes: bytes(forMbit: 100, seconds: 10)
        )

        XCTAssertNil(TrafficRateEstimator.sample(from: observations, to: current))
        XCTAssertEqual(TrafficRateEstimator.observations(afterAdding: current, to: observations).map(\.recordedAt), [
            current.recordedAt,
        ])
    }

    private func sample(at date: Date) -> TrafficSample {
        sample(at: date, downloadBitsPerSecond: 2)
    }

    private func sample(at date: Date, downloadBitsPerSecond: Double) -> TrafficSample {
        TrafficSample(
            recordedAt: date,
            uploadBitsPerSecond: 1,
            downloadBitsPerSecond: downloadBitsPerSecond
        )
    }

    private func chartPoint(at date: Date, point: CGPoint) -> TrafficChartInterpolation.ChartPoint {
        TrafficChartInterpolation.ChartPoint(recordedAt: date, point: point)
    }

    private func counterObservation(
        at date: Date,
        sentBytes: UInt64 = 0,
        receivedBytes: UInt64
    ) -> TrafficCounterObservation {
        TrafficCounterObservation(recordedAt: date, sent: sentBytes, received: receivedBytes)
    }

    private func bytes(forMbit mbit: Double, seconds: Double) -> UInt64 {
        UInt64(mbit * 1_000_000 * seconds / 8)
    }
}
