package wav

import "core:testing"

TEST_SAMPLE_RATE :: i32(1000)

compute_test_edges :: proc(w: ^Wav) -> Edges {
  return compute_edges(w, context.allocator)
}

make_test_wav :: proc(frame_count: int, channels: i16 = 1) -> (Wav, []f32) {
  sample_count := frame_count * int(channels)
  samples := make([]f32, sample_count, context.allocator)
  w := Wav {
    channels    = channels,
    frequency   = TEST_SAMPLE_RATE,
    num_samples = i32(sample_count),
    samples_raw = samples,
    edge_params = default_edge_params(),
  }
  return w, samples
}

delete_test_edges :: proc(edges: ^Edges) {
  delete(edges.leading)
  delete(edges.trailing)
}

fill_frames :: proc(samples: []f32, channels: i16, start_frame, end_frame: int, amplitude: f32) {
  channel_count := int(channels)
  for frame in start_frame ..< end_frame {
    for channel in 0 ..< channel_count {
      samples[frame * channel_count + channel] = amplitude
    }
  }
}

expect_paired_sorted_edges :: proc(t: ^testing.T, edges: ^Edges) {
  testing.expect_value(t, len(edges.leading), len(edges.trailing))

  pair_count := min(len(edges.leading), len(edges.trailing))
  for i in 0 ..< pair_count {
    testing.expect(
      t,
      edges.leading[i] < edges.trailing[i],
      "leading edge must precede trailing edge",
    )
  }

  if len(edges.leading) > 1 {
    for i in 1 ..< len(edges.leading) {
      testing.expect(t, edges.leading[i - 1] < edges.leading[i], "leading edges must be sorted")
    }
  }
  if len(edges.trailing) > 1 {
    for i in 1 ..< len(edges.trailing) {
      testing.expect(t, edges.trailing[i - 1] < edges.trailing[i], "trailing edges must be sorted")
    }
  }
}

@(test)
compute_edges_silent_buffer_has_no_edges :: proc(t: ^testing.T) {
  w, samples := make_test_wav(240)
  defer delete(samples)

  edges := compute_test_edges(&w)
  defer delete_test_edges(&edges)

  testing.expect_value(t, len(edges.leading), 0)
  testing.expect_value(t, len(edges.trailing), 0)
  expect_paired_sorted_edges(t, &edges)
}

@(test)
compute_edges_single_burst_produces_one_pair :: proc(t: ^testing.T) {
  w, samples := make_test_wav(240)
  defer delete(samples)
  fill_frames(samples, w.channels, 80, 160, 1.0)

  edges := compute_test_edges(&w)
  defer delete_test_edges(&edges)

  testing.expect_value(t, len(edges.leading), 1)
  testing.expect_value(t, len(edges.trailing), 1)
  expect_paired_sorted_edges(t, &edges)

  if len(edges.leading) == 1 && len(edges.trailing) == 1 {
    testing.expect(
      t,
      edges.leading[0] >= 60 && edges.leading[0] <= 80,
      "leading edge should land near burst onset",
    )
    testing.expect(
      t,
      edges.trailing[0] >= 150 && edges.trailing[0] <= 170,
      "trailing edge should land near burst offset",
    )
  }
}

@(test)
compute_edges_keeps_separated_events_sorted_and_paired :: proc(t: ^testing.T) {
  w, samples := make_test_wav(360)
  defer delete(samples)
  fill_frames(samples, w.channels, 80, 130, 1.0)
  fill_frames(samples, w.channels, 220, 270, 1.0)

  edges := compute_test_edges(&w)
  defer delete_test_edges(&edges)

  testing.expect_value(t, len(edges.leading), 2)
  testing.expect_value(t, len(edges.trailing), 2)
  expect_paired_sorted_edges(t, &edges)
}

