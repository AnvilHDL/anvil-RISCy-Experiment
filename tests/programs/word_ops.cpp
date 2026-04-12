extern "C" int main() {
    long a = 0x00000000ffffffffull;
    long b = 2;
    long c = static_cast<int>(a) + static_cast<int>(b);
    long d = static_cast<int>(0xfffffff0u) >> 2;
    return (c == 1 && d == -4) ? 0 : 3;
}
