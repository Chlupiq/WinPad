/* A 32-bit OpenGL program for WinPad's i386 set, drawn the way games of the
 * Quake III era draw: opengl32.dll through Wine's EGL path to WinPad's EGL,
 * gl4es and Apple's OpenGL ES (tests/opengl).
 *
 * It opens a 640x480 window, picks a pixel format (32-bit colour, 24-bit
 * depth, 8-bit stencil, double buffered), makes a context with
 * wglCreateContext, logs GL_VENDOR, GL_RENDERER, GL_VERSION and whether
 * wglGetProcAddress finds glActiveTextureARB (multitexture, which Quake III
 * engines need), and draws per frame: a clear in a changing colour, a
 * textured quad from a client-side vertex array (glDrawArrays, the way
 * Quake III's renderer sends its geometry) and a spinning triangle with
 * glBegin/glEnd, then SwapBuffers. After the first frame it reads the
 * pixel in the middle of the quad back with glReadPixels: green (the
 * texture's colour), which says that drawing happened, not just the clear.
 * It runs for WINPAD_GL_SECONDS of wall-clock time and exits with 43.
 *
 * The log lines start with WINPAD-GL. Exit statuses: 20 no pixel format,
 * 21 no context, 22 MakeCurrent failed, 24 SwapBuffers failed, 25 no window,
 * 27 the quad did not draw, 43 done.
 */
#include <stddef.h>
#include <windows.h>
#include <GL/gl.h>

#define TAG "WINPAD-GL: "
#ifndef WINPAD_GL_SECONDS
#define WINPAD_GL_SECONDS 15
#endif
#define WIN_W 640
#define WIN_H 480

/* -nostdlib: clang may lower a struct initialisation to memset or memcpy. */
void *memset( void *dst, int c, size_t n )
{
    unsigned char *p = dst;
    while (n--) *p++ = (unsigned char)c;
    return dst;
}

void *memcpy( void *dst, const void *src, size_t n )
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

/* ---------------------------------------------------------------- logging */

static void out_str( const char *s )
{
    DWORD written = 0;
    const char *e = s;
    while (*e) e++;
    WriteFile( GetStdHandle( STD_ERROR_HANDLE ), s, (DWORD)(e - s), &written, NULL );
}

static char *put_str( char *p, const char *s )
{
    while (*s) *p++ = *s++;
    return p;
}

static char *put_uint( char *p, unsigned int v )
{
    char tmp[16];
    int n = 0;
    if (!v) { *p++ = '0'; return p; }
    while (v) { tmp[n++] = (char)('0' + v % 10); v /= 10; }
    while (n--) *p++ = tmp[n];
    return p;
}

static char *put_hex( char *p, unsigned int v )
{
    static const char digits[] = "0123456789abcdef";
    int i;
    *p++ = '0'; *p++ = 'x';
    for (i = 28; i >= 0; i -= 4) *p++ = digits[(v >> i) & 0xf];
    return p;
}

