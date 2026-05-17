@header package shaders
@header import sg "sokol:gfx"

@ctype mat4 Mat4

@vs vs
layout(binding=0) uniform Triangle_Vs_Params {
    mat4 mvp;
};

in vec3 triangle_pos;
in vec4 triangle_color0;
in vec2 triangle_uv;

out vec4 tri_color;
out vec2 tri_texcoord;

void main() {
    gl_Position = mvp * vec4(triangle_pos, 1);
    tri_color = triangle_color0;
    tri_texcoord = triangle_uv;
}
@end

@fs fs
in vec4 tri_color;
in vec2 tri_texcoord;

layout(binding=0) uniform texture2D triangle_tex;
layout(binding=0) uniform sampler triangle_smp;

out vec4 frag_color;

void main() {
    frag_color = texture(sampler2D(triangle_tex, triangle_smp), tri_texcoord) * tri_color;
}
@end

@program triangle vs fs
