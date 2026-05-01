extern "C" int main() {
    volatile long a = -123456789;
    volatile long b = 97;
    volatile unsigned long c = 0xfffffffffffffff0ull;
    volatile unsigned long d = 9;

    long q = a / b;
    long r = a % b;
    unsigned long uq = c / d;
    unsigned long ur = c % d;

    return (q == -1272750 &&
            r == -39 &&
            uq == 2049638230412172400ull &&
            ur == 0) ? 0 : 6;
}
