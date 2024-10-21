# AST datastructures

A global `ast` array stores nodes, allocated with successive indices as they're
being created. Each node is described by a string with whitespace-separated
components. The first component is the type of the node, and what follows
depends on that type.

## Position data

Each token parsed from the input is inserted into the `toktype` and `tokdata`
arrays, with the position information of the first character of the token
being stored in `tokline` and `tokcol`. The end position is implicit,
as `tokdata` always stores the exact characters that created the token.

All other position information is stored in terms of token indices. Each AST
node stores the position information of its first and last token in the `ast_pos`
side-table. This information is collected semi-automatically at `mknode` time.
Parser functions must pass the `begin` position unless the AST node consists
of only a single token, while the `end` position is determined automatically
(unless the `mknode` is being done during the post-processing in
`unfuck_declarator`, where both endpoints must be specified to maintain
correct position data).

## Lifetime of AST data

The AST nodes corresponding to each *external-declaration* are processed
immediately after parsing by handing off to `emit_function` and `emit_global`
respectively. However, since global tables keep references to type information
stored in the AST, the `ast` array is not cleared between functions.

## Inspecting the AST

When ran with the `DEBUG_AST=1` environment variable, the compiler will output
visualizations of the AST as it is processing the input. As a simple,
randomly-chosen example, consider this program:

```c
int main(void) {
    return ~2 * -2 == 1 + 5;
}
```

The corresponding AST looks like this:

```
$ DEBUG_AST=1 ./cc.sh testsuite/tests/chapter_4/valid/compare_arithmetic_results.c
declaration of function main:
 + 7: declare_var 6 1
   + 6: ty_fun 0 4
     + 0: ty_int
     + 4: params
   + 1: var main
body of function main:
 + 18: compound 17
   + 17: return 16
     + 16: eq 12 15
       + 12: mul 9 11
         + 9: bnot 8
           + 8: literal 2
         + 11: negate 10
           + 10: literal 2
       + 15: add 13 14
         + 13: literal 1
         + 14: literal 5
```

## Structure of the AST

Large parts of the AST are self-explanatory. Therefore, this section does not
aim to be exhaustive, instead seeking to clarify the semantics of the AST nodes

### `declare` and `declare_var`

Apart from statements, a `compound` node can contain declarations.
To properly handle declarations declaring multiple variables at once, the parser
will emit a variadic `declare` node with a `declare_var` child for each variable.

For example:

```c
int main(void) {
    int a, b = 42;
}
```

```
body of function main:
 + 16: compound 15
   + 15: declare 10 14
     + 10: declare_var 8 9
       + 8: ty_int
       + 9: var a
     + 14: declare_var 8 11 13
       + 8: ty_int
       + 11: var b
       + 13: expr 12
         + 12: literal 42
```

### `for` loops

The `for` node has three children: condition, loop step, and loop body.
To make sure that all scope-handling code is confined to the `compound` node
and not duplicated, the setup clause gets desugared during parsing.

```c
    for (i = 5; i >= 0; i = i - 1)
        a = a / 3;
```

```
   + 38: compound 21 37
     + 21: expr 20
       + 20: assn 18 19
         + 18: var i
         + 19: literal 5
     + 37: for 24 30 36
       + 24: ge 22 23
         + 22: var i
         + 23: literal 0
       + 30: expr 29
         + 29: assn 25 28
           + 25: var i
           + 28: sub 26 27
             + 26: var i
             + 27: literal 1
       + 36: expr 35
         + 35: assn 31 34
           + 31: var a
           + 34: div 32 33
             + 32: var a
             + 33: literal 3
```

### The `expr` node

In places where an expression can occur, but is not the only option,
the `expr` node is used to make it easier to handle the possible cases.

Thus the `expr` node will occur when:
- an expression is used as a statement, e.g. `a = 6 * 7;`
- an expression is used as an initializer, e.g. `int x = 42;`
  (as opposed to e.g. `int a[10] = { 1, 2 };`)

### Declarators

In C standard lingo, a declaration consists of declaration specifiers, such as
`extern`, `const`, or `unsigned long`, and a list of *declarators*, such as `x`,
`*p[30]`, or `main(int argc, char **argv)`.

Famously, the syntax of declarators is a bit of a galaxy-brain idea that didn't
pan out in the end — the syntax tree needs to be inverted inside-out to actually
obtain the type it is supposed to represent.

This postprocessing is handled by `unfuck_declarator` in `types.sh`.
During parsing, the declarator is represented by various AST nodes, which follow
the naming convention of `decl_*`.

After a top-level declarator is parsed, it is passed to `unfuck_declarator`
in order to turn it into `ty_*` nodes. The result gets stored in the main AST.
