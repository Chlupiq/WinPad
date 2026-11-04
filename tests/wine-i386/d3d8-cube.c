/* The Direct3D 8 counterpart of d3d9-cube.c: the same 32-bit cube, made with the
 * Direct3D 8 API, for d3d8.dll in WinPad's i386 set (d3d8to9, which turns each
 * D3D8 call into D3D9 ones for DXMT; tests/wine-i386/build-d3d9.sh). Games of
 * the early 2000s (Mafia, ...) use D3D8.
 *
 * Differences from d3d9-cube.c, all the API's: Direct3DCreate8, the FVF set
 * with SetVertexShader, CreateVertexBuffer without a shared handle,
 * SetStreamSource without an offset, FullScreen_PresentationInterval. The log
 * lines start with WINPAD-D3D8, so that a run cannot be mistaken for the D3D9
 * one, and the run time is WINPAD_D3D8_SECONDS. The rest of the comment of
 * d3d9-cube.c, its design and its exit statuses, hold here too.
 */
#include <stddef.h>
#include <windows.h>
#include <d3d8.h>

#ifndef WINPAD_D3D8_SECONDS
#define WINPAD_D3D8_SECONDS  15
#endif
#define WIN_W                 640
#define WIN_H                 480

/* Off by default: flip with -DWINPAD_D3D8_ZENABLE=1 to exercise the depth
 * path instead of relying purely on D3DRS_CULLMODE (see the header comment
 * and the SetRenderState/Clear calls in start() below). */
#ifndef WINPAD_D3D8_ZENABLE
#define WINPAD_D3D8_ZENABLE 0
#endif

/* -nostdlib: clang may still lower a struct initialisation to a memset or
 * memcpy call, so provide them rather than hoping it does not. */
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

/* Prints a non-negative float with a fixed number of decimal digits, rounded
 * to nearest -- no CRT snprintf/dtoa available. */
static char *put_fixed( char *p, float v, int decimals )
{
    unsigned int scale = 1;
    unsigned int scaled, whole, frac, d;
    int i;

    if (v < 0.0f) v = 0.0f;
    for (i = 0; i < decimals; i++) scale *= 10;
    scaled = (unsigned int)(v * (float)scale + 0.5f);
    whole  = scaled / scale;
    frac   = scaled % scale;

    p = put_uint( p, whole );
    *p++ = '.';
    d = scale / 10;
    while (d)
    {
        *p++ = (char)('0' + (frac / d) % 10);
        d /= 10;
    }
    return p;
}

