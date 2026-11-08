# big32 Linux init + tiny shell, RV32I, hand-assembled by rootfs/mkelf.py.
# PID 1: mounts /proc and /sys (best effort), prints a banner, then loops
# as a real shell on the console: help, echo, ls, cat, uname, pwd.
# No M/A/C instructions, no libc, no toolchain: syscalls via ecall only.
# Syscall numbers are the asm-generic (riscv) ones: read 63, write 64,
# openat 56, close 57, getdents64 61, mount 40, getcwd 17, uname 160.
# s0 = line buffer, s1 = args pointer. puts/streq clobber a0-a2,t0-t1 only.

_start:
    li s0, linebuf
    li a0, proc_src
    li a1, proc_tgt
    li a2, proc_fs
    li a3, 0
    li a4, 0
    li a7, 40
    ecall
    li a0, sys_src
    li a1, sys_tgt
    li a2, sys_fs
    li a3, 0
    li a4, 0
    li a7, 40
    ecall
    li a1, banner
    jal puts
shell_loop:
    li a1, prompt
    jal puts
    li a0, 0
    li a1, linebuf
    li a2, 255
    li a7, 63
    ecall
    ble a0, zero, shell_loop
    # NUL-terminate at the byte count returned (a0 < 256, buffer is 256)
    li t0, linebuf
    add t0, t0, a0
    sb zero, 0(t0)
    # Strip trailing newline / carriage return: first 10 or 13 becomes NUL
    li t0, linebuf
strip_loop:
    lbu t1, 0(t0)
    beq t1, zero, parse
    li t2, 10
    beq t1, t2, strip_done
    li t2, 13
    beq t1, t2, strip_done
    addi t0, t0, 1
    j strip_loop
strip_done:
    sb zero, 0(t0)
parse:
    # Split first word from args: first space becomes NUL, s1 = args
    li t0, linebuf
    li s1, linebuf
split_loop:
    lbu t1, 0(t0)
    beq t1, zero, dispatch
    li t2, 32
    beq t1, t2, split_done
    addi t0, t0, 1
    j split_loop
split_done:
    sb zero, 0(t0)
    addi s1, t0, 1
    # Skip extra spaces in args
skip_spaces:
    lbu t1, 0(s1)
    li t2, 32
    bne t1, t2, dispatch
    addi s1, s1, 1
    j skip_spaces
dispatch:
    li a1, linebuf
    li a2, cmd_help
    jal streq
    bne a0, zero, do_help
    li a1, linebuf
    li a2, cmd_echo
    jal streq
    bne a0, zero, do_echo
    li a1, linebuf
    li a2, cmd_ls
    jal streq
    bne a0, zero, do_ls
    li a1, linebuf
    li a2, cmd_cat
    jal streq
    bne a0, zero, do_cat
    li a1, linebuf
    li a2, cmd_uname
    jal streq
    bne a0, zero, do_uname
    li a1, linebuf
    li a2, cmd_pwd
    jal streq
    bne a0, zero, do_pwd
    # Empty line: just re-prompt
    lbu t1, 0(s0)
    beq t1, zero, shell_loop
    li a1, unk_prefix
    jal puts
    li a1, linebuf
    jal puts
    li a1, newline
    jal puts
    j shell_loop
do_help:
    li a1, help_txt
    jal puts
    j shell_loop
do_echo:
    # No-argument test, same pattern as the Step 23 do_ls fix: parse
    # leaves s1 = linebuf (s0) when the line has no space, so s1 == s0
    # means "no argument". Bare `echo` used to print the word "echo"
    # itself (s1 pointed at the command word); now it prints just a
    # newline. (Trailing-space `echo ` also yields just a newline:
    # skip_spaces leaves s1 on the NUL, so puts prints empty.)
    beq s1, s0, echo_nl
    mv a1, s1
    jal puts
echo_nl: li a1, newline
    jal puts
    j shell_loop
do_uname:
    li a0, utsbuf
    li a7, 160
    ecall
    li a1, utsbuf
    jal puts
    li a1, space
    jal puts
    li a1, utsbuf+130
    jal puts
    li a1, space
    jal puts
    li a1, utsbuf+260
    jal puts
    li a1, newline
    jal puts
    j shell_loop
do_pwd:
    li a0, cwdbuf
    li a1, 256
    li a7, 17
    ecall
    blt a0, zero, pwd_fail
    li a1, cwdbuf
    jal puts
    li a1, newline
    jal puts
    j shell_loop
pwd_fail:
    li a1, qmark
    jal puts
    j shell_loop
do_ls:
    # Default path "." when no argument given. No-argument test: parse
    # leaves s1 = linebuf (s0) when the line has no space, so s1 == s0
    # means "no argument". (The old test read *s1, which for bare `ls`
    # is the command word itself, so it opened a file literally named
    # "ls" in / and failed with ENOENT. The lbu is now redundant but
    # is retained, harmless, to keep the binary layout byte-identical
    # in size: the rebuilt init must stay 3440 bytes for the in-place
    # image patch.)
    lbu t1, 0(s1)
    bne s1, s0, ls_open
    li s1, dot
