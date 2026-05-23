@header package shaders
@header import sg "sokol:gfx"
@ctype mat4 Mat4

@vs vs
layout(binding=0) uniform Text_Vs_Params {
    mat4 mvp;
};

in vec2 pos0;
in vec2 uv0;
in vec4 color0;

out vec2 uv;
out vec4 color;

void main() {
    gl_Position = mvp * vec4(pos0, 0.0, 1.0);
    uv = uv0;
    color = color0;
}
@end

@fs fs
layout(binding=0) uniform texture2D text_tex;
layout(binding=0) uniform sampler   text_smp;
in vec2 uv;
in vec4 color;
out vec4 frag_color;

void main() {
   // Atlas is R8: red channel holds glyph coverage, use as alpha
   float alpha = texture(sampler2D(text_tex, text_smp), uv).r;
   frag_color = vec4(color.rgb, color.a * alpha);
}
@end

@program text vs fs