static void log_step( const char *what, unsigned int hr )
{
    char buf[128];
    char *p = buf;
    const char *s = "WINPAD-D3D8: ";
    while (*s) *p++ = *s++;
    while (*what) *p++ = *what++;
    *p++ = ' ';
    p = put_hex( p, hr );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* One line per presented frame for the first few frames: the frame number and
 * the HRESULT Present actually returned.  `frame N` below is only printed once
 * Present has already succeeded, so it cannot show a Present that returned a
 * failure code or one that never returned at all. */
static void log_present( unsigned int frame, unsigned int hr )
{
    char buf[96];
    char *p = buf;
    const char *s = "WINPAD-D3D8: present ";
    while (*s) *p++ = *s++;
    p = put_uint( p, frame );
    *p++ = ' '; *p++ = 'h'; *p++ = 'r'; *p++ = '=';
    p = put_hex( p, hr );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_frame( unsigned int frame )
{
    char buf[64];
    char *p = buf;
    const char *s = "WINPAD-D3D8: frame ";
    while (*s) *p++ = *s++;
    p = put_uint( p, frame );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* ------------------------------------------------------------- cube model */

struct vertex           /* D3DFVF_XYZRHW | D3DFVF_DIFFUSE */
{
    float    x, y, z, rhw;
    D3DCOLOR color;
};

#define FVF_CUBE (D3DFVF_XYZRHW | D3DFVF_DIFFUSE)

/* Unit cube corners, and the six faces as CCW quads seen from outside. */
static const float corner[8][3] =
{
    { -1, -1, -1 }, {  1, -1, -1 }, {  1,  1, -1 }, { -1,  1, -1 },
    { -1, -1,  1 }, {  1, -1,  1 }, {  1,  1,  1 }, { -1,  1,  1 },
};

static const int face[6][4] =
{
    { 0, 1, 2, 3 },   /* -Z */
    { 5, 4, 7, 6 },   /* +Z */
    { 4, 0, 3, 7 },   /* -X */
    { 1, 5, 6, 2 },   /* +X */
    { 4, 5, 1, 0 },   /* -Y */
    { 3, 2, 6, 7 },   /* +Y */
};

static const D3DCOLOR face_color[6] =
{
    0xffe04040, 0xff40e040, 0xff4040e0,
    0xffe0e040, 0xff40e0e0, 0xffe040e0,
};

/* ---------------------------------------------------------- trig, no libm */

#define MADEIRA_PI      3.14159265358979323846f
#define MADEIRA_TWO_PI  (2.0f * MADEIRA_PI)

/* Range-reduce x into [-PI, PI].  The float-to-int truncation is a native
 * cvttss2si/fistp instruction, not a runtime call. */
static float wrap_pi( float x )
{
    float k = (float)(int)(x * (1.0f / MADEIRA_TWO_PI));
    x -= k * MADEIRA_TWO_PI;
    if (x >  MADEIRA_PI) x -= MADEIRA_TWO_PI;
    if (x < -MADEIRA_PI) x += MADEIRA_TWO_PI;
    return x;
}

/* 7th-order Taylor sine/cosine over the reduced range: plenty accurate for a
 * spinning test cube, and no libm dependency -- just multiplies and adds. */
static float sinf_approx( float x )
{
    float x2;
    x = wrap_pi( x );
    x2 = x * x;
    return x * (1.0f + x2 * (-1.0f / 6.0f +
                    x2 * (1.0f / 120.0f +
                    x2 * (-1.0f / 5040.0f))));
}

static float cosf_approx( float x )
{
    return sinf_approx( x + MADEIRA_PI * 0.5f );
}

/* Angular rates matching the milestone's original per-frame steps (2*pi/180
 * and 2*pi/300 at an assumed 60 fps), but now expressed as rad/s so the
 * rotation is frame-rate independent. */
#define YAW_RATE_RAD_PER_SEC    (MADEIRA_TWO_PI / 3.0f)   /* full turn / 3s */
#define PITCH_RATE_RAD_PER_SEC  (MADEIRA_TWO_PI / 5.0f)   /* full turn / 5s */

/* Converts a 64-bit tick delta to a double using only 32-bit-to-double
 * conversions and 64-bit shifts/subtracts (all native, no compiler-rt call):
 * -nostdlib means a direct (double)(LONGLONG) cast or a 64-bit integer
 * divide could silently need a __floatdidf/__divdi3 helper we cannot link. */
static double ll_to_double( LONGLONG v )
{
    LONG  hi = (LONG)(v >> 32);
    DWORD lo = (DWORD)(v & 0xFFFFFFFFu);
    return (double)hi * 4294967296.0 + (double)lo;
}

/* ---------------------------------------------------------- cube geometry */

/* Fill `out` with all 12 triangles for this frame; returns the triangle
 * count (always 12).  Vertices come out already in screen space, which is
 * what XYZRHW means.  Back-face rejection is left entirely to the device's
 * D3DRS_CULLMODE now, so every triangle is submitted regardless of facing. */
static unsigned int build_frame( struct vertex *out,
                                 float ca, float sa, float cb, float sb,
                                 float width, float height )
{
    float sx[8], sy[8], sw[8];
    unsigned int tris = 0;
    const float cam_z = 4.5f;            /* camera distance along +Z   */
    const float focal = 0.9f * height;   /* pixels per unit at z = 1   */
    const float cx = width * 0.5f;
    const float cy = height * 0.5f;
    int i, f;

    for (i = 0; i < 8; i++)
    {
        float x = corner[i][0], y = corner[i][1], z = corner[i][2];
        float x1, y1, z1, z2, inv;

        /* yaw about Y, then pitch about X */
        x1 =  x * ca + z * sa;
        z1 = -x * sa + z * ca;
        y1 =  y * cb - z1 * sb;
        z2 =  y * sb + z1 * cb;

        z2 += cam_z;                     /* always >= ~2.7: cube half-
                                             diagonal < cam_z, no near clip */
        inv = 1.0f / z2;
        sx[i] = cx + focal * x1 * inv;
        sy[i] = cy - focal * y1 * inv;
        sw[i] = inv;
    }

    for (f = 0; f < 6; f++)
    {
        const int *q = face[f];
        /* Reversed relative to face[]'s CCW-from-outside quad authoring: a
         * quad (q0,q1,q2,q3) is split here as (q0,q2,q1) and (q0,q3,q2), the
         * mirror image of the natural (q0,q1,q2)/(q0,q2,q3) split.  That
         * makes front (camera-facing) triangles wind clockwise in screen
         * space, which is D3D9's front-facing convention under the default
         * D3DRS_CULLMODE = D3DCULL_CCW. */
        static const int tri[6] = { 0, 2, 1, 0, 3, 2 };
        int k;

        for (k = 0; k < 6; k++)
        {
            int c = q[tri[k]];
            out->x     = sx[c];
            out->y     = sy[c];
            out->z     = 0.5f;
            out->rhw   = sw[c];
            out->color = face_color[f];
            out++;
        }
        tris += 2;
    }
    return tris;
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

/* -------------------------------------------------------------------- main */

void start( void )
{
    WNDCLASSEXA wc;
    D3DPRESENT_PARAMETERS pp;
    HWND hwnd;
    HINSTANCE inst = GetModuleHandleA( NULL );
    IDirect3D8 *d3d;
    IDirect3DDevice8 *dev = NULL;
    IDirect3DVertexBuffer8 *vb = NULL;
    unsigned int frame, presented = 0;
    LARGE_INTEGER qpc_freq, qpc_start, qpc_now;
    double freq_d, total_elapsed_d;
    float total_elapsed, avg_fps;
    HRESULT hr;

    out_str( "WINPAD-D3D8: 32-bit D3D8 cube starting\n" );

    memset( &wc, 0, sizeof(wc) );
    wc.cbSize        = sizeof(wc);
    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance     = inst;
    wc.hCursor       = NULL;
    wc.lpszClassName = "WinPadD3D8CubeX86";
    if (!RegisterClassExA( &wc ))
    {
        log_step( "RegisterClassExA failed, err", GetLastError() );
        ExitProcess( 25 );
    }

    hwnd = CreateWindowExA( 0, wc.lpszClassName, "WinPad D3D8 cube (32-bit)",
                            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            0, 0, WIN_W, WIN_H, NULL, NULL, inst, NULL );
    if (!hwnd)
    {
        log_step( "CreateWindowExA failed, err", GetLastError() );
        ExitProcess( 25 );
    }
    log_step( "hwnd", (unsigned int)(ULONG_PTR)hwnd );

    d3d = Direct3DCreate8( D3D_SDK_VERSION );
    if (!d3d)
    {
        out_str( "WINPAD-D3D8: Direct3DCreate8 returned NULL\n" );
        ExitProcess( 20 );
    }
    out_str( "WINPAD-D3D8: Direct3DCreate8 ok\n" );

    memset( &pp, 0, sizeof(pp) );
    pp.Windowed               = TRUE;
    pp.SwapEffect             = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat       = D3DFMT_UNKNOWN;
    pp.BackBufferWidth        = WIN_W;
    pp.BackBufferHeight       = WIN_H;
    pp.hDeviceWindow          = hwnd;
#if WINPAD_D3D8_ZENABLE
    pp.EnableAutoDepthStencil = TRUE;
    pp.AutoDepthStencilFormat = D3DFMT_D16;
#else
    pp.EnableAutoDepthStencil = FALSE;
#endif
    pp.FullScreen_PresentationInterval = D3DPRESENT_INTERVAL_DEFAULT;

    hr = IDirect3D8_CreateDevice( d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                  D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &dev );
    if (FAILED(hr) || !dev)
    {
        log_step( "CreateDevice failed, hr", (unsigned int)hr );
        ExitProcess( 21 );
    }
    out_str( "WINPAD-D3D8: device created (software vertex processing)\n" );

    hr = IDirect3DDevice8_CreateVertexBuffer( dev, 12 * 3 * sizeof(struct vertex),
                                              D3DUSAGE_DYNAMIC | D3DUSAGE_WRITEONLY,
                                              FVF_CUBE, D3DPOOL_DEFAULT, &vb );
    if (FAILED(hr) || !vb)
    {
        log_step( "CreateVertexBuffer failed, hr", (unsigned int)hr );
        ExitProcess( 22 );
    }
    out_str( "WINPAD-D3D8: dynamic vertex buffer created\n" );

    IDirect3DDevice8_SetRenderState( dev, D3DRS_LIGHTING, FALSE );
    IDirect3DDevice8_SetRenderState( dev, D3DRS_ZENABLE,
                                     WINPAD_D3D8_ZENABLE ? D3DZB_TRUE : D3DZB_FALSE );
    IDirect3DDevice8_SetRenderState( dev, D3DRS_CULLMODE, D3DCULL_CCW );
    IDirect3DDevice8_SetVertexShader( dev, FVF_CUBE );

    {
        char buf[64];
        char *p = buf;
        const char *s = "WINPAD-D3D8: cull=CCW z=";
        while (*s) *p++ = *s++;
        s = WINPAD_D3D8_ZENABLE ? "on" : "off";
        while (*s) *p++ = *s++;
        s = " seconds=";
        while (*s) *p++ = *s++;
        p = put_uint( p, WINPAD_D3D8_SECONDS );
        *p++ = '\n';
        *p = 0;
        out_str( buf );
    }

    QueryPerformanceFrequency( &qpc_freq );
    QueryPerformanceCounter( &qpc_start );
    freq_d = ll_to_double( qpc_freq.QuadPart );

    for (frame = 0; ; frame++)
    {
        void *locked = NULL;
        unsigned int tris, clear_flags;
        float elapsed_seconds, angle_a, angle_b, ca, sa, cb, sb;

        pump();
        if (window_closed) break;

        QueryPerformanceCounter( &qpc_now );
        elapsed_seconds = (float)(ll_to_double( qpc_now.QuadPart - qpc_start.QuadPart ) / freq_d);
        if (elapsed_seconds >= (float)WINPAD_D3D8_SECONDS) break;

        angle_a = elapsed_seconds * YAW_RATE_RAD_PER_SEC;
        angle_b = elapsed_seconds * PITCH_RATE_RAD_PER_SEC;
        ca = cosf_approx( angle_a ); sa = sinf_approx( angle_a );
        cb = cosf_approx( angle_b ); sb = sinf_approx( angle_b );

        hr = IDirect3DVertexBuffer8_Lock( vb, 0, 0, (BYTE **)&locked, D3DLOCK_DISCARD );
        if (FAILED(hr) || !locked)
        {
            log_step( "Lock failed, hr", (unsigned int)hr );
            ExitProcess( 23 );
        }
        if (!frame) log_step( "first locked vertex pointer", (unsigned int)(ULONG_PTR)locked );

        tris = build_frame( locked, ca, sa, cb, sb, (float)WIN_W, (float)WIN_H );
        IDirect3DVertexBuffer8_Unlock( vb );

        clear_flags = D3DCLEAR_TARGET | (WINPAD_D3D8_ZENABLE ? D3DCLEAR_ZBUFFER : 0);
        IDirect3DDevice8_Clear( dev, 0, NULL, clear_flags,
                                D3DCOLOR_XRGB( 24, 28, 40 ), 1.0f, 0 );
        if (SUCCEEDED(IDirect3DDevice8_BeginScene( dev )))
        {
            if (tris)
            {
                IDirect3DDevice8_SetStreamSource( dev, 0, vb, sizeof(struct vertex) );
                hr = IDirect3DDevice8_DrawPrimitive( dev, D3DPT_TRIANGLELIST, 0, tris );
                if (!frame) log_step( "first DrawPrimitive returned hr", (unsigned int)hr );
            }
            IDirect3DDevice8_EndScene( dev );
        }

        hr = IDirect3DDevice8_Present( dev, NULL, NULL, NULL, NULL );
        if (frame < 3) log_present( frame + 1, (unsigned int)hr );
        if (FAILED(hr))
        {
            log_step( "Present failed, hr", (unsigned int)hr );
            if (hr == D3DERR_DEVICELOST || hr == D3DERR_DEVICENOTRESET)
            {
                Sleep( 50 );
                continue;
            }
            ExitProcess( 24 );
        }
        presented++;
        if (frame == 0 || frame == 1 || ((frame + 1) % 60) == 0) log_frame( frame + 1 );
    }

    QueryPerformanceCounter( &qpc_now );
    total_elapsed_d = ll_to_double( qpc_now.QuadPart - qpc_start.QuadPart ) / freq_d;
    total_elapsed   = (float)total_elapsed_d;
    avg_fps         = (total_elapsed > 0.0f) ? ((float)presented / total_elapsed) : 0.0f;

    if (vb)  IDirect3DVertexBuffer8_Release( vb );
    if (dev) IDirect3DDevice8_Release( dev );
    IDirect3D8_Release( d3d );
    DestroyWindow( hwnd );

    if (!presented)
    {
        out_str( "WINPAD-D3D8: closed before any frame was presented\n" );
        ExitProcess( 26 );
    }

    {
        char buf[128];
        char *p = buf;
        const char *s = "WINPAD-D3D8: done, frames presented = ";
        while (*s) *p++ = *s++;
        p = put_uint( p, presented );
        s = ", seconds = ";
        while (*s) *p++ = *s++;
        p = put_fixed( p, total_elapsed, 2 );
        s = ", avg fps = ";
        while (*s) *p++ = *s++;
        p = put_fixed( p, avg_fps, 1 );
        *p++ = '\n';
        *p = 0;
        out_str( buf );
    }
    ExitProcess( 43 );
}
