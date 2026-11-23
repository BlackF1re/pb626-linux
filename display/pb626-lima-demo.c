#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { width = 320, height = 320, channels = 4 };
static unsigned char pixels[width * height * channels];

// Use entry points from the EGL implementation that owns the context.
#define GLES_FUNCTIONS(X) \
    X(AttachShader) \
    X(BindAttribLocation) \
    X(Clear) \
    X(ClearColor) \
    X(CompileShader) \
    X(CreateProgram) \
    X(CreateShader) \
    X(DeleteShader) \
    X(DrawArrays) \
    X(EnableVertexAttribArray) \
    X(GetError) \
    X(GetProgramInfoLog) \
    X(GetProgramiv) \
    X(GetShaderInfoLog) \
    X(GetShaderiv) \
    X(GetString) \
    X(LinkProgram) \
    X(ReadPixels) \
    X(ShaderSource) \
    X(UseProgram) \
    X(VertexAttribPointer) \
    X(Viewport)

static struct {
#define GLES_FIELD(name) __typeof__(&gl##name) name;
    GLES_FUNCTIONS(GLES_FIELD)
#undef GLES_FIELD
} gles;

static int load_gles(void)
{
#define GLES_LOAD(name)                                                 \
    gles.name = (__typeof__(gles.name))eglGetProcAddress("gl" #name);    \
    if (!gles.name) {                                                   \
        fprintf(stderr, "Missing GLES2 entry point: gl%s\n", #name);   \
        return 0;                                                       \
    }
    GLES_FUNCTIONS(GLES_LOAD)
#undef GLES_LOAD
    return 1;
}

static GLuint compile_shader(GLenum type, const char *source)
{
    GLuint shader = gles.CreateShader(type);
    GLint compiled;
    char log[512];

    gles.ShaderSource(shader, 1, &source, NULL);
    gles.CompileShader(shader);
    gles.GetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        gles.GetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "Shader compilation failed: %s\n", log);
        gles.DeleteShader(shader);
        return 0;
    }
    return shader;
}

static int draw_scene(void)
{
    static const GLfloat vertices[] = {
        -0.86f, -0.74f, -0.86f, 0.74f, 0.86f, 0.74f, 0.86f, -0.74f,
        -0.62f, -0.50f,  0.62f, -0.50f, 0.00f, 0.57f,
    };
    static const GLfloat tones[] = {
        0.03f, 0.74f, 0.96f, 0.28f, 1.0f, 1.0f, 0.40f,
    };
    GLuint vs = compile_shader(GL_VERTEX_SHADER,
        "attribute vec2 position; attribute float tone; varying float gray;"
        "void main() { gl_Position = vec4(position, 0.0, 1.0); gray = tone; }");
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER,
        "precision mediump float; varying float gray;"
        "void main() { gl_FragColor = vec4(gray, gray, gray, 1.0); }");
    if (!vs || !fs)
        return 0;

    GLuint program = gles.CreateProgram();
    GLint linked;
    gles.AttachShader(program, vs);
    gles.AttachShader(program, fs);
    gles.BindAttribLocation(program, 0, "position");
    gles.BindAttribLocation(program, 1, "tone");
    gles.LinkProgram(program);
    gles.GetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        char log[512];
        gles.GetProgramInfoLog(program, sizeof(log), NULL, log);
        fprintf(stderr, "Shader linking failed: %s\n", log);
        return 0;
    }

    gles.Viewport(0, 0, width, height);
    gles.ClearColor(1.0f, 1.0f, 1.0f, 1.0f);
    gles.Clear(GL_COLOR_BUFFER_BIT);
    gles.UseProgram(program);
    gles.VertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, vertices);
    gles.VertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 0, tones);
    gles.EnableVertexAttribArray(0);
    gles.EnableVertexAttribArray(1);
    gles.DrawArrays(GL_TRIANGLE_FAN, 0, 4);
    gles.DrawArrays(GL_TRIANGLES, 4, 3);
    gles.ReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    GLenum error = gles.GetError();
    unsigned corner = pixels[0];
    unsigned dark = pixels[(48 * width + 40) * channels];
    unsigned center = pixels[((height / 2) * width + width / 2) * channels];
    printf("GLES2 readback: white=%u dark=%u triangle=%u gl_error=0x%x\n",
           corner, dark, center, error);
    return error == GL_NO_ERROR && corner >= 250 && dark < 60 &&
           center > 150 && center < 235;
}

