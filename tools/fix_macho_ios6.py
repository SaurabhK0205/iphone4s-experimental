#!/usr/bin/env python3
import sys
import struct

def fix_macho_for_ios6(input_path, output_path=None):
    if output_path is None:
        output_path = input_path

    with open(input_path, "rb") as f:
        data = bytearray(f.read())

    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags = struct.unpack("<IIIIIII", data[:28])
    assert magic == 0xfeedface, "Only 32-bit Mach-O (0xfeedface) supported"
    assert cputype == 12, "Only ARM (12) supported"

    offset = 28
    text_vmaddr = 0
    first_sect_fileoff = len(data)
    lc_main_offset = None
    lc_main_size = 0
    entryoff = 0

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[offset:offset+8])
        if cmd == 1: # LC_SEGMENT
            segname = data[offset+8:offset+24].rstrip(b'\x00').decode()
            nsects = struct.unpack("<I", data[offset+48:offset+52])[0]
            if segname == "__TEXT":
                text_vmaddr = struct.unpack("<I", data[offset+24:offset+28])[0]
            # Check sections for lowest file offset > 0
            sect_off = offset + 56
            for _ in range(nsects):
                s_fileoff = struct.unpack("<I", data[sect_off+40:sect_off+44])[0]
                if 0 < s_fileoff < first_sect_fileoff:
                    first_sect_fileoff = s_fileoff
                sect_off += 68
        elif cmd == 0x80000028: # LC_MAIN
            lc_main_offset = offset
            lc_main_size = cmdsize
            entryoff = struct.unpack("<Q", data[offset+8:offset+16])[0]
        offset += cmdsize

    if lc_main_offset is None:
        print("No LC_MAIN found, binary might already use LC_UNIXTHREAD or have no main.")
        return

    # Check instruction at entryoff to detect Thumb vs ARM
    first_u16 = struct.unpack("<H", data[entryoff:entryoff+2])[0]
    first_u32 = struct.unpack("<I", data[entryoff:entryoff+4])[0]
    is_thumb = True
    if (first_u32 & 0x0e000000) in (0x08000000, 0x0a000000, 0x0e000000) or (first_u32 >> 28) == 0xe:
        is_thumb = False

    entry_pc = text_vmaddr + entryoff
    if is_thumb:
        entry_pc |= 1
        print(f"Detected THUMB mode. Setting entry_pc = {hex(entry_pc)}")
    else:
        entry_pc &= ~1
        print(f"Detected ARM mode. Setting entry_pc = {hex(entry_pc)}")

    print(f"Found LC_MAIN at offset {hex(lc_main_offset)}: entryoff={hex(entryoff)}, pc={hex(entry_pc)}")

    # Construct 84-byte LC_UNIXTHREAD for ARM
    thread_cmd = bytearray(84)
    struct.pack_into("<IIII", thread_cmd, 0, 5, 84, 1, 17)
    struct.pack_into("<I", thread_cmd, 76, entry_pc)
    if is_thumb:
        struct.pack_into("<I", thread_cmd, 80, 0x20) # Thumb bit in CPSR

    cmds_end = 28 + sizeofcmds
    after_main_offset = lc_main_offset + lc_main_size
    new_cmds = data[28:lc_main_offset] + thread_cmd + data[after_main_offset:cmds_end]

    delta = 84 - lc_main_size
    new_sizeofcmds = sizeofcmds + delta
    assert 28 + new_sizeofcmds <= first_sect_fileoff, "Load commands exceeded padding before first section!"

    # Header with updated sizeofcmds
    header = bytearray(data[:28])
    struct.pack_into("<I", header, 20, new_sizeofcmds)

    # Reconstruct binary WITHOUT moving any file offsets
    # header (28) + new_cmds (new_sizeofcmds) + zero padding up to first_sect_fileoff + rest of file
    new_padding_len = first_sect_fileoff - (28 + new_sizeofcmds)
    new_data = header + new_cmds + bytes(new_padding_len) + data[first_sect_fileoff:]

    assert len(new_data) == len(data), f"File size changed! Old: {len(data)}, New: {len(new_data)}"

    with open(output_path, "wb") as f:
        f.write(new_data)

    print(f"Successfully converted LC_MAIN to LC_UNIXTHREAD! Total size preserved: {len(new_data)} bytes.")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: fix_macho_ios6.py <binary> [output]")
        sys.exit(1)
    out = sys.argv[2] if len(sys.argv) > 2 else sys.argv[1]
    fix_macho_for_ios6(sys.argv[1], out)
