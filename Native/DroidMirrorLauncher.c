#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argc;

    char executable[PATH_MAX];
    if (!realpath(argv[0], executable)) {
        return 126;
    }

    char *slash = strrchr(executable, '/');
    if (!slash) {
        return 126;
    }
    *slash = '\0';

    char host[PATH_MAX];
    char helpers[PATH_MAX];
    char hostShim[PATH_MAX];
    snprintf(host, sizeof(host), "%s/DroidMirrorHost", executable);
    snprintf(helpers, sizeof(helpers), "%s/../Helpers", executable);
    snprintf(hostShim, sizeof(hostShim),
             "%s/../Frameworks/libDroidMirrorHostShim.dylib", executable);

    const char *oldPath = getenv("PATH");
    char path[PATH_MAX * 2];
    snprintf(path, sizeof(path), "%s:%s", helpers,
             oldPath ? oldPath : "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin");
    setenv("PATH", path, 1);
    setenv("DYLD_INSERT_LIBRARIES", hostShim, 1);

    execv(host, argv);
    perror("DroidMirrorHost");
    return 126;
}