static int render(void)
{
    static const EGLint config_attrs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    static const EGLint surface_attrs[] = {
        EGL_WIDTH, width, EGL_HEIGHT, height, EGL_NONE,
    };
    static const EGLint context_attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLDisplay display = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                                                EGL_DEFAULT_DISPLAY, NULL);
    EGLConfig config;
    EGLint count, major, minor;
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, &major, &minor)) {
        fprintf(stderr, "EGL initialization failed: 0x%x\n", eglGetError());
        return 0;
    }
    if (!eglBindAPI(EGL_OPENGL_ES_API) ||
        !eglChooseConfig(display, config_attrs, &config, 1, &count) || count != 1) {
        fprintf(stderr, "No GLES2 pbuffer config: 0x%x\n", eglGetError());
        eglTerminate(display);
        return 0;
    }

    EGLSurface surface = eglCreatePbufferSurface(display, config, surface_attrs);
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attrs);
    int passed = 0;
    if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT ||
        !eglMakeCurrent(display, surface, surface, context)) {
        fprintf(stderr, "GLES2 context setup failed: 0x%x\n", eglGetError());
    } else if (load_gles()) {
        const char *renderer = (const char *)gles.GetString(GL_RENDERER);
        const char *version = (const char *)gles.GetString(GL_VERSION);
        printf("EGL %d.%d vendor=%s\n", major, minor, eglQueryString(display, EGL_VENDOR));
        printf("GL_RENDERER=%s\n", renderer ? renderer : "(unavailable)");
        printf("GL_VERSION=%s\n", version ? version : "(unavailable)");
        fflush(stdout);
        if (renderer && (strstr(renderer, "Mali400") || strstr(renderer, "Mali-400")))
            passed = draw_scene();
        else
            fprintf(stderr, "A hardware Mali-400 renderer is required\n");
    }
    if (eglGetCurrentContext() != EGL_NO_CONTEXT)
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (surface != EGL_NO_SURFACE)
        eglDestroySurface(display, surface);
    if (context != EGL_NO_CONTEXT)
        eglDestroyContext(display, context);
    eglTerminate(display);
    fflush(stdout);
    return passed;
}

static int show_scene(void)
{
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        fprintf(stderr, "Cannot open the PocketBook X11 session\n");
        return 0;
    }
    int screen = DefaultScreen(display);
    Visual *visual = DefaultVisual(display, screen);
    if (visual->class != TrueColor || visual->red_mask != 0xff0000 ||
        visual->green_mask != 0xff00 || visual->blue_mask != 0xff) {
        fprintf(stderr, "The demo expects the PocketBook RGB888 visual\n");
        XCloseDisplay(display);
        return 0;
    }
    XImage *image = XCreateImage(display, visual, DefaultDepth(display, screen),
                                 ZPixmap, 0, NULL, width, height, 32, 0);
    if (!image || !(image->data = calloc(height, image->bytes_per_line))) {
        if (image)
            XDestroyImage(image);
        XCloseDisplay(display);
        return 0;
    }
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const unsigned char *p = &pixels[((height - 1 - y) * width + x) * channels];
            XPutPixel(image, x, y, ((unsigned)p[0] << 16) | ((unsigned)p[1] << 8) | p[2]);
        }
    }
    Window window = XCreateSimpleWindow(display, RootWindow(display, screen),
        0, 0, width, height, 0, BlackPixel(display, screen), WhitePixel(display, screen));
    Atom close = XInternAtom(display, "WM_DELETE_WINDOW", False);
    Atom protocols = XInternAtom(display, "WM_PROTOCOLS", False);
    XSetWMProtocols(display, window, &close, 1);
    XStoreName(display, window, "Mali-400 / Lima GLES2");
    XSelectInput(display, window, ExposureMask | KeyPressMask);
    XMapWindow(display, window);
    for (;;) {
        XEvent event;
        XNextEvent(display, &event);
        if (event.type == Expose && event.xexpose.count == 0) {
            XWindowAttributes attrs;
            XGetWindowAttributes(display, window, &attrs);
            XPutImage(display, window, DefaultGC(display, screen), image, 0, 0,
                      (attrs.width - width) / 2, (attrs.height - height) / 2, width, height);
            XSync(display, False);
            puts("GPU readback presented to X11 for the E-Ink renderer");
            fflush(stdout);
        }
        if ((event.type == ClientMessage && event.xclient.message_type == protocols &&
             (Atom)event.xclient.data.l[0] == close) ||
            (event.type == KeyPress && XLookupKeysym(&event.xkey, 0) == XK_Escape))
            break;
    }
    XDestroyImage(image);
    XCloseDisplay(display);
    return 1;
}

int main(int argc, char **argv)
{
    int verify_only = argc == 2 && strcmp(argv[1], "--verify-only") == 0;
    if (argc != 1 && !verify_only) {
        fprintf(stderr, "Usage: %s [--verify-only]\n", argv[0]);
        return EXIT_FAILURE;
    }
    return render() && (verify_only || show_scene()) ? EXIT_SUCCESS : EXIT_FAILURE;
}
