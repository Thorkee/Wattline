import Foundation

struct TimelineSample {
    let sample: HistorySample
    let maximumGap: TimeInterval
    let startsSegment: Bool
}

enum MonitorTimeline {
    private static let minuteGap: TimeInterval = 95

    static func merge(archive: [HistorySample], live: [HistorySample], from start: Date, through end: Date,
                      liveGaps: [Date: TimeInterval] = [:]) -> [TimelineSample] {
        guard start <= end else { return [] }
        let archive = ordered(archive, start: start, end: end)
        let live = ordered(live, start: start, end: end)
        var coarse = 0
        var fine = 0
        var result: [TimelineSample] = []
        result.reserveCapacity(archive.count + live.count)
        var archiveBreak = false

        func append(_ sample: HistorySample, maximumGap: TimeInterval, boundary: Bool) {
            let tooFar = result.last.map {
                sample.date.timeIntervalSince($0.sample.date) > max($0.maximumGap, maximumGap)
            } ?? false
            result.append(TimelineSample(sample: sample, maximumGap: maximumGap,
                                         startsSegment: boundary || archiveBreak || tooFar))
            archiveBreak = false
        }

        while coarse < archive.count || fine < live.count {
            let minute = coarse < archive.count ? archive[coarse] : nil
            let next = fine < live.count ? live[fine] : nil
            if let minute, next.map({ minute.sample.date < $0.sample.date }) ?? true {
                coarse += 1
                archiveBreak = archiveBreak || minute.sample.startsSegment || minute.clockReset
                // Only suppress minutes bracketed by continuous live measurements.
                if let next, fine > 0, !next.sample.startsSegment, !next.clockReset,
                   next.sample.date.timeIntervalSince(live[fine - 1].sample.date) <= (liveGaps[next.sample.date] ?? 6) {
                    continue
                }
                append(minute.sample, maximumGap: minuteGap, boundary: false)
            } else if let next {
                fine += 1
                var sample = next.sample
                if let minute, minute.sample.date == sample.date {
                    coarse += 1
                    archiveBreak = archiveBreak || minute.sample.startsSegment || minute.clockReset
                    sample = fillingMissing(sample, from: minute.sample)
                }
                // Reopening the monitor starts a new rate baseline. If its prior
                // neighbor is a recent background sample, the Mac kept recording.
                let resumesFromArchive = result.last?.maximumGap == minuteGap
                append(sample, maximumGap: liveGaps[sample.date] ?? 6,
                       boundary: next.clockReset || (sample.startsSegment && !resumesFromArchive))
            }
        }
        return result
    }

    private struct Observation {
        var sample: HistorySample
        var clockReset: Bool
    }

    private static func ordered(_ samples: [HistorySample], start: Date, end: Date) -> [Observation] {
        var result: [Observation] = []
        var previous: Date?
        var clockReset = false
        for sample in samples where sample.date.timeIntervalSinceReferenceDate.isFinite {
            if let previous, sample.date < previous {
                // Wall time went backwards. Earlier samples belong to the old clock.
                result.removeAll(keepingCapacity: true)
                clockReset = true
            }
            previous = sample.date
            guard sample.date >= start, sample.date <= end else { continue }
            var entry = Observation(sample: sample, clockReset: clockReset)
            if let last = result.last, last.sample.date == sample.date {
                entry.sample.startsSegment = entry.sample.startsSegment || last.sample.startsSegment
                entry.clockReset = entry.clockReset || last.clockReset
                result[result.count - 1] = entry
            } else {
                result.append(entry)
            }
            clockReset = false
        }
        return result
    }

    // A new live rate baseline may coincide with a measured archive minute.
    // Only borrow values when the two observations carry the exact same timestamp.
    private static func fillingMissing(_ live: HistorySample, from minute: HistorySample) -> HistorySample {
        HistorySample(date: live.date, cpuPercent: live.cpuPercent ?? minute.cpuPercent,
                      memoryUsed: live.memoryUsed ?? minute.memoryUsed,
                      downloadBytesPerSecond: live.downloadBytesPerSecond ?? minute.downloadBytesPerSecond,
                      uploadBytesPerSecond: live.uploadBytesPerSecond ?? minute.uploadBytesPerSecond,
                      systemWatts: live.systemWatts ?? minute.systemWatts,
                      diskReadBytesPerSecond: live.diskReadBytesPerSecond ?? minute.diskReadBytesPerSecond,
                      diskWriteBytesPerSecond: live.diskWriteBytesPerSecond ?? minute.diskWriteBytesPerSecond,
                      startsSegment: live.startsSegment)
    }
}