@(test)
compute_edges_debounces_nearby_flicker_into_one_region :: proc(t: ^testing.T) {
  w, samples := make_test_wav(240)
  defer delete(samples)
  fill_frames(samples, w.channels, 60, 90, 1.0)
  fill_frames(samples, w.channels, 110, 140, 1.0)

  edges := compute_test_edges(&w)
  defer delete_test_edges(&edges)

  testing.expect_value(t, len(edges.leading), 1)
  testing.expect_value(t, len(edges.trailing), 1)
  expect_paired_sorted_edges(t, &edges)
}

@(test)
compute_edges_detects_moderate_events_despite_one_loud_outlier :: proc(t: ^testing.T) {
  w, samples := make_test_wav(560)
  defer delete(samples)
  fill_frames(samples, w.channels, 0, 560, 0.01)
  fill_frames(samples, w.channels, 60, 110, 0.2)
  fill_frames(samples, w.channels, 180, 230, 0.2)
  fill_frames(samples, w.channels, 320, 370, 1.0)
  fill_frames(samples, w.channels, 430, 480, 0.2)

  edges := compute_test_edges(&w)
  defer delete_test_edges(&edges)

  testing.expect_value(t, len(edges.leading), 4)
  testing.expect_value(t, len(edges.trailing), 4)
  expect_paired_sorted_edges(t, &edges)
}

@(test)
compute_edges_k_values_change_resolved_thresholds :: proc(t: ^testing.T) {
  w, samples := make_test_wav(240)
  defer delete(samples)
  fill_frames(samples, w.channels, 0, 240, 0.01)
  fill_frames(samples, w.channels, 80, 160, 1.0)

  low_k_edges := compute_edges_with_params(&w, context.allocator, 0.2, 0.1)
  defer delete_test_edges(&low_k_edges)

  high_k_edges := compute_edges_with_params(&w, context.allocator, 1.1, 0.8)
  defer delete_test_edges(&high_k_edges)

  testing.expect(
    t,
    low_k_edges.t_high_db < high_k_edges.t_high_db,
    "higher K_HIGH should raise t_high_db",
  )
  testing.expect(
    t,
    low_k_edges.t_low_db < high_k_edges.t_low_db,
    "higher K_LOW should raise t_low_db",
  )
}

@(test)
edge_navigation_is_strict_and_returns_minus_one_at_bounds :: proc(t: ^testing.T) {
  w := Wav{}
  w.edges.leading = make([dynamic]i32, context.allocator)
  w.edges.trailing = make([dynamic]i32, context.allocator)
  defer delete(w.edges.leading)
  defer delete(w.edges.trailing)

  append(&w.edges.leading, 10, 40, 100)
  append(&w.edges.trailing, 20, 60, 120)

  testing.expect_value(t, next_leading(&w, 9), 10)
  testing.expect_value(t, next_leading(&w, 10), 40)
  testing.expect_value(t, next_leading(&w, 100), -1)
  testing.expect_value(t, next_trailing(&w, 19), 20)
  testing.expect_value(t, next_trailing(&w, 20), 60)
  testing.expect_value(t, next_trailing(&w, 120), -1)
  testing.expect_value(t, prev_leading(&w, 10), -1)
  testing.expect_value(t, prev_leading(&w, 11), 10)
  testing.expect_value(t, prev_leading(&w, 101), 100)
}

@(test)
mark_edges_dirty_retains_old_edges_and_advances_generation :: proc(t: ^testing.T) {
  w := Wav{}
  w.edges.leading = make([dynamic]i32, context.allocator)
  w.edges.trailing = make([dynamic]i32, context.allocator)
  defer delete(w.edges.leading)
  defer delete(w.edges.trailing)
  append(&w.edges.leading, 10, 40)
  append(&w.edges.trailing, 20, 60)
  w.edges.dirty = false
  w.edge_status = .Ready
  w.edge_generation = 7

  mark_edges_dirty(&w)

  testing.expect(t, w.edges.dirty)
  testing.expect_value(t, len(w.edges.leading), 2)
  testing.expect_value(t, len(w.edges.trailing), 2)
  testing.expect_value(t, w.edge_status, Edge_Status.Uncomputed)
  testing.expect_value(t, w.edge_generation, 8)
}

