import Foundation

// MARK: - Stratum Client for Pool Mining

struct StratumJob {
    let id: String
    let headerHash: String  // hex, no 0x
    let seedHash: String    // hex, no 0x
    let target: String      // hex, no 0x
    let height: Int
    let bits: String
    let cleanJobs: Bool
}

actor StratumClient {
    private var host: String
    private var port: Int
    private var worker: String
    private var password: String

    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var buffer = ""
    private var nextId = 1
    private(set) var subscribed = false
    private(set) var authorized = false

    private(set) var latestJob: StratumJob? = nil
    private(set) var currentTarget: String = ""
    private var jobVersion: Int = 0  // increments on each new job

    var isConnected: Bool { subscribed && authorized }

    init(host: String, port: Int, worker: String, password: String = "x") {
        self.host = host
        self.port = port
        self.worker = worker
        self.password = password
    }

    func getTarget() -> String { currentTarget }
    func getJobVersion() -> Int { jobVersion }

    func connect() async throws {
        var inStream: InputStream?
        var outStream: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &inStream, outputStream: &outStream)
        guard let ins = inStream, let outs = outStream else {
            throw NSError(domain: "Stratum", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create streams"])
        }
        inputStream = ins
        outputStream = outs
        ins.open()
        outs.open()

        // Small delay for connection
        try await Task.sleep(nanoseconds: 500_000_000)

        // Subscribe
        try sendJson(["id": nextId, "method": "mining.subscribe", "params": ["kawpow-metal/1.0", "EthereumStratum/1.0.0"]])
        nextId += 1

        // Start reading in background
        Task { await self.readLoop() }
    }

    /// Wait until we have a job (poll-based)
    func waitForJob(timeout: Double = 30) async throws -> StratumJob {
        let deadline = Date().addingTimeInterval(timeout)
        while latestJob == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let job = latestJob else {
            throw NSError(domain: "Stratum", code: -1, userInfo: [NSLocalizedDescriptionKey: "No job received from pool"])
        }
        return job
    }

    private func sendJson(_ obj: [String: Any]) throws {
        guard let outs = outputStream else { throw NSError(domain: "Stratum", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"]) }
        let data = try JSONSerialization.data(withJSONObject: obj)
        let line = String(data: data, encoding: .utf8)! + "\n"
        let bytes = Array(line.utf8)
        outs.write(bytes, maxLength: bytes.count)
    }

    func submitShare(jobId: String, nonce: String, headerHash: String, mixHash: String) async throws {
        try sendJson([
            "id": nextId,
            "method": "mining.submit",
            "params": [worker, jobId, "0x" + nonce, "0x" + headerHash, "0x" + mixHash]
        ])
        nextId += 1
    }

    private func readLoop() async {
        guard let ins = inputStream else { return }
        let bufSize = 4096
        var readBuf = [UInt8](repeating: 0, count: bufSize)

        while ins.streamStatus == .open || ins.hasBytesAvailable {
            if ins.hasBytesAvailable {
                let count = ins.read(&readBuf, maxLength: bufSize)
                if count <= 0 {
                    if count < 0 { print("[STRATUM] Read error"); break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                buffer += String(bytes: readBuf[0..<count], encoding: .utf8) ?? ""

                while let nl = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<nl]).trimmingCharacters(in: .whitespaces)
                    buffer = String(buffer[buffer.index(after: nl)...])
                    if !line.isEmpty { await handleMessage(line) }
                }
            } else {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        print("[STRATUM] Connection closed")
    }

    private func handleMessage(_ msg: String) async {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let method = json["method"] as? String {
            let params = json["params"] as? [Any] ?? []

            switch method {
            case "mining.notify":
                guard params.count >= 6 else { return }
                let jobId = params[0] as? String ?? ""
                let headerHash = (params[1] as? String ?? "").replacingOccurrences(of: "0x", with: "")
                let seedHash = (params[2] as? String ?? "").replacingOccurrences(of: "0x", with: "")
                let target = (params[3] as? String ?? "").replacingOccurrences(of: "0x", with: "")
                let cleanJobs = params[4] as? Bool ?? true
                let height = params[5] as? Int ?? 0
                let bits = (params.count > 6 ? params[6] as? String ?? "" : "").replacingOccurrences(of: "0x", with: "")

                let job = StratumJob(id: jobId, headerHash: headerHash, seedHash: seedHash,
                                     target: target, height: height, bits: bits, cleanJobs: cleanJobs)
                latestJob = job
                jobVersion += 1
                // Don't override share target from mining.set_target with block target from notify
                print("[STRATUM] New job: \(jobId) height=\(height) clean=\(cleanJobs)")

            case "mining.set_target":
                if let t = params.first as? String {
                    currentTarget = t.replacingOccurrences(of: "0x", with: "")
                    print("[STRATUM] New target: \(currentTarget.prefix(20))...")
                }

            case "mining.set_difficulty":
                if let d = params.first as? Double, d > 0 {
                    // difficulty -> target: target = maxTarget / difficulty
                    // maxTarget = 0x00000000ffff... (simplified)
                    // For now just store the raw difficulty, pool sends set_target anyway
                    print("[STRATUM] New difficulty: \(d)")
                }

            default:
                print("[STRATUM] Unknown method: \(method)")
            }
        } else {
            // Response to our request
            let id = json["id"] as? Int ?? 0
            let result = json["result"]
            let error = json["error"]

            if !subscribed && id == 1 {
                subscribed = true
                print("[STRATUM] Subscribed")
                // Authorize
                try? sendJson(["id": nextId, "method": "mining.authorize", "params": [worker, password]])
                nextId += 1
            } else if !authorized && id == 2 {
                if result as? Bool == true {
                    authorized = true
                    print("[STRATUM] Authorized as \(worker)")
                } else {
                    print("[STRATUM] Auth failed: \(String(describing: error))")
                }
            } else {
                // Share response
                if let accepted = result as? Bool {
                    if accepted {
                        print("[STRATUM] ✅ Share accepted!")
                    } else {
                        let errMsg = (error as? [Any])?[1] as? String ?? "unknown"
                        print("[STRATUM] ❌ Share rejected: \(errMsg)")
                    }
                }
            }
        }
    }

    func disconnect() {
        inputStream?.close()
        outputStream?.close()
        print("[STRATUM] Disconnected")
    }
}
