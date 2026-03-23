#!/usr/bin/env python3
"""Repack AVD ramdisk with matching KernelSU kernel modules."""
import sys, os, io, struct, gzip, lz4.frame, shutil, tempfile

def read_cpio(data):
    """Parse cpio newc archive, return list of (name, mode, content)."""
    entries = []
    pos = 0
    while pos < len(data):
        if data[pos:pos+6] != b'070701':
            break
        ino = int(data[pos+6:pos+14], 16)
        mode = int(data[pos+14:pos+22], 16)
        filesize = int(data[pos+54:pos+62], 16)
        namesize = int(data[pos+94:pos+102], 16)
        hdr_end = pos + 110
        name_end = hdr_end + namesize
        # Align to 4 bytes
        name_end_aligned = (name_end + 3) & ~3
        name = data[hdr_end:hdr_end+namesize-1].decode('utf-8', errors='replace')
        data_start = name_end_aligned
        data_end = data_start + filesize
        data_end_aligned = (data_end + 3) & ~3
        content = data[data_start:data_end]
        if name == 'TRAILER!!!':
            break
        entries.append((name, mode, content))
        pos = data_end_aligned
    return entries

def write_cpio(entries):
    """Write cpio newc archive."""
    out = io.BytesIO()
    ino = 1
    for name, mode, content in entries:
        name_bytes = name.encode('utf-8') + b'\x00'
        namesize = len(name_bytes)
        filesize = len(content)
        hdr = f'070701{ino:08X}{mode:08X}00000000000000000000000100000000{filesize:08X}00000000000000000000000000000000{namesize:08X}00000000'
        out.write(hdr.encode())
        out.write(name_bytes)
        # Pad to 4-byte boundary
        pad = (4 - (110 + namesize) % 4) % 4
        out.write(b'\x00' * pad)
        out.write(content)
        pad = (4 - filesize % 4) % 4
        out.write(b'\x00' * pad)
        ino += 1
    # Trailer
    trailer = b'TRAILER!!!\x00'
    namesize = len(trailer)
    hdr = f'07070100000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000{namesize:08X}00000000'
    out.write(hdr.encode())
    out.write(trailer)
    pad = (4 - (110 + namesize) % 4) % 4
    out.write(b'\x00' * pad)
    return out.getvalue()

def main():
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <stock-ramdisk.img> <modules-dir> <output-ramdisk.img>")
        sys.exit(1)

    ramdisk_path = sys.argv[1]
    modules_dir = sys.argv[2]
    output_path = sys.argv[3]

    print(f"Reading stock ramdisk: {ramdisk_path}")
    with open(ramdisk_path, 'rb') as f:
        raw = f.read()

    # Detect compression
    if raw[:4] == b'\x04\x22\x4d\x18':  # LZ4 magic
        print("Decompressing LZ4...")
        cpio_data = lz4.frame.decompress(raw)
        compress = 'lz4'
    elif raw[:2] == b'\x1f\x8b':  # gzip magic
        print("Decompressing gzip...")
        cpio_data = gzip.decompress(raw)
        compress = 'gzip'
    else:
        cpio_data = raw
        compress = 'none'

    print(f"Parsing CPIO archive ({len(cpio_data)} bytes)...")
    entries = read_cpio(cpio_data)
    print(f"Found {len(entries)} entries")

    # Find and replace modules
    replaced = 0
    module_files = {}
    for f in os.listdir(modules_dir):
        if f.endswith('.ko'):
            module_files[f] = os.path.join(modules_dir, f)

    new_entries = []
    for name, mode, content in entries:
        basename = os.path.basename(name)
        if basename in module_files:
            with open(module_files[basename], 'rb') as mf:
                new_content = mf.read()
            print(f"  Replaced: {name} ({len(content)} -> {len(new_content)} bytes)")
            new_entries.append((name, mode, new_content))
            replaced += 1
        else:
            new_entries.append((name, mode, content))

    print(f"\nReplaced {replaced} modules")

    # Write new CPIO
    print("Writing new CPIO archive...")
    new_cpio = write_cpio(new_entries)

    # Compress
    if compress == 'lz4':
        print("Compressing with LZ4...")
        compressed = lz4.frame.compress(new_cpio)
    elif compress == 'gzip':
        print("Compressing with gzip...")
        compressed = gzip.compress(new_cpio)
    else:
        compressed = new_cpio

    with open(output_path, 'wb') as f:
        f.write(compressed)

    print(f"\nOutput: {output_path} ({len(compressed)} bytes)")
    print("Done!")

if __name__ == '__main__':
    main()
