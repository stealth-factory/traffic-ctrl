import Darwin
import Foundation

let invokedPath = URL(fileURLWithPath: CommandLine.arguments[0])
let canonicalPath = invokedPath.deletingLastPathComponent()
    .appendingPathComponent("traffic-ctrl").path
let arguments = [canonicalPath] + CommandLine.arguments.dropFirst()
var cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
cArguments.append(nil)
defer {
    for argument in cArguments { free(argument) }
}

let status = canonicalPath.withCString { executable in
    cArguments.withUnsafeMutableBufferPointer { buffer in
        execv(executable, buffer.baseAddress!)
    }
}

if status == -1 {
    let message = String(cString: strerror(errno))
    fputs("trctrl: could not launch traffic-ctrl: \(message)\n", stderr)
    exit(127)
}
