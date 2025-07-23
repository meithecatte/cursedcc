ELFCLASS32="\x01"
ELFCLASS64="\x02"
ei_class="$ELFCLASS64" # we are emitting 64-bit code
ehsize=64
phentsize=56
shentsize=64

ELFDATA2LSB="\x01"
ELFDATA2MSB="\x02"
ei_data="$ELFDATA2LSB" # for a little-endian machine

ELFOSABI_SYSV="\x00"
ei_osabi="$ELFOSABI_SYSV" # running an OS with the System V ABI

ET_REL=1

EM_X86_64=62

SHN_UNDEF=0

SHT_PROGBITS=1
SHT_SYMTAB=2
SHT_STRTAB=3
SHT_RELA=4
SHT_NOBITS=8
SHT_REL=9

SHF_WRITE=1
SHF_ALLOC=2
SHF_EXECINSTR=4

STB_LOCAL=0
STB_GLOBAL=1

STT_NOTYPE=0

R_X86_64_PC32=2
R_X86_64_PLT32=4

# addresses are 64 bit
psz() {
    p64 "$@"
}

# Maps the section name to its index in the section header table
declare -iA section_index

# Maps the symbol name to its index in the symbol table
declare -iA symtab_index

# Maps the section name to the data it should contain
declare -A sections

# Maps the section name to its sh_type
declare -A section_types

# Maps the section name to its sh_flags
declare -A section_attrs

# Maps the section name to its sh_info
declare -A section_info

# Maps the names of defined symbols to their positions. If a symbol is not
# declared, but is referenced from the relocations array, it'll be emitted
# as imported, in which case the section and offset will be set to "" and 0
# respectively.
declare -A symbol_sections
declare -A symbol_offsets
# Maps the names of defined symbols to the value of st_info they should have
declare -iA symbol_info

# List of all relocations that should be included in the output file.
# Each entry is a string with the following fields separated by spaces:
# - position of the relocation:
#   - section
#   - offset
# - target symbol
# - type of relocation
# - addend
declare -a relocations

# build_stringtable section_name out_array entries...
build_stringtable() {
    local section="$1"
    local -n positions="$2"
    shift 2
    local data="\x00"
    local s
    for s in "$@"; do
        local pos
        binlength pos "$data"
        positions[$s]="$pos"
        data+="$s\x00"
    done

    sections[$section]="$data"
    section_types[$section]="$SHT_STRTAB"
}

collect_imports() {
    local reloc
    for reloc in "${relocations[@]}"; do
        local reloc_parts=($reloc)
        local section="${reloc_parts[0]}"
        local symbol="${reloc_parts[2]}"

        if [ -z "${symbol_sections[$symbol]-}" ]; then
            symbol_sections[$symbol]=
            symbol_offsets[$symbol]=0
            symbol_info[$symbol]=$((STB_GLOBAL << 4 | STT_NOTYPE))
        fi

        # Make sure the relocation section exists so that it gets
        # included in section_order
        sections[.rela$section]+=""
    done
}

build_symtab() {
    local -iA strtab_positions
    # Table of symbol names
    build_stringtable .strtab strtab_positions "${!symbol_sections[@]}"

    # XXX: this struct differs between 32- and 64-bit ELFs. Let's do only 64-bit
    # for now.
    local symtab=""

    # Of *course* the first symbol table entry needs to be null, what did you
    # expect?

    local i
    for (( i=0; i < 24; i++ )); do
        symtab+="\x00"
    done

    local -i symbol_count=1
    local symbol num_locals
    for do_local in 1 0; do
        for symbol in "${!symbol_sections[@]}"; do
            local section="${symbol_sections[$symbol]}"
            local offset="${symbol_offsets[$symbol]}"
            local info="${symbol_info[$symbol]}"
            if (( (info >> 4) == STB_LOCAL && !do_local )) ||
               (( (info >> 4) != STB_LOCAL && do_local )); then
                continue
            fi

            if [ -z "$section" ]; then
                # imported symbol
                local shndx=$SHN_UNDEF
            else
                local shndx=${section_index[$section]}
            fi

            p32 symtab "${strtab_positions[$symbol]}" # st_name
            p8 symtab "${symbol_info[$symbol]}" # st_info
            symtab+="\x00" # st_other: reserved, 0
            p16 symtab "$shndx" # st_shndx
            p64 symtab "$offset" # st_value
            p64 symtab 0 # st_size
            symtab_index[$symbol]=$symbol_count
            symbol_count+=1
        done

        if (( do_local )); then
            num_locals=$symbol_count
        fi
    done

    sections[.symtab]="$symtab"
    section_types[.symtab]="$SHT_SYMTAB"
    section_info[.symtab]=$num_locals
}

