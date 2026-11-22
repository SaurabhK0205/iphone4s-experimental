#include <stdio.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    printf("=== HELLO FROM NATIVE ARMv7 ON iOS 6.1.3! ===\n");
    printf("PID: %d, argc: %d\n", getpid(), argc);
    for (int i = 0; i < argc; i++) {
        printf("argv[%d] = %s\n", i, argv[i]);
    }
    printf("Native binary execution fully verified!\n");
    return 42;
}
