// Manual integration harness: compile for an iOS simulator with the real SDK.
// Arguments: private test network ID, result JSON path, HTTP port, FTP port.
import Foundation
import CryptoKit

@main struct EmbeddedNetworkSmoke {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count == 5 else { exit(2) }
        let result = URL(fileURLWithPath: args[2]), node = ZeroTierService.shared
        func report(_ phase: String, _ detail: String = "") {
            let data = try! JSONSerialization.data(withJSONObject: ["phase":phase,"node":node.nodeID,"ip":node.address,"detail":detail])
            try! data.write(to: result, options: .atomic)
        }
        do {
            node.networkID = args[1]; await node.setEnabled(true)
            for _ in 0..<120 {
                report("joining", node.status)
                if node.ready { break }; try await Task.sleep(for: .seconds(1))
            }
            guard node.ready else { throw NSError(domain:"smoke",code:1,userInfo:[NSLocalizedDescriptionKey:"Network did not become ready"]) }
            report("transferring")
            let tunnel = try await node.tunnel(host:"172.29.77.1",port:UInt16(args[3])!)
            let session = URLSession(configuration:.ephemeral)
            let (data,response) = try await session.data(from:URL(string:"http://127.0.0.1:\(tunnel.port)/fixture")!)
            session.invalidateAndCancel(); tunnel.cancel()
            guard (response as? HTTPURLResponse)?.statusCode == 200, data == Data(repeating:0x5a,count:512*1024) else { throw NSError(domain:"smoke",code:2) }
            let ftp = FTPClient(host:"172.29.77.1",port:Int(args[4])!,useZeroTier:true)
            report("ftp")
            try await ftp.connect(username:"smoke",password:"fixture-only")
            let entries = try await ftp.listDirectory("/")
            guard entries.contains(where:{$0.name == "fixture.bin"}) else { throw NSError(domain:"smoke",code:3) }
            let upload = result.deletingLastPathComponent().appendingPathComponent("zt-upload.bin")
            let download = result.deletingLastPathComponent().appendingPathComponent("zt-download.bin")
            defer { try? FileManager.default.removeItem(at:upload);try? FileManager.default.removeItem(at:download) }
            try data.write(to:upload)
            try await ftp.upload(localURL:upload,to:"/fixture.bin")
            try await ftp.download(remotePath:"/fixture.bin",to:download)
            guard try Data(contentsOf:download) == data else { throw NSError(domain:"smoke",code:4) }
            await ftp.disconnect()
            let id = node.nodeID
            report("restart")
            await node.setEnabled(false)
            try await Task.sleep(for:.seconds(2))
            await node.setEnabled(true)
            for _ in 0..<30 { if node.ready { break };try await Task.sleep(for:.seconds(1)) }
            guard node.ready, node.nodeID == id else { throw NSError(domain:"smoke",code:5,userInfo:[NSLocalizedDescriptionKey:node.status]) }
            await node.setEnabled(false); report("passed","HTTP + FTP upload/download + disable/re-enable with stable identity")
        } catch { await node.setEnabled(false);report("failed",error.localizedDescription);exit(1) }
    }
}
