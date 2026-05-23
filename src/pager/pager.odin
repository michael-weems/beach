package pager

pager :: struct {
  active_index:  int,
  paging_index:  int,
  total_entries: int,
}

set_index :: proc(p: ^pager, index: int) -> (prev: int, new: int) {
  prev = p.paging_index
  new = index

  if new < 1 {
    for new < 1 do new += p.total_entries
  } else if new > p.total_entries {
    for new > p.total_entries do new -= p.total_entries
  }

  p.paging_index = new
  return prev, new
}

select :: proc(p: ^pager) -> (prev: int, new: int) {
  prev = p.active_index
  new = p.paging_index
  p.active_index = new
  return prev, new
}

next :: proc(p: ^pager) -> (prev: int, new: int) {
  prev = p.paging_index

  new = p.paging_index + 1
  if new > p.total_entries do new = 1

  p.paging_index = new
  return prev, new
}
prev :: proc(p: ^pager) -> (prev: int, new: int) {
  prev = p.paging_index

  new = p.paging_index - 1
  if new < 1 do new = p.total_entries

  p.paging_index = new
  return prev, new
}

jump :: proc(p: ^pager, by: int) -> (prev: int, new: int) {
  prev = p.paging_index
  new = p.paging_index + by

  if new < 1 {
    for new < 1 do new += p.total_entries
  } else if new > p.total_entries {
    for new > p.total_entries do new -= p.total_entries
  }

  p.paging_index = new
  return prev, new
}

last :: proc(p: ^pager) -> (prev: int, new: int) {
  prev = p.paging_index

  new = p.total_entries

  p.paging_index = new
  return prev, new
}
first :: proc(p: ^pager) -> (prev: int, new: int) {
  prev = p.paging_index

  new = 1

  p.paging_index = new
  return prev, new
}

