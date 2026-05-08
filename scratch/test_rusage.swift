import Foundation

// swiftlint:disable identifier_name
struct rusage_info_v4 {
    var ri_uuid: [UInt8] = Array(repeating: 0, count: 16)
    var ri_user_time: UInt64 = 0
    var ri_system_time: UInt64 = 0
    var ri_pkg_idle_wkups: UInt64 = 0
    var ri_interrupt_wkups: UInt64 = 0
    var ri_pageins: UInt64 = 0
    var ri_wired_size: UInt64 = 0
    var ri_resident_size: UInt64 = 0
    var ri_phys_footprint: UInt64 = 0
    var ri_proc_start_abstime: UInt64 = 0
    var ri_proc_exit_abstime: UInt64 = 0
    var ri_child_user_time: UInt64 = 0
    var ri_child_system_time: UInt64 = 0
    var ri_child_pkg_idle_wkups: UInt64 = 0
    var ri_child_interrupt_wkups: UInt64 = 0
    var ri_child_pageins: UInt64 = 0
    var ri_child_elapsed_abstime: UInt64 = 0
    var ri_diskio_bytesread: UInt64 = 0
    var ri_diskio_byteswritten: UInt64 = 0
    var ri_cpu_time_qos_default: UInt64 = 0
    var ri_cpu_time_qos_maintenance: UInt64 = 0
    var ri_cpu_time_qos_background: UInt64 = 0
    var ri_cpu_time_qos_utility: UInt64 = 0
    var ri_cpu_time_qos_legacy: UInt64 = 0
    var ri_cpu_time_qos_user_interactive: UInt64 = 0
    var ri_cpu_time_qos_user_initiated: UInt64 = 0
    var ri_energy_impact_nanoseconds: UInt64 = 0
}

@_silgen_name("proc_pid_rusage")
func proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

let RUSAGE_INFO_V4: Int32 = 4

func test() {
    let pid: Int32 = getpid()
    print("Testing for PID: \(pid)")
    
    for flavor in Int32(3)...Int32(6) {
        var usage = rusage_info_v4()
        let res = proc_pid_rusage(pid, flavor, &usage)
        print("Flavor \(flavor) Result: \(res)")
        if res == 0 {
            print("  Energy Impact: \(usage.ri_energy_impact_nanoseconds)")
        }
    }
}

test()
// swiftlint:enable identifier_name
