extern "C" int main() {
    long a = 40;
    long b = 2;
    long c = (a + b) - 10;
    long d = c << 2;
    long e = d >> 3;
    return (e == 16) ? 0 : 2;
}
