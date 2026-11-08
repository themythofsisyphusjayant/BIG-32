#!/usr/bin/env python3
"""Assemble rootfs/init.asm (RV32I, no M/A/C) and emit a static ELF32
RISC-V executable at a fixed base address, with no toolchain at all.

Usage: python3 rootfs/mkelf.py [init.asm] [init.elf]
Defaults: rootfs/init.asm -> rootfs/init (the file placed in the rootfs
as /init; it is an ELF, not a script).

Syntax per line: [label:] MNEMONIC operands   # comments start with #
Directives: .string "..." (escapes \n \t \\ \"), .space N (N zero bytes).
Pseudos: nop, mv, li (immediate, label, or label+/-offset), j, jr, ret,
ble (bge with swapped operands), bgt (blt with swapped operands).
Data labels are word-aligned (padded with zeros) in the single PT_LOAD
segment, which is RWX so the buffers live in the file image.
ELF: ET_EXEC, EM_RISCV (243), e_flags 0 (no RVC, soft-float ABI),
one PT_LOAD, no section headers (the kernel does not need them).
"""
import struct
import sys

BASE = 0x10000
# ELF header (52 bytes) + one program header (32 bytes) = 84 bytes.
# The PT_LOAD has p_offset=0, so the kernel maps file byte F to VA
# BASE+F. The code image therefore starts at VA BASE+HDR, NOT at BASE:
# label addresses must be BASE + file_offset, i.e. BASE + HDR +
# image_offset. (Before this fix, layout() started at BASE, so every
# label was 84 bytes low and e_entry pointed at the ELF header itself.)
HDR = 84

REGS = {"zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
        "t0": 5, "t1": 6, "t2": 7, "t3": 28, "t4": 29, "t5": 30, "t6": 31,
        "s0": 8, "s1": 9, "s2": 18, "s3": 19, "s4": 20, "s5": 21,
        "s6": 22, "s7": 23, "s8": 24, "s9": 25, "s10": 26, "s11": 27,
        "a0": 10, "a1": 11, "a2": 12, "a3": 13,
        "a4": 14, "a5": 15, "a6": 16, "a7": 17}
for i in range(32):
    REGS[f"x{i}"] = i

R_OPS = {"add": (0x0, 0x00), "sub": (0x0, 0x20), "and": (0x7, 0x00),
         "or": (0x6, 0x00), "xor": (0x4, 0x00), "sll": (0x1, 0x00),
         "srl": (0x5, 0x00), "sra": (0x5, 0x20), "slt": (0x2, 0x00),
         "sltu": (0x3, 0x00)}
I_OPS = {"addi": 0x0, "andi": 0x7, "ori": 0x6, "xori": 0x4,
         "slti": 0x2, "sltiu": 0x3}
SH_OPS = {"slli": (0x1, 0x00), "srli": (0x5, 0x00), "srai": (0x5, 0x20)}
LOADS = {"lb": 0x0, "lh": 0x1, "lw": 0x2, "lbu": 0x4, "lhu": 0x5}
STORES = {"sb": 0x0, "sh": 0x1, "sw": 0x2}
BRANCHES = {"beq": 0x0, "bne": 0x1, "blt": 0x4, "bge": 0x5,
            "bltu": 0x6, "bgeu": 0x7}


def reg(name):
    n = name.strip().lower()
    if n not in REGS:
        raise ValueError(f"unknown register: {name}")
    return REGS[n]


def parse_int(s):
    s = s.strip()
    return int(s, 16) if s.startswith(("0x", "0X", "-0x")) else int(s, 10)


def split_operands(s):
    # Commas separate operands, except inside offset(reg) there is none.
    return [p.strip() for p in s.split(",") if p.strip()]


def parse_mem(s):
    # offset(reg)
    off, rest = s.split("(", 1)
    return parse_int(off), reg(rest.rstrip(")"))


def unescape(s):
    out = bytearray()
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            nxt = s[i + 1]
            out += {"n": b"\n", "t": b"\t", "\\": b"\\", '"': b'"'}.get(nxt, nxt.encode())
            i += 2
        else:
            out += c.encode()
            i += 1
    return bytes(out)


