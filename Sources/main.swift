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
    // Optimization #7: Use simd_broadcast instead of divergent if + barrier for lane election
    c += "offset = simd_broadcast(mix[0], loop % PROGPOW_LANES);\n"
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

// MARK: - Keccak (for light cache generation)
func keccakf1600(_ state: inout [UInt64]) {
    let rc: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    func rol(_ x: UInt64, _ s: UInt64) -> UInt64 { (x << s) | (x >> (64 - s)) }
    var Aba=state[0],Abe=state[1],Abi=state[2],Abo=state[3],Abu=state[4]
    var Aga=state[5],Age=state[6],Agi=state[7],Ago=state[8],Agu=state[9]
    var Aka=state[10],Ake=state[11],Aki=state[12],Ako=state[13],Aku=state[14]
    var Ama=state[15],Ame=state[16],Ami=state[17],Amo=state[18],Amu=state[19]
    var Asa=state[20],Ase=state[21],Asi=state[22],Aso=state[23],Asu=state[24]
    var Ba:UInt64,Be:UInt64,Bi:UInt64,Bo:UInt64,Bu:UInt64
    var Da:UInt64,De:UInt64,Di:UInt64,Do:UInt64,Du:UInt64
    var Eba:UInt64,Ebe:UInt64,Ebi:UInt64,Ebo:UInt64,Ebu:UInt64
    var Ega:UInt64,Ege:UInt64,Egi:UInt64,Ego:UInt64,Egu:UInt64
    var Eka:UInt64,Eke:UInt64,Eki:UInt64,Eko:UInt64,Eku:UInt64
    var Ema:UInt64,Eme:UInt64,Emi:UInt64,Emo:UInt64,Emu:UInt64
    var Esa:UInt64,Ese:UInt64,Esi:UInt64,Eso:UInt64,Esu:UInt64
    for round in stride(from: 0, to: 24, by: 2) {
        Ba=Aba^Aga^Aka^Ama^Asa; Be=Abe^Age^Ake^Ame^Ase
        Bi=Abi^Agi^Aki^Ami^Asi; Bo=Abo^Ago^Ako^Amo^Aso; Bu=Abu^Agu^Aku^Amu^Asu
        Da=Bu^rol(Be,1); De=Ba^rol(Bi,1); Di=Be^rol(Bo,1); Do=Bi^rol(Bu,1); Du=Bo^rol(Ba,1)
        Ba=Aba^Da; Be=rol(Age^De,44); Bi=rol(Aki^Di,43); Bo=rol(Amo^Do,21); Bu=rol(Asu^Du,14)
        Eba=Ba^(~Be&Bi)^rc[round]; Ebe=Be^(~Bi&Bo); Ebi=Bi^(~Bo&Bu); Ebo=Bo^(~Bu&Ba); Ebu=Bu^(~Ba&Be)
        Ba=rol(Abo^Do,28); Be=rol(Agu^Du,20); Bi=rol(Aka^Da,3); Bo=rol(Ame^De,45); Bu=rol(Asi^Di,61)
        Ega=Ba^(~Be&Bi); Ege=Be^(~Bi&Bo); Egi=Bi^(~Bo&Bu); Ego=Bo^(~Bu&Ba); Egu=Bu^(~Ba&Be)
        Ba=rol(Abe^De,1); Be=rol(Agi^Di,6); Bi=rol(Ako^Do,25); Bo=rol(Amu^Du,8); Bu=rol(Asa^Da,18)
        Eka=Ba^(~Be&Bi); Eke=Be^(~Bi&Bo); Eki=Bi^(~Bo&Bu); Eko=Bo^(~Bu&Ba); Eku=Bu^(~Ba&Be)
        Ba=rol(Abu^Du,27); Be=rol(Aga^Da,36); Bi=rol(Ake^De,10); Bo=rol(Ami^Di,15); Bu=rol(Aso^Do,56)
        Ema=Ba^(~Be&Bi); Eme=Be^(~Bi&Bo); Emi=Bi^(~Bo&Bu); Emo=Bo^(~Bu&Ba); Emu=Bu^(~Ba&Be)
        Ba=rol(Abi^Di,62); Be=rol(Ago^Do,55); Bi=rol(Aku^Du,39); Bo=rol(Ama^Da,41); Bu=rol(Ase^De,2)
        Esa=Ba^(~Be&Bi); Ese=Be^(~Bi&Bo); Esi=Bi^(~Bo&Bu); Eso=Bo^(~Bu&Ba); Esu=Bu^(~Ba&Be)
        Ba=Eba^Ega^Eka^Ema^Esa; Be=Ebe^Ege^Eke^Eme^Ese
        Bi=Ebi^Egi^Eki^Emi^Esi; Bo=Ebo^Ego^Eko^Emo^Eso; Bu=Ebu^Egu^Eku^Emu^Esu
        Da=Bu^rol(Be,1); De=Ba^rol(Bi,1); Di=Be^rol(Bo,1); Do=Bi^rol(Bu,1); Du=Bo^rol(Ba,1)
        Ba=Eba^Da; Be=rol(Ege^De,44); Bi=rol(Eki^Di,43); Bo=rol(Emo^Do,21); Bu=rol(Esu^Du,14)
        Aba=Ba^(~Be&Bi)^rc[round+1]; Abe=Be^(~Bi&Bo); Abi=Bi^(~Bo&Bu); Abo=Bo^(~Bu&Ba); Abu=Bu^(~Ba&Be)
        Ba=rol(Ebo^Do,28); Be=rol(Egu^Du,20); Bi=rol(Eka^Da,3); Bo=rol(Eme^De,45); Bu=rol(Esi^Di,61)
        Aga=Ba^(~Be&Bi); Age=Be^(~Bi&Bo); Agi=Bi^(~Bo&Bu); Ago=Bo^(~Bu&Ba); Agu=Bu^(~Ba&Be)
        Ba=rol(Ebe^De,1); Be=rol(Egi^Di,6); Bi=rol(Eko^Do,25); Bo=rol(Emu^Du,8); Bu=rol(Esa^Da,18)
        Aka=Ba^(~Be&Bi); Ake=Be^(~Bi&Bo); Aki=Bi^(~Bo&Bu); Ako=Bo^(~Bu&Ba); Aku=Bu^(~Ba&Be)
        Ba=rol(Ebu^Du,27); Be=rol(Ega^Da,36); Bi=rol(Eke^De,10); Bo=rol(Emi^Di,15); Bu=rol(Eso^Do,56)
        Ama=Ba^(~Be&Bi); Ame=Be^(~Bi&Bo); Ami=Bi^(~Bo&Bu); Amo=Bo^(~Bu&Ba); Amu=Bu^(~Ba&Be)
        Ba=rol(Ebi^Di,62); Be=rol(Ego^Do,55); Bi=rol(Eku^Du,39); Bo=rol(Ema^Da,41); Bu=rol(Ese^De,2)
        Asa=Ba^(~Be&Bi); Ase=Be^(~Bi&Bo); Asi=Bi^(~Bo&Bu); Aso=Bo^(~Bu&Ba); Asu=Bu^(~Ba&Be)
    }
    state[0]=Aba;state[1]=Abe;state[2]=Abi;state[3]=Abo;state[4]=Abu
    state[5]=Aga;state[6]=Age;state[7]=Agi;state[8]=Ago;state[9]=Agu
    state[10]=Aka;state[11]=Ake;state[12]=Aki;state[13]=Ako;state[14]=Aku
    state[15]=Ama;state[16]=Ame;state[17]=Ami;state[18]=Amo;state[19]=Amu
    state[20]=Asa;state[21]=Ase;state[22]=Asi;state[23]=Aso;state[24]=Asu
}

