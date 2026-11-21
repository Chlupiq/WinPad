/* The parts of WinPad's EGL (winpad_egl.m) that reach into gl4es's own state.
 *
 * gl4es turns desktop OpenGL 1.x/2.x (fixed function, glBegin/glEnd, display
 * lists...) into OpenGL ES 2 calls. It keeps one state per context (NewGLState,
 * ActivateGLState) and maps framebuffer 0, the window's own, to a "main FBO" of
 * its state. Apple's OpenGL ES has no window framebuffer at all here, so each
 * context gets a framebuffer of its own for the surface it draws to: an RGBA
 * texture and a packed depth/stencil renderbuffer (iOS takes no separate
 * stencil buffer, which gl4es's own createMainFBO makes) that this file hands
 * to gl4es as that main FBO. Reading it back for the window is here too.
 *
 * Built with gl4es's headers, apart from winpad_egl.m, whose headers are
 * Apple's. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gl/gl4es.h"
#include "gl/glstate.h"
#include "gl/loader.h"
#include "gl/init.h"
#include "gl/framebuffers.h"

#ifndef GL_DEPTH24_STENCIL8_OES
#define GL_DEPTH24_STENCIL8_OES 0x88F0
#endif

void *NewGLState( void *shared_glstate, int es2only );
void ActivateGLState( void *new_glstate );
void initialize_gl4es( void );
void set_getprocaddress( void *(*new_proc_address)(const char *) );
GLuint gl4es_getCurrentFBO( void );
void gl4es_setCurrentFBO( void );
void gl4es_flush( void );

void winpad_gl4es_init( void *(*get_proc_address)(const char *) )
{
    static int done;
    if (done++) return;
    set_getprocaddress( get_proc_address );
    initialize_gl4es();
}

void *winpad_gl4es_new_state( void *share )
{
    return NewGLState( share, 0 );
}

void winpad_gl4es_activate( void *state )
{
    ActivateGLState( state );
}

/* Points the current state's main FBO at FBO (0: none, a context without a
 * surface) and binds what gl4es thinks is bound. */
void winpad_gl4es_set_main_fbo( GLuint fbo, GLuint tex, int width, int height )
{
    glstate->fbo.mainfbo_fbo = fbo;
    glstate->fbo.mainfbo_tex = tex;
    glstate->fbo.mainfbo_dep = glstate->fbo.mainfbo_ste = 0;  /* not gl4es's to delete */
    glstate->fbo.mainfbo_width = glstate->fbo.mainfbo_nwidth = width;
    glstate->fbo.mainfbo_height = glstate->fbo.mainfbo_nheight = height;
    gl4es_setCurrentFBO();
}

/* As real GL does on a context's first MakeCurrent: viewport and scissor box
 * cover the drawable. */
void winpad_gl4es_first_viewport( int width, int height )
{
    gl4es_glViewport( 0, 0, width, height );
    gl4es_glScissor( 0, 0, width, height );
}

/* Gives TEX and RB (made here when 0) storage of WIDTH x HEIGHT. Goes around
 * gl4es, so the bindings it tracks are put back as createMainFBO does. */
void winpad_gl4es_storage( GLuint *tex, GLuint *rb, int width, int height )
{
    LOAD_GLES(glGenTextures);
    LOAD_GLES(glBindTexture);
    LOAD_GLES(glActiveTexture);
    LOAD_GLES(glTexImage2D);
    LOAD_GLES2_OR_OES(glGenRenderbuffers);
    LOAD_GLES2_OR_OES(glBindRenderbuffer);
    LOAD_GLES2_OR_OES(glRenderbufferStorage);
    void gles_glTexParameteri(glTexParameteri_ARG_EXPAND);

    gl4es_flush();
    if (glstate->texture.active != 0) gles_glActiveTexture( GL_TEXTURE0 );
    if (!*tex)
    {
        gles_glGenTextures( 1, tex );
        gles_glBindTexture( GL_TEXTURE_2D, *tex );
        gles_glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST );
        gles_glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST );
        gles_glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE );
        gles_glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
    }
    else gles_glBindTexture( GL_TEXTURE_2D, *tex );
    gles_glTexImage2D( GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL );
    gles_glBindTexture( GL_TEXTURE_2D, glstate->texture.bound[0][ENABLED_TEX2D]->glname );
    if (glstate->texture.active != 0) gles_glActiveTexture( GL_TEXTURE0 + glstate->texture.active );

    if (!*rb) gles_glGenRenderbuffers( 1, rb );
    gles_glBindRenderbuffer( GL_RENDERBUFFER, *rb );
    gles_glRenderbufferStorage( GL_RENDERBUFFER, GL_DEPTH24_STENCIL8_OES, width, height );
    gles_glBindRenderbuffer( GL_RENDERBUFFER, glstate->fbo.current_rb->renderbuffer );
}

/* Makes FBO (when 0) with TEX as colour and RB as depth and stencil. Returns
 * its completeness status. */
GLenum winpad_gl4es_attach( GLuint *fbo, GLuint tex, GLuint rb )
{
    LOAD_GLES2_OR_OES(glGenFramebuffers);
    LOAD_GLES2_OR_OES(glBindFramebuffer);
    LOAD_GLES2_OR_OES(glFramebufferTexture2D);
    LOAD_GLES2_OR_OES(glFramebufferRenderbuffer);
    LOAD_GLES2_OR_OES(glCheckFramebufferStatus);
    GLenum status;

    gl4es_flush();
    if (!*fbo) gles_glGenFramebuffers( 1, fbo );
    gles_glBindFramebuffer( GL_FRAMEBUFFER, *fbo );
    gles_glFramebufferTexture2D( GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0 );
    gles_glFramebufferRenderbuffer( GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, rb );
    gles_glFramebufferRenderbuffer( GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, rb );
    status = gles_glCheckFramebufferStatus( GL_FRAMEBUFFER );
    gl4es_setCurrentFBO();
    return status;
}

/* Reads FBO's colour (WIDTH x HEIGHT, RGBA rows bottom up) into PIXELS. */
void winpad_gl4es_read( GLuint fbo, int width, int height, void *pixels )
{
    LOAD_GLES2_OR_OES(glBindFramebuffer);
    LOAD_GLES(glReadPixels);
    LOAD_GLES(glPixelStorei);

    gl4es_flush();
    gles_glBindFramebuffer( GL_FRAMEBUFFER, fbo );
    gles_glPixelStorei( GL_PACK_ALIGNMENT, 4 );
    gles_glReadPixels( 0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels );
    gles_glPixelStorei( GL_PACK_ALIGNMENT, glstate->texture.pack_align );
    gl4es_setCurrentFBO();
}

void winpad_gl4es_delete_fbo( GLuint fbo )
{
    LOAD_GLES2_OR_OES(glDeleteFramebuffers);
    if (fbo) gles_glDeleteFramebuffers( 1, &fbo );
}

/* GL's own strings for the log: what gl4es reports and what is under it. */
const char *winpad_gl4es_string( unsigned int name )
{
    return (const char *)gl4es_glGetString( name );
}
