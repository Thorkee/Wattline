import Combine
import Foundation
import SQLite3

struct HistorySample: Codable, Sendable {
    let date: Date
    let cpuPercent: Double?
    let memoryUsed: UInt64?
    let downloadBytesPerSecond: Double?
    let uploadBytesPerSecond: Double?
    let systemWatts: Double?
    let diskReadBytesPerSecond: Double?
    let diskWriteBytesPerSecond: Double?
    var startsSegment: Bool

    fileprivate var minute: Int64 { Int64(floor(date.timeIntervalSince1970 / 60)) }
    fileprivate var valid: Bool {
        let values = [cpuPercent, downloadBytesPerSecond, uploadBytesPerSecond, systemWatts,
                      diskReadBytesPerSecond, diskWriteBytesPerSecond]
        return date.timeIntervalSince1970.isFinite && abs(date.timeIntervalSince1970) < 1e13 &&
            values.compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 } && (cpuPercent ?? 0) <= 100.000001
    }
}

// Compare elapsed wall and monotonic time so clock changes and sleep never join different sessions.
struct ArchiveSchedule {
    private var previous: (wall: Date, uptime: TimeInterval)?
    private var lastSampleUptime: TimeInterval?

    mutating func request(at wall: Date, uptime: TimeInterval) -> (due: Bool, newSegment: Bool) {
        let interrupted = previous.map {
            let elapsed = uptime - $0.uptime
            return elapsed < 0 || elapsed > 120 || abs(wall.timeIntervalSince($0.wall) - elapsed) > 2
        } ?? true
        previous = (wall, uptime)
        guard interrupted || lastSampleUptime.map({ uptime - $0 >= 60 }) == true else { return (false, false) }
        lastSampleUptime = uptime
        return (true, interrupted)
    }
}

// A minute occupies one row. Appending and expiring rows in one transaction also preserves
// the last committed archive if the app terminates during a write.
actor HistoryDatabase {
    static let retention: TimeInterval = 24 * 3600
    private let url: URL

    init(url: URL = URL.applicationSupportDirectory.appendingPathComponent("local.wattline.macos/monitor-history.sqlite3")) {
        self.url = url
    }

    func load(at now: Date) -> [HistorySample]? {
        withDatabase { db in
            let sql = "SELECT recorded, payload, minute FROM history WHERE minute BETWEEN ? AND ? AND recorded BETWEEN ? AND ? ORDER BY minute"
            guard let statement = prepare(sql, db) else { return nil }
            defer { sqlite3_finalize(statement) }
            let cutoff = now.timeIntervalSince1970 - Self.retention
            sqlite3_bind_int64(statement, 1, Int64(floor(cutoff / 60)))
            sqlite3_bind_int64(statement, 2, Int64(floor(now.timeIntervalSince1970 / 60)))
            sqlite3_bind_double(statement, 3, cutoff)
            sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
            var result: [HistorySample] = []
            let decoder = PropertyListDecoder()
            var gap = false
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                defer { step = sqlite3_step(statement) }
                let count = Int(sqlite3_column_bytes(statement, 1))
                guard (1...16384).contains(count), let bytes = sqlite3_column_blob(statement, 1),
                      var sample = try? decoder.decode(HistorySample.self, from: Data(bytes: bytes, count: count)),
                      sample.valid, sample.minute == sqlite3_column_int64(statement, 2),
                      abs(sample.date.timeIntervalSince1970 - sqlite3_column_double(statement, 0)) < 0.001,
                      result.last.map({ $0.date < sample.date }) != false else { gap = true; continue }
                if gap || result.last.map({ sample.date.timeIntervalSince($0.date) > 120 }) == true {
                    sample.startsSegment = true
                }
                result.append(sample)
                gap = false
            }
            return step == SQLITE_DONE ? result : nil
        }
    }

    func append(_ sample: HistorySample) {
        guard sample.valid, let payload = try? PropertyListEncoder().encode(sample) else { return }
        _ = withDatabase { db -> Bool in
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
            defer { if sqlite3_get_autocommit(db) == 0 { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
            guard let insert = prepare("INSERT OR REPLACE INTO history (minute, recorded, payload) VALUES (?, ?, ?)", db)
            else { return false }
            defer { sqlite3_finalize(insert) }
            let time = sample.date.timeIntervalSince1970
            sqlite3_bind_int64(insert, 1, sample.minute)
            sqlite3_bind_double(insert, 2, time)
            let inserted = payload.withUnsafeBytes { bytes in
                sqlite3_bind_blob(insert, 3, bytes.baseAddress, Int32(payload.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK &&
                    sqlite3_step(insert) == SQLITE_DONE
            }
            guard inserted, let prune = prepare("DELETE FROM history WHERE minute < ? OR minute > ? OR (minute = ? AND recorded < ?)", db)
            else { return false }
            defer { sqlite3_finalize(prune) }
            let cutoff = time - Self.retention
            let firstMinute = Int64(floor(cutoff / 60))
            sqlite3_bind_int64(prune, 1, firstMinute)
            sqlite3_bind_int64(prune, 2, sample.minute)
            sqlite3_bind_int64(prune, 3, firstMinute)
            sqlite3_bind_double(prune, 4, cutoff)
            return sqlite3_step(prune) == SQLITE_DONE && sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) -> T?) -> T? {
        let directory = url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return nil }
        var connection: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard let db = connection else { return nil }
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 1000)
        guard let version = prepare("PRAGMA user_version", db) else { return nil }
        let schema = sqlite3_step(version) == SQLITE_ROW ? sqlite3_column_int(version, 0) : -1
        sqlite3_finalize(version)
        switch schema {
        case 0:
            let create = """
                BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS history (minute INTEGER PRIMARY KEY, recorded REAL NOT NULL, payload BLOB NOT NULL);
                PRAGMA user_version=1;
                COMMIT;
                """
            guard sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK else { return nil }
        case 1: break
        default: return nil
        }
        return body(db)
    }

    private func prepare(_ sql: String, _ db: OpaquePointer) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }
}