func keccak(_ data: [UInt8], bits: Int) -> [UInt8] {
    let hashSize = bits / 8
    let blockSize = (1600 - bits * 2) / 8
    var state = [UInt64](repeating: 0, count: 25)
    var pos = 0
    // Absorb full blocks
    while data.count - pos >= blockSize {
        for i in 0..<(blockSize / 8) {
            state[i] ^= data.withUnsafeBytes { $0.load(fromByteOffset: pos + i * 8, as: UInt64.self) }
        }
        keccakf1600(&state)
        pos += blockSize
    }
    // Absorb remaining bytes
    var stateIdx = 0
    var lastWord: UInt64 = 0
    var lastPos = 0
    while data.count - pos >= 8 {
        state[stateIdx] ^= data.withUnsafeBytes { $0.load(fromByteOffset: pos, as: UInt64.self) }
        stateIdx += 1; pos += 8
    }
    while pos < data.count { lastWord |= UInt64(data[pos]) << (lastPos * 8); lastPos += 1; pos += 1 }
    lastWord |= UInt64(0x01) << (lastPos * 8)
    state[stateIdx] ^= lastWord
    state[(blockSize / 8) - 1] ^= 0x8000000000000000
    keccakf1600(&state)
    // Squeeze
    var out = [UInt8](repeating: 0, count: hashSize)
    for i in 0..<(hashSize / 8) {
        var w = state[i]
        for j in 0..<8 { out[i * 8 + j] = UInt8(w & 0xff); w >>= 8 }
    }
    return out
}

