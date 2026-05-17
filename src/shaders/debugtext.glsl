@header package shaders
@header import sg "sokol:gfx"

@ctype mat4 Mat4

@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
};

in vec3 pos;
in vec4 color0;
in vec2 uv;

out vec4 color;
out vec2 texcoord;

void main() {
    gl_Position = mvp * vec4(pos, 1);
    color = color0;
    texcoord = uv;
}
@end

@fs fs
in vec4 color;
in vec2 texcoord;

layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;

out vec4 frag_color;

void main() {
    frag_color = texture(sampler2D(tex, smp), texcoord) * color;
}
@end

@program dbgtext vs fs
