# $dir, $source, $history (newline-separated, newest last). One CLI response on stdin.
.result.layout | select(.zoomed == false) | .panes as $p |
($p[] | select(.pane_id == $source) | .rect) as $s |
def touches($c):
  if   $dir == "right" then $c.x == $s.x + $s.width  and $c.y < $s.y + $s.height and $s.y < $c.y + $c.height
  elif $dir == "left"  then $c.x + $c.width == $s.x  and $c.y < $s.y + $s.height and $s.y < $c.y + $c.height
  elif $dir == "down"  then $c.y == $s.y + $s.height and $c.x < $s.x + $s.width  and $s.x < $c.x + $c.width
  else                      $c.y + $c.height == $s.y and $c.x < $s.x + $s.width  and $s.x < $c.x + $c.width
  end;
[$p[] | select(.pane_id != $source and touches(.rect)) | .pane_id] as $e |
first(($history | split("\n") | reverse)[] | select(IN($e[])))