func keccak256(_ data: [UInt8]) -> [UInt8] { keccak(data, bits: 256) }
func keccak512(_ data: [UInt8]) -> [UInt8] { keccak(data, bits: 512) }

// MARK: - Light Cache Generation
func findLargestPrime(_ upperBound: Int) -> Int {
    var n = upperBound
    if n < 2 { return 0 }
    if n == 2 { return 2 }
    if n % 2 == 0 { n -= 1 }
    while true {
        var isPrime = true
        var d = 3
        while Int64(d) * Int64(d) <= Int64(n) {
            if n % d == 0 { isPrime = false; break }
            d += 2
        }
        if isPrime { return n }
        n -= 2
    }
}

func generateLightCache(epoch: Int) -> (lightItems: Int, datasetItems: Int, cache: [UInt8]) {
    let LIGHT_CACHE_INIT = 262144   // (1 << 24) / 64
    let LIGHT_CACHE_GROWTH = 2048   // (1 << 17) / 64
    let DATASET_INIT = 8388608      // (1 << 30) / 128
    let DATASET_GROWTH = 65536      // (1 << 23) / 128
    let CACHE_ROUNDS = 3

    let lightItems = findLargestPrime(LIGHT_CACHE_INIT + epoch * LIGHT_CACHE_GROWTH)
    let datasetItems = findLargestPrime(DATASET_INIT + epoch * DATASET_GROWTH)

    print("  Computing seed hash...")
    // Seed = keccak256 applied epoch times to zeros
    var seed = [UInt8](repeating: 0, count: 32)
    for _ in 0..<epoch { seed = keccak256(seed) }

    print("  Building cache: \(lightItems) items (\(lightItems * 64 / 1024 / 1024) MB)...")
    var cache = [UInt8](repeating: 0, count: lightItems * 64)

    // Phase 1: Sequential keccak512
    let first = keccak512(seed)
    cache.replaceSubrange(0..<64, with: first)
    for i in 1..<lightItems {
        let prev = Array(cache[(i-1)*64..<i*64])
        let item = keccak512(prev)
        cache.replaceSubrange(i*64..<(i+1)*64, with: item)
        if i % 50000 == 0 { print("    Sequential: \(i)/\(lightItems)") }
    }

    // Phase 2: RandMemoHash (3 rounds)
    for q in 0..<CACHE_ROUNDS {
        print("  RandMemoHash round \(q+1)/\(CACHE_ROUNDS)...")
        for i in 0..<lightItems {
            // v = first word of cache[i] as LE uint32, mod lightItems
            let off = i * 64
            let t = UInt32(cache[off]) | (UInt32(cache[off+1]) << 8) |
                    (UInt32(cache[off+2]) << 16) | (UInt32(cache[off+3]) << 24)
            let v = Int(t) % lightItems
            let w = (lightItems + (i - 1)) % lightItems
            // XOR cache[v] and cache[w]
            var xored = [UInt8](repeating: 0, count: 64)
            for j in 0..<64 { xored[j] = cache[v * 64 + j] ^ cache[w * 64 + j] }
            let hashed = keccak512(xored)
            cache.replaceSubrange(off..<off+64, with: hashed)
            if i % 50000 == 0 { print("    Round \(q+1): \(i)/\(lightItems)") }
        }
    }

    print("  Light cache generated! Dataset items: \(datasetItems)")
    return (lightItems, datasetItems, cache)
}

// MARK: - Main
let PROGPOW_CACHE_WORDS = 4096
let MAX_OUTPUTS = 4


