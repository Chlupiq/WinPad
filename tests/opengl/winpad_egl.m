/* WinPad's EGL: what Wine's win32u (dlls/win32u/opengl.c, EGL path) needs to
 * give a Windows program desktop OpenGL on iOS.
 *
 * Wine 11 drives OpenGL through EGL with the desktop GL API (EGL_OPENGL_API,
 * EGL_OPENGL_BIT configs). iOS has neither: it has OpenGL ES 2/3 through
 * EAGL (OpenGLES.framework, deprecated but present, drawn with Metal). So:
 *
 *   - a context is an EAGLContext (ES 3, else ES 2) plus a gl4es state;
 *     gl4es (tests/opengl/build.sh) turns the desktop GL 1.x/2.x calls of a
 *     game of the Quake III era into ES calls;
 *   - a surface (a window or a pbuffer) has no framebuffer from the system,
 *     so each context draws into one of its own (gl4es-glue.c), which gl4es
 *     uses as framebuffer 0;
 *   - eglSwapBuffers reads that framebuffer back into BGRA pixels; win32u
 *     (patches/wine/0004) puts them into the window with GDI, and the host
 *     shows the window as it shows every other one.
 *
 * Reading back costs a copy per frame; enough for the first games. A Metal
 * layer of its own per window is the faster way and can come later.
 *
 * OpenGLES.framework is opened with dlopen, not linked: gl4es defines the GL
 * entry points (glViewport...) itself, and its ES calls have to reach the
 * framework's functions, which it looks up through winpad_gles_proc().
 *
 * Built without ARC (the EAGLContext of a context is released by hand); the
 * calls into EAGL run in an autorelease pool, Wine's threads have none.
 *
 * Win32u finds everything through winpad_egl_get_proc_address(); besides the
 * EGL functions it has winpadEGLSurfacePixels and winpadEGLSurfaceResize.
 * Log lines start with "winpad-egl:".
 */
#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t EGLint;
typedef unsigned int EGLBoolean;
typedef unsigned int EGLenum;
typedef void *EGLDisplay, *EGLConfig, *EGLSurface, *EGLContext;
typedef intptr_t EGLAttrib;

#define EGL_FALSE 0
#define EGL_TRUE 1
#define EGL_SUCCESS 0x3000
#define EGL_NOT_INITIALIZED 0x3001
#define EGL_BAD_ALLOC 0x3003
#define EGL_BAD_ATTRIBUTE 0x3004
#define EGL_BAD_CONFIG 0x3005
#define EGL_BAD_CONTEXT 0x3006
#define EGL_BAD_DISPLAY 0x3008
#define EGL_BAD_MATCH 0x3009
#define EGL_BAD_PARAMETER 0x300C
#define EGL_BAD_SURFACE 0x300D
#define EGL_BUFFER_SIZE 0x3020
#define EGL_ALPHA_SIZE 0x3021
#define EGL_BLUE_SIZE 0x3022
#define EGL_GREEN_SIZE 0x3023
#define EGL_RED_SIZE 0x3024
#define EGL_DEPTH_SIZE 0x3025
#define EGL_STENCIL_SIZE 0x3026
#define EGL_CONFIG_CAVEAT 0x3027
#define EGL_CONFIG_ID 0x3028
#define EGL_LEVEL 0x3029
#define EGL_MAX_PBUFFER_HEIGHT 0x302A
#define EGL_MAX_PBUFFER_PIXELS 0x302B
#define EGL_MAX_PBUFFER_WIDTH 0x302C
#define EGL_NATIVE_RENDERABLE 0x302D
#define EGL_NATIVE_VISUAL_ID 0x302E
#define EGL_NATIVE_VISUAL_TYPE 0x302F
#define EGL_SAMPLES 0x3031
#define EGL_SAMPLE_BUFFERS 0x3032
#define EGL_SURFACE_TYPE 0x3033
#define EGL_TRANSPARENT_TYPE 0x3034
#define EGL_NONE 0x3038
#define EGL_MIN_SWAP_INTERVAL 0x303B
#define EGL_MAX_SWAP_INTERVAL 0x303C
#define EGL_COLOR_BUFFER_TYPE 0x303F
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_CONFORMANT 0x3042
#define EGL_VENDOR 0x3053
#define EGL_VERSION 0x3054
#define EGL_EXTENSIONS 0x3055
#define EGL_HEIGHT 0x3056
#define EGL_WIDTH 0x3057
#define EGL_DRAW 0x3059
#define EGL_READ 0x305A
#define EGL_RENDER_BUFFER 0x3086
#define EGL_BACK_BUFFER 0x3084
#define EGL_CLIENT_APIS 0x308D
#define EGL_RGB_BUFFER 0x308E
#define EGL_OPENGL_ES_API 0x30A0
#define EGL_OPENGL_API 0x30A2
#define EGL_CONTEXT_MAJOR_VERSION 0x3098
#define EGL_CONTEXT_MINOR_VERSION 0x30FB
#define EGL_CONTEXT_FLAGS 0x30FC
#define EGL_CONTEXT_OPENGL_PROFILE_MASK 0x30FD
#define EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT 0x1
#define EGL_CONTEXT_OPENGL_NO_ERROR 0x31B3
#define EGL_PBUFFER_BIT 0x0001
#define EGL_WINDOW_BIT 0x0004
#define EGL_OPENGL_BIT 0x0008

