import Foundation
import OrreryCore

/// Each step type has its own executor (the project intentionally avoids a
/// single beastly `applyStep(_:)` switch). Executors are pure-ish: they touch
/// the filesystem but do not maintain internal state between calls.
enum StepExecutor {}
