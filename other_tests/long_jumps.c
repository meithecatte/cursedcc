// really basic "i just want to generate a jump over more than 128 bytes"

int main(void) {
    int a = 6;
    meow:
    if (a == 3) {
        a = (a * a + a - 4) / 7;
        int b = a * a * a * a;
        int c = (b + a) << 7 | 4 + 42;
        int d = c * b * a + b;
        goto meow;
        return (b + a * c) >> 4;
    }

    return 0;
}
