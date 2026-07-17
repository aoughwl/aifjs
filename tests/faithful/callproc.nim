import std/syncio
proc bump(x: int64): int64 = x + 1'i64
proc addup(a: int64, b: int64): int64 = a + b
var n: int64 = 9223372036854775800'i64
echo bump(n)
echo bump(5'i64)
echo addup(n, 3'i64)
var c: int32 = 40'i32
echo bump(int64(c))
