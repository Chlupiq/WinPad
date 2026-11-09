// SPDX-License-Identifier: MIT
// WinPad Wine's built-in JIT helper: an app extension (PlugIns/WinPadJITHelper.appex) that
// enables the JIT for the app with StikJIT, over the device's own debug tunnel (LocalDevVPN
// and a pairing file), so that no StikDebug app is needed. It has to be another process: a
// process that attaches a debugger to itself stops with it.
//
// The app (WinPadJIT.m, WinPadJITBuiltInSend) starts it by its bundle ID with one extension
// request: JSON in the input item's userInfo["winpad-jit-request"]:
//   {"operation": "prepare" | "enable", "pid": N, "pairing": <base64 pairing file>, "txm": true}
// and gets JSON back in the returned item's userInfo["winpad-jit-response"]:
//   {"success": true, "message": "..."}
// "enable" attaches StikJIT's universal.js script to the app and returns once the app has had
// its JIT pool prepared and the script has detached (JITPool.c). "prepare" only checks the
// tunnel and mounts the Developer Disk Image.
import Foundation
#if canImport(StikJIT)
import StikJIT
#endif

struct WinPadJITRequest: Codable {
    static let itemKey = "winpad-jit-request"
    let operation: String
    let pid: Int32?
    let pairing: Data?
    let txm: Bool?
}

struct WinPadJITResponse: Codable {
    static let itemKey = "winpad-jit-response"
    let success: Bool
    let message: String
}

private enum Work {
    // One request at a time: StikJIT's calls block and must not run side by side.
    static let queue = DispatchQueue(label: "winpad.jit-helper")

    static func handle(_ request: WinPadJITRequest) -> WinPadJITResponse {
#if canImport(StikJIT)
        let files = FileManager.default
        let root = files.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)
        guard let pairing = request.pairing, !pairing.isEmpty else {
            return .init(success: false, message: "Chybí párovací soubor.")
        }
        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            // The pairing file only for this request, removed straight after.
            let pairingURL = root.appendingPathComponent("pairing-\(UUID().uuidString).plist")
            try pairing.write(to: pairingURL, options: .atomic)
            defer { try? files.removeItem(at: pairingURL) }
            var log: [String] = []
            let note: (String) -> Void = { line in
                NSLog("[WinPadJIT] %@", line)
                log.append(line)
                if log.count > 6 { log.removeFirst() }
            }
            switch request.operation {
            case "prepare":
                switch StikJIT.prepareDevice(pairingFile: pairingURL, paths: paths,
                                             progress: { note(String(describing: $0)) }) {
                case .ready:
                    return .init(success: true, message: "LocalDevVPN funguje a vývojářský obraz disku je připravený.")
                case .unreachable(let reason):
                    return .init(success: false, message: "Zařízení není dosažitelné (zapnutá LocalDevVPN?): \(reason)")
                case .preparationFailed(let reason):
                    return .init(success: false, message: reason)
                @unknown default:
                    return .init(success: false, message: "StikJIT vrátil neznámý stav.")
                }
            case "enable":
                guard let pid = request.pid else {
                    return .init(success: false, message: "Chybí číslo procesu aplikace.")
                }
                try StikJIT.enableJIT(targetPID: pid, pairingFile: pairingURL, ddiPaths: paths,
                                      script: .universal, forceScript: request.txm ?? false,
                                      preparationProgress: { note(String(describing: $0)) },
                                      progress: note)
                return .init(success: true, message: "JIT je zapnutý.")
            default:
                return .init(success: false, message: "Neznámá operace \(request.operation).")
            }
        } catch {
            return .init(success: false, message: error.localizedDescription)
        }
#else
        return .init(success: false, message: "Vestavěný JIT funguje jen na skutečném iPadu nebo iPhonu.")
#endif
    }
}

// NSExtensionPrincipalClass (Info.plist). The request completes with the answer, so this
// process lives as long as the debugger it runs.
@objc(WinPadJITHelperHandler)
final class WinPadJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[WinPadJITRequest.itemKey] as? Data
        let request = data.flatMap { try? JSONDecoder().decode(WinPadJITRequest.self, from: $0) }
        Work.queue.async {
            let response = request.map(Work.handle)
                ?? WinPadJITResponse(success: false, message: "Pomocník JITu nedostal žádnou žádost.")
            let item = NSExtensionItem()
            item.userInfo = [WinPadJITResponse.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
