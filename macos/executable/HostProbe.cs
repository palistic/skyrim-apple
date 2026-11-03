// Authored host-readiness probe. Contains no game code and never executes a PE input.
using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using SharpDisasm;
using Steamless.API.Crypto;
using Steamless.API.Model;
using Steamless.API.PE32;

internal static class HostProbe
{
    private static int Main(string[] args)
    {
        if (RuntimeInformation.ProcessArchitecture != Architecture.Arm64)
            throw new Exception("Probe must run in the native ARM64 host");
        var parsed = new Pe32File(args[0]);
        if (!parsed.Parse() || parsed.IsFile64Bit() || parsed.HasSection(".bind"))
            throw new Exception("Authored PE fixture was not parsed correctly");
        if (new SteamlessOptions().RecalculateFileChecksum)
            throw new Exception("Windows checksum must stay disabled");
        var key = Convert.FromHexString("2b7e151628aed2a6abf7158809cf4f3c");
        var cipher = Convert.FromHexString("3ad77bb40d7a3660a89ecaf32466ef97");
        using var aes = new AesHelper(key, new byte[16], CipherMode.ECB, PaddingMode.None);
        var plain = aes.Decrypt(cipher, CipherMode.ECB, PaddingMode.None);
        if (Convert.ToHexString(plain).ToLowerInvariant() != "6bc1bee22e409f96e93d7e117393172a")
            throw new Exception("Unmodified upstream AES helper failed NIST AES-128 ECB vector");
        using var disassembler = new Disassembler(new byte[] { 0x55, 0x89, 0xe5 }, ArchitectureMode.x86_32, 0, true);
        var instructions = disassembler.Disassemble().ToArray();
        if (instructions.Length != 2 || instructions[0].Length != 1 || instructions[1].Length != 2)
            throw new Exception("Managed SharpDisasm did not decode authored x86 bytes");
        Console.WriteLine(JsonSerializer.Serialize(new {
            process_architecture = RuntimeInformation.ProcessArchitecture.ToString(),
            pe32_parse = true, windows_checksum_disabled = true,
            aes_128_ecb_nist_vector = true, sharpdisasm_instruction_count = instructions.Length,
            sharpdisasm_assembly = typeof(Disassembler).Assembly.FullName
        }));
        return 0;
    }
}
