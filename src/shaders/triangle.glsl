@header package shaders
@header import sg "shared:sokol/gfx"

@ctype mat4 Mat4

@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
};

in vec4 pos;
in vec2 texcoord0;
out vec2 uv;

void main() {
    gl_Position = mvp * pos;
    // hmm...
    #if SOKOL_GLSL
    uv = vec2(texcoord0.x, 1.0f - texcoord0.y);
    #else
    uv = texcoord0;
    #endif
}
@end

@fs fs
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
in vec2 uv;
out vec4 frag_color;

void main() {
    frag_color = texture(sampler2D(tex, smp), uv);
}
@end

@program debugtext_context vs fs