#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_VENDOR 0x1F00
#define GL_RENDERER 0x1F01
#define GL_VERSION 0x1F02

/* gl4es-glue.c */
void winpad_gl4es_init( void *(*get_proc_address)(const char *) );
void *winpad_gl4es_new_state( void *share );
void winpad_gl4es_activate( void *state );
void winpad_gl4es_set_main_fbo( unsigned int fbo, unsigned int tex, int width, int height );
void winpad_gl4es_first_viewport( int width, int height );
void winpad_gl4es_storage( unsigned int *tex, unsigned int *rb, int width, int height );
unsigned int winpad_gl4es_attach( unsigned int *fbo, unsigned int tex, unsigned int rb );
void winpad_gl4es_read( unsigned int fbo, int width, int height, void *pixels );
void winpad_gl4es_delete_fbo( unsigned int fbo );
const char *winpad_gl4es_string( unsigned int name );
void *gl4es_GetProcAddress( const char *name );

#define LOG(...) do { fprintf( stderr, "winpad-egl: " __VA_ARGS__ ); fflush( stderr ); } while (0)

/* --------------------------------------------------------------- configs */

struct config
{
    EGLint red, green, blue, alpha, depth, stencil;
};

/* What a game of that time asks for first: 32-bit colour, 24-bit depth and an
 * 8-bit stencil. Every surface gets RGBA8 and packed depth 24 / stencil 8
 * whatever the config, so the others only describe less. */
static const struct config configs[] =
{
    { 8, 8, 8, 8, 24, 8 },
    { 8, 8, 8, 0, 24, 8 },
    { 8, 8, 8, 8, 16, 0 },
    { 5, 6, 5, 0, 16, 0 },
};
#define CONFIG_COUNT ((EGLint)(sizeof(configs) / sizeof(configs[0])))

static const struct config *config_of( EGLConfig handle )
{
    intptr_t i = (intptr_t)handle - 1;
    return i >= 0 && i < CONFIG_COUNT ? &configs[i] : NULL;
}

/* ------------------------------------------------------ surfaces, contexts */

struct surface
{
    void *hwnd;              /* a window's, NULL for a pbuffer */
    EGLint width, height;
    unsigned int tex, rb;    /* colour texture, depth/stencil buffer */
    EGLint storage_width, storage_height;
    id sharegroup;           /* the EAGLSharegroup tex and rb belong to */
    unsigned char *pixels;   /* the last frame, BGRA, bottom-up */
    EGLint pixels_width, pixels_height;
    unsigned int swaps;
};