def parse_lines(path):
    items = []  # (kind, label, payload) kind: insn | string | space
    for raw in open(path):
        # Strip comments, but not a '#' inside a quoted string.
        line, in_q = "", False
        for ch in raw:
            if ch == '"':
                in_q = not in_q
            if ch == "#" and not in_q:
                break
            line += ch
        line = line.strip()
        if not line:
            continue
        label = None
        # Split off a label only at a ':' outside quotes.
        in_q, colon = False, -1
        for idx, ch in enumerate(line):
            if ch == '"':
                in_q = not in_q
            elif ch == ":" and not in_q:
                colon = idx
                break
        if colon >= 0:
            label, line = line[:colon].strip(), line[colon + 1:].strip()
        if not line:
            items.append(("label_only", label, None))
            continue
        parts = line.split(None, 1)
        mnem = parts[0].lower()
        rest = parts[1].strip() if len(parts) > 1 else ""
        if mnem == ".string":
            assert rest.startswith('"') and rest.endswith('"'), line
            items.append(("string", label, unescape(rest[1:-1]) + b"\x00"))
        elif mnem == ".space":
            items.append(("space", label, parse_int(rest)))
        else:
            items.append(("insn", label, (mnem, rest)))
    return items


def li_size(expr, labels):
    # li expands to 1 insn (small immediate) or 2 (lui+addi); label refs: 2.
    expr = expr.strip()
    if expr.lstrip("-").startswith("0x") or expr.lstrip("-").isdigit():
        v = parse_int(expr)
        return 4 if -2048 <= v < 2048 else 8
    return 8


def insn_size(mnem, rest):
    if mnem == "li":
        return li_size(rest.split(",")[1], None)
    return 4


def layout(items):
    """Pass 1: assign addresses; returns (labels, expanded list).

    Addresses are virtual addresses under the kernel's mapping
    (file byte F -> VA BASE+F), so the first image byte sits at
    BASE+HDR, and label VA = BASE + file_offset.
    """
    labels = {}
    addr = BASE + HDR
    expanded = []  # (addr, kind, payload)
    for kind, label, payload in items:
        if kind == "label_only":
            labels[label] = addr
            continue
        if kind in ("string", "space"):
            if addr % 4:
                addr += 4 - (addr % 4)
            if label:
                labels[label] = addr
            n = len(payload) if kind == "string" else payload
            expanded.append((addr, kind, payload))
            addr += (n + 3) // 4 * 4
            continue
        # insn
        if label:
            labels[label] = addr
        mnem, rest = payload
        expanded.append((addr, "insn", payload))
        addr += insn_size(mnem, rest)
    return labels, expanded, addr


def resolve_value(expr, labels):
    expr = expr.strip()
    for op in ("+", "-"):
        if op in expr[1:]:
            name, off = expr.split(op, 1)
            name = name.strip()
            if name in labels:
                v = labels[name] + (parse_int(off) if op == "+" else -parse_int(off))
                return v
    if expr in labels:
        return labels[expr]
    return parse_int(expr)


def enc_li(rd, expr, labels):
    v = resolve_value(expr, labels) & 0xFFFFFFFF
    if v & 0x80000000:
        v -= 0x100000000
    if -2048 <= v < 2048:
        return [enc_i(0x13, rd, 0, 0x0, v & 0xFFF)]
    hi = (v + 0x800) >> 12
    lo = v - (hi << 12)
    return [enc_u(0x37, rd, hi & 0xFFFFF), enc_i(0x13, rd, rd, 0x0, lo & 0xFFF)]


def enc_r(f3, f7, rd, rs1, rs2):
    return (0x33 | (rd << 7) | (f3 << 12) | (rs1 << 15) | (rs2 << 20) | (f7 << 25))


def enc_i(op, rd, rs1, f3, imm):
    return (op | (rd << 7) | (f3 << 12) | (rs1 << 15) | ((imm & 0xFFF) << 20))


def enc_u(op, rd, imm20):
    return (op | (rd << 7) | ((imm20 & 0xFFFFF) << 12))


def enc_s(op, f3, rs1, rs2, imm):
    imm &= 0xFFF
    return (op | ((imm & 0x1F) << 7) | (f3 << 12) | (rs1 << 15) |
            (rs2 << 20) | ((imm >> 5) << 25))


def enc_b(f3, rs1, rs2, off):
    off &= 0x1FFF
    return (0x63 | ((off >> 11 & 0x1) << 7) | ((off & 0x1E) << 7) |
            (f3 << 12) | (rs1 << 15) | (rs2 << 20) |
            ((off >> 5 & 0x3F) << 25) | ((off >> 12 & 0x1) << 31))


def enc_j(rd, off):
    off &= 0x1FFFFF
    return (0x6F | (rd << 7) | ((off >> 12 & 0xFF) << 12) |
            ((off >> 11 & 0x1) << 20) | ((off >> 1 & 0x3FF) << 21) |
            ((off >> 20 & 0x1) << 31))


