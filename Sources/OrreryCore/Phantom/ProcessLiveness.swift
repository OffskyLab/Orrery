import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Process identity that survives pid recycling.
///
/// A pid on its own is not an identity — the kernel hands the same number out
/// again once a process is reaped. Pairing it with the process's start time
/// (`kinfo_proc.kp_proc.p_starttime`) gives a stable identity, which is the
/// standard pidfile technique.
public enum ProcessLiveness {

    /// Process start time as seconds since the epoch, or nil if the pid does
    /// not resolve.
    public static func startTime(pid: Int32) -> Double? {
        #if canImport(Darwin)
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var procInfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        let result = mib.withUnsafeMutableBufferPointer { mibPtr in
            withUnsafeMutablePointer(to: &procInfo) { infoPtr in
                infoPtr.withMemoryRebound(to: CChar.self, capacity: size) { bytes in
                    sysctl(mibPtr.baseAddress, 4, bytes, &size, nil, 0)
                }
            }
        }
        // size == 0 means the pid resolved to nothing (already reaped).
        guard result == 0, size > 0 else { return nil }

        let tv = procInfo.kp_proc.p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000.0
        #else
        return nil
        #endif
    }

    /// Tolerance for comparing recorded vs. actual process start times.
    ///
    /// `p_starttime` has microsecond resolution, and `Double` round-trips
    /// exactly through `JSONEncoder`/`JSONDecoder` (no precision is lost), so
    /// this only needs to absorb last-bit formatting drift — not a wide
    /// window. Keeping it at microsecond scale matters: a wide tolerance
    /// would let an unrelated process that reuses a pid shortly after the
    /// recorded process died be mistaken for the same process, which is
    /// exactly the false positive this type exists to prevent.
    private static let startTimeEpsilon = 0.000_002

    /// Whether `pid` is the same process we recorded.
    ///
    /// No `tolerance` parameter is exposed here: a defaulted parameter is
    /// still part of the function's type when referenced as a value (not
    /// called), so `ProcessLiveness.isAlive` would no longer convert to the
    /// `(Int32, Double) -> Bool` closure type `PhantomRegistry.liveEntries`
    /// requires. Keep the epsilon internal instead.
    public static func isAlive(pid: Int32, startedAt: Double) -> Bool {
        guard let actual = startTime(pid: pid) else { return false }
        return abs(actual - startedAt) <= Self.startTimeEpsilon
    }
}
