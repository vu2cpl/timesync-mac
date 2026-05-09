// SPDX-License-Identifier: MIT

import Foundation

NSLog("TimeSyncHelper starting (mach service: \(HelperConstants.machServiceName))")

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
let delegate = HelperListenerDelegate()
listener.delegate = delegate
listener.resume()

// launchd will SIGTERM us when there are no active connections (and ProcessType=Adaptive).
// In the meantime, run the main loop forever.
RunLoop.main.run()
