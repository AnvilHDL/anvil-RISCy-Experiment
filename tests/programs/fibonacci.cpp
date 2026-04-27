static int fib(int n) {
    if (n < 2) {
        return n;
    }
    return fib(n - 1) + fib(n - 2);
}

extern "C" int main() {
    const int result = fib(10);
    return (result == 55) ? 0 : result;
}
