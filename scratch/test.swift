import Foundation
import Darwin

let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
var pids = [pid_t](repeating: 0, count: Int(bufferSize) / MemoryLayout<pid_t>.size)
proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)

for pid in pids.prefix(10) {
    if pid == 0 { continue }
    var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
    let name = String(cString: nameBuffer)
    
    var taskInfo = proc_taskinfo()
    let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
    if result == MemoryLayout<proc_taskinfo>.size {
        print("PID: \(pid), Name: \(name), RSS: \(taskInfo.pti_resident_size)")
    }
}