@(test)
two_stage_compute_matches_combined :: proc(t: ^testing.T) {
  w, samples := make_test_wav(360)
  defer delete(samples)
  fill_frames(samples, w.channels, 80, 130, 1.0)
  fill_frames(samples, w.channels, 220, 270, 1.0)

  params := default_edge_params()

  combined := compute_edges(&w, context.allocator)
  defer delete_test_edges(&combined)

  analysis := compute_edge_analysis(&w, params, context.allocator)
  defer delete(analysis.env_db, context.allocator)
  staged := classify_edges(&analysis, params, context.allocator)
  defer delete_test_edges(&staged)

  testing.expect_value(t, len(staged.leading), len(combined.leading))
  testing.expect_value(t, len(staged.trailing), len(combined.trailing))
  testing.expect_value(t, staged.t_high_db, combined.t_high_db)
  testing.expect_value(t, staged.t_low_db, combined.t_low_db)
  expect_paired_sorted_edges(t, &staged)
}

@(test)
classify_only_reuses_analysis_with_different_k :: proc(t: ^testing.T) {
  w, samples := make_test_wav(240)
  defer delete(samples)
  fill_frames(samples, w.channels, 0, 240, 0.01)
  fill_frames(samples, w.channels, 80, 160, 1.0)

  params := default_edge_params()
  analysis := compute_edge_analysis(&w, params, context.allocator)
  defer delete(analysis.env_db, context.allocator)

  low_params := params
  low_params.k_high = 0.2
  low_params.k_low = 0.1
  low_edges := classify_edges(&analysis, low_params, context.allocator)
  defer delete_test_edges(&low_edges)

  high_params := params
  high_params.k_high = 1.1
  high_params.k_low = 0.8
  high_edges := classify_edges(&analysis, high_params, context.allocator)
  defer delete_test_edges(&high_edges)

  testing.expect(
    t,
    low_edges.t_high_db < high_edges.t_high_db,
    "higher K_HIGH should raise t_high_db from same analysis",
  )
  testing.expect(
    t,
    low_edges.t_low_db < high_edges.t_low_db,
    "higher K_LOW should raise t_low_db from same analysis",
  )
  expect_paired_sorted_edges(t, &low_edges)
  expect_paired_sorted_edges(t, &high_edges)
}

// ─── Section discovery tests ─────────────────────────────────────

make_test_analysis :: proc(env_db: []f32) -> Edge_Analysis {
  return Edge_Analysis{
    env_db       = env_db,
    sample_rate  = 44100,
    hop_frames   = 441,
    win_frames   = 882,
    total_frames = i32(len(env_db)) * 441,
  }
}

expect_sections_cover_file :: proc(t: ^testing.T, sections: []Edge_Section, num_hops: i32) {
  if len(sections) == 0 do return
  testing.expect_value(t, sections[0].start_hop, 0)
  testing.expect_value(t, sections[len(sections) - 1].end_hop, num_hops)
  for i in 1 ..< len(sections) {
    testing.expect(
      t,
      sections[i].start_hop == sections[i - 1].end_hop,
      "sections must be contiguous",
    )
  }
}

@(test)
discover_sections_uniform_file_one_section :: proc(t: ^testing.T) {
  hops := 3000
  env := make([]f32, hops, context.allocator)
  defer delete(env, context.allocator)
  for i in 0 ..< hops {
    env[i] = -30.0
  }
  analysis := make_test_analysis(env)

  sections := discover_sections(&analysis, default_edge_params(), context.allocator)
  defer delete(sections)

  testing.expect_value(t, len(sections), 1)
  expect_sections_cover_file(t, sections[:], i32(hops))
}

