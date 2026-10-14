// Mała biblioteka C do benchmarku FFI (isLeaf vs non-leaf, asTypedList).
// Budowana przez tool/build_native.sh: gcc -O2 -shared -fPIC -o native/libfastmath.so native/fastmath.c
#include <stdint.h>
#include <stddef.h>

int64_t add_i64(int64_t a, int64_t b) { return a + b; }

double dot_f64(const double *a, const double *b, int64_t n) {
    double s = 0.0;
    for (int64_t i = 0; i < n; i++) s += a[i] * b[i];
    return s;
}

// Wypełnia bufor wartościami; zwraca sumę (żeby wynik nie był martwy).
int64_t fill_u8(uint8_t *buf, int64_t n, uint8_t v) {
    int64_t s = 0;
    for (int64_t i = 0; i < n; i++) { buf[i] = (uint8_t)(v + i); s += buf[i]; }
    return s;
}
