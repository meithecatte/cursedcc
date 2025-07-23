# cursedcc

cursedcc is a C compiler written in bash targeting x86\_64 platforms
making use of the System V ABI and ELF object format.

## External programs used

- `dirname` is used in `cc.sh` to resolve the compiler installation directory
  and source all the other `.sh` files. I am not aware of any way of avoiding
  calling this external program that correctly handles the case where `cc.sh`
  itself is a symlink.
- unless suppressed with `-c`, the system linker is called
  (`cc` with `.o` files as arguments) to create an executable
  after emitting the object file. In this case, `mktemp` and `rm` are also invoked
  to handle the temporary object file.
- unless suppressed with `-p`, the system preprocessor is called (`cpp`)
  to preprocess the file.

The latter two are because I wanted to focus on the actual compiler first, and
might get replaced by bash implementations at some point if I hate myself enough.

## Subset of language implemented

Currently, the compiler implements only a subset of the C language. 

- The only implemented type is `int`
- Control flow
  - [x] `if`, `else`
  - [x] `for`, `while`, `do`-`while`
  - [x] ternary operator `?`
  - [x] short-circuiting binary operators `&&`, `||`
  - [x] `goto`
  - [ ] `switch`
- Expressions
  - [x] arithmetic and binary operators
  - [ ] compound assignment `+=`, `*=`, etc.
  - [ ] increment and decrement operators `++`, `--`
- Functions
  - [x] function declarations
  - [x] calls to external functions
  - [x] `static` functions
- File-scope variables
  - [x] Global variables
  - [x] `static` variables
  - [ ] `extern` variables
- [ ] Local `static` variables