@(test)
discover_sections_two_distinct_regions :: proc(t: ^testing.T) {
  hops := 3000
  env := make([]f32, hops, context.allocator)
  defer delete(env, context.allocator)
  for i in 0 ..< hops {
    if i < 1500 do env[i] = -40.0
    else do env[i] = -20.0
  }
  analysis := make_test_analysis(env)

  sections := discover_sections(&analysis, default_edge_params(), context.allocator)
  defer delete(sections)

  testing.expect(t, len(sections) >= 2, "should detect the 20dB floor shift")
  expect_sections_cover_file(t, sections[:], i32(hops))
}

@(test)
discover_sections_short_file_one_section :: proc(t: ^testing.T) {
  hops := 500
  env := make([]f32, hops, context.allocator)
  defer delete(env, context.allocator)
  for i in 0 ..< hops {
    env[i] = -30.0
  }
  analysis := make_test_analysis(env)

  sections := discover_sections(&analysis, default_edge_params(), context.allocator)
  defer delete(sections)

  testing.expect_value(t, len(sections), 1)
  expect_sections_cover_file(t, sections[:], i32(hops))
}

@(test)
discover_sections_three_regions :: proc(t: ^testing.T) {
  hops := 4000
  env := make([]f32, hops, context.allocator)
  defer delete(env, context.allocator)
  for i in 0 ..< hops {
    if i < 1200 do env[i] = -40.0
    else if i < 2800 do env[i] = -15.0
    else do env[i] = -40.0
  }
  analysis := make_test_analysis(env)

  sections := discover_sections(&analysis, default_edge_params(), context.allocator)
  defer delete(sections)

  testing.expect(t, len(sections) >= 3, "should detect two 25dB floor shifts")
  expect_sections_cover_file(t, sections[:], i32(hops))
}

@(test)
fit_section_params_suppresses_low_iqr_sections :: proc(t: ^testing.T) {
  section := Edge_Section{
    stats = Section_Stats{ q25_db = -40, q75_db = -39, iqr_db = 1, q10_db = -41, q90_db = -38 },
    params = default_edge_params(),
  }
  fit_section_params(&section, default_edge_params())

  testing.expect(t, section.params.k_high >= 1.5, "low IQR section should get high K to suppress edges")
  testing.expect(t, section.auto_fit)
}

@(test)
fit_section_params_uses_standard_k_for_normal_iqr :: proc(t: ^testing.T) {
  base := default_edge_params()
  section := Edge_Section{
    stats = Section_Stats{ q25_db = -40, q75_db = -30, iqr_db = 10, q10_db = -45, q90_db = -20 },
    params = base,
  }
  fit_section_params(&section, base)

  testing.expect(t, section.params.k_high <= base.k_high, "normal IQR with wide range should get standard or lower K")
  testing.expect(t, section.auto_fit)
}

@(test)
per_section_classify_produces_edges_in_section_range :: proc(t: ^testing.T) {
  w, samples := make_test_wav(360)
  defer delete(samples)
  fill_frames(samples, w.channels, 80, 130, 1.0)
  fill_frames(samples, w.channels, 220, 270, 1.0)

  params := default_edge_params()
  analysis := compute_edge_analysis(&w, params, context.allocator)
  defer delete(analysis.env_db, context.allocator)

  sections := discover_sections(&analysis, params, context.allocator)
  defer delete_all_sections(&sections)

  fit_and_classify_sections(sections[:], &analysis, params, context.allocator)
  merged := merge_section_edges(sections[:], context.allocator)
  defer delete_test_edges(&merged)

  testing.expect(t, len(merged.leading) > 0, "should find edges via per-section classify")
  testing.expect_value(t, len(merged.leading), len(merged.trailing))

  for l in merged.leading {
    testing.expect(t, l >= 0 && l < analysis.total_frames, "leading edge in valid range")
  }
  for tr in merged.trailing {
    testing.expect(t, tr >= 0 && tr < analysis.total_frames, "trailing edge in valid range")
  }
}
