#!/usr/bin/env python3
"""
Post-process kernel modules to inject correct __versions CRC data from device.

This script performs DIRECT BINARY PATCHING of ELF files, avoiding objcopy
which can corrupt the ELF structure. It:
1. Reads device Module.symvers with correct CRCs
2. For each .ko, finds undefined symbols needing CRCs
3. Creates __versions binary data
4. Writes the data directly into the ELF file by:
   - Appending the new section data at the end of file (before section headers)
   - Updating the section header entry for __versions to point to new data
"""

import os
import struct
import subprocess
import sys

ENTRY_SIZE = 64  # 8 byte CRC + 56 byte name on aarch64
CRC_SIZE = 8
NAME_SIZE = 56

NM = "aarch64-linux-gnu-nm"


def load_symvers(path):
    symvers = {}
    with open(path) as f:
        for line in f:
            fields = line.strip().split('\t')
            if len(fields) >= 2:
                try:
                    symvers[fields[1]] = int(fields[0], 16)
                except ValueError:
                    pass
    return symvers


def get_undefined_symbols(ko_path):
    result = subprocess.run([NM, "--undefined-only", ko_path],
                          capture_output=True, text=True)
    symbols = []
    for line in result.stdout.strip().split('\n'):
        parts = line.strip().split()
        if len(parts) >= 2 and parts[-2] == 'U':
            symbols.append(parts[-1])
    return symbols


def make_entry(crc, name):
    """Create a single modversion_info binary entry (64 bytes)."""
    name_bytes = name.encode('ascii')[:NAME_SIZE - 1]
    name_padded = name_bytes + b'\x00' * (NAME_SIZE - len(name_bytes))
    # Store CRC as unsigned long (64-bit LE), zero-extended from 32-bit
    return struct.pack('<Q', crc & 0xFFFFFFFF) + name_padded


def parse_and_patch_elf(ko_path, symvers):
    """Directly patch the ELF binary to add/replace __versions section data."""
    with open(ko_path, 'rb') as f:
        data = bytearray(f.read())

    # Parse ELF64 header
    assert data[:4] == b'\x7fELF', f"Not an ELF file: {ko_path}"
    ei_class = data[4]
    assert ei_class == 2, "Not ELF64"

    e_shoff = struct.unpack_from('<Q', data, 40)[0]     # section header table offset
    e_shentsize = struct.unpack_from('<H', data, 58)[0]  # section header entry size
    e_shnum = struct.unpack_from('<H', data, 60)[0]      # number of sections
    e_shstrndx = struct.unpack_from('<H', data, 62)[0]   # string table section index

    # Get string table
    str_sh = e_shoff + e_shstrndx * e_shentsize
    strtab_off = struct.unpack_from('<Q', data, str_sh + 24)[0]
    strtab_sz = struct.unpack_from('<Q', data, str_sh + 32)[0]
    strtab = data[strtab_off:strtab_off + strtab_sz]

    # Find __versions section header
    versions_idx = None
    versions_sh_offset = None
    existing_entries = {}

    for i in range(e_shnum):
        sh = e_shoff + i * e_shentsize
        ni = struct.unpack_from('<I', data, sh)[0]
        end = strtab.index(b'\x00', ni)
        nm = strtab[ni:end].decode()
        if nm == '__versions':
            versions_idx = i
            versions_sh_offset = sh
            sec_off = struct.unpack_from('<Q', data, sh + 24)[0]
            sec_sz = struct.unpack_from('<Q', data, sh + 32)[0]
            # Read existing entries
            for j in range(sec_sz // ENTRY_SIZE):
                eo = sec_off + j * ENTRY_SIZE
                crc = struct.unpack_from('<Q', data, eo)[0]
                nb = data[eo + CRC_SIZE:eo + ENTRY_SIZE]
                sym = nb[:nb.index(b'\x00' if b'\x00' in nb else 0)].decode()
                existing_entries[sym] = crc
            break

    if versions_idx is None:
        print(f"    No __versions section found!")
        return False, 0, 0

    # Get undefined symbols
    undef = get_undefined_symbols(ko_path)

    # Find missing kernel CRCs
    missing = []
    for sym in undef:
        if sym in symvers and sym not in existing_entries:
            missing.append(sym)
    if 'module_layout' in symvers and 'module_layout' not in existing_entries:
        if 'module_layout' not in missing:
            missing.append('module_layout')

    if not missing:
        return True, len(existing_entries), 0

    # Build complete __versions data: existing + missing
    new_data = b''
    for sym, crc in existing_entries.items():
        new_data += make_entry(crc, sym)
    for sym in missing:
        new_data += make_entry(symvers[sym], sym)

    total_entries = len(existing_entries) + len(missing)
    new_size = total_entries * ENTRY_SIZE
    assert len(new_data) == new_size

    # Strategy: Place new data where old data was, or extend file
    # The section headers are at e_shoff, which is typically at the end of the file
    # We need to:
    # 1. Insert new (larger) section data
    # 2. Update section header to reflect new offset and size

    old_sec_off = struct.unpack_from('<Q', data, versions_sh_offset + 24)[0]
    old_sec_sz = struct.unpack_from('<Q', data, versions_sh_offset + 32)[0]

    if new_size <= old_sec_sz:
        # Fits in existing space - just overwrite
        data[old_sec_off:old_sec_off + new_size] = new_data
        # Update size in section header
        struct.pack_into('<Q', data, versions_sh_offset + 32, new_size)
    else:
        # Need more space - append data before section headers
        # Move section headers to make room

        # Calculate where to put new data: right where the old section headers start
        new_data_offset = e_shoff

        # Write new __versions data at old section header position
        new_shoff = new_data_offset + new_size
        # Align section headers to 8 bytes
        if new_shoff % 8 != 0:
            padding = 8 - (new_shoff % 8)
            new_shoff += padding
        else:
            padding = 0

        # Build new file: everything before section headers + new data + padding + section headers
        section_headers = data[e_shoff:e_shoff + e_shnum * e_shentsize]
        new_file = data[:e_shoff] + new_data + b'\x00' * padding + section_headers

        # Update e_shoff in ELF header to point to moved section headers
        struct.pack_into('<Q', new_file, 40, new_shoff)

        # Update __versions section header with new offset and size
        versions_sh_in_new = new_shoff + versions_idx * e_shentsize
        struct.pack_into('<Q', new_file, versions_sh_in_new + 24, new_data_offset)  # sh_offset
        struct.pack_into('<Q', new_file, versions_sh_in_new + 32, new_size)          # sh_size

        data = new_file

    with open(ko_path, 'wb') as f:
        f.write(data)

    return True, total_entries, len(missing)


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <modules_dir> <module_symvers>")
        sys.exit(1)

    modules_dir = sys.argv[1]
    symvers_path = sys.argv[2]

    print(f"Loading device CRCs from {symvers_path}")
    symvers = load_symvers(symvers_path)
    print(f"Loaded {len(symvers)} symbol CRCs")

    ko_files = sorted([f for f in os.listdir(modules_dir) if f.endswith('.ko')])
    print(f"Processing {len(ko_files)} modules (direct binary patching)")

    for ko_name in ko_files:
        ko_path = os.path.join(modules_dir, ko_name)
        print(f"\n  {ko_name}:")

        success, total, added = parse_and_patch_elf(ko_path, symvers)
        if success:
            if added > 0:
                print(f"    Added {added} device CRCs -> total {total} entries")
            else:
                print(f"    Already complete ({total} entries)")
        else:
            print(f"    FAILED")

    print("\nDone!")


if __name__ == "__main__":
    main()
