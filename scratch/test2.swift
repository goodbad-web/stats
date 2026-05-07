import Foundation
import Darwin

var usage = rusage_info_v4()
let result = withUnsafeMutablePointer(to: &usage) {
    $0.withMemoryRebound(to: (rusage_info_t?.self), capacity: 1) {
        proc_pid_rusage(1, RUSAGE_INFO_V4, $0)
    }
}
print(usage.ri_energy_impact)
