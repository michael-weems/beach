@header package shaders
@header import sg "sokol:gfx"

@ctype mat4 Mat4

@vs vs
layout(binding=0) uniform Quad_Vs_Params {
    mat4 mvp;
};

in vec3 pos0;
in vec2 uv0;
in vec4 color0;

out vec4 color;
out vec2 texcoord;

void main() {
    gl_Position = mvp * vec4(pos0, 1);
    color = color0;
    texcoord = uv0;
}
@end

@fs fs
in vec4 color;
in vec2 texcoord;

layout(binding=0) uniform texture2D quad_tex;
layout(binding=0) uniform sampler quad_smp;

out vec4 frag_color;

void main() {
    frag_color = texture(sampler2D(quad_tex, quad_smp), texcoord) * color;
}
@end

@program quad vs fs
