int main(void) {
    int a = 42;

    {
        int a(int x);
    }

    a = a * 2;
    return a;
}
