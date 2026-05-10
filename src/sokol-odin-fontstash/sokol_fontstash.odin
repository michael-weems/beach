package sokol_fontstash

import "../math"
import sg "sokol:gfx"
import fs "vendor:fontstash" // Adjust based on your binding location

// TODO: move this somewhere better
FONT_DATA :: #load("assets/fonts/Geometra.ttf")

FontContext :: struct {
  pipeline:    sg.Pipeline,
  bindings:    sg.Bindings,
  atlas_img:   sg.Image,
  fons:        ^fs.Context,

  // We'll use a dynamic buffer or a large fixed one for quads
  vertices:    [4096]math.Vertex,
  curr_vertex: i32,
}

TextVertex :: struct {
  pos: [2]f32,
  uv:  [2]f32,
  col: u32,
}

text_shader_desc :: proc() -> sg.Shader_Desc
{
  // Note: Use 'desc.attrs' to match your vertex struct
  desc: sg.Shader_Desc
  desc.attrs[0].name = "position"
  desc.attrs[1].name = "texcoord0"
  desc.attrs[2].name = "color0"

  desc.vs.uniform_blocks[0].size = size_of(f32) * 16 // One Mat4 (MVP)
  desc.vs.uniform_blocks[0].uniforms[0].name = "mvp"
  desc.vs.uniform_blocks[0].uniforms[0].type = .MAT4

  desc.fs.images[0].name = "tex"
  desc.fs.images[0].image_type = ._2D

  // Minimal GLSL 330 Shader Strings
  desc.vs.source = `
        #version 330
        uniform mat4 mvp;
        layout(location=0) in vec2 position;
        layout(location=1) in vec2 texcoord0;
        layout(location=2) in vec4 color0;
        out vec2 uv;
        out vec4 color;
        void main() {
            gl_Position = mvp * vec4(position, 0.0, 1.0);
            uv = texcoord0;
            color = color0;
        }
    `
  desc.fs.source = `
        #version 330
        uniform sampler2D tex;
        in vec2 uv;
        in vec4 color;
        out vec4 frag_color;
        void main() {
            // Sample R channel from atlas and use as alpha
            float alpha = texture(tex, uv).r;
            frag_color = vec4(color.rgb, color.a * alpha);
        }
    `
  return desc
}

// Called when fontstash needs to create the atlas texture
render_create :: proc "c" (user_ptr: rawptr, width, height: i32) -> i32
{
  ctx := (^FontContext)(user_ptr)

  img_desc := sg.Image_Desc {
    width        = width,
    height       = height,
    usage        = .DYNAMIC, // We will update this as fonts load
    pixel_format = .R8, // Alpha only is usually enough
  }
  ctx.atlas_img = sg.make_image(img_desc)
  ctx.bindings.fs_images[0] = ctx.atlas_img
  return 1
}

// Called when a new glyph is added to the texture
render_update :: proc "c" (user_ptr: rawptr, rect: ^i32, data: ^u8)
{
  ctx := (^FontContext)(user_ptr)

  // rect is [x0, y0, x1, y1]
  x := rect[0]
  y := rect[1]
  w := rect[2] - rect[0]
  h := rect[3] - rect[1]

  // Use sg.update_image to push the new pixels to the GPU
  update_desc := sg.Image_Data{}
  update_desc.subimage[0][0] = {
    ptr  = data,
    size = u64(w * h),
  }
  // Note: This requires a custom offset/pitch if updating a sub-rect
  // Simplified: many just re-upload the whole atlas or use specific sub-image updates
  sg.update_image(ctx.atlas_img, update_desc)
}

