# AMD memory encryption on black (Ryzen 7 7700, Zen 4).
#
# Dormant. The CPU supports SME (CPUID 0x8000001F: SME=1, C-bit 51, SEV/SNP=0),
# but the BIOS has SYSCFG.MemEncryptionModEn ("SMEE") off, so `mem_encrypt=on`
# is a no-op until the BIOS setting changes. TSME (BIOS-only, no OS change) is
# the preferred path; this specialisation is the SME fallback and the one-shot
# test vehicle. See runbooks/black-memory-encryption.md.
#
# The specialisation is only a non-default GRUB entry ("NixOS - (sme)").
# `nixos-rebuild switch` never activates it; boot it once with grub-reboot so
# a hardware reset falls back to the default entry.
{
  specialisation.sme.configuration = {
    system.nixos.tags = ["sme"];
    boot.kernelParams = ["mem_encrypt=on"];
  };
}
