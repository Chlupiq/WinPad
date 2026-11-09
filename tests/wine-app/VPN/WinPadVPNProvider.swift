// SPDX-License-Identifier: MIT
// WinPad Wine's own loopback VPN (PlugIns/WinPadVPN.appex), in place of the LocalDevVPN app:
// the built-in JIT helper (JITHelper/) reaches the iPad's own debug services at 10.7.0.1, and
// this tunnel sends every packet for that address straight back with source and destination
// swapped, so the iPad sees a connection from the "network". The approach is that of the
// SideStore team's StosVPN / LocalDevVPN; this is a separate, minimal implementation.
//
// A packet tunnel needs the Network Extension entitlement, which only a paid developer account
// can sign: the app carries it only when built with WINPAD_VPN = YES (WinPad.xcconfig), else
// it uses LocalDevVPN (WinPadJIT.m, WinPadVPNBuiltIn).
import NetworkExtension

final class WinPadVPNProvider: NEPacketTunnelProvider {
    // As LocalDevVPN's defaults: this end of the tunnel, and the address the debug tools use.
    static let interfaceIP = "10.7.1.1"
    static let peerIP = "10.7.0.1"

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let ipv4 = NEIPv4Settings(addresses: [Self.interfaceIP], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: Self.peerIP, subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = [.default()]
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Self.peerIP)
        settings.ipv4Settings = ipv4
        setTunnelNetworkSettings(settings) { error in
            if let error {
                completionHandler(error)
                return
            }
            self.loop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    // Each IPv4 packet goes back with its source and destination addresses swapped (bytes 12-15
    // and 16-19 of the header); the checksum stays valid, as it sums both the same.
    private func loop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            var out = packets
            for i in out.indices where protocols[i].int32Value == AF_INET && out[i].count >= 20 {
                out[i].withUnsafeMutableBytes { bytes in
                    for k in 0..<4 { bytes.swapAt(12 + k, 16 + k) }
                }
            }
            self.packetFlow.writePackets(out, withProtocols: protocols)
            self.loop()
        }
    }
}
