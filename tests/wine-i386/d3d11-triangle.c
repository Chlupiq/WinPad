/* A 32-bit Direct3D 11 program for WinPad's i386 set: DXMT's d3d11.dll and
 * dxgi.dll (tests/wine-i386/build-d3d9.sh), which reach Metal through
 * winemetal's 32-bit unix-call table like the D3D9 frontend does.
 *
 * It opens a 640x480 window, makes a device and a swap chain with
 * D3D11CreateDeviceAndSwapChain, compiles a vertex and a pixel shader with
 * D3DCompile (Wine's d3dcompiler_47, loaded at run time; games ship their
 * shaders compiled, so a failure here is logged and the program goes on
 * clearing the screen), and draws a spinning triangle from a dynamic vertex
 * buffer it rewrites each frame with Map(WRITE_DISCARD). It runs for
 * WINPAD_D3D11_SECONDS of wall-clock time and exits with 43.
 *
 * Built with -DWINPAD_D3D10=1 it is d3d10-triangle.exe instead: the same
 * window through Direct3D 10 (Wine's d3d10.dll, which hands the device to
 * DXMT's d3d10core.dll): D3D10CreateDeviceAndSwapChain, then a clear in a
 * changing colour and a Present per frame, no shaders.
 *
 * The log lines start with WINPAD-D3D11 (WINPAD-D3D10). Exit statuses as in
 * d3d9-cube.c: 20 no device, 21 no back buffer or view, 22 no vertex buffer,
 * 23 Map failed, 24 Present failed, 25 no window, 26 no frame presented,
 * 43 done.
 */
#define COBJMACROS
#define CINTERFACE
#include <stddef.h>
#include <windows.h>
#if WINPAD_D3D10
#include <d3d10.h>
#define TAG "WINPAD-D3D10: "
#else
#include <d3d11.h>
#include <d3dcompiler.h>
#define TAG "WINPAD-D3D11: "
#endif

