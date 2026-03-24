import Foundation

func rol32(_ x: UInt32, _ s: UInt32) -> UInt32 { (x << (s % 32)) | (x >> (32 - (s % 32))) }

func keccak_f800_cpu(_ state: inout [UInt32]) {
    let rc: [UInt32] = [0x00000001,0x00008082,0x0000808A,0x80008000,0x0000808B,0x80000001,
        0x80008081,0x00008009,0x0000008A,0x00000088,0x80008009,0x8000000A,
        0x8000808B,0x0000008B,0x00008089,0x00008003,0x00008002,0x00000080,
        0x0000800A,0x8000000A,0x80008081,0x00008080]

    var a = state // copy
    var e = [UInt32](repeating: 0, count: 25)
    var Ba: UInt32=0,Be: UInt32=0,Bi: UInt32=0,Bo: UInt32=0,Bu: UInt32=0
    var Da: UInt32=0,De: UInt32=0,Di: UInt32=0,Do: UInt32=0,Du: UInt32=0

    var round = 0
    while round < 22 {
        Ba=a[0]^a[5]^a[10]^a[15]^a[20]; Be=a[1]^a[6]^a[11]^a[16]^a[21]
        Bi=a[2]^a[7]^a[12]^a[17]^a[22]; Bo=a[3]^a[8]^a[13]^a[18]^a[23]
        Bu=a[4]^a[9]^a[14]^a[19]^a[24]
        Da=Bu^rol32(Be,1); De=Ba^rol32(Bi,1); Di=Be^rol32(Bo,1)
        Do=Bi^rol32(Bu,1); Du=Bo^rol32(Ba,1)

        Ba=a[0]^Da; Be=rol32(a[6]^De,12); Bi=rol32(a[12]^Di,11)
        Bo=rol32(a[18]^Do,21); Bu=rol32(a[24]^Du,14)
        e[0]=Ba^(~Be&Bi)^rc[round]; e[1]=Be^(~Bi&Bo); e[2]=Bi^(~Bo&Bu)
        e[3]=Bo^(~Bu&Ba); e[4]=Bu^(~Ba&Be)

        Ba=rol32(a[3]^Do,28); Be=rol32(a[9]^Du,20); Bi=rol32(a[10]^Da,3)
        Bo=rol32(a[16]^De,13); Bu=rol32(a[22]^Di,29)
        e[5]=Ba^(~Be&Bi); e[6]=Be^(~Bi&Bo); e[7]=Bi^(~Bo&Bu)
        e[8]=Bo^(~Bu&Ba); e[9]=Bu^(~Ba&Be)

        Ba=rol32(a[1]^De,1); Be=rol32(a[7]^Di,6); Bi=rol32(a[13]^Do,25)
        Bo=rol32(a[19]^Du,8); Bu=rol32(a[20]^Da,18)
        e[10]=Ba^(~Be&Bi); e[11]=Be^(~Bi&Bo); e[12]=Bi^(~Bo&Bu)
        e[13]=Bo^(~Bu&Ba); e[14]=Bu^(~Ba&Be)

        Ba=rol32(a[4]^Du,27); Be=rol32(a[5]^Da,4); Bi=rol32(a[11]^De,10)
        Bo=rol32(a[17]^Di,15); Bu=rol32(a[23]^Do,24)
        e[15]=Ba^(~Be&Bi); e[16]=Be^(~Bi&Bo); e[17]=Bi^(~Bo&Bu)
        e[18]=Bo^(~Bu&Ba); e[19]=Bu^(~Ba&Be)

        Ba=rol32(a[2]^Di,30); Be=rol32(a[8]^Do,23); Bi=rol32(a[14]^Du,7)
        Bo=rol32(a[15]^Da,9); Bu=rol32(a[21]^De,2)
        e[20]=Ba^(~Be&Bi); e[21]=Be^(~Bi&Bo); e[22]=Bi^(~Bo&Bu)
        e[23]=Bo^(~Bu&Ba); e[24]=Bu^(~Ba&Be)

        // Round 1: e -> a
        Ba=e[0]^e[5]^e[10]^e[15]^e[20]; Be=e[1]^e[6]^e[11]^e[16]^e[21]
        Bi=e[2]^e[7]^e[12]^e[17]^e[22]; Bo=e[3]^e[8]^e[13]^e[18]^e[23]
        Bu=e[4]^e[9]^e[14]^e[19]^e[24]
        Da=Bu^rol32(Be,1); De=Ba^rol32(Bi,1); Di=Be^rol32(Bo,1)
        Do=Bi^rol32(Bu,1); Du=Bo^rol32(Ba,1)

        Ba=e[0]^Da; Be=rol32(e[6]^De,12); Bi=rol32(e[12]^Di,11)
        Bo=rol32(e[18]^Do,21); Bu=rol32(e[24]^Du,14)
        a[0]=Ba^(~Be&Bi)^rc[round+1]; a[1]=Be^(~Bi&Bo); a[2]=Bi^(~Bo&Bu)
        a[3]=Bo^(~Bu&Ba); a[4]=Bu^(~Ba&Be)

        Ba=rol32(e[3]^Do,28); Be=rol32(e[9]^Du,20); Bi=rol32(e[10]^Da,3)
        Bo=rol32(e[16]^De,13); Bu=rol32(e[22]^Di,29)
        a[5]=Ba^(~Be&Bi); a[6]=Be^(~Bi&Bo); a[7]=Bi^(~Bo&Bu)
        a[8]=Bo^(~Bu&Ba); a[9]=Bu^(~Ba&Be)

        Ba=rol32(e[1]^De,1); Be=rol32(e[7]^Di,6); Bi=rol32(e[13]^Do,25)
        Bo=rol32(e[19]^Du,8); Bu=rol32(e[20]^Da,18)
        a[10]=Ba^(~Be&Bi); a[11]=Be^(~Bi&Bo); a[12]=Bi^(~Bo&Bu)
        a[13]=Bo^(~Bu&Ba); a[14]=Bu^(~Ba&Be)

        Ba=rol32(e[4]^Du,27); Be=rol32(e[5]^Da,4); Bi=rol32(e[11]^De,10)
        Bo=rol32(e[17]^Di,15); Bu=rol32(e[23]^Do,24)
        a[15]=Ba^(~Be&Bi); a[16]=Be^(~Bi&Bo); a[17]=Bi^(~Bo&Bu)
        a[18]=Bo^(~Bu&Ba); a[19]=Bu^(~Ba&Be)

        Ba=rol32(e[2]^Di,30); Be=rol32(e[8]^Do,23); Bi=rol32(e[14]^Du,7)
        Bo=rol32(e[15]^Da,9); Bu=rol32(e[21]^De,2)
        a[20]=Ba^(~Be&Bi); a[21]=Be^(~Bi&Bo); a[22]=Bi^(~Bo&Bu)
        a[23]=Bo^(~Bu&Ba); a[24]=Bu^(~Ba&Be)

        round += 2
    }
    state = a
}

