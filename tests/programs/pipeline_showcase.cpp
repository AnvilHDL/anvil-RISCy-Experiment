volatile long g_src[4] = {3, 7, 11, 13};
volatile long g_dst[4];
volatile long g_final = 0;

extern "C" int main() {
    long acc = 0;

    for (int i = 0; i < 4; ++i) {
        long loaded = g_src[i];
        long biased = loaded + 5;
        long next = acc + biased;
        g_dst[i] = next;
        acc = next;
        asm volatile("" : "+r"(acc), "+r"(loaded), "+r"(biased), "+r"(next) : : "memory");
    }

    g_final = acc;

    return (g_dst[0] == 8 &&
            g_dst[1] == 20 &&
            g_dst[2] == 36 &&
            g_dst[3] == 54 &&
            g_final == 54) ? 0 : 9;
}