build_relocs() {
    local -A reloc_sections

    local reloc
    for reloc in "${relocations[@]}"; do
        local reloc_parts=($reloc)
        local section="${reloc_parts[0]}"
        local offset="${reloc_parts[1]}"
        local symbol="${reloc_parts[2]}"
        local rtype="${reloc_parts[3]}"
        local addend="${reloc_parts[4]}"
        p64 reloc_sections[$section] $offset
        p32 reloc_sections[$section] $rtype
        p32 reloc_sections[$section] ${symtab_index[$symbol]}
        p64 reloc_sections[$section] $addend
    done

    local section
    for section in "${!reloc_sections[@]}"; do
        sections[.rela$section]="${reloc_sections[$section]}"
        section_types[.rela$section]="$SHT_RELA"
        section_info[.rela$section]="${section_index[$section]}"
    done
}

# emit_elf filename
emit_elf() {
    local filename="$1"

    collect_imports

    # Iteration order of bash's associative arrays is not stable. Pick one
    # ordering and stick to it.
    local -a section_order=("${!sections[@]}" .shstrtab .strtab .symtab)

    # The first entry in the section table should be SHT_NULL
    # (this is probably to not conflict with SHN_UNDEF)
    # cf. https://stackoverflow.com/q/26812142
    local -i section_count=1
    for section in "${section_order[@]}"; do
        section_index["$section"]=$section_count
        section_count+=1
    done

    build_symtab
    build_relocs

    # Table of section names
    local -iA shstrtab_positions
    build_stringtable .shstrtab shstrtab_positions "${!sections[@]}" .shstrtab

    local -i position=$ehsize
    local section_data=""

    # first section header needs to be NULL, apparently
    local section_headers=""
    local -i i
    for (( i=0; i < shentsize; i++)); do
        section_headers+="\x00"
    done

    local section_name
    for section_name in "${section_order[@]}"; do
        local section="${sections[$section_name]}"
        local section_size
        if (( ${section_types[$section_name]} == SHT_NOBITS )); then
            section_size="$section"
        else
            binlength section_size "$section"
        fi
        p32 section_headers "${shstrtab_positions[$section_name]}" # sh_name
        p32 section_headers "${section_types[$section_name]}" # sh_type
        psz section_headers "${section_attrs[$section_name]-0}" # sh_flags
        psz section_headers 0 # sh_addr
        psz section_headers $position # sh_offset
        psz section_headers $section_size # sh_size

        local entsize=0 link=0
        if (( section_types["$section_name"] == SHT_SYMTAB )); then
            entsize=24
            link=${section_index[.strtab]}
        elif (( section_types["$section_name"] == SHT_RELA )); then
            entsize=24
            link=${section_index[.symtab]}
        fi

        p32 section_headers $link # sh_link
        p32 section_headers "${section_info[$section_name]-0}" # sh_info
        psz section_headers 0 # sh_addralign
        psz section_headers $entsize # sh_entsize

        if (( ${section_types[$section_name]} != SHT_NOBITS )); then
            section_data+="$section"
            position+=$section_size
        fi
    done

    exec {fd}>"$filename"

    local elf_header="\x7fELF"
    elf_header+="${ei_class}"
    elf_header+="${ei_data}"
    elf_header+="\x01" # EI_VERSION
    elf_header+="${ei_osabi}"

    # padding
    local i
    for (( i=0; i < 8; i++ )); do
        elf_header+="\x00"
    done

    p16 elf_header $ET_REL # e_type - relocatable file
    p16 elf_header $EM_X86_64 # e_machine
    p32 elf_header 1 # e_version
    psz elf_header 0 # e_entry
    psz elf_header 0 # e_phoff
    psz elf_header $position # e_shoff
    p32 elf_header 0 # e_flags
    p16 elf_header $ehsize # e_ehsize
    p16 elf_header $phentsize # e_phentsize
    p16 elf_header 0 # e_phnum
    p16 elf_header $shentsize # e_shentsize
    p16 elf_header $section_count # e_shnum
    p16 elf_header ${section_index[.shstrtab]} # e_shstrndx

    printf "%b" "$elf_header" >&$fd
    printf "%b" "$section_data" >&$fd
    printf "%b" "$section_headers" >&$fd
    exec {fd}>&-
}
