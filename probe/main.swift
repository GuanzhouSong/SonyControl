import Foundation

let link = SonyLink()
link.log = { print($0) }
link.onStatus = { print("status:", $0) }
link.onAmbient = { print("ambient:", $0) }
link.connect()

// Each arg is a hex payload like "66:17", sent in order after connecting.
var t = 4.0
for a in CommandLine.arguments.dropFirst() {
    let bytes = a.split(separator: ":").map { UInt8($0, radix: 16)! }
    DispatchQueue.main.asyncAfter(deadline: .now() + t) { link.sendRaw(bytes) }
    t += 1
}
RunLoop.main.run(until: Date().addingTimeInterval(t + 2))
link.disconnect()
