package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"

import sapp "sokol:app" // Change to your actual binding path
import sg "sokol:gfx" // Change to your actual binding path
import sgl "sokol:gl" // Change to your actual binding path
import sglue "sokol:glue"
import slog "sokol:log"
import fs "vendor:fontstash" // Change to your actual binding path

Vertex :: struct {
  pos: [2]f32,
  uv:  [2]f32,
  col: [4]f32,
}

Global :: struct {
  dpi_scale:   f32,
  font_ctx:    fs.FontContext,
  font_id:     int,
  font_img:    sg.Image,
  pipeline:    sg.Pipeline,
  pass_action: sg.Pass_Action,
  bindings:    sg.Bindings,
}

g: Global

round_pow2 :: proc(v: f32) -> int
{
  vi: u32 = u32(v) - 1
  for i := u32(0); i < 5; i = i + 1 {
    vi |= (vi >> (i << i))
  }
  return (int)(vi + 1)
}

init :: proc "c" ()
{
  context = runtime.default_context()
  g.dpi_scale = sapp.dpi_scale()
  sg.setup({environment = sglue.environment(), logger = {func = slog.func}})
  sgl.setup({logger = {func = slog.func}})

  atlas_dim := round_pow2(512.0 * g.dpi_scale)

  fs.Init(&g.font_ctx, 512, 512, .TOPLEFT)
  font_data := #load("../assets/fonts/Geometra.ttf")
  g.font_id = fs.AddFontMem(&g.font_ctx, "sans", font_data, false, 0)
  g.font_img = sg.make_image(sg.Image_Desc{usage = {stream_update = true}})

  // 2. Create a Vertex Buffer
  // odinfmt: disable
    vertices := [?]f32{
        // x, y, z, color
        0.0,  0.5, 0.5,  1.0, 0.0, 0.0, 1.0,
        0.5, -0.5, 0.5,  0.0, 1.0, 0.0, 1.0,
       -0.5, -0.5, 0.5,  0.0, 0.0, 1.0, 1.0,
    }
  // odinfmt: enable

  g.bindings.vertex_buffers[0] = sg.make_buffer(
    {data = {ptr = &vertices, size = size_of(vertices)}},
  )

  indices := [?]u16{0, 1, 2}
  g.bindings.index_buffer = sg.make_buffer(
    {usage = {index_buffer = true}, data = {ptr = &indices, size = size_of(indices)}},
  )

  // TODO: follow some examples from sokol


}

frame :: proc "c" ()
{
  context = runtime.default_context()

  vertices := make([dynamic]Vertex, context.temp_allocator)

  // Draw the text // TODO: do this outside the render pass?
  // TODO: clear text texture
  // TODO:
  fs.ClearState(&g.font_ctx) // TODO: clear text texture

  sgl.defaults()
  sgl.matrix_mode_projection()
  sgl.ortho(0.0, sapp.widthf(), sapp.heightf(), 0.0, -1.0, 1.0)

  if (g.font_id != fs.INVALID) {
    fs.SetFont(&g.font_ctx, g.font_id) // TODO: set font
    fs.SetSize(&g.font_ctx, 48.0) // TODO: set  font size
    fs.SetColor(&g.font_ctx, {255, 255, 255, 255}) // set font color
    ascender, descender, line_height := fs.VerticalMetrics(&g.font_ctx)

    quad: fs.Quad
    iter := fs.TextIterInit(&g.font_ctx, 100, 100, "yee")
    for fs.TextIterNext(&g.font_ctx, &iter, &quad) {
      // 'quad' now contains the data for the current character:
      // Screen Positions: quad.x0, quad.y0 (top-left) to quad.x1, quad.y1 (bottom-right)

      char_color := [4]f32{1, 1, 1, 1} // Default white

      // Example: Highlight the first letter of every word
      if iter.codepointCount == 1 {
        char_color = {1, 0, 0, 1} // Red
      }

      // Example: Rainbow effect using the character index
      char_color.r = abs(math.sin(f32(iter.codepointCount) * 0.5))

      // Apply char_color to the 4 vertices of this quad
      // ...

      // Standard 6-vertex quad (two triangles: TL-TR-BR, TL-BR-BL)
      v0 := Vertex{{quad.x0, quad.y0}, {quad.s0, quad.t0}, char_color}
      v1 := Vertex{{quad.x1, quad.y0}, {quad.s1, quad.t0}, char_color}
      v2 := Vertex{{quad.x1, quad.y1}, {quad.s1, quad.t1}, char_color}
      v3 := Vertex{{quad.x0, quad.y1}, {quad.s0, quad.t1}, char_color}

      append(&vertices, v0, v1, v2, v0, v2, v3) // Texture UVs:      quad.s0, quad.t0 (top-left) to quad.s1, quad.t1 (bottom-right)

    }
  }

  img_data := sg.Image_Data {
    mip_levels = {
      0 = {ptr = &g.font_ctx.textureData, size = c.size_t(g.font_ctx.width * g.font_ctx.height)},
    },
  }

  sg.update_image(g.font_img, img_data)

  /*
SOKOL_API_IMPL void sfons_flush(FONScontext* ctx) {
    SOKOL_ASSERT(ctx && ctx->params.userPtr);
    _sfons_t* sfons = (_sfons_t*) ctx->params.userPtr;
    if (sfons->img_dirty) {
        sfons->img_dirty = false;
        sg_image_data data;
        _sfons_clear(&data, sizeof(data));
        data.mip_levels[0].ptr = ctx->texData;
        data.mip_levels[0].size = (size_t) (sfons->cur_width * sfons->cur_height);
        sg_update_image(sfons->img, &data);
    }

*/


  sg.begin_pass(
    {action = g.pass_action, swapchain = sglue.swapchain()}, // TODO: draw text?
  ) // TODO: setup render pass
  // TODO: use the docs from sokol, they have step-by-step guides.
  // TODO: fontstash can render into a texture anytime during the frame
  // TODO: gfx renders
  // TODO: gl applies opengl 1.x-style render API over-top of gfx
  // TODO: so:
  // TODO: setup the images in init, then in the frame callback, render text (anywhere), and render
  // TODO: everything else in a separate pass
  //           font-stash somehow stores off the font with AddFont, then you can just draw into a
  //           ?common? texture every frame. ? does it make sense to have multiple textures here to render text into for different parts of the UI? or just one texture for the whole UI? I assume 1 texture per ui-element?

  // Upload to Sokol (assuming a dynamic vertex buffer)
  sg.update_buffer(
    g.bindings.vertex_buffers[0],
    {ptr = &vertices[0], size = len(vertices) * size_of(Vertex)},
  )

  sg.draw(0, len(vertices), 1)


  // TODO: draw square texture?

  sg.end_pass()
  sg.commit()

  free_all(context.temp_allocator)
}

/*
   // multi-line strings

line_height: f32
fontstash.vertical_metrics(stash, nil, nil, &line_height)

current_y := start_y
for line in strings.split_lines(multi_line_string) {
    fontstash.text_iter(stash, &iter, start_x, current_y, line, font_size)
    
    for fontstash.TextIterNext(stash, &iter, &quad) {
        // ... build vertices as shown above ...
    }
    
    current_y += line_height // Move down to next line
}
   */

main :: proc()
{
  sapp.run(
    {
      init_cb = init,
      frame_cb = frame,
      width = 800,
      height = 600,
      window_title = "Sokol + Odin + Fontstash",
    },
  )
}