static void log_line( const char *what )
{
    char buf[512];
    char *p = put_str( buf, TAG );
    p = put_str( p, what );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_str( const char *what, const char *value )
{
    char buf[512], *p = put_str( buf, TAG ), *end = buf + sizeof(buf) - 2;
    p = put_str( p, what );
    *p++ = ' ';
    if (!value) value = "(null)";
    while (*value && p < end) *p++ = *value++;
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_hex( const char *what, unsigned int v )
{
    char buf[256];
    char *p = put_str( buf, TAG );
    p = put_str( p, what );
    *p++ = ' ';
    p = put_hex( p, v );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_uint( const char *what, unsigned int v )
{
    char buf[256];
    char *p = put_str( buf, TAG );
    p = put_str( p, what );
    *p++ = ' ';
    p = put_uint( p, v );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_swap( unsigned int frame, unsigned int ok )
{
    char buf[96];
    char *p = put_str( buf, TAG );
    p = put_str( p, "swap " );
    p = put_uint( p, frame );
    p = put_str( p, ok ? " ok" : " FAILED" );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* ---------------------------------------------------------- trig, no libm */

#define PI_F     3.14159265358979323846f
#define TWO_PI_F (2.0f * PI_F)

static float wrap_pi( float x )
{
    float k = (float)(int)(x * (1.0f / TWO_PI_F));
    x -= k * TWO_PI_F;
    if (x >  PI_F) x -= TWO_PI_F;
    if (x < -PI_F) x += TWO_PI_F;
    return x;
}

static float sinf_approx( float x )
{
    float x2;
    x = wrap_pi( x );
    x2 = x * x;
    return x * (1.0f + x2 * (-1.0f / 6.0f + x2 * (1.0f / 120.0f + x2 * (-1.0f / 5040.0f))));
}

static float cosf_approx( float x )
{
    return sinf_approx( x + PI_F * 0.5f );
}

/* ------------------------------------------------------------------ window */

static volatile int window_closed;

static LRESULT CALLBACK wnd_proc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch (msg)
    {
    case WM_CLOSE:
    case WM_DESTROY:
        window_closed = 1;
        return 0;
    }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

static void pump( void )
{
    MSG msg;
    while (PeekMessageA( &msg, NULL, 0, 0, PM_REMOVE ))
    {
        TranslateMessage( &msg );
        DispatchMessageA( &msg );
    }
}

static HWND make_window( void )
{
    WNDCLASSEXA wc;
    HINSTANCE inst = GetModuleHandleA( NULL );
    HWND hwnd;

    memset( &wc, 0, sizeof(wc) );
    wc.cbSize        = sizeof(wc);
    wc.style         = CS_OWNDC;
    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance     = inst;
    wc.lpszClassName = "WinPadGLTriangle";
    if (!RegisterClassExA( &wc ))
    {
        log_hex( "RegisterClassExA failed, err", GetLastError() );
        ExitProcess( 25 );
    }
    hwnd = CreateWindowExA( 0, wc.lpszClassName, "WinPad OpenGL", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            0, 0, WIN_W, WIN_H, NULL, NULL, inst, NULL );
    if (!hwnd)
    {
        log_hex( "CreateWindowExA failed, err", GetLastError() );
        ExitProcess( 25 );
    }
    log_hex( "hwnd", (unsigned int)(ULONG_PTR)hwnd );
    return hwnd;
}

/* -------------------------------------------------------------- drawing */

static GLuint make_texture( void )
{
    /* 8x8 checker of two greens: the middle of the quad reads back green */
    static unsigned char pixels[8 * 8 * 3];
    GLuint tex = 0;
    int i;

    for (i = 0; i < 64; i++)
    {
        int dark = ((i & 7) ^ (i >> 3)) & 1;
        pixels[i * 3 + 0] = 0;
        pixels[i * 3 + 1] = dark ? 0xc0 : 0xff;
        pixels[i * 3 + 2] = 0;
    }
    glGenTextures( 1, &tex );
    glBindTexture( GL_TEXTURE_2D, tex );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST );
    glTexImage2D( GL_TEXTURE_2D, 0, GL_RGB, 8, 8, 0, GL_RGB, GL_UNSIGNED_BYTE, pixels );
    return tex;
}

static void draw( float t, GLuint tex )
{
    /* the quad in the middle, x and y in -0.5..0.5, from client arrays */
    static const GLfloat quad_xy[] = { -0.5f, -0.5f, 0.5f, -0.5f, 0.5f, 0.5f, -0.5f, 0.5f };
    static const GLfloat quad_st[] = { 0.0f, 0.0f, 4.0f, 0.0f, 4.0f, 4.0f, 0.0f, 4.0f };
    float a = t * 1.5f;

    glClearColor( 0.5f + 0.5f * sinf_approx( t ), 0.2f, 0.5f + 0.5f * cosf_approx( t ), 1.0f );
    glClear( GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT );
    glMatrixMode( GL_PROJECTION );
    glLoadIdentity();
    glOrtho( -1.0, 1.0, -1.0, 1.0, -1.0, 1.0 );
    glMatrixMode( GL_MODELVIEW );
    glLoadIdentity();

    glEnable( GL_TEXTURE_2D );
    glBindTexture( GL_TEXTURE_2D, tex );
    glColor4f( 1.0f, 1.0f, 1.0f, 1.0f );
    glEnableClientState( GL_VERTEX_ARRAY );
    glEnableClientState( GL_TEXTURE_COORD_ARRAY );
    glVertexPointer( 2, GL_FLOAT, 0, quad_xy );
    glTexCoordPointer( 2, GL_FLOAT, 0, quad_st );
    glDrawArrays( GL_TRIANGLE_FAN, 0, 4 );
    glDisableClientState( GL_TEXTURE_COORD_ARRAY );
    glDisableClientState( GL_VERTEX_ARRAY );
    glDisable( GL_TEXTURE_2D );

    /* a spinning triangle in the corner, immediate mode */
    glTranslatef( 0.7f, 0.7f, 0.0f );
    glBegin( GL_TRIANGLES );
    glColor3f( 1.0f, 0.0f, 0.0f );
    glVertex2f( 0.25f * cosf_approx( a ), 0.25f * sinf_approx( a ) );
    glColor3f( 0.0f, 1.0f, 0.0f );
    glVertex2f( 0.25f * cosf_approx( a + 2.094f ), 0.25f * sinf_approx( a + 2.094f ) );
    glColor3f( 0.0f, 0.0f, 1.0f );
    glVertex2f( 0.25f * cosf_approx( a + 4.189f ), 0.25f * sinf_approx( a + 4.189f ) );
    glEnd();
}

static unsigned int elapsed_ms( DWORD start )
{
    return (unsigned int)(GetTickCount() - start);
}

void start( void )
{
    PIXELFORMATDESCRIPTOR pfd;
    unsigned int frame, swapped = 0;
    HGLRC ctx;
    GLuint tex;
    DWORD t0;
    HWND hwnd;
    HDC hdc;
    int format;

    log_line( "32-bit OpenGL test starting" );
    hwnd = make_window();
    hdc = GetDC( hwnd );

    memset( &pfd, 0, sizeof(pfd) );
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;
    pfd.iLayerType = PFD_MAIN_PLANE;
    format = ChoosePixelFormat( hdc, &pfd );
    if (!format || !SetPixelFormat( hdc, format, &pfd ))
    {
        log_hex( "no pixel format, err", GetLastError() );
        ExitProcess( 20 );
    }
    DescribePixelFormat( hdc, format, sizeof(pfd), &pfd );
    log_uint( "pixel format", (unsigned int)format );
    log_uint( "  colour bits", pfd.cColorBits );
    log_uint( "  depth bits", pfd.cDepthBits );
    log_uint( "  stencil bits", pfd.cStencilBits );

    if (!(ctx = wglCreateContext( hdc )))
    {
        log_hex( "wglCreateContext failed, err", GetLastError() );
        ExitProcess( 21 );
    }
    log_line( "context created" );
    if (!wglMakeCurrent( hdc, ctx ))
    {
        log_hex( "wglMakeCurrent failed, err", GetLastError() );
        ExitProcess( 22 );
    }
    log_line( "context current" );
    log_str( "GL_VENDOR", (const char *)glGetString( GL_VENDOR ) );
    log_str( "GL_RENDERER", (const char *)glGetString( GL_RENDERER ) );
    log_str( "GL_VERSION", (const char *)glGetString( GL_VERSION ) );
    log_str( "glActiveTextureARB", wglGetProcAddress( "glActiveTextureARB" ) ? "found" : "missing" );
    log_str( "wglSwapIntervalEXT", wglGetProcAddress( "wglSwapIntervalEXT" ) ? "found" : "missing" );

    tex = make_texture();
    log_hex( "texture", tex );
    log_hex( "glGetError", glGetError() );

    t0 = GetTickCount();
    for (frame = 0; ; frame++)
    {
        BOOL ok;

        pump();
        if (window_closed) break;
        if (elapsed_ms( t0 ) >= WINPAD_GL_SECONDS * 1000u) break;
        draw( (float)elapsed_ms( t0 ) * 0.001f, tex );
        if (frame == 0)
        {
            unsigned char px[4] = { 0 };
            RECT rc;
            GetClientRect( hwnd, &rc );
            log_uint( "client width", (unsigned int)rc.right );
            log_uint( "client height", (unsigned int)rc.bottom );
            /* inside the quad, which covers the middle half of the client area */
            glReadPixels( rc.right / 2 - rc.right / 8, rc.bottom / 2 - rc.bottom / 8, 1, 1,
                          GL_RGBA, GL_UNSIGNED_BYTE, px );
            log_hex( "quad pixel RGBA", ((unsigned int)px[0] << 24) | (px[1] << 16) | (px[2] << 8) | px[3] );
            log_hex( "glGetError after the first frame", glGetError() );
            if (px[0] > 0x20 || px[1] < 0xa0 || px[2] > 0x20)
            {
                log_line( "the textured quad did not draw" );
                ExitProcess( 27 );
            }
            log_line( "the textured quad drew" );
        }
        ok = SwapBuffers( hdc );
        if (frame < 3) log_swap( frame + 1, ok );
        if (!ok) ExitProcess( 24 );
        swapped++;
    }
    {
        char buf[128];
        char *p = put_str( buf, TAG );
        p = put_str( p, "done, frames presented = " );
        p = put_uint( p, swapped );
        p = put_str( p, ", ms = " );
        p = put_uint( p, elapsed_ms( t0 ) );
        *p++ = '\n';
        *p = 0;
        out_str( buf );
    }
    wglMakeCurrent( NULL, NULL );
    wglDeleteContext( ctx );
    ReleaseDC( hwnd, hdc );
    DestroyWindow( hwnd );
    ExitProcess( swapped ? 43 : 26 );
}