def encode(mnem, rest, pc, labels):
    ops = split_operands(rest)
    if mnem in R_OPS:
        f3, f7 = R_OPS[mnem]
        return [enc_r(f3, f7, reg(ops[0]), reg(ops[1]), reg(ops[2]))]
    if mnem in I_OPS:
        return [enc_i(0x13, reg(ops[0]), reg(ops[1]), I_OPS[mnem],
                       parse_int(ops[2]) & 0xFFF)]
    if mnem in SH_OPS:
        f3, f7 = SH_OPS[mnem]
        return [enc_i(0x13, reg(ops[0]), reg(ops[1]), f3,
                       (f7 << 10) | (parse_int(ops[2]) & 0x1F))]
    if mnem in LOADS:
        off, rs1 = parse_mem(ops[1])
        return [enc_i(0x03, reg(ops[0]), rs1, LOADS[mnem], off & 0xFFF)]
    if mnem in STORES:
        off, rs1 = parse_mem(ops[1])
        return [enc_s(0x23, STORES[mnem], rs1, reg(ops[0]), off)]
    if mnem in BRANCHES:
        off = labels[ops[2]] - pc
        assert -4096 <= off < 4096 and off % 2 == 0, f"branch out of range: {mnem} {ops[2]}"
        return [enc_b(BRANCHES[mnem], reg(ops[0]), reg(ops[1]), off)]
    if mnem in ("ble", "bgt"):
        # ble rs,rt -> bge rt,rs ; bgt rs,rt -> blt rt,rs
        f3 = 0x5 if mnem == "ble" else 0x4
        off = labels[ops[2]] - pc
        assert -4096 <= off < 4096 and off % 2 == 0
        return [enc_b(f3, reg(ops[1]), reg(ops[0]), off)]
    if mnem == "jal":
        if len(ops) == 1:
            rd, tgt = 1, ops[0]
        else:
            rd, tgt = reg(ops[0]), ops[1]
        off = labels[tgt] - pc
        assert -(1 << 20) <= off < (1 << 20) and off % 2 == 0
        return [enc_j(rd, off)]
    if mnem == "jalr":
        # jalr rd, off(rs1)
        rd = reg(ops[0])
        off, rs1 = parse_mem(ops[1])
        return [enc_i(0x67, rd, rs1, 0x0, off & 0xFFF)]
    if mnem == "lui":
        return [enc_u(0x37, reg(ops[0]), parse_int(ops[1]) & 0xFFFFF)]
    if mnem == "auipc":
        return [enc_u(0x17, reg(ops[0]), parse_int(ops[1]) & 0xFFFFF)]
    if mnem == "ecall":
        return [0x00000073]
    if mnem == "ebreak":
        return [0x00100073]
    if mnem == "nop":
        return [enc_i(0x13, 0, 0, 0x0, 0)]
    if mnem == "mv":
        return [enc_i(0x13, reg(ops[0]), reg(ops[1]), 0x0, 0)]
    if mnem == "li":
        return enc_li(reg(ops[0]), ops[1], labels)
    if mnem == "j":
        off = labels[ops[0]] - pc
        return [enc_j(0, off)]
    if mnem == "jr":
        return [enc_i(0x67, 0, reg(ops[0]), 0x0, 0)]
    if mnem == "ret":
        return [enc_i(0x67, 0, 1, 0x0, 0)]
    raise ValueError(f"unknown mnemonic: {mnem}")


def build(src_path, out_path):
    items = parse_lines(src_path)
    labels, expanded, end = layout(items)
    image = bytearray(end - (BASE + HDR))
    for addr, kind, payload in expanded:
        off = addr - (BASE + HDR)
        if kind == "string":
            image[off:off + len(payload)] = payload
        elif kind == "space":
            pass  # zeros already
        else:
            mnem, rest = payload
            for i, word in enumerate(encode(mnem, rest, addr, labels)):
                struct.pack_into("<I", image, off + 4 * i, word)
    entry = labels["_start"]
    # ELF32 header (52 bytes) + one program header (32 bytes)
    ehdr = struct.pack("<16sHHIIIIIHHHHHH",
                       b"\x7fELF\x01\x01\x01" + b"\x00" * 9,
                       2, 243, 1, entry, 52, 0, 0, 52, 32, 1, 0, 0, 0)
    # p_offset=0 maps the whole file to VA BASE, so filesz/memsz must
    # cover the header too (len(image)+HDR == total file size); with the
    # old filesz=len(image), the last HDR bytes of the image (the tail
    # buffers) sat beyond the declared segment.
    phdr = struct.pack("<IIIIIIII", 1, 0, BASE, BASE,
                       len(image) + HDR, len(image) + HDR, 7, 0x1000)
    with open(out_path, "wb") as fh:
        fh.write(ehdr + phdr + bytes(image))
    print(f"{out_path}: entry=0x{entry:x} size={len(image)} bytes "
          f"({(len(image) + HDR)} file bytes)")


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else "rootfs/init.asm"
    out = sys.argv[2] if len(sys.argv) > 2 else "rootfs/init"
    build(src, out)
