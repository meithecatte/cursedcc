# NOTE: the label resolver assumes that all bytes in "$code" are encoded
# as four characters (backslash, x, and two hexdigits). So don't get clever
# with octal or \n or whatever else.

STACK_ALIGNMENT=16

EAX=0
ECX=1
EDX=2
EBX=3
ESP=4; RSP=4
EBP=5; RBP=5
ESI=6
EDI=7
R8=8
R9=9

declare abi_regs=($EDI $ESI $EDX $ECX $R8 $R9)
declare num_abi_regs=${#abi_regs[@]}

CC_E=4
CC_Z=4
CC_NE=5
CC_NZ=5
CC_L=12
CC_GE=13
CC_LE=14
CC_G=15

# rex r b w
# where
# r - the register in the register field (of which the msb should be encoded)
# b - the register in the base field
# w - if non-zero, the instruction uses 64-bit data
rex() {
    local r=$1 b=$2 w=${3-0}
    local -i byte=0x40
    (( w )) && (( byte |= 8 ))
    (( r >= 8 )) && (( byte |= 4 ))
    (( b >= 8 )) && (( byte |= 1 ))
    if (( byte != 0x40 )); then
        p8 code $byte
    fi
}

op_modrm_reg() {
    # reg - register field
    # rm - r/m field (register index)
    # wide - if nonzero, 64-bit data
    local op="$1" reg="$2" rm="$3" wide="${4-0}"
    rex $reg $rm $wide
    code+="$op"
    p8 code $((0xc0 + 8 * (reg & 7) + (rm & 7)))
}

op_modrm_rbpoff() {
    local op="$1" reg="$2" offset="$3"
    rex $reg 0
    code+="$op"
    if (( -128 <= offset && offset <= 127 )); then
        p8 code $((0x45 + 8 * (reg & 7)))
        p8 code $offset
    else
        p8 code $((0x85 + 8 * (reg & 7)))
        p32 code $offset
    fi
}

op_modrm_sym() {
    local op="$1" reg="$2" sym="$3"
    rex $reg 0
    code+="$op"
    p8 code $((5 + 8 * (reg & 7)))
    local -i pos
    binlength pos "$code"
    reloc "$sym" $R_X86_64_PC32 -4
    p32 code 0
}

leave() {
    code+="\xc9"
}

ret() {
    code+="\xc3"
}

mov_reg_imm() {
    local reg="$1" imm="$2"
    (( reg < 8 )) || fail "TODO: load immediate into high reg"
    p8 code $((0xb8 + reg))
    p32 code "$imm"
}

mov_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x89" "$src" "$dst"
}

mov_rbpoff_reg() {
    local offset="$1" src="$2"
    op_modrm_rbpoff "\x89" "$src" "$offset"
}

mov_reg_rbpoff() {
    local dst="$1" offset="$2"
    op_modrm_rbpoff "\x8b" "$dst" "$offset"
}

mov_sym_reg() {
    local sym="$1" src="$2"
    op_modrm_sym "\x89" "$src" "$sym"
}

mov_reg_sym() {
    local dst="$1" sym="$2"
    op_modrm_sym "\x8b" "$dst" "$sym"
}

movq_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x89" "$src" "$dst" 1
}

not_reg() {
    local reg="$1"
    op_modrm_reg "\xf7" 2 "$reg"
}

neg_reg() {
    local reg="$1"
    op_modrm_reg "\xf7" 3 "$reg"
}

shl_reg_cl() {
    local reg="$1"
    op_modrm_reg "\xd3" 4 "$reg"
}

shr_reg_cl() {
    local reg="$1"
    op_modrm_reg "\xd3" 5 "$reg"
}

sar_reg_cl() {
    local reg="$1"
    op_modrm_reg "\xd3" 7 "$reg"
}

push_reg() {
    local reg="$1"
    rex 0 $reg
    p8 code $((0x50 + (reg & 7)))
}

pop_reg() {
    local reg="$1"
    rex 0 $reg
    p8 code $((0x58 + (reg & 7)))
}

add_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x01" "$src" "$dst"
}

or_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x09" "$src" "$dst"
}

and_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x21" "$src" "$dst"
}

sub_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x29" "$src" "$dst"
}

addq_reg_imm() {
    local dst="$1" imm="$2"
    if (( -128 <= imm && imm <= 127 )); then
        op_modrm_reg "\x83" 0 "$dst" 1
        p8 code "$imm"
    else
        op_modrm_reg "\x81" 0 "$dst" 1
        p32 code "$imm"
    fi
}

subq_reg_imm() {
    local dst="$1" imm="$2"
    if (( -128 <= imm && imm <= 127 )); then
        op_modrm_reg "\x83" 5 "$dst" 1
        p8 code "$imm"
    else
        op_modrm_reg "\x81" 5 "$dst" 1
        p32 code "$imm"
    fi
}

xor_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x31" "$src" "$dst"
}

cmp_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x39" "$src" "$dst"
}

test_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x85" "$src" "$dst"
}

imul_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x0f\xaf" "$dst" "$src"
}

cdq() {
    code+="\x99"
}

idiv_reg() {
    local reg="$1"
    op_modrm_reg "\xf7" 7 "$reg"
}

movzxb_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x0f\xb6" "$src" "$dst"
}

setcc_reg() {
    local cc="$1" dst="$2"
    local opcode="\x0f"
    p8 opcode $((0x90 + cc))
    op_modrm_reg "$opcode" 0 "$dst"
}

# jmp label
jmp() {
    jump "$1"
}

# jmp cc label
jcc() {
    jump "$2" "$1"
}

# call symbol
call_symbol() {
    local -i pos
    code+="\xe8"
    binlength pos "$code"
    reloc $1 $R_X86_64_PLT32 -4
    p32 code 0
}