// Parse args
let args = CommandLine.arguments
let poolMode = args.contains("--pool")
let poolArg = args.firstIndex(of: "--pool").flatMap { i in i + 1 < args.count ? args[i + 1] : nil } ?? "127.0.0.1:3456"
let workerArg = args.firstIndex(of: "--worker").flatMap { i in i + 1 < args.count ? args[i + 1] : nil } ?? "miner.metal01"

print("🔥 KAWPOW Metal Miner for Ravencoin")
print("====================================")
if poolMode {
    print("🏊 Pool mode: \(poolArg) worker: \(workerArg)")
} else {
    print("⛏️  Solo mining mode")
}

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device") }
print("GPU: \(device.name)")
let globalStart = Date()

let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSrc.setEventHandler { print("\n👋 Miner stopped."); exit(0) }
signal(SIGINT, SIG_IGN)
sigintSrc.resume()

Task {
    do {
        // 1. Get initial work (solo: from ravend, pool: from stratum)
        var stratum: StratumClient? = nil

        let height: Int
        let targetHex: String
        let epoch: Int
        var progSeed: UInt64

        if poolMode {
            let parts = poolArg.split(separator: ":")
            let poolHost = String(parts[0])
            let poolPort = parts.count > 1 ? Int(parts[1])! : 3456
            print("\n[1/6] Connecting to pool \(poolHost):\(poolPort)...")
            let client = StratumClient(host: poolHost, port: poolPort, worker: workerArg)
            stratum = client
            try await client.connect()

            // Wait for first job
            print("  Waiting for first job...")
            let job = try await client.waitForJob()
            height = job.height
            targetHex = job.target
            epoch = height / 7500
            progSeed = UInt64(height / 3)
            print("  Height: \(height), Epoch: \(epoch)")
            print("  Target: \(targetHex.prefix(20))...")
        } else {
            print("\n[1/6] Getting block template...")
            let tmpl = try await rpcCall("getblocktemplate", params: [["rules":["segwit"]]]) as! [String:Any]
            height = tmpl["height"] as! Int
            let _ = tmpl["bits"] as! String
            targetHex = tmpl["target"] as! String
            epoch = height / 7500
            progSeed = UInt64(height / 3)
            let address = try await rpcCall("getnewaddress") as! String
            print("  Height: \(height), Epoch: \(epoch)")
            print("  Target: \(targetHex.prefix(20))...")
            print("  Mining to: \(address)")
        }

        // Compute target as little-endian uint64 for shader comparison
        let targetBytes = hexToBytes(targetHex)
        var target64: UInt64 = 0
        for i in 0..<8 { target64 = (target64 << 8) | UInt64(targetBytes[i]) }

        // 2. Load or generate light cache
        print("\n[2/6] Loading light cache...")
        let lightCachePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("epoch\(epoch).light").path
        let lightItems: Int32
        let datasetItems: Int32
        let lightCacheBytes: Data
        if let lightData = try? Data(contentsOf: URL(fileURLWithPath: lightCachePath)) {
            lightItems = lightData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int32.self) }
            datasetItems = lightData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }
            lightCacheBytes = lightData.subdata(in: 8..<lightData.count)
            print("  Loaded from cache file")
        } else {
            print("  Cache file not found, generating for epoch \(epoch)...")
            let gen = generateLightCache(epoch: epoch)
            lightItems = Int32(gen.lightItems)
            datasetItems = Int32(gen.datasetItems)
            lightCacheBytes = Data(gen.cache)
            // Save for next time
            var header = Data(count: 8)
            header.withUnsafeMutableBytes { ptr in
                ptr.storeBytes(of: lightItems, toByteOffset: 0, as: Int32.self)
                ptr.storeBytes(of: datasetItems, toByteOffset: 4, as: Int32.self)
            }
            try (header + lightCacheBytes).write(to: URL(fileURLWithPath: lightCachePath))
            print("  Saved to \(lightCachePath)")
        }
        print("  Light cache: \(lightItems) items (\(lightCacheBytes.count / 1024 / 1024) MB)")
        print("  Dataset items: \(datasetItems)")

        // Upload light cache to GPU
        let lightBuffer = lightCacheBytes.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: Int(lightItems) * 64, options: .storageModeShared)!
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
        var searchPipeline = try await device.makeComputePipelineState(function: library.makeFunction(name: "kawpow_search")!)
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
                let pct = Double(offset) / Double(dagHash512Count)
                let elapsed = Date().timeIntervalSince(dagGenStart)
                let barWidth = 30
                let filled = Int(pct * Double(barWidth))
                let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: barWidth - filled)
                print("  [\(bar)] \(String(format: "%5.1f%%", pct * 100)) (\(Int(elapsed))s)", terminator: "\r")
                fflush(stdout)
            }
        }
        // Wait for last batch
        let finalCmd = commandQueue.makeCommandBuffer()!
        finalCmd.commit()
        await finalCmd.completed()
        let dagTime = Date().timeIntervalSince(dagGenStart)
        let doneBar = String(repeating: "█", count: 30)
        print("  [\(doneBar)] 100.0% (\(Int(dagTime))s)")
        print("  DAG generated in \(String(format: "%.1f", dagTime))s")

        print("  DAG generation complete")

        // 5-6. Mining loop with auto-refresh
        var headerHashHex = ""
        var currentJobId = ""
        var lastJobVersion = 0

        while true { // outer loop for new templates
        let newHeaderHash: String
        let newHeight: Int

        if poolMode, let client = stratum {
            // Wait for a job if we don't have one yet
            if lastJobVersion == 0 {
                while true {
                    let ver = await client.getJobVersion()
                    if ver > 0, let job = await client.latestJob {
                        lastJobVersion = ver
                        newHeaderHash = job.headerHash
                        newHeight = job.height
                        currentJobId = job.id
                        break
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } else {
                // Check for new job (called after inner loop breaks)
                let ver = await client.getJobVersion()
                guard let job = await client.latestJob else { continue }
                lastJobVersion = ver
                newHeaderHash = job.headerHash
                newHeight = job.height
                currentJobId = job.id
            }
        } else {
            let freshTmpl = try await rpcCall("getblocktemplate", params: [["rules":["segwit"]]]) as! [String:Any]
            guard let hdr = freshTmpl["pprpcheader"] as? String else {
                print("  ERROR: No pprpcheader. Start ravend with -miningaddress=<addr>")
                exit(1)
            }
            newHeaderHash = hdr
            newHeight = freshTmpl["height"] as! Int
        }

        let prevHeaderHash = headerHashHex
        headerHashHex = newHeaderHash
        let newProgSeed = UInt64(newHeight / 3)

        // Recompile kernel if progSeed changed
        if newProgSeed != progSeed || prevHeaderHash == "" {
            progSeed = newProgSeed
            print("  Compiling kernel for progSeed \(progSeed)...")
            let newProgPowLoop = generateProgPowLoop(progSeed: progSeed, dagElements: dagElements)
            let newShaderSource = try String(contentsOfFile: shaderPath, encoding: .utf8)
                .replacingOccurrences(of: "// GENERATED_PROGPOW_LOOP", with: newProgPowLoop)
            let newLibrary = try await device.makeLibrary(source: newShaderSource, options: nil)
            searchPipeline = try await device.makeComputePipelineState(
                function: newLibrary.makeFunction(name: "kawpow_search")!)
        }

        print("\n  Mining block \(newHeight) | Header: \(headerHashHex.prefix(16))...")

        // Optimization #3: Pre-allocate header buffer once, update in-place
        let headerBuffer = device.makeBuffer(length: 32, options: .storageModeShared)!
        let headerBytes = hexToBytes(headerHashHex)
        var headerWords = [UInt32](repeating: 0, count: 8)
        for i in 0..<8 {
            headerWords[i] = UInt32(headerBytes[i*4]) | (UInt32(headerBytes[i*4+1]) << 8) |
                             (UInt32(headerBytes[i*4+2]) << 16) | (UInt32(headerBytes[i*4+3]) << 24)
        }
        headerBuffer.contents().copyMemory(from: &headerWords, byteCount: 32)

        // Setup mining buffers
        let resultsSize = 4 + MAX_OUTPUTS * (4 + 32 + 8) + 64
        // c_dag(4096*4) + share(16*16*4) + per-thread state2(256*8*4)
        let sharedMemSize = (PROGPOW_CACHE_WORDS + 16 * 16 + 256 * 8) * 4
        var dagElemsForBuf = dagElements
        let dagElemsBuffer = device.makeBuffer(bytes: &dagElemsForBuf, length: 4, options: .storageModeShared)!

        // Mining loop
        print("\n  ⛏️  MINING block \(newHeight)...\n")

        // Optimization #2: Triple-buffer results for pipelined reads
        let NUM_RESULT_BUFFERS = 3
        let resultsBuffers = (0..<NUM_RESULT_BUFFERS).map { _ in
            device.makeBuffer(length: resultsSize, options: .storageModeShared)!
        }
        var startNonce: UInt64 = UInt64.random(in: 0..<(UInt64.max / 2))
        // Optimization #3: Pre-allocate nonce buffer, update in-place
        let nonceBuffer = device.makeBuffer(length: 8, options: .storageModeShared)!
        nonceBuffer.contents().storeBytes(of: startNonce, as: UInt64.self)
        // For pool mode, use share target from pool; for solo, use block target
        var targetVal: UInt64
        if poolMode, let client = stratum {
            let poolTarget = await client.getTarget()
            print("  Pool share target: \(poolTarget.isEmpty ? "(empty!)" : poolTarget.prefix(20) + "...")")
            if !poolTarget.isEmpty {
                let tb = hexToBytes(poolTarget)
                var t64: UInt64 = 0
                for i in 0..<min(8, tb.count) { t64 = (t64 << 8) | UInt64(tb[i]) }
                targetVal = t64
                print("  Target64: 0x\(String(format: "%016llx", targetVal))")
            } else {
                targetVal = target64
            }
        } else {
            targetVal = target64
        }
        let targetBuffer = device.makeBuffer(bytes: &targetVal, length: 8, options: .storageModeShared)!
        _ = dagElements

        let threadsPerGroup = min(256, searchPipeline.maxTotalThreadsPerThreadgroup)
        // Optimization #4: Increase batch size for better GPU utilization with pipelining
        let threadsPerDispatch = 256 * 256  // 65536 hashes per dispatch (was 256*64=16384)
        let hashesPerDispatch = threadsPerDispatch

        var totalHashes: UInt64 = 0
        let miningStart = Date()
        var found = false
        var submittedNonces = Set<UInt64>()  // Dedup across triple-buffered results

        // Optimization #1: Double-buffering to keep GPU fed
        let MAX_IN_FLIGHT = 2
        var pendingBuffers: [(MTLCommandBuffer, Int)] = []

        var batch = 0
        while !found {
            // Optimization #2: Rotate result buffers — write to buffer[batch % 3]
            let currentResultIdx = batch % NUM_RESULT_BUFFERS
            let currentResultsBuffer = resultsBuffers[currentResultIdx]

            // Clear results for this buffer
            memset(currentResultsBuffer.contents(), 0, resultsSize)

            // Sequential nonce — update in-place (Optimization #3)
            startNonce &+= UInt64(hashesPerDispatch)
            nonceBuffer.contents().storeBytes(of: startNonce, as: UInt64.self)

            // Optimization #1: If we have MAX_IN_FLIGHT buffers pending, wait for oldest
            // This ensures GPU stays busy while we prepare the next dispatch
            if pendingBuffers.count >= MAX_IN_FLIGHT {
                let (oldCmd, oldResultIdx) = pendingBuffers.removeFirst()
                await oldCmd.completed()
                // Check results from the completed buffer
                let completedBuffer = resultsBuffers[oldResultIdx]
                let earlyResultCount = completedBuffer.contents().load(as: UInt32.self)
                if earlyResultCount > 0 {
                    print(poolMode ? "\n⛏️  Share found! count=\(earlyResultCount)" : "\n🎉 BLOCK FOUND! count=\(earlyResultCount)")
                    let resultPtr = completedBuffer.contents()
                    for i in 0..<min(Int(earlyResultCount), MAX_OUTPUTS) {
                        let mixOffset = 4 + MAX_OUTPUTS * 4 + i * 32
                        let nonceArrayOffset = ((4 + MAX_OUTPUTS * 4 + MAX_OUTPUTS * 32 + 7) / 8) * 8
                        let nonceOffset = nonceArrayOffset + i * 8
                        var nonceVal: UInt64 = 0
                        memcpy(&nonceVal, resultPtr + nonceOffset, 8)
                        // Dedup: skip if we already submitted this nonce
                        if submittedNonces.contains(nonceVal) { continue }
                        submittedNonces.insert(nonceVal)
                        if submittedNonces.count > 1000 { submittedNonces.removeAll() }
                        var mixHash = [UInt32](repeating: 0, count: 8)
                        for j in 0..<8 {
                            mixHash[j] = resultPtr.load(fromByteOffset: mixOffset + j * 4, as: UInt32.self)
                        }
                        let mixHex = mixHash.map { String(format: "%08x", $0.byteSwapped) }.joined()
                        let nonceHex = String(format: "%016llx", nonceVal)
                        print("  Nonce: 0x\(nonceHex)")
                        print("  Mix:   \(mixHex)")
                        if poolMode, let client = stratum {
                            print("  Submitting share to pool...")
                            let _ = try await client.submitShare(
                                jobId: currentJobId, nonce: nonceHex,
                                headerHash: headerHashHex, mixHash: mixHex)
                        } else {
                            print("  Submitting via pprpcsb...")
                            do {
                                let submitResult = try await rpcCall("pprpcsb",
                                    params: [headerHashHex, mixHex, nonceHex])
                                print("  ✅ BLOCK SUBMITTED! Result: \(submitResult)")
                                found = true
                            } catch {
                                print("  ❌ Submit failed: \(error.localizedDescription)")
                                do {
                                    let verify = try await rpcCall("getkawpowhash",
                                        params: [headerHashHex, mixHex, nonceHex, height, targetHex])
                                    print("  Verify: \(verify)")
                                } catch {
                                    print("  Verify failed: \(error)")
                                }
                            }
                        }
                    }
                    if found { break }
                }
            }

            let cmd = commandQueue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(searchPipeline)
            enc.setBuffer(currentResultsBuffer, offset: 0, index: 0)
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

            // Track pending command buffers
            pendingBuffers.append((cmd, currentResultIdx))

            totalHashes += UInt64(hashesPerDispatch)

            if batch % 100 == 0 {
                let elapsed = Date().timeIntervalSince(miningStart)
                let hashRate = Double(totalHashes) / elapsed
                let mh = hashRate / 1_000_000
                let totalElapsed = Date().timeIntervalSince(globalStart)
                let hoursElapsed = totalElapsed / 3600
                if poolMode {
                    print("  \(String(format: "%.2f MH/s", mh)) | \(totalHashes) hashes | \(String(format: "%.1fh", hoursElapsed))")
                } else {
                    let balance = try? await rpcCall("getwalletinfo") as? [String: Any]
                    let bal = (balance?["balance"] as? Double) ?? 0
                    let immBal = (balance?["immature_balance"] as? Double) ?? 0
                    print("  \(String(format: "%.2f MH/s", mh)) | \(totalHashes) hashes | \(String(format: "%.1fh", hoursElapsed)) | bal: \(String(format: "%.0f", bal))+\(String(format: "%.0f", immBal)) tRVN")
                }
            }


            // Refresh header
            if poolMode, let client = stratum, batch % 50 == 49 {
                let ver = await client.getJobVersion()
                if ver != lastJobVersion {
                    print("  ⚡ New job from pool!")
                    break
                }
            } else if !poolMode && batch % 500 == 499 {
                if let newTmpl = try? await rpcCall("getblocktemplate", params: [["rules":["segwit"]]]) as? [String:Any],
                   let newHeader = newTmpl["pprpcheader"] as? String, newHeader != headerHashHex {
                    print("  ⚡ New block! Refreshing template...")
                    break // break inner loop, outer loop gets new header
                }
            }

            batch += 1
        }

        // Drain remaining pending command buffers
        for (pendingCmd, _) in pendingBuffers {
            await pendingCmd.completed()
        }
        pendingBuffers.removeAll()

        if found {
            let elapsed = Date().timeIntervalSince(miningStart)
            print("\n🏆 BLOCK MINED! \(totalHashes) hashes in \(String(format: "%.1f", elapsed))s")
            print("  Starting next block...\n")
            // continue outer loop to mine next block
        }

        } // end outer while loop

    } catch {
        print("Error: \(error)")
    }
    exit(0)
}

RunLoop.main.run()