func cpuKawpowHash(headerHash: [UInt32], nonce: UInt64) -> [UInt32] {
    let rvnc: [UInt32] = [0x72,0x41,0x56,0x45,0x4E,0x43,0x4F,0x49,0x4E,0x4B,0x41,0x57,0x50,0x4F,0x57]
    var state = [UInt32](repeating: 0, count: 25)
    for i in 0..<8 { state[i] = headerHash[i] }
    state[8] = UInt32(nonce & 0xFFFFFFFF)
    state[9] = UInt32(nonce >> 32)
    for i in 10..<25 { state[i] = rvnc[i-10] }
    keccak_f800_cpu(&state)
    return Array(state[0..<8])
}

func verifyCPUKeccak(headerHex: String, nonce: UInt64) {
    let headerBytes = hexToBytes(headerHex)
    var headerWords = [UInt32](repeating: 0, count: 8)
    for i in 0..<8 {
        headerWords[i] = UInt32(headerBytes[i*4]) | (UInt32(headerBytes[i*4+1]) << 8) |
                         (UInt32(headerBytes[i*4+2]) << 16) | (UInt32(headerBytes[i*4+3]) << 24)
    }
    let state2 = cpuKawpowHash(headerHash: headerWords, nonce: nonce)
    print("CPU Keccak verification:")
    print("  Header: \(headerWords.map{String(format:"%08x",$0)}.joined(separator: " "))")
    print("  State2: \(state2.map{String(format:"%08x",$0)}.joined(separator: " "))")
}