struct context
{
    id eagl;                 /* EAGLContext */
    void *gl4es;             /* gl4es state */
    unsigned int fbo;        /* this context's framebuffer for ... */
    struct surface *fbo_surface; /* ... this surface */
    int viewport_set;
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static __thread EGLint last_error = EGL_SUCCESS;
static __thread struct context *current;
static __thread struct surface *current_draw;
static __thread EGLenum bound_api = EGL_OPENGL_ES_API;
static int display_dummy;
static void *gles_lib;
static Class eagl_class;

static EGLBoolean fail( EGLint error )
{
    last_error = error;
    return EGL_FALSE;
}

static EGLBoolean ok( void )
{
    last_error = EGL_SUCCESS;
    return EGL_TRUE;
}

static void *winpad_gles_proc( const char *name )
{
    return gles_lib ? dlsym( gles_lib, name ) : NULL;
}

static int load_gles( void )
{
    static int tried;
    if (tried++) return gles_lib != NULL;
    gles_lib = dlopen( "/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW | RTLD_LOCAL );
    eagl_class = NSClassFromString( @"EAGLContext" );
    if (!gles_lib || !eagl_class)
    {
        LOG( "no OpenGL ES on this system (%s), no OpenGL\n", dlerror() );
        gles_lib = NULL;
        return 0;
    }
    return 1;
}

/* ------------------------------------------------------------ the display */

static EGLDisplay egl_GetDisplay( void *native )
{
    return load_gles() ? &display_dummy : NULL;
}

static EGLDisplay egl_GetPlatformDisplay( EGLenum platform, void *native, const EGLAttrib *attribs )
{
    return egl_GetDisplay( native );
}

static EGLBoolean egl_Initialize( EGLDisplay dpy, EGLint *major, EGLint *minor )
{
    if (dpy != &display_dummy) return fail( EGL_BAD_DISPLAY );
    if (major) *major = 1;
    if (minor) *minor = 5;
    return ok();
}

static EGLBoolean egl_Terminate( EGLDisplay dpy )
{
    return ok();
}

static const char *egl_QueryString( EGLDisplay dpy, EGLint name )
{
    if (!dpy)
    {
        if (name == EGL_EXTENSIONS)
            return "EGL_EXT_platform_base EGL_KHR_client_get_all_proc_addresses EGL_MESA_platform_surfaceless";
        last_error = EGL_BAD_DISPLAY;
        return NULL;
    }
    switch (name)
    {
    case EGL_EXTENSIONS:
        return "EGL_KHR_create_context EGL_KHR_create_context_no_error EGL_KHR_no_config_context "
               "EGL_KHR_surfaceless_context";
    case EGL_VENDOR: return "WinPad";
    case EGL_VERSION: return "1.5 WinPad (gl4es on OpenGL ES)";
    case EGL_CLIENT_APIS: return "OpenGL";
    }
    last_error = EGL_BAD_PARAMETER;
    return NULL;
}

static EGLint egl_GetError( void )
{
    EGLint e = last_error;
    last_error = EGL_SUCCESS;
    return e;
}

static EGLBoolean egl_GetConfigs( EGLDisplay dpy, EGLConfig *out, EGLint size, EGLint *count )
{
    EGLint i, n = 0;
    if (!count) return fail( EGL_BAD_PARAMETER );
    if (!out) *count = CONFIG_COUNT;
    else
    {
        for (i = 0; i < CONFIG_COUNT && n < size; i++) out[n++] = (EGLConfig)(intptr_t)(i + 1);
        *count = n;
    }
    return ok();
}

static EGLBoolean egl_ChooseConfig( EGLDisplay dpy, const EGLint *attribs, EGLConfig *out, EGLint size, EGLint *count )
{
    return egl_GetConfigs( dpy, out, size, count );
}

static EGLBoolean egl_GetConfigAttrib( EGLDisplay dpy, EGLConfig handle, EGLint attrib, EGLint *value )
{
    const struct config *c = config_of( handle );
    if (!c) return fail( EGL_BAD_CONFIG );
    switch (attrib)
    {
    case EGL_BUFFER_SIZE: *value = c->red + c->green + c->blue + c->alpha; break;
    case EGL_RED_SIZE: *value = c->red; break;
    case EGL_GREEN_SIZE: *value = c->green; break;
    case EGL_BLUE_SIZE: *value = c->blue; break;
    case EGL_ALPHA_SIZE: *value = c->alpha; break;
    case EGL_DEPTH_SIZE: *value = c->depth; break;
    case EGL_STENCIL_SIZE: *value = c->stencil; break;
    case EGL_CONFIG_ID: *value = (EGLint)(intptr_t)handle; break;
    case EGL_CONFIG_CAVEAT: *value = EGL_NONE; break;
    case EGL_LEVEL: *value = 0; break;
    case EGL_SAMPLES: case EGL_SAMPLE_BUFFERS: *value = 0; break;
    case EGL_SURFACE_TYPE: *value = EGL_WINDOW_BIT | EGL_PBUFFER_BIT; break;
    case EGL_RENDERABLE_TYPE: case EGL_CONFORMANT: *value = EGL_OPENGL_BIT; break;
    case EGL_COLOR_BUFFER_TYPE: *value = EGL_RGB_BUFFER; break;
    case EGL_NATIVE_RENDERABLE: *value = EGL_FALSE; break;
    case EGL_NATIVE_VISUAL_ID: case EGL_NATIVE_VISUAL_TYPE: *value = 0; break;
    case EGL_TRANSPARENT_TYPE: *value = EGL_NONE; break;
    case EGL_MAX_PBUFFER_WIDTH: case EGL_MAX_PBUFFER_HEIGHT: *value = 4096; break;
    case EGL_MAX_PBUFFER_PIXELS: *value = 4096 * 4096; break;
    case EGL_MIN_SWAP_INTERVAL: *value = 0; break;
    case EGL_MAX_SWAP_INTERVAL: *value = 1; break;
    default: return fail( EGL_BAD_ATTRIBUTE );
    }
    return ok();
}

/* --------------------------------------------------------------- surfaces */

static struct surface *new_surface( void *hwnd, EGLint width, EGLint height )
{
    struct surface *s = calloc( 1, sizeof(*s) );
    if (!s) return NULL;
    s->hwnd = hwnd;
    s->width = width > 0 ? width : 1;
    s->height = height > 0 ? height : 1;
    return s;
}

static EGLSurface egl_CreateWindowSurface( EGLDisplay dpy, EGLConfig config, void *hwnd, const EGLint *attribs )
{
    struct surface *s;
    if (!config_of( config )) { fail( EGL_BAD_CONFIG ); return NULL; }
    if (!(s = new_surface( hwnd, 1, 1 ))) { fail( EGL_BAD_ALLOC ); return NULL; }
    LOG( "window surface %p for hwnd %p\n", s, hwnd );
    ok();
    return s;
}

static EGLSurface egl_CreatePlatformWindowSurface( EGLDisplay dpy, EGLConfig config, void *native, const EGLAttrib *attribs )
{
    return egl_CreateWindowSurface( dpy, config, native, NULL );
}

static EGLSurface egl_CreatePbufferSurface( EGLDisplay dpy, EGLConfig config, const EGLint *attribs )
{
    EGLint width = 1, height = 1;
    struct surface *s;
    if (!config_of( config )) { fail( EGL_BAD_CONFIG ); return NULL; }
    for (; attribs && attribs[0] != EGL_NONE; attribs += 2)
    {
        if (attribs[0] == EGL_WIDTH) width = attribs[1];
        else if (attribs[0] == EGL_HEIGHT) height = attribs[1];
    }
    if (!(s = new_surface( NULL, width, height ))) { fail( EGL_BAD_ALLOC ); return NULL; }
    LOG( "pbuffer surface %p %dx%d\n", s, width, height );
    ok();
    return s;
}

static EGLBoolean egl_DestroySurface( EGLDisplay dpy, EGLSurface handle )
{
    struct surface *s = handle;
    if (!s) return fail( EGL_BAD_SURFACE );
    /* tex and rb go with their share group; a surface lives as long as its window */
    if (current_draw == s) current_draw = NULL;
    if (current && current->fbo_surface == s) current->fbo_surface = NULL;
    free( s->pixels );
    free( s );
    return ok();
}

static EGLBoolean egl_QuerySurface( EGLDisplay dpy, EGLSurface handle, EGLint attrib, EGLint *value )
{
    struct surface *s = handle;
    if (!s) return fail( EGL_BAD_SURFACE );
    switch (attrib)
    {
    case EGL_WIDTH: *value = s->width; break;
    case EGL_HEIGHT: *value = s->height; break;
    case EGL_RENDER_BUFFER: *value = EGL_BACK_BUFFER; break;
    default: return fail( EGL_BAD_ATTRIBUTE );
    }
    return ok();
}

static EGLBoolean egl_SurfaceAttrib( EGLDisplay dpy, EGLSurface s, EGLint attrib, EGLint value )
{
    return ok();
}

/* Gives the current context's framebuffer for S storage of S's size, and
 * hands it to gl4es as framebuffer 0. The context is current. */
static void bind_surface( struct context *ctx, struct surface *s )
{
    id group = [ctx->eagl sharegroup];

    if (!s)
    {
        winpad_gl4es_set_main_fbo( 0, 0, 0, 0 );
        return;
    }
    if (s->sharegroup && s->sharegroup != group)
    {
        /* drawn by contexts that share nothing: this one gets storage of its own */
        LOG( "surface %p moves to another share group, its contents are lost\n", s );
        s->tex = s->rb = 0;
        s->storage_width = s->storage_height = 0;
    }
    s->sharegroup = group;
    if (s->storage_width != s->width || s->storage_height != s->height)
    {
        winpad_gl4es_storage( &s->tex, &s->rb, s->width, s->height );
        s->storage_width = s->width;
        s->storage_height = s->height;
        ctx->fbo_surface = NULL;  /* attach again */
    }
    if (ctx->fbo_surface != s)
    {
        unsigned int status = winpad_gl4es_attach( &ctx->fbo, s->tex, s->rb );
        if (status != GL_FRAMEBUFFER_COMPLETE)
            LOG( "framebuffer %u for surface %p (%dx%d) is not complete: %#x\n", ctx->fbo, s, s->width, s->height, status );
        ctx->fbo_surface = s;
    }
    winpad_gl4es_set_main_fbo( ctx->fbo, s->tex, s->width, s->height );
}

/* win32u: the window's client area is now WIDTH x HEIGHT. */
static void winpad_SurfaceResize( EGLSurface handle, int width, int height )
{
    struct surface *s = handle;
    if (!s || (s->width == width && s->height == height)) return;
    LOG( "surface %p is now %dx%d\n", s, width, height );
    s->width = width > 0 ? width : 1;
    s->height = height > 0 ? height : 1;
    if (current && current_draw == s)
    {
        @autoreleasepool { bind_surface( current, s ); }
    }
}

/* win32u: the last frame eglSwapBuffers read, BGRA rows bottom up. */
static const void *winpad_SurfacePixels( EGLSurface handle, int *width, int *height )
{
    struct surface *s = handle;
    if (!s || !s->pixels) return NULL;
    *width = s->pixels_width;
    *height = s->pixels_height;
    return s->pixels;
}

/* --------------------------------------------------------------- contexts */

static EGLBoolean egl_BindAPI( EGLenum api )
{
    if (api != EGL_OPENGL_API && api != EGL_OPENGL_ES_API) return fail( EGL_BAD_PARAMETER );
    bound_api = api;
    return ok();
}

static EGLenum egl_QueryAPI( void )
{
    return bound_api;
}

static EGLContext egl_CreateContext( EGLDisplay dpy, EGLConfig config, EGLContext share_handle, const EGLint *attribs )
{
    struct context *share = share_handle, *ctx;
    EGLint major = 1, minor = 0, profile = 0;
    id group = nil;
    id eagl;
    static int logged;

    if (!load_gles()) { fail( EGL_BAD_DISPLAY ); return NULL; }
    if (share) group = [share->eagl sharegroup];
    if (bound_api != EGL_OPENGL_API) { fail( EGL_BAD_MATCH ); return NULL; }
    for (; attribs && attribs[0] != EGL_NONE; attribs += 2)
    {
        switch (attribs[0])
        {
        case EGL_CONTEXT_MAJOR_VERSION: major = attribs[1]; break;
        case EGL_CONTEXT_MINOR_VERSION: minor = attribs[1]; break;
        case EGL_CONTEXT_OPENGL_PROFILE_MASK: profile = attribs[1]; break;
        case EGL_CONTEXT_FLAGS: case EGL_CONTEXT_OPENGL_NO_ERROR: break;
        default: LOG( "context attribute %#x = %#x ignored\n", attribs[0], attribs[1] ); break;
        }
    }
    /* gl4es is OpenGL 2.1 with the compatibility features; no core profile */
    if (major > 2 || (major == 2 && minor > 1) || (profile & EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT))
    {
        LOG( "OpenGL %d.%d%s asked for, only 2.1 here\n", major, minor,
             (profile & EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT) ? " core" : "" );
        fail( EGL_BAD_MATCH );
        return NULL;
    }

    @autoreleasepool {
    eagl = [[eagl_class alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3 sharegroup:group];
    if (!eagl) eagl = [[eagl_class alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2 sharegroup:group];
    if (!eagl)
    {
        LOG( "no OpenGL ES context\n" );
        fail( EGL_BAD_ALLOC );
        return NULL;
    }
    if (!(ctx = calloc( 1, sizeof(*ctx) ))) { [eagl release]; fail( EGL_BAD_ALLOC ); return NULL; }
    ctx->eagl = eagl;

    pthread_mutex_lock( &lock );
    {
        /* gl4es looks at the hardware of the context current when it starts */
        id previous = [eagl_class currentContext];
        [eagl_class setCurrentContext:eagl];
        winpad_gl4es_init( winpad_gles_proc );
        ctx->gl4es = winpad_gl4es_new_state( share ? share->gl4es : NULL );
        if (!logged++)
        {
            const char *(*gles_string)( unsigned int ) = winpad_gles_proc( "glGetString" );
            LOG( "OpenGL ES %s, %s, %s; through gl4es: %s, %s\n",
                 [eagl API] == kEAGLRenderingAPIOpenGLES3 ? "3" : "2",
                 gles_string ? gles_string( GL_RENDERER ) : "?", gles_string ? gles_string( GL_VERSION ) : "?",
                 winpad_gl4es_string( GL_RENDERER ), winpad_gl4es_string( GL_VERSION ) );
        }
        if (current) winpad_gl4es_activate( current->gl4es );
        [eagl_class setCurrentContext:previous];
    }
    pthread_mutex_unlock( &lock );
    }
    LOG( "context %p (OpenGL %d.%d asked for, shares with %p)\n", ctx, major, minor, share );
    ok();
    return ctx;
}

static EGLBoolean egl_DestroyContext( EGLDisplay dpy, EGLContext handle )
{
    struct context *ctx = handle;
    if (!ctx) return fail( EGL_BAD_CONTEXT );
    if (current == ctx)
    {
        [eagl_class setCurrentContext:nil];
        current = NULL;
        current_draw = NULL;
    }
    /* its gl4es state is kept: gl4es frees one only while it is the active one */
    @autoreleasepool { [ctx->eagl release]; }
    free( ctx );
    return ok();
}

static EGLBoolean egl_MakeCurrent( EGLDisplay dpy, EGLSurface draw, EGLSurface read, EGLContext handle )
{
    struct context *ctx = handle;
    struct surface *s = draw;

    if (!ctx)
    {
        [eagl_class setCurrentContext:nil];
        current = NULL;
        current_draw = NULL;
        return ok();
    }
    if (![eagl_class setCurrentContext:ctx->eagl]) return fail( EGL_BAD_CONTEXT );
    pthread_mutex_lock( &lock );
    @autoreleasepool {
    winpad_gl4es_activate( ctx->gl4es );
    current = ctx;
    current_draw = s;
    bind_surface( ctx, s );
    if (s && !ctx->viewport_set)
    {
        winpad_gl4es_first_viewport( s->width, s->height );
        ctx->viewport_set = 1;
    }
    }
    pthread_mutex_unlock( &lock );
    if (read && read != draw) LOG( "a read surface apart from the draw surface is not supported\n" );
    return ok();
}

static EGLContext egl_GetCurrentContext( void )
{
    return current;
}

static EGLSurface egl_GetCurrentSurface( EGLint which )
{
    return current_draw;
}

static EGLDisplay egl_GetCurrentDisplay( void )
{
    return current ? &display_dummy : NULL;
}

static EGLBoolean egl_QueryContext( EGLDisplay dpy, EGLContext ctx, EGLint attrib, EGLint *value )
{
    return fail( EGL_BAD_ATTRIBUTE );
}

static EGLBoolean egl_SwapBuffers( EGLDisplay dpy, EGLSurface handle )
{
    struct surface *s = handle;
    size_t size, i;

    if (!s) return fail( EGL_BAD_SURFACE );
    if (!current || current_draw != s || current->fbo_surface != s) return ok();  /* nothing drawn here */
    size = (size_t)s->width * s->height * 4;
    if (s->pixels_width != s->width || s->pixels_height != s->height)
    {
        free( s->pixels );
        if (!(s->pixels = malloc( size ))) { s->pixels_width = s->pixels_height = 0; return fail( EGL_BAD_ALLOC ); }
        s->pixels_width = s->width;
        s->pixels_height = s->height;
    }
    winpad_gl4es_read( current->fbo, s->width, s->height, s->pixels );
    for (i = 0; i < size; i += 4)  /* RGBA -> BGRX */
    {
        unsigned char r = s->pixels[i];
        s->pixels[i] = s->pixels[i + 2];
        s->pixels[i + 2] = r;
        s->pixels[i + 3] = 0xff;
    }
    if (++s->swaps <= 3 || !(s->swaps % 600))
    {
        const unsigned char *c = s->pixels + ((size_t)(s->height / 2) * s->width + s->width / 2) * 4;
        LOG( "swap %u of surface %p, %dx%d, centre pixel BGR %02x%02x%02x\n", s->swaps, s, s->width, s->height,
             c[0], c[1], c[2] );
    }
    return ok();
}

static EGLBoolean egl_SwapInterval( EGLDisplay dpy, EGLint interval )
{
    return ok();
}

static EGLBoolean egl_ReleaseThread( void )
{
    return egl_MakeCurrent( &display_dummy, NULL, NULL, NULL );
}

static EGLBoolean egl_WaitClient( void ) { return ok(); }
static EGLBoolean egl_WaitGL( void ) { return ok(); }
static EGLBoolean egl_WaitNative( EGLint engine ) { return ok(); }

/* Everything else win32u looks up: fails as unsupported. */
static EGLBoolean egl_unsupported( void )
{
    return fail( EGL_BAD_MATCH );
}

/* ----------------------------------------------------------------- lookup */

static const struct { const char *name; void *func; } egl_funcs[] =
{
#define F(n) { "egl" #n, (void *)egl_##n }
    F(BindAPI), F(ChooseConfig), F(CreateContext), F(CreatePbufferSurface), F(CreatePlatformWindowSurface),
    F(CreateWindowSurface), F(DestroyContext), F(DestroySurface), F(GetConfigAttrib), F(GetConfigs),
    F(GetCurrentContext), F(GetCurrentDisplay), F(GetCurrentSurface), F(GetDisplay), F(GetError),
    F(GetPlatformDisplay), F(Initialize), F(MakeCurrent), F(QueryAPI), F(QueryContext), F(QueryString),
    F(QuerySurface), F(ReleaseThread), F(SurfaceAttrib), F(SwapBuffers), F(SwapInterval), F(Terminate),
    F(WaitClient), F(WaitGL), F(WaitNative),
#undef F
    { "winpadEGLSurfacePixels", (void *)winpad_SurfacePixels },
    { "winpadEGLSurfaceResize", (void *)winpad_SurfaceResize },
};

static void *egl_GetProcAddress( const char *name );

__attribute__((visibility("default"))) void *winpad_egl_get_proc_address( const char *name )
{
    return egl_GetProcAddress( name );
}

static void *egl_GetProcAddress( const char *name )
{
    size_t i;
    if (!name) return NULL;
    if (!strcmp( name, "eglGetProcAddress" )) return (void *)egl_GetProcAddress;
    for (i = 0; i < sizeof(egl_funcs) / sizeof(egl_funcs[0]); i++)
        if (!strcmp( name, egl_funcs[i].name )) return egl_funcs[i].func;
    if (!strncmp( name, "egl", 3 )) return (void *)egl_unsupported;
    return gl4es_GetProcAddress( name );
}
