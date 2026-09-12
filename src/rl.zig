pub const c = @cImport({
    @cDefine("GRAPHICS_API_OPENGL_33", "1");
    @cInclude("raylib.h");
    @cInclude("raymath.h");
    @cInclude("rlgl.h");
});
