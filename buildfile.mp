-- buildfile

seq =
  [1]: "cynosure"
  [2]: "refinement"

build = (dir) ->
  log "err", "building sub-project ", dir
  io.write assert ex "cd", dir, "; ../build"

_G.main = () ->
  log "err", "Assembling ULOS"
  for dir in *seq
    build dir
  log "err", "ULOS assembled"
