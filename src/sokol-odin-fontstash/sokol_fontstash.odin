package sokol_fontstash

import "../math"
import sg "sokol/gfx"
import fs "vendor:fontstash" // Adjust based on your binding location

FontContext :: struct {
  pipeline:    sg.Pipeline,
  bindings:    sg.Bindings,
  atlas_img:   sg.Image,
  fons:        ^fs.Context,

  // We'll use a dynamic buffer or a large fixed one for quads
  vertices:    [4096]math.Vertex,
  curr_vertex: i32,
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
}

init_font_system :: proc(ctx: ^FontContext)
{
  params := fs.Params {
    width        = 512,
    height       = 512,
    flags        = u8(fs.Flags.ZERO_TOPLEFT),
    userPtr      = ctx,
    renderCreate = render_create,
    renderUpdate = render_update,
    renderDraw   = render_draw,
  }

  ctx.fons = fs.CreateInternal(&params)

  // Create your shader and pipeline here
  // Ensure your shader expects a 1-channel (R8) texture for the atlas
  shader := sg.make_shader(text_shader_desc())

  pip_desc := sg.Pipeline_Desc {
    shader = shader,
    // ... set up vertex attributes for Position, UV, and Color
  }
  ctx.pipeline = sg.make_pipeline(pip_desc)
}

// The Shader: Your vertex shader needs to handle vec2 positions and vec2 UVs.
//     Your fragment shader should sample the R8 texture and use the value as the alpha channel for your text color.

// Update Image: The sg.update_image for a sub-rectangle in Sokol can be tricky.
//     Most people simply update the entire atlas if the performance hit is negligible, or they use sg.append_buffer for the vertex data.

// Coordinate System: Fontstash uses pixel coordinates.
//     You'll need to pass an Ortho Matrix (Projection) to your shader so the text maps correctly to your square/screen.