ls_open:
    li a0, -100
    mv a1, s1
    li a2, 0
    li a7, 56
    ecall
    blt a0, zero, ls_fail
    mv s3, a0
ls_dents:
    mv a0, s3
    li a1, dentbuf
    li a2, 1024
    li a7, 61
    ecall
    ble a0, zero, ls_close
    li s5, dentbuf
    add s6, s5, a0
ls_entry:
    bge s5, s6, ls_dents
    lhu s7, 16(s5)
    addi a1, s5, 19
    jal puts
    li a1, newline
    jal puts
    add s5, s5, s7
    j ls_entry
ls_close:
    mv a0, s3
    li a7, 57
    ecall
    j shell_loop
ls_fail:
    li a1, ls_err
    jal puts
    j shell_loop
do_cat:
    # No-argument test, same pattern as the Step 23 do_ls fix: parse
    # leaves s1 = linebuf (s0) when the line has no space, so s1 == s0
    # means "no argument". Bare `cat` used to open a file literally
    # named "cat" (s1 pointed at the command word) and fail with
    # ENOENT; now it prints the usage line. The old lbu is dropped,
    # not retained: its value was dead (cat_read overwrites t1 with
    # the read count before any read, cat_fail only calls puts),
    # and dropping it exactly offsets the extra word added in
    # do_echo above, keeping the rebuilt init at 3440 bytes.
    # (Trailing-space `cat ` still reaches cat_fail with an empty
    # path, i.e. an error line, not the usage line -- same as the
    # Step 23 do_ls behaviour for trailing-space `ls `.)
    beq s1, s0, cat_missing
    li a0, -100
    mv a1, s1
    li a2, 0
    li a7, 56
    ecall
    blt a0, zero, cat_fail
    mv s3, a0
cat_read:
    mv a0, s3
    li a1, dentbuf
    li a2, 1024
    li a7, 63
    ecall
    ble a0, zero, cat_close
    li t0, dentbuf
    mv t1, a0
cat_write:
    beq t1, zero, cat_read
    mv a0, t0
    # write(1, t0, t1): keep ptr/len in s5/s6 across the ecall
    mv s5, t0
    mv s6, t1
    li a0, 1
    mv a1, s5
    mv a2, s6
    li a7, 64
    ecall
    ble a0, zero, cat_close
    add s5, s5, a0
    sub s6, s6, a0
    mv t0, s5
    mv t1, s6
    j cat_write
cat_close:
    mv a0, s3
    li a7, 57
    ecall
    j shell_loop
cat_missing:
    li a1, cat_usage
    jal puts
    j shell_loop
cat_fail:
    li a1, cat_err1
    jal puts
    mv a1, s1
    jal puts
    li a1, cat_err2
    jal puts
    j shell_loop

# puts(a1 = NUL-terminated string): write it fully to fd 1.
# Clobbers a0-a2, t0-t1.
puts:
    mv t0, a1
    li t1, 0
puts_len:
    add t2, t0, t1
    lbu t2, 0(t2)
    beq t2, zero, puts_write
    addi t1, t1, 1
    j puts_len
puts_write:
    beq t1, zero, puts_ret
    li a0, 1
    mv a1, t0
    mv a2, t1
    li a7, 64
    ecall
    ble a0, zero, puts_ret
    add t0, t0, a0
    sub t1, t1, a0
    j puts_write
puts_ret:
    ret

# streq(a1, a2): a0 = 1 if the two NUL-terminated strings are equal.
# Clobbers a0-a2, t0-t1.
streq:
streq_loop:
    lbu t0, 0(a1)
    lbu t1, 0(a2)
    bne t0, t1, streq_no
    beq t0, zero, streq_yes
    addi a1, a1, 1
    addi a2, a2, 1
    j streq_loop
streq_yes:
    li a0, 1
    ret
streq_no:
    li a0, 0
    ret

banner:
    .string "\nbig32 init: userspace is up (PID 1, RV32I, no libc)\n"
prompt:
    .string "big32# "
help_txt:
    .string "commands: help echo ls cat uname pwd\n"
unk_prefix:
    .string "unknown command: "
newline:
    .string "\n"
space:
    .string " "
qmark:
    .string "?\n"
proc_src:
    .string "proc"
proc_tgt:
    .string "/proc"
proc_fs:
    .string "proc"
sys_src:
    .string "sysfs"
sys_tgt:
    .string "/sys"
sys_fs:
    .string "sysfs"
cmd_help:
    .string "help"
cmd_echo:
    .string "echo"
cmd_ls:
    .string "ls"
cmd_cat:
    .string "cat"
cmd_uname:
    .string "uname"
cmd_pwd:
    .string "pwd"
dot:
    .string "."
ls_err:
    .string "ls: cannot open directory\n"
cat_usage:
    .string "cat: missing file\n"
cat_err1:
    .string "cat: "
cat_err2:
    .string ": cannot open\n"
linebuf:
    .space 256
dentbuf:
    .space 1024
utsbuf:
    .space 390
cwdbuf:
    .space 256
