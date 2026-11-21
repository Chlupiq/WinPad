/* The unix call tables of opengl32.dll's unix side (tests/opengl/build.sh),
 * for Madeira's ntdll (patches/madeira/0012-opengl32-unixlib.patch), which
 * binds them for opengl32.dll instead of its "GL absent" stub table. A host
 * without OpenGL has a stub of this function that returns NULL (link-host.sh),
 * and the stub table stays. WOW: the table for 32-bit callers. */
extern const void *opengl32_unix_call_funcs[];
extern const void *opengl32_unix_call_wow64_funcs[];

const void *winpad_opengl32_unix_table( int wow )
{
    return wow ? (const void *)opengl32_unix_call_wow64_funcs : (const void *)opengl32_unix_call_funcs;
}
