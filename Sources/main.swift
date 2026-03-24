import Foundation
@preconcurrency import Metal

// MARK: - KISS99 RNG
struct Kiss99 {
    var z: UInt32, w: UInt32, jsr: UInt32, jcong: UInt32
    mutating func next() -> UInt32 {
        z = 36969 &* (z & 65535) &+ (z >> 16)
        w = 18000 &* (w & 65535) &+ (w >> 16)
        let mwc = (z << 16) &+ w
        jsr ^= (jsr << 17); jsr ^= (jsr >> 13); jsr ^= (jsr << 5)
        jcong = 69069 &* jcong &+ 1234567
        return (mwc ^ jcong) &+ jsr
    }
}

func fnv1a(_ h: inout UInt32, _ d: UInt32) -> UInt32 {
    h = (h ^ d) &* 0x01000193; return h
}

// MARK: - ProgPow Loop Code Generator
func generateProgPowLoop(progSeed: UInt64, dagElements: UInt32) -> String {
    let REGS = 32; let DAG_LOADS = 4; let CNT_CACHE = 11; let CNT_MATH = 18
    var fnvHash: UInt32 = 0x811c9dc5
    var rng = Kiss99(z: fnv1a(&fnvHash, UInt32(progSeed & 0xFFFFFFFF)),
                     w: fnv1a(&fnvHash, UInt32(progSeed >> 32)),
                     jsr: fnv1a(&fnvHash, UInt32(progSeed & 0xFFFFFFFF)),
                     jcong: fnv1a(&fnvHash, UInt32(progSeed >> 32)))
    var mixSeqDst = Array(0..<REGS), mixSeqCache = Array(0..<REGS)
    var dstCnt = 0, cacheCnt = 0
    for i in stride(from: REGS - 1, through: 1, by: -1) {
        var j = Int(rng.next()) % (i + 1); mixSeqDst.swapAt(i, j)
        j = Int(rng.next()) % (i + 1); mixSeqCache.swapAt(i, j)
    }
    func mixDst() -> String { let r = "mix[\(mixSeqDst[dstCnt % REGS])]"; dstCnt += 1; return r }
    func mixCacheSrc() -> String { let r = "mix[\(mixSeqCache[cacheCnt % REGS])]"; cacheCnt += 1; return r }
    func merge(_ a: String, _ b: String, _ r: UInt32) -> String {
        switch r % 4 {
        case 0: return "\(a) = (\(a) * 33) + \(b);\n"
        case 1: return "\(a) = (\(a) ^ \(b)) * 33;\n"
        case 2: return "\(a) = ROTL32(\(a), \(((r >> 16) % 31) + 1)) ^ \(b);\n"
        case 3: return "\(a) = ROTR32(\(a), \(((r >> 16) % 31) + 1)) ^ \(b);\n"
        default: return ""
        }
    }
    func math(_ d: String, _ a: String, _ b: String, _ r: UInt32) -> String {
        switch r % 11 {
        case 0: return "\(d) = \(a) + \(b);\n"
        case 1: return "\(d) = \(a) * \(b);\n"
        case 2: return "\(d) = mulhi(\(a), \(b));\n"
        case 3: return "\(d) = min(\(a), \(b));\n"
        case 4: return "\(d) = ROTL32(\(a), \(b) % 32);\n"
        case 5: return "\(d) = ROTR32(\(a), \(b) % 32);\n"
        case 6: return "\(d) = \(a) & \(b);\n"
        case 7: return "\(d) = \(a) | \(b);\n"
        case 8: return "\(d) = \(a) ^ \(b);\n"
        case 9: return "\(d) = clz(\(a)) + clz(\(b));\n"
        case 10: return "\(d) = popcount(\(a)) + popcount(\(b));\n"
        default: return ""
        }
    }
    var c = "inline void progPowLoop(const uint loop, thread uint mix[PROGPOW_REGS],\n"
    c += "    device const dag_t* g_dag, threadgroup const uint* c_dag,\n"
    c += "    threadgroup ulong* share, uint lane_id, uint group_id) {\n"
    c += "dag_t data_dag; uint offset, data;\n"
    c += "uint PROGPOW_DAG_ELEMENTS = \(dagElements);\n"
    // c += "return; // DEBUG: skip progPowLoop to test framework\n"
    c += "if(lane_id == (loop % PROGPOW_LANES)) share[group_id * 8] = (ulong)mix[0];\n"
    c += "threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    c += "offset = (uint)share[group_id * 8];\n"
    c += "offset %= PROGPOW_DAG_ELEMENTS;\n"
    c += "offset = offset * PROGPOW_LANES + (lane_id ^ loop) % PROGPOW_LANES;\n"
    c += "data_dag = g_dag[offset];\n"
    for i in 0..<max(CNT_CACHE, CNT_MATH) {
        if i < CNT_CACHE {
            let src = mixCacheSrc(), dst = mixDst(), r = rng.next()
            c += "offset = \(src) % PROGPOW_CACHE_WORDS; data = c_dag[offset];\n"
            c += merge(dst, "data", r)
        }
        if i < CNT_MATH {
            let srcRnd = Int(rng.next()) % ((REGS - 1) * REGS)
            let src1 = srcRnd % REGS; var src2 = srcRnd / REGS
            if src2 >= src1 { src2 += 1 }
            let r1 = rng.next(), dst = mixDst(), r2 = rng.next()
            c += math("data", "mix[\(src1)]", "mix[\(src2)]", r1)
            c += merge(dst, "data", r2)
        }
    }
    c += merge("mix[0]", "data_dag.s[0]", rng.next())
    for i in 1..<DAG_LOADS { c += merge(mixDst(), "data_dag.s[\(i)]", rng.next()) }
    c += "}\n\n"
    return c
}

