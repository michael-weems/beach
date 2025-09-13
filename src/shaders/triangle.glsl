@header package shaders
@header import sg "shared:sokol/gfx"

@ctype mat4 Mat4

@vs vs
layout(binding=0) uniform Vs_Params {
    mat4 mvp;
};

in vec3 position;
in vec4 color0;
in vec2 uv;

out vec4 color;
out vec2 texcoord;

void main() {
    gl_Position = mvp * vec4(position, 1);
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

@program triangle vs fs