#ifndef WINPAD_D3D11_SECONDS
#define WINPAD_D3D11_SECONDS 15
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
    char buf[256];
    char *p = put_str( buf, TAG );
    p = put_str( p, what );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_hr( const char *what, unsigned int hr )
{
    char buf[256];
    char *p = put_str( buf, TAG );
    p = put_str( p, what );
    *p++ = ' ';
    p = put_hex( p, hr );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* "present N hr=0x..." for the first frames, the line CI waits for. */
static void log_present( unsigned int frame, unsigned int hr )
{
    char buf[96];
    char *p = put_str( buf, TAG );
    p = put_str( p, "present " );
    p = put_uint( p, frame );
    p = put_str( p, " hr=" );
    p = put_hex( p, hr );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_done( unsigned int presented, unsigned int ms )
{
    char buf[128];
    char *p = put_str( buf, TAG );
    p = put_str( p, "done, frames presented = " );
    p = put_uint( p, presented );
    p = put_str( p, ", ms = " );
    p = put_uint( p, ms );
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

static __attribute__((unused)) float cosf_approx( float x )
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
    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance     = inst;
    wc.lpszClassName = "WinPadD3D11Triangle";
    if (!RegisterClassExA( &wc ))
    {
        log_hr( "RegisterClassExA failed, err", GetLastError() );
        ExitProcess( 25 );
    }
    hwnd = CreateWindowExA( 0, wc.lpszClassName, "WinPad " TAG, WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            0, 0, WIN_W, WIN_H, NULL, NULL, inst, NULL );
    if (!hwnd)
    {
        log_hr( "CreateWindowExA failed, err", GetLastError() );
        ExitProcess( 25 );
    }
    log_hr( "hwnd", (unsigned int)(ULONG_PTR)hwnd );
    return hwnd;
}

static void swap_desc( DXGI_SWAP_CHAIN_DESC *sd, HWND hwnd )
{
    memset( sd, 0, sizeof(*sd) );
    sd->BufferDesc.Width  = WIN_W;
    sd->BufferDesc.Height = WIN_H;
    sd->BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd->BufferDesc.RefreshRate.Numerator   = 60;
    sd->BufferDesc.RefreshRate.Denominator = 1;
    sd->SampleDesc.Count = 1;
    sd->BufferUsage      = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd->BufferCount      = 2;
    sd->OutputWindow     = hwnd;
    sd->Windowed         = TRUE;
    sd->SwapEffect       = DXGI_SWAP_EFFECT_DISCARD;
}

static unsigned int elapsed_ms( DWORD start )
{
    return (unsigned int)(GetTickCount() - start);
}

#if WINPAD_D3D10

void start( void )
{
    DXGI_SWAP_CHAIN_DESC sd;
    IDXGISwapChain *sc = NULL;
    ID3D10Device *dev = NULL;
    ID3D10Texture2D *back = NULL;
    ID3D10RenderTargetView *rtv = NULL;
    unsigned int frame, presented = 0;
    DWORD t0;
    HWND hwnd;
    HRESULT hr;

    log_line( "32-bit D3D10 clear test starting" );
    hwnd = make_window();
    swap_desc( &sd, hwnd );
    hr = D3D10CreateDeviceAndSwapChain( NULL, D3D10_DRIVER_TYPE_HARDWARE, NULL, 0, D3D10_SDK_VERSION,
                                        &sd, &sc, &dev );
    if (FAILED(hr) || !dev || !sc)
    {
        log_hr( "D3D10CreateDeviceAndSwapChain failed, hr", (unsigned int)hr );
        ExitProcess( 20 );
    }
    log_line( "device created" );
    hr = IDXGISwapChain_GetBuffer( sc, 0, &IID_ID3D10Texture2D, (void **)&back );
    if (SUCCEEDED(hr)) hr = ID3D10Device_CreateRenderTargetView( dev, (ID3D10Resource *)back, NULL, &rtv );
    if (FAILED(hr) || !rtv)
    {
        log_hr( "back buffer view failed, hr", (unsigned int)hr );
        ExitProcess( 21 );
    }
    log_line( "render target view created" );

    t0 = GetTickCount();
    for (frame = 0; ; frame++)
    {
        float t, color[4];
        D3D10_VIEWPORT vp = { 0, 0, WIN_W, WIN_H, 0.0f, 1.0f };

        pump();
        if (window_closed) break;
        if (elapsed_ms( t0 ) >= WINPAD_D3D11_SECONDS * 1000u) break;
        t = (float)elapsed_ms( t0 ) * 0.001f;
        color[0] = 0.5f + 0.5f * sinf_approx( t );
        color[1] = 0.5f + 0.5f * sinf_approx( t + 2.0f );
        color[2] = 0.5f + 0.5f * sinf_approx( t + 4.0f );
        color[3] = 1.0f;
        ID3D10Device_OMSetRenderTargets( dev, 1, &rtv, NULL );
        ID3D10Device_RSSetViewports( dev, 1, &vp );
        ID3D10Device_ClearRenderTargetView( dev, rtv, color );
        hr = IDXGISwapChain_Present( sc, 1, 0 );
        if (frame < 3) log_present( frame + 1, (unsigned int)hr );
        if (FAILED(hr))
        {
            log_hr( "Present failed, hr", (unsigned int)hr );
            ExitProcess( 24 );
        }
        presented++;
    }

    ID3D10RenderTargetView_Release( rtv );
    ID3D10Texture2D_Release( back );
    IDXGISwapChain_Release( sc );
    ID3D10Device_Release( dev );
    DestroyWindow( hwnd );
    if (!presented)
    {
        log_line( "closed before any frame was presented" );
        ExitProcess( 26 );
    }
    log_done( presented, elapsed_ms( t0 ) );
    ExitProcess( 43 );
}

#else

struct vertex
{
    float x, y;
    float r, g, b, a;
};

static const char vs_src[] =
    "struct o { float4 p : SV_Position; float4 c : COLOR; };\n"
    "o main( float2 p : POSITION, float4 c : COLOR ) { o r; r.p = float4( p, 0, 1 ); r.c = c; return r; }\n";
static const char ps_src[] =
    "float4 main( float4 p : SV_Position, float4 c : COLOR ) : SV_Target { return c; }\n";

typedef HRESULT (WINAPI *compile_fn)( const void *, SIZE_T, const char *, const D3D_SHADER_MACRO *,
                                      ID3DInclude *, const char *, const char *, UINT, UINT,
                                      ID3DBlob **, ID3DBlob ** );

/* Compiles SRC for TARGET with d3dcompiler_47's D3DCompile; NULL on failure
 * (logged, with the compiler's message). */
static ID3DBlob *compile( compile_fn fn, const char *src, SIZE_T len, const char *target )
{
    ID3DBlob *code = NULL, *errors = NULL;
    HRESULT hr = fn( src, len, target, NULL, NULL, "main", target, 0, 0, &code, &errors );
    if (FAILED(hr) || !code)
    {
        log_hr( target, (unsigned int)hr );
        if (errors)
        {
            char buf[256];
            const char *m = ID3D10Blob_GetBufferPointer( errors );
            SIZE_T n = ID3D10Blob_GetBufferSize( errors ), i;
            char *p = put_str( buf, TAG );
            for (i = 0; i < n && i < 200 && m[i]; i++) *p++ = m[i] == '\n' ? ' ' : m[i];
            *p++ = '\n';
            *p = 0;
            out_str( buf );
            ID3D10Blob_Release( errors );
        }
        return NULL;
    }
    if (errors) ID3D10Blob_Release( errors );
    return code;
}

void start( void )
{
    static const D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
                                                D3D_FEATURE_LEVEL_10_0 };
    static const D3D11_INPUT_ELEMENT_DESC layout_desc[] =
    {
        { "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0 },
        { "COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    };
    DXGI_SWAP_CHAIN_DESC sd;
    D3D_FEATURE_LEVEL level = 0;
    IDXGISwapChain *sc = NULL;
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    ID3D11Texture2D *back = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    ID3D11Buffer *vb = NULL;
    ID3D11VertexShader *vs = NULL;
    ID3D11PixelShader *ps = NULL;
    ID3D11InputLayout *layout = NULL;
    D3D11_BUFFER_DESC bd;
    unsigned int frame, presented = 0;
    HMODULE compiler;
    DWORD t0;
    HWND hwnd;
    HRESULT hr;

    log_line( "32-bit D3D11 triangle starting" );
    hwnd = make_window();
    swap_desc( &sd, hwnd );
    hr = D3D11CreateDeviceAndSwapChain( NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, levels, 3,
                                        D3D11_SDK_VERSION, &sd, &sc, &dev, &level, &ctx );
    if (FAILED(hr) || !dev || !sc || !ctx)
    {
        log_hr( "D3D11CreateDeviceAndSwapChain failed, hr", (unsigned int)hr );
        ExitProcess( 20 );
    }
    log_line( "device created" );
    log_hr( "feature level", (unsigned int)level );

    hr = IDXGISwapChain_GetBuffer( sc, 0, &IID_ID3D11Texture2D, (void **)&back );
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateRenderTargetView( dev, (ID3D11Resource *)back, NULL, &rtv );
    if (FAILED(hr) || !rtv)
    {
        log_hr( "back buffer view failed, hr", (unsigned int)hr );
        ExitProcess( 21 );
    }
    log_line( "render target view created" );

    memset( &bd, 0, sizeof(bd) );
    bd.ByteWidth      = 3 * sizeof(struct vertex);
    bd.Usage          = D3D11_USAGE_DYNAMIC;
    bd.BindFlags      = D3D11_BIND_VERTEX_BUFFER;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    hr = ID3D11Device_CreateBuffer( dev, &bd, NULL, &vb );
    if (FAILED(hr) || !vb)
    {
        log_hr( "CreateBuffer failed, hr", (unsigned int)hr );
        ExitProcess( 22 );
    }
    log_line( "dynamic vertex buffer created" );

    compiler = LoadLibraryA( "d3dcompiler_47.dll" );
    if (!compiler)
        log_hr( "no d3dcompiler_47.dll, err", GetLastError() );
    else
    {
        compile_fn fn = (compile_fn)GetProcAddress( compiler, "D3DCompile" );
        ID3DBlob *vs_code = fn ? compile( fn, vs_src, sizeof(vs_src) - 1, "vs_4_0" ) : NULL;
        ID3DBlob *ps_code = fn ? compile( fn, ps_src, sizeof(ps_src) - 1, "ps_4_0" ) : NULL;
        if (vs_code && ps_code)
        {
            log_line( "shaders compiled" );
            hr = ID3D11Device_CreateVertexShader( dev, ID3D10Blob_GetBufferPointer( vs_code ),
                                                  ID3D10Blob_GetBufferSize( vs_code ), NULL, &vs );
            log_hr( "CreateVertexShader", (unsigned int)hr );
            hr = ID3D11Device_CreatePixelShader( dev, ID3D10Blob_GetBufferPointer( ps_code ),
                                                 ID3D10Blob_GetBufferSize( ps_code ), NULL, &ps );
            log_hr( "CreatePixelShader", (unsigned int)hr );
            hr = ID3D11Device_CreateInputLayout( dev, layout_desc, 2, ID3D10Blob_GetBufferPointer( vs_code ),
                                                 ID3D10Blob_GetBufferSize( vs_code ), &layout );
            log_hr( "CreateInputLayout", (unsigned int)hr );
        }
        if (vs_code) ID3D10Blob_Release( vs_code );
        if (ps_code) ID3D10Blob_Release( ps_code );
    }
    if (!vs || !ps || !layout) log_line( "no shaders, clearing only" );

    t0 = GetTickCount();
    for (frame = 0; ; frame++)
    {
        static const float clear[4] = { 24 / 255.0f, 28 / 255.0f, 40 / 255.0f, 1.0f };
        D3D11_VIEWPORT vp = { 0, 0, WIN_W, WIN_H, 0.0f, 1.0f };
        D3D11_MAPPED_SUBRESOURCE map;
        float t, c, s;
        int i;

        pump();
        if (window_closed) break;
        if (elapsed_ms( t0 ) >= WINPAD_D3D11_SECONDS * 1000u) break;
        t = (float)elapsed_ms( t0 ) * 0.001f * (TWO_PI_F / 3.0f);
        c = cosf_approx( t );
        s = sinf_approx( t );

        hr = ID3D11DeviceContext_Map( ctx, (ID3D11Resource *)vb, 0, D3D11_MAP_WRITE_DISCARD, 0, &map );
        if (FAILED(hr) || !map.pData)
        {
            log_hr( "Map failed, hr", (unsigned int)hr );
            ExitProcess( 23 );
        }
        for (i = 0; i < 3; i++)
        {
            /* An equilateral triangle, clockwise (D3D's front face), turned by t. */
            static const float px[3] = { 0.0f, 0.6062f, -0.6062f };
            static const float py[3] = { 0.7f, -0.35f, -0.35f };
            struct vertex *v = (struct vertex *)map.pData + i;
            v->x = (px[i] * c - py[i] * s) * (float)WIN_H / (float)WIN_W;
            v->y = px[i] * s + py[i] * c;
            v->r = i == 0 ? 1.0f : 0.15f;
            v->g = i == 1 ? 1.0f : 0.15f;
            v->b = i == 2 ? 1.0f : 0.15f;
            v->a = 1.0f;
        }
        ID3D11DeviceContext_Unmap( ctx, (ID3D11Resource *)vb, 0 );

        ID3D11DeviceContext_OMSetRenderTargets( ctx, 1, &rtv, NULL );
        ID3D11DeviceContext_RSSetViewports( ctx, 1, &vp );
        ID3D11DeviceContext_ClearRenderTargetView( ctx, rtv, clear );
        if (vs && ps && layout)
        {
            UINT stride = sizeof(struct vertex), offset = 0;
            ID3D11DeviceContext_IASetInputLayout( ctx, layout );
            ID3D11DeviceContext_IASetPrimitiveTopology( ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST );
            ID3D11DeviceContext_IASetVertexBuffers( ctx, 0, 1, &vb, &stride, &offset );
            ID3D11DeviceContext_VSSetShader( ctx, vs, NULL, 0 );
            ID3D11DeviceContext_PSSetShader( ctx, ps, NULL, 0 );
            ID3D11DeviceContext_Draw( ctx, 3, 0 );
            if (!frame) log_line( "first Draw issued" );
        }
        hr = IDXGISwapChain_Present( sc, 1, 0 );
        if (frame < 3) log_present( frame + 1, (unsigned int)hr );
        if (FAILED(hr))
        {
            log_hr( "Present failed, hr", (unsigned int)hr );
            ExitProcess( 24 );
        }
        presented++;
    }

    if (layout) ID3D11InputLayout_Release( layout );
    if (ps) ID3D11PixelShader_Release( ps );
    if (vs) ID3D11VertexShader_Release( vs );
    ID3D11Buffer_Release( vb );
    ID3D11RenderTargetView_Release( rtv );
    ID3D11Texture2D_Release( back );
    IDXGISwapChain_Release( sc );
    ID3D11DeviceContext_Release( ctx );
    ID3D11Device_Release( dev );
    DestroyWindow( hwnd );
    if (!presented)
    {
        log_line( "closed before any frame was presented" );
        ExitProcess( 26 );
    }
    log_done( presented, elapsed_ms( t0 ) );
    ExitProcess( 43 );
}

#endif
