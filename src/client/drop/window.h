#include "drop.h"

static void WindowDropCallback(GLFWwindow *window, int count, const char **paths)
{
    (void)window;
    for (unsigned int i = 0; i < CORE.Window.dropFileCount; i++) RL_FREE(CORE.Window.dropFilepaths[i]);
    RL_FREE(CORE.Window.dropFilepaths);
    CORE.Window.dropFileCount = 0;
    CORE.Window.dropFilepaths = NULL;
    if (count <= 0 || count > ZC_DROP_FILES) { zc_drop_reject(); return; }
    for (int i = 0; i < count; i++)
        if (!paths[i] || paths[i][0] != '/' || strlen(paths[i]) >= ZC_DROP_PATH)
        { zc_drop_reject(); return; }
    char** copies = RL_CALLOC(count, sizeof(char*));
    if (!copies) { zc_drop_reject(); return; }
    for (int i = 0; i < count; i++)
    {
        size_t size = strlen(paths[i]) + 1;
        copies[i] = RL_CALLOC(size, 1);
        if (!copies[i])
        {
            for (int j = 0; j < i; j++) RL_FREE(copies[j]);
            RL_FREE(copies);
            zc_drop_reject();
            return;
        }
        memcpy(copies[i], paths[i], size);
    }
    CORE.Window.dropFilepaths = copies;
    CORE.Window.dropFileCount = (unsigned int)count;
}

