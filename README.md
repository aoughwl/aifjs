# aifjs

The **nimony-native** `.s.nif` → **native-JavaScript** backend.

`aifjs` reads a typed nimony NIF (`.s.nif`) and emits **real JavaScript** — mapping
nimony values onto native JS values (`int`/`float` → number, `string` → string,
`seq` → Array, object → plain object) so the browser's JIT compiles the result.
Near-native speed, readable output.

It is written **in nimony**, the way the rest of the toolchain is (`aifparser`,
`aifsem`, `aifi`, `lengcgen`) — not hand-written in JavaScript. That's the point:
aifjs belongs *inside* the ecosystem, and once nimony can compile it, aifjs can
compile **itself**.

> **Two repos, on purpose.**
> - **`aoughwl/aifjs`** (this one) — the nimony implementation. The real one.
> - **[`aoughwl/aifjs-js`](https://github.com/aoughwl/aifjs-js)** — the original
>   hand-written **JavaScript** implementation. It's the **bootstrap seed** and
>   the differential oracle: it works today, powers the playground's *Native JS*
>   engine, and is what compiles *this* nimony version the first time.

## The one idea

`aifjs` is **[`aifi`](https://github.com/aoughwl/aifi) with the interpreter
swapped for a JavaScript emitter.** aifi is already a nimony program that loads a
`.s.nif` (`parseFromBuffer` → `beginRead` → a `Cursor`) and walks it with a
`case n.tagEnum` dispatch (`execStmt`/`execIf`/`execWhile`/`execCall`/…). aifjs
reuses that entire, tested front-end and changes each handler from *"do the
thing"* to *"append the JavaScript"*:

```
aifi:   of IfTagId:   result = execIf(ip, n)       # run the branch
aifjs:  of IfTagId:   emitIf(e, n)                 # print `if(cond){…}`
```

So we don't re-solve NIF reading, symbol resolution, or the type model — we
inherit them from aifi and write only the emitter.

## Bootstrap — how it self-hosts

```
1. seed:   aoughwl/aifjs-js  (hand-written JS)   .s.nif ─▶ native JS   [works today]
2. write:  aoughwl/aifjs     (this, in nimony)   .s.nif ─▶ native JS
3. compile aifjs.nim with nimony               → aifjs.s.nif
4. run aifjs.s.nif through the JS seed          → a fast, native-JS aifjs   ← self-hosted
```

After step 4 the JS seed is disposable: aifjs compiles itself, `aifparser`,
`aifsem`, and your programs — all to fast native JS, all from nimony source.

**Prerequisite the seed still needs:** to transpile *this* (a nimony program that
uses `Table`/`Cursor`/etc.), the JS seed must cover those. `Table` → JS `Map` is
the main remaining item on the seed; the language surface is otherwise complete.

## Status

**Seed / WIP.** `src/emitjs.nim` holds the emitter skeleton (the tag dispatch,
modeled on aifi's `interp.nim`) and `src/webmain_js.nim` the browser entry
(modeled on aifi's `webmain.nim`). It reuses aifi's front-end, so it builds
alongside a aifi checkout — see the source headers.

## License

MIT — see [LICENSE](LICENSE).