@MainActor
final class MonitorHistory: ObservableObject {
    @Published private(set) var samples: [HistorySample] = []
    private let database: HistoryDatabase
    private var loaded = false
    private var schedule = ArchiveSchedule()
    private var sampler: SystemMetricsSampler?
    private var task: Task<Void, Never>?

    init(database: HistoryDatabase = HistoryDatabase()) {
        self.database = database
    }

    func sampleIfDue(_ power: PowerReading, uptime: TimeInterval, onMetrics: ((SystemSample) -> Void)? = nil) {
        guard task == nil else { return }
        let request = schedule.request(at: power.date, uptime: uptime)
        guard request.due else { return }
        if request.newSegment { sampler = SystemMetricsSampler(maxInterval: 120) }
        guard let sampler else { return }
        task = Task {
            // pause() cancels a pending task before scheduling a new session.
            defer { if !Task.isCancelled { task = nil } }
            if !loaded {
                let restored = await database.load(at: power.date)
                guard !Task.isCancelled else { return }
                if let restored {
                    samples = Self.restore(restored, keeping: samples, at: power.date)
                    loaded = true
                }
            }
            let metrics = await sampler.sample()
            guard !Task.isCancelled else { return }
            onMetrics?(metrics)
            var sample = HistorySample(
                date: metrics.date, cpuPercent: metrics.cpuPercent, memoryUsed: metrics.memoryUsed,
                downloadBytesPerSecond: metrics.downloadBytesPerSecond, uploadBytesPerSecond: metrics.uploadBytesPerSecond,
                systemWatts: abs(power.date.timeIntervalSince(metrics.date)) <= 12 ? power.systemWatts : nil,
                diskReadBytesPerSecond: metrics.diskReadBytesPerSecond, diskWriteBytesPerSecond: metrics.diskWriteBytesPerSecond,
                startsSegment: request.newSegment)
            guard sample.valid else { return }
            // The wall clock may jump backwards into the middle of recorded history.
            var kept = samples.filter { $0.date >= sample.date.addingTimeInterval(-HistoryDatabase.retention) && $0.minute <= sample.minute }
            if let previous = kept.last, previous.minute == sample.minute {
                sample.startsSegment = sample.startsSegment || previous.startsSegment
                kept.removeLast()
            }
            // Persist before publication. Readers only need the in-memory array; database IO stays on its actor.
            await database.append(sample)
            guard !Task.isCancelled else { return }
            kept.append(sample)
            samples = kept
        }
    }

    // Keep newer in-memory minutes if the archive becomes available after a temporary failure.
    static func restore(_ archive: [HistorySample], keeping live: [HistorySample], at now: Date) -> [HistorySample] {
        guard !live.isEmpty else { return archive }
        let cutoff = now.addingTimeInterval(-HistoryDatabase.retention)
        var minutes = Dictionary(uniqueKeysWithValues: archive.map { ($0.minute, $0) })
        for sample in live where (cutoff...now).contains(sample.date) {
            var newest = sample
            if let stored = minutes[sample.minute] {
                if stored.date > sample.date { newest = stored }
                newest.startsSegment = stored.startsSegment || sample.startsSegment
            }
            minutes[sample.minute] = newest
        }
        return minutes.values.sorted { $0.date < $1.date }
    }

    func pause() {
        if task != nil { loaded = false }
        task?.cancel()
        task = nil
        schedule = ArchiveSchedule()
        sampler = nil
    }
}
