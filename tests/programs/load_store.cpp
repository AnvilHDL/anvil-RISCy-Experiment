volatile unsigned char g_b;
volatile unsigned short g_h;
volatile unsigned int g_w;
volatile unsigned long g_d;

extern "C" int main() {
    g_b = 0x12;
    g_h = 0x3456;
    g_w = 0x789abcdeu;
    g_d = 0x1122334455667788ull;

    return (g_b == 0x12 &&
            g_h == 0x3456 &&
            g_w == 0x789abcdeu &&
            g_d == 0x1122334455667788ull) ? 0 : 4;
}
