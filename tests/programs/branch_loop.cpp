volatile int g_start = 100;
volatile int g_acc_sink = 0;

extern "C" int main() {
    int acc = 0;
    for (int i = g_start; i != 0; --i) {
        acc += i;
        asm volatile("" : "+r"(acc), "+r"(i) : : "memory");
    }
    g_acc_sink = acc;
    return (g_acc_sink == 5050) ? 0 : 5;
}
