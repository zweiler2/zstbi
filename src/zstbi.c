#include <stdlib.h>

// Image
void *(*zstbi_image_MallocPtr)(size_t size) = NULL;
void *(*zstbi_image_ReallocPtr)(void *ptr, size_t size) = NULL;
void (*zstbi_image_FreePtr)(void *ptr) = NULL;
#define STBI_MALLOC(size) zstbi_image_MallocPtr(size)
#define STBI_REALLOC(ptr, size) zstbi_image_ReallocPtr(ptr, size)
#define STBI_FREE(ptr) zstbi_image_FreePtr(ptr)
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

// Resize
void *(*zstbi_resize_MallocPtr)(size_t size, void *context) = NULL;
void (*zstbi_resize_FreePtr)(void *ptr, void *context) = NULL;
#define STBIR_MALLOC(size, context) zstbi_resize_MallocPtr(size, context)
#define STBIR_FREE(ptr, context) zstbi_resize_FreePtr(ptr, context)
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize2.h"

// Write
void *(*zstbi_write_MallocPtr)(size_t size) = NULL;
void *(*zstbi_write_ReallocPtr)(void *ptr, size_t size) = NULL;
void (*zstbi_write_FreePtr)(void *ptr) = NULL;
#define STBIW_MALLOC(size) zstbi_write_MallocPtr(size)
#define STBIW_REALLOC(ptr, size) zstbi_write_ReallocPtr(ptr, size)
#define STBIW_FREE(ptr) zstbi_write_FreePtr(ptr)
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