// MARK: - Helpers
func hexToBytes(_ hex: String) -> [UInt8] {
    var bytes = [UInt8](); var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        bytes.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return bytes
}

func bytesToHex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

func rpcCall(_ method: String, params: [Any] = []) async throws -> Any {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:18766")!)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.addValue("Basic \(Data("rvn:rvn123".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc":"1.0","id":1,"method":method,"params":params])
    request.timeoutInterval = 120
    let (data, _) = try await URLSession.shared.data(for: request)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    if let error = json["error"] as? [String: Any], let msg = error["message"] as? String {
        throw NSError(domain: "RPC", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
    return json["result"]!
}

// MARK: - Main
let PROGPOW_CACHE_WORDS = 4096
let MAX_OUTPUTS = 4

print("🔥 KAWPOW Metal Miner for Ravencoin")
print("====================================")

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device") }
print("GPU: \(device.name)")

Task {
    do {
        // 1. Get block template
        print("\n[1/6] Getting block template...")
        let tmpl = try await rpcCall("getblocktemplate", params: [["rules":["segwit"]]]) as! [String:Any]
        let height = tmpl["height"] as! Int
        let _ = tmpl["bits"] as! String
        let targetHex = tmpl["target"] as! String
        let epoch = height / 7500
        var progSeed = UInt64(height / 3)  // PROGPOW_PERIOD = 3
        let address = try await rpcCall("getnewaddress") as! String
        print("  Height: \(height), Epoch: \(epoch)")
        print("  Target: \(targetHex.prefix(20))...")
        print("  Mining to: \(address)")

        // Compute target as little-endian uint64 for shader comparison
        let targetBytes = hexToBytes(targetHex)
        var target64: UInt64 = 0
        for i in 0..<8 { target64 = (target64 << 8) | UInt64(targetBytes[i]) }

        // 2. Load light cache
        print("\n[2/6] Loading light cache...")
        let lightCachePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("epoch\(epoch).light").path
        guard let lightData = try? Data(contentsOf: URL(fileURLWithPath: lightCachePath)) else {
            print("  Light cache not found at \(lightCachePath)")
            print("  Generate it: ./dump_light_cache \(epoch) epoch\(epoch)")
            exit(1)
        }
        let lightItems = lightData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int32.self) }
        let datasetItems = lightData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }
        print("  Light cache: \(lightItems) items (\(lightData.count / 1024 / 1024) MB)")
        print("  Dataset items: \(datasetItems)")

        // Upload light cache to GPU
        let lightBuffer = lightData.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress! + 8, length: Int(lightItems) * 64, options: .storageModeShared)!
        }

        // 3. Generate DAG on GPU
        print("\n[3/6] Generating DAG on GPU...")
        // DAG items for the search kernel are dag_t (4 x uint32 = 16 bytes)
        // But the generate_dag kernel produces hash512_t items (64 bytes)
        // The search kernel reads dag_t from consecutive hash512 items
        // Each dataset item is hash1024 (128 bytes), but our generator makes hash512 (64 bytes)
        // So we need datasetItems * 2 hash512 items
        let dagHash512Count = Int(datasetItems) * 2
        let dagBytes = dagHash512Count * 64
        print("  DAG size: \(dagBytes / 1024 / 1024) MB (\(dagHash512Count) hash512 items)")

        guard let dagBuffer = device.makeBuffer(length: dagBytes, options: .storageModeShared) else {
            print("  ERROR: Cannot allocate \(dagBytes / 1024 / 1024) MB for DAG")
            exit(1)
        }

        // DAG generation params (unused pre-allocated buffer removed; params set per-batch below)

        // Compile shaders
        print("\n[4/6] Compiling Metal shaders...")
        let dagElements = UInt32(datasetItems) / 2  // PROGPOW_DAG_ELEMENTS = dagNumItems / 2
        let progPowLoop = generateProgPowLoop(progSeed: progSeed, dagElements: dagElements)
        let shaderPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("KawpowShader.metal.template").path
        let shaderSource = try String(contentsOfFile: shaderPath, encoding: .utf8)
            .replacingOccurrences(of: "// GENERATED_PROGPOW_LOOP", with: progPowLoop)
        let library = try await device.makeLibrary(source: shaderSource, options: nil)

        let dagPipeline = try await device.makeComputePipelineState(function: library.makeFunction(name: "generate_dag")!)
        let searchPipeline = try await device.makeComputePipelineState(function: library.makeFunction(name: "kawpow_search")!)
        print("  DAG gen pipeline: \(dagPipeline.maxTotalThreadsPerThreadgroup) threads")
        print("  Search pipeline: \(searchPipeline.maxTotalThreadsPerThreadgroup) threads")

        // Generate DAG on GPU
        let commandQueue = device.makeCommandQueue()!
        let dagGenStart = Date()
        let batchSize = 65536
        for offset in stride(from: 0, to: dagHash512Count, by: batchSize) {
            let count = min(batchSize, dagHash512Count - offset)
            let cmd = commandQueue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(dagPipeline)
            // Pass full DAG buffer (kernel indexes by global node_index)
            enc.setBuffer(dagBuffer, offset: 0, index: 0)
            enc.setBuffer(lightBuffer, offset: 0, index: 1)
            var params: [UInt32] = [UInt32(offset), UInt32(dagHash512Count), UInt32(lightItems)]
            enc.setBytes(&params, length: 12, index: 2)
            let tg = MTLSize(width: min(256, dagPipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
            enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: tg)
            enc.endEncoding()
            cmd.commit()

            if offset % (batchSize * 10) == 0 {
                await cmd.completed()
                let pct = Double(offset) / Double(dagHash512Count) * 100
                let elapsed = Date().timeIntervalSince(dagGenStart)
                print("  \(String(format: "%.1f%%", pct)) (\(Int(elapsed))s)")
            }
        }
        // Wait for last batch
        let finalCmd = commandQueue.makeCommandBuffer()!
        finalCmd.commit()
        await finalCmd.completed()
        let dagTime = Date().timeIntervalSince(dagGenStart)
        print("  DAG generated in \(String(format: "%.1f", dagTime))s")

        // Verify DAG against C++ reference
        let dagPtr = dagBuffer.contents().bindMemory(to: UInt32.self, capacity: dagHash512Count * 16)
        print("  DAG[0] words: ", terminator: "")
        for w in 0..<4 { print("0x\(String(format: "%08x", dagPtr[w])) ", terminator: "") }
        print("\n  Expected[0]:  0xa2a35c1e ...")
        if dagPtr[0] == 0xa2a35c1e {
            print("  ✅ DAG[0] matches reference!")
        } else {
            print("  ❌ DAG[0] MISMATCH! GPU Keccak-512 is broken.")
            print("  Dumping first few DAG items for debugging...")
            for item in 0..<3 {
                print("    DAG[\(item)]: ", terminator: "")
                for w in 0..<8 { print(String(format: "%08x", dagPtr[item * 16 + w]), terminator: " ") }
                print()
            }
        }

        // 5-6. Mining loop with auto-refresh
        var headerHashHex = ""
        while true { // outer loop for new templates
        let freshTmpl = try await rpcCall("getblocktemplate", params: [["rules":["segwit"]]]) as! [String:Any]
        guard let newHeaderHash = freshTmpl["pprpcheader"] as? String else {
            print("  ERROR: No pprpcheader. Start ravend with -miningaddress=<addr>")
            exit(1)
        }
        let prevHeaderHash = headerHashHex
        headerHashHex = newHeaderHash
        let newHeight = freshTmpl["height"] as! Int
        let newProgSeed = UInt64(newHeight / 3)

        // Recompile kernel if progSeed changed
        if newProgSeed != progSeed || prevHeaderHash == "" {
            print("  Recompiling kernel for height \(newHeight) (progSeed \(newProgSeed))...")
            // TODO: recompile searchPipeline with new progPowLoop
        }

        print("\n  Mining block \(newHeight) | Header: \(headerHashHex.prefix(16))...")

        // Convert header hash to uint32 array (little-endian words)
        let headerBytes = hexToBytes(headerHashHex)
        var headerWords = [UInt32](repeating: 0, count: 8)
        for i in 0..<8 {
            headerWords[i] = UInt32(headerBytes[i*4]) | (UInt32(headerBytes[i*4+1]) << 8) |
                             (UInt32(headerBytes[i*4+2]) << 16) | (UInt32(headerBytes[i*4+3]) << 24)
        }
        let headerBuffer = device.makeBuffer(bytes: &headerWords, length: 32, options: .storageModeShared)!

        // Setup mining buffers
        let resultsSize = 4 + MAX_OUTPUTS * (4 + 32 + 8) + 64
        // c_dag(4096*4) + share(16*16*4) + per-thread state2(256*8*4)
        let sharedMemSize = (PROGPOW_CACHE_WORDS + 16 * 16 + 256 * 8) * 4
        var dagElemsForBuf = dagElements
        let dagElemsBuffer = device.makeBuffer(bytes: &dagElemsForBuf, length: 4, options: .storageModeShared)!

        // Mining loop
        print("\n  ⛏️  MINING block \(newHeight)...\n")

        let resultsBuffer = device.makeBuffer(length: resultsSize, options: .storageModeShared)!
        var startNonce: UInt64 = UInt64.random(in: 0..<(UInt64.max / 2))
        let nonceBuffer = device.makeBuffer(bytes: &startNonce, length: 8, options: .storageModeShared)!
        var targetVal = target64
        let targetBuffer = device.makeBuffer(bytes: &targetVal, length: 8, options: .storageModeShared)!
        var dagElemsVal = dagElements

        let threadsPerGroup = min(256, searchPipeline.maxTotalThreadsPerThreadgroup)
        let threadsPerDispatch = 256 * 64  // 16384 hashes per dispatch
        let hashesPerDispatch = threadsPerDispatch

        var totalHashes: UInt64 = 0
        let miningStart = Date()
        var found = false

        var batch = 0
        while !found {
            // Clear results
            memset(resultsBuffer.contents(), 0, resultsSize)

            // Sequential nonce
            startNonce &+= UInt64(hashesPerDispatch)
            nonceBuffer.contents().storeBytes(of: startNonce, as: UInt64.self)

            let cmd = commandQueue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(searchPipeline)
            enc.setBuffer(resultsBuffer, offset: 0, index: 0)
            enc.setBuffer(headerBuffer, offset: 0, index: 1)
            enc.setBuffer(dagBuffer, offset: 0, index: 2)
            enc.setBuffer(nonceBuffer, offset: 0, index: 3)
            enc.setBuffer(targetBuffer, offset: 0, index: 4)
            enc.setBuffer(dagElemsBuffer, offset: 0, index: 5)
            enc.setThreadgroupMemoryLength(sharedMemSize, index: 0)
            enc.dispatchThreads(
                MTLSize(width: threadsPerDispatch, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
            enc.endEncoding()
            cmd.commit()
            await cmd.completed()

            totalHashes += UInt64(hashesPerDispatch)

            // Check results
            let resultCount = resultsBuffer.contents().load(as: UInt32.self)
            if resultCount > 0 {
                print("\n🎉 SOLUTION FOUND! count=\(resultCount)")
                let resultPtr = resultsBuffer.contents()
                for i in 0..<min(Int(resultCount), MAX_OUTPUTS) {
                    // SearchResults layout: count(4) + gid[4](16) + mix[4][8](128) + nonce[4](32)
                    let gidOffset = 4 + i * 4
                    let mixOffset = 4 + MAX_OUTPUTS * 4 + i * 32
                    // SearchResults struct has padding before nonce[] for 8-byte alignment
            let nonceArrayOffset = ((4 + MAX_OUTPUTS * 4 + MAX_OUTPUTS * 32 + 7) / 8) * 8 // align to 8
            let nonceOffset = nonceArrayOffset + i * 8

                    let foundNonce: UInt64
                    // Use memcpy to avoid alignment issues
                    var nonceVal: UInt64 = 0
                    memcpy(&nonceVal, resultPtr + nonceOffset, 8)
                    foundNonce = nonceVal

                    var mixHash = [UInt32](repeating: 0, count: 8)
                    for j in 0..<8 {
                        mixHash[j] = resultPtr.load(fromByteOffset: mixOffset + j * 4, as: UInt32.self)
                    }
                    let mixHex = mixHash.map { String(format: "%08x", $0.byteSwapped) }.joined()
                    let nonceHex = String(format: "%016llx", foundNonce)

                    print("  Nonce: 0x\(nonceHex)")
                    print("  Mix:   \(mixHex)")

                    // Submit to node!
                    print("  Submitting via pprpcsb...")
                    do {
                        let submitResult = try await rpcCall("pprpcsb",
                            params: [headerHashHex, mixHex, nonceHex])
                        print("  ✅ BLOCK SUBMITTED! Result: \(submitResult)")
                        found = true
                    } catch {
                        print("  ❌ Submit failed: \(error.localizedDescription)")
                        // Verify hash
                        do {
                            let verify = try await rpcCall("getkawpowhash",
                                params: [headerHashHex, mixHex, nonceHex, height, targetHex])
                            print("  Verify: \(verify)")
                        } catch {
                            print("  Verify failed: \(error)")
                        }
                    }
                }
                if found { break }
            }

            if batch % 100 == 0 {
                let elapsed = Date().timeIntervalSince(miningStart)
                let hashRate = Double(totalHashes) / elapsed
                let mh = hashRate / 1_000_000
                print("  \(String(format: "%.2f MH/s", mh)) | \(totalHashes) hashes | \(String(format: "%.0fs", elapsed))")
            }

            // Refresh header every 500 batches
            if batch % 500 == 499 {
                if let newTmpl = try? await rpcCall("getblocktemplate", params: [["rules":["segwit"]]]) as? [String:Any],
                   let newHeader = newTmpl["pprpcheader"] as? String, newHeader != headerHashHex {
                    print("  ⚡ New block! Refreshing template...")
                    break // break inner loop, outer loop gets new header
                }
            }

            batch += 1
        }

        if found {
            let elapsed = Date().timeIntervalSince(miningStart)
            print("\n🏆 BLOCK MINED! \(totalHashes) hashes in \(String(format: "%.1f", elapsed))s")
            break // exit outer loop
        }

        } // end outer while loop

    } catch {
        print("Error: \(error)")
    }
    exit(0)
}

RunLoop.main.run()
