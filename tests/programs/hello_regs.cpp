extern "C" int main() {
    register unsigned long x5 asm("a0") = 42;
    register unsigned long x6 asm("a1") = 7;
    register unsigned long x7 asm("a2") = 9;
    register unsigned long x8 asm("a3") = 11;
    register unsigned long x9 asm("a4") = 13;
    unsigned long sum = x5 + x6 + x7 + x8 + x9;
    return (sum == 82) ? 42 : 1;
}
