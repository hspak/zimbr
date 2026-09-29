#include "drop.h"

char** _glfwParseUriList(char* text, int* count)
{
    *count = 0;
    ZcDrop* drop = _glfw_calloc(1, sizeof(ZcDrop));
    if (!drop) { zc_drop_reject(); return NULL; }
    if (!zc_drop_parse(text, strlen(text), drop) || !drop->count)
    {
        _glfw_free(drop);
        return NULL;
    }
    char** paths = _glfw_calloc(drop->count, sizeof(char*));
    if (!paths) { _glfw_free(drop); zc_drop_reject(); return NULL; }
    for (int i = 0; i < drop->count; i++)
    {
        paths[i] = _glfw_strdup(drop->paths[i]);
        if (!paths[i])
        {
            for (int j = 0; j < i; j++) _glfw_free(paths[j]);
            _glfw_free(paths);
            _glfw_free(drop);
            zc_drop_reject();
            return NULL;
        }
    }
    *count = drop->count;
    _glfw_free(drop);
    return paths;
}

