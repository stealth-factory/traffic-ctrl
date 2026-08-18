import Darwin
import Foundation

enum ProcessController {
    static func pause(_ id: ProcessID) -> String? {
        guard id.pid > 1 else {
            return "Refusing to pause a critical system process"
        }
        guard id.pid != Int(getpid()) else {
            return "Refusing to pause Traffic Ctrl itself"
        }
        return send(SIGSTOP, to: id, action: "pause")
    }

    static func resume(_ id: ProcessID) -> String? {
        send(SIGCONT, to: id, action: "resume")
    }

    private static func send(_ signal: Int32, to id: ProcessID, action: String) -> String? {
        guard kill(pid_t(id.pid), signal) == 0 else {
            let message = String(cString: strerror(errno))
            return "Could not \(action) \(id.name) (PID \(id.pid)): \(message)"
        }
        return nil
    }
}
