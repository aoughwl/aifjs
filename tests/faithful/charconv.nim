import std/syncio
proc bump(x: int64): int64 = x + 1'i64
echo bump(5)
var ch: char = 'A'
echo int(ch)
var s = "hi"
echo int(s[0])
