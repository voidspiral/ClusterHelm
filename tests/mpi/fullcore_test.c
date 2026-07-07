#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define HOST_MAX 64

static void hostname_short(char *buf, size_t n) {
    if (gethostname(buf, n) != 0) {
        snprintf(buf, n, "unknown");
        return;
    }
    char *dot = strchr(buf, '.');
    if (dot)
        *dot = '\0';
}

int main(int argc, char **argv) {
    int rank, size, local;
    char host[HOST_MAX];
    int sum, all_ok = 1;

    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    MPI_Comm_size(MPI_COMM_SELF, &local);

    hostname_short(host, sizeof(host));

    printf("rank=%d/%d host=%s pid=%d local_ranks=%d\n",
           rank, size, host, (int)getpid(), local);
    fflush(stdout);

    sum = rank + 1;
    MPI_Allreduce(MPI_IN_PLACE, &sum, 1, MPI_INT, MPI_SUM, MPI_COMM_WORLD);
    int expected = size * (size + 1) / 2;
    if (sum != expected)
        all_ok = 0;

    MPI_Allreduce(MPI_IN_PLACE, &all_ok, 1, MPI_INT, MPI_MIN, MPI_COMM_WORLD);

    if (rank == 0) {
        if (all_ok)
            printf("PASS: allreduce ok (sum=%d, size=%d)\n", sum, size);
        else
            printf("FAIL: allreduce mismatch (got=%d expected=%d)\n", sum, expected);
        fflush(stdout);
    }

    if (!all_ok) {
        MPI_Finalize();
        return 1;
    }

    int duration = 0;
    if (argc > 1)
        duration = atoi(argv[1]);
    if (duration <= 0) {
        char *env = getenv("FULLCORE_DURATION_SEC");
        if (env)
            duration = atoi(env);
    }
    if (duration > 0) {
        time_t end = 0;
        if (rank == 0) {
            end = time(NULL) + duration;
            printf("RUN: sustained compute %d sec on all ranks\n", duration);
            fflush(stdout);
        }
        MPI_Bcast(&end, 1, MPI_LONG, 0, MPI_COMM_WORLD);
        while (time(NULL) < end) {
            volatile double x = 0.0;
            for (int i = 0; i < 500000; i++)
                x += (double)i * 0.0001;
            (void)x;
        }
        MPI_Barrier(MPI_COMM_WORLD);
        if (rank == 0) {
            printf("PASS: sustained compute finished (%d sec)\n", duration);
            fflush(stdout);
        }
    }

    MPI_Finalize();
    return 0;
}