// Called when fontstash is ready to draw a batch of quads
render_draw :: proc "c" (user_ptr: rawptr, verts, tcoords: ^f32, colors: ^u32, nverts: i32)
{
  ctx := (^FontContext)(user_ptr)

  // 1. Convert incoming raw pointers to Odin slices
  // 2. Map them to your ctx.vertices buffer
  // 3. Call sg.apply_pipeline(ctx.pipeline)
  // 4. Call sg.apply_bindings(ctx.bindings)
  // 5. Call sg.draw(0, nverts, 1)

  if nverts == 0 do return

  // 1. Prepare vertex data
  // We create a slice from the raw pointers for easier handling
  v_ptr := cast(^f32)verts
  t_ptr := cast(^f32)tcoords
  c_ptr := cast(^u32)colors

  // Create a temporary buffer for this draw call
  // In a real app, use a pre-allocated sg.Buffer for performance
  temp_verts := make([]TextVertex, nverts, context.temp_allocator)

  for i in 0 ..< nverts {
    temp_verts[i] = {
      pos = {v_ptr[i * 2], v_ptr[i * 2 + 1]},
      uv  = {t_ptr[i * 2], t_ptr[i * 2 + 1]},
      col = c_ptr[i],
    }
  }

  // 2. Update Sokol Vertex Buffer
  // Assuming ctx.bindings.vertex_buffers[0] is created with .STREAM or .DYNAMIC
  sg.update_buffer(
    ctx.bindings.vertex_buffers[0],
    {ptr = raw_data(temp_verts), size = u64(nverts * size_of(TextVertex))},
  )

  // 3. Apply and Draw
  sg.apply_pipeline(ctx.pipeline)
  sg.apply_bindings(ctx.bindings)

  // Pass the MVP matrix (usually an Ortho matrix for 2D)
  // sg.apply_uniforms(.VS, 0, { ptr = &my_ortho_matrix, size = 64 })

  sg.draw(0, nverts, 1)
}

init_font_system :: proc(ctx: ^FontContext, width: i32, height: i32)
{
  params := fs.Params {
    width        = width,
    height       = height,
    flags        = u8(fs.Flags.ZERO_TOPLEFT),
    userPtr      = ctx,
    renderCreate = render_create,
    renderUpdate = render_update,
    renderDraw   = render_draw,
  }

  font_id := fs.AddFontMem(ctx.fons, "embedded", raw_data(FONT_DATA), i32(len(FONT_DATA)), 0)

  ctx.fons = fs.CreateInternal(&params)

  // Create your shader and pipeline here
  // Ensure your shader expects a 1-channel (R8) texture for the atlas
  shader := sg.make_shader(text_shader_desc())

  pip_desc := sg.Pipeline_Desc {
    shader     = shader,
    index_type = .NONE,
    // ... set up vertex attributes for Position, UV, and Color
  }
  pip_desc.colors[0].blend = {
    enabled          = true,
    src_factor_rgb   = .SRC_ALPHA,
    dst_factor_rgb   = .ONE_MINUS_SRC_ALPHA,
    src_factor_alpha = .ONE,
    dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
  }

  // Vertex Layout
  pip_desc.layout.attrs[0].format = .FLOAT2 // position
  pip_desc.layout.attrs[1].format = .FLOAT2 // texcoord0
  pip_desc.layout.attrs[2].format = .UBYTE4N // color0 (Normalized)

  ctx.pipeline = sg.make_pipeline(pip_desc)


}

draw_text :: proc(ctx: ^FontContext, font_id: i32)
{
  fs.ClearState(ctx.fons)
  fs.SetFont(ctx.fons, font_id)
  fs.SetSize(ctx.fons, 32.0)
  fs.SetColor(ctx.fons, 0xffffffff)
  fs.SetAlignVertical(ctx.fons, .TOP)
  fs.SetAlignHorizontal(ctx.fons, .LEFT)

  fs.DrawText(ctx.fons, 10, 10, "Hello Odin!", nil)
  fs.EndState(ctx)
}

// The Shader: Your vertex shader needs to handle vec2 positions and vec2 UVs.
//     Your fragment shader should sample the R8 texture and use the value as the alpha channel for your text color.

// Update Image: The sg.update_image for a sub-rectangle in Sokol can be tricky.
//     Most people simply update the entire atlas if the performance hit is negligible, or they use sg.append_buffer for the vertex data.

// Coordinate System: Fontstash uses pixel coordinates.
//     You'll need to pass an Ortho Matrix (Projection) to your shader so the text maps correctly to your square/screen.

