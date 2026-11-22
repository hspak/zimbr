# Migrating Zimbr from Zig 0.16 to 0.17

Zimbr now pins Zig **0.17.1** for the Linux client and macOS relay. The original
upgrade probe found that both the project build and the sibling zrct build failed
to configure, and 29 source files used the removed array repetition syntax.
The checklist below records the port. [0.17.0 release notes](https://ziglang.org/download/0.17.0/release-notes.html) ·
[0.17.1 release announcement](https://ziglang.org/news/0.17.1-released/)

## Validation on 2026-11-21

| Host | Checks and results |
| --- | --- |
| Arch Linux x86-64 | 241 Zig tests passed, one skipped. Client and relay integration, seven HTTP/2 tests, all 29 GUI workflows, native and SDL desktop tests, and all four Korean IME scenarios passed. Warm-cache builds detected both the presence and absence of IBus. |
| Apple Silicon, macOS 27.0.1, SDK 27.0 | Both relay variants built. 157 native tests passed, three skipped. Enrichment, HTTP/2, mutual TLS, integration, and menu restart checks passed. The production target built for Apple M1, and a change in the SDK path reached the compiler with a warm cache. |
| Release tools | The Arch source archive built with a fresh package cache and passed its checks. The Mac release builder signed the app with the existing local identity, verified the extracted signature, and validated the archive manifest, helper, and license files. All 29 Python packaging tests passed. |
| Rendering | The 0.16.0 reference and migrated safe builds each ran all nine Vulkan workloads with 100 measured frames per workload on the same headless Weston and Lavapipe setup. The migrated OpenGL and Vulkan report and startup benchmark also passed. |

The Arch host's default libcurl used OpenSSL 4. At the time of the migration
the Linux client required OpenSSL 3, so the integration and GUI checks used an OpenSSL 3 build
of libcurl. The local Arch artifact was built with curl 8.23.0 and OpenSSL
3.6.5. Its packaged executable opened a Wayland window and synced all four
fixture conversations over mutual TLS. The macOS archive identifies the
temporary source snapshot used for local signing.

## 1. Make the build graph configure on both hosts

- [x] Change `std.builtin.OptimizeMode` to `std.lang.Optimize` in the root build script,
  `build/sdl.zig`, and `build/nghttp2.zig`. Fix `optimize != .Debug` in the SDL build
  to use `.debug` so optimized C builds still define `NDEBUG`. The corresponding CLI
  values are `-Doptimize=debug|safe|fast|small`. The existing `--release=safe` works.
  Keep the independent `-Dprofile=dev|release` choice for relay identity, ports and storage.
- [x] In `build.zig`, replace the `std.meta.fields(RelayProfile)` loop with an
  `inline for` over `@typeInfo(RelayProfile).@"struct".field_names` and `field_types`
  in parallel. Use the name for both the generated `relay_` option and `@field`, and
  the corresponding type for `addOption`. This loop configures *both* relay profiles.
- [x] In `client`, call `run.addPassthruArgs()`. In `addGuiSuites`, remove all uses of
  `b.args` in suite options. Append passthrough args once to each final runner command,
  after its fixed suite and fixture arguments. Cover the isolated native suite, SDL desktop,
  application, recovery, content, benchmark and IME entry points. A filter after `--`
  must reach the selected suite, including when a previous run populated the configure cache.
- [x] Coordinate a 0.17-compatible zrct revision or checkout. The manifest declares
  `../zrct`; the probe compiled its build script even with the default GUI options.
  Port its own `b.args`, `.Debug`, `global_cache_root`, `cache_root`, `pathFromRoot`,
  and `LazyPath.getPath` uses. Its SDL host, input and engine also contain `@cImport`.
  Preserve the consumer's patched SDL linkage (`link_system_sdl = false`), the
  writable per-project Python environment, and lazy provisioning of native GUI tools.
- [x] Rework `build/gui.zig`. Pass the dependency's `.python-version` to provisioning
  as an input file and trim it when constructing the Python argument, or read the source
  during configuration and declare `b.dependOnFileContents`. Replace `b.getInstallPath`
  for `ZIMBR_LAVAPIPE_ROOT` with a make-time path passed to the launcher. Verify that
  the runner discovers the installed driver with a custom install prefix.
- [x] Audit configure-time inputs. SDL's `pkg-config` queries decide header flags, library
  versions and optional IBus support. The relay discovers its SDK with `xcrun` when no
  explicit SDK was supplied. Track inputs that determine these results, move discovery
  to make time where practical, or call `b.graph.poisonCache()` when the results cannot
  be tracked. A make-time header-check step cannot invalidate an already cached
  configuration. Verify changes to `PKG_CONFIG_PATH`, IBus availability and SDK selection
  take effect on a warm build. Keep Wayland XML, generated headers, the Vulkan patch and
  the generated SDL revision header wired as build inputs.
- [x] Check Run step path wrappers when touching those steps. In 0.17.1,
  `addFileArg`, `addOutputFileArg` and `addOutputDirectoryArg` still forward to the
  corresponding `*Arg2` methods with default options. Existing simple calls can stay.
  Build the SDL config header with its supplied values because all config-header styles
  now check for unused values.

[Build system changes](https://ziglang.org/download/0.17.0/release-notes.html#Build-System) ·
[Zimbr build graph](build.zig) · [SDL build](build/sdl.zig) · [GUI tool provisioning](build/gui.zig)

## 2. Replace all 13 C import blocks

- [x] Add the official `translate_c` dependency using
  `zig fetch --save 'git+https://codeberg.org/ziglang/translate-c#zig-0.17.x'`.
  Record the resolved revision and content hash in `build.zig.zon`. For each header
  group, use `@import("translate_c").Translator`, initialize it with the dependency,
  C header, target and optimization mode, then add `translator.mod` as a named import
  to each consuming module. Use a small wrapper header where a block includes several
  headers or needs a preprocessor directive. Keep shared C types in the same generated
  module wherever pointers or callbacks cross between Zig consumers.
- [x] Reproduce the actual translation environment. Give translators the project include
  paths, pinned SDL and nghttp2 headers, pkg-config inputs, target libc, and selected
  SDK or OpenSSL prefix wherever used. Wire generated-header dependencies explicitly.
  Preserve linkage of C and Objective-C implementations and static archives in the
  final binaries. Test translation with the target headers during cross compilation.

| Consumer | Bindings to supply |
| --- | --- |
| `src/common.zig` | `platform.h`, including SQLite and libc. Preserve the translation-only `_FORTIFY_SOURCE` workaround until the fortified declarations work with the selected translator. Keep fortification for compiled C. |
| `src/client/c.zig` | The client bridge, outgoing and drop headers. Supply this module to the headless client tests, probes and benchmarks as well as the GUI. |
| `src/client/desktop.zig`, `src/client_main.zig` | SDL3 and the desktop bridge. Reuse the SDL binding in the native GUI test that currently imports SDL locally. |
| `src/client/graphics.zig` | libpng declarations from `png.h`. |
| `src/relay/http2.zig` | The pinned nghttp2 header and its version header. Exercise the Zig callbacks against the linked static library. |
| `src/relay/Assets.zig`, `src/relay/uploads/Files.zig`, `src/relay/sends/{Handoff,observation}.zig` | Media, upload and errno declarations as required by each consumer. Share the media declarations. |
| `src/relay/Tls.zig`, `src/relay/Menu.zig` | Relay TLS and menu bridge headers. Compile both the fixture and native implementations on their supported targets. |
| `src/relay/Mutex.zig` | Translate `os/lock.h` only for macOS. Verify the unfair lock's initializer and ABI on Apple Silicon and the `std.Io.Mutex` path on Linux. |

Inventory command: `rg -n '@cImport|@cInclude|@cUndef|@cDefine' src`. Run it separately
on the selected zrct sources. [Upstream C translation migration](https://ziglang.org/download/0.17.0/release-notes.html#C-Translation-Moving-to-External-Package)

## 3. Port the Zig source

| Required change | Zimbr work |
| --- | --- |
| Remove array multiplication | Find all sites with `rg -n -F '**' src -g '*.zig'`. For a repeated element, supply the destination type, e.g. `const digest: [32]u8 = @splat(0x12);`. For a repeated word, UTF-8 sequence or pixel, copy the entire pattern into a flat array for each repetition. Preserve sentinel termination where a C API requires it. Keep the original counts, exact bytes and boundary sizes in the JSON depth, attachment, editor, rendering and benchmark fixtures. Fix syntax before relying on `zig fmt`. |
| Port field reflection | In `src/client/Store.zig`, iterate the **union's** field names and types together to decode and construct the correct incoming variant. In `src/client/outgoing.zig`, the **struct's** field names suffice to compare uploads. In `src/client_main.zig`, port `copyControl` to the new struct layout and account for the new `.spirv` tag in its exhaustive type switch. Preserve recursive ownership of copied strings. |
| Replace removed case-insensitive search | Use `std.ascii.findIgnoreCase` in `src/client/IdentityDirectory.zig` and both link-detection checks in `src/client/content.zig`. Verify mixed-case contact search and HTTP(S) link handling. |
| Replace removed buffer formatter | Replace `std.fmt.bufPrintZ(buf, fmt, args)` with `std.mem.printSentinel(buf, fmt, args, 0)`. This affects URL construction, worker and media paths, the disk cache, SQLite tests and the hot-path benchmark. Preserve the existing `NoSpaceLeft` behavior and trailing NUL. The tests in `src/protocol/url.zig` check both. |
| Fix held-key bitset initialization | In `src/client/desktop.zig` use `std.bit_set.Static(c.SDL_SCANCODE_COUNT)` and `.empty` for the declaration and both resets. Check that focus loss clears held input and lets rendering return to idle. |

**Deprecations that still compile on 0.17.1.** Use the same allocator for the move from
`std.fmt.allocPrint` and `allocPrintSentinel` to `allocator.print` and
`allocator.printSentinel`. Use `std.mem.print` for `bufPrint`. Replace legacy
`std.mem.indexOf*` aliases with their `find*` counterparts as those sites are touched.
Use the enum's reflected `field_names` in `src/client/Media.zig`. Run the 0.17 formatter
for `@intFromEnum` → `@backingInt`. Migrate `builtin.os` and `builtin.cpu` to
`builtin.target.os` and `builtin.target.cpu`, including the inline pixel-endianness test.
Use `builtin.optimize` for render-benchmark metadata and update consumers of its tag names.

**Changes that can silently affect behavior.** Check that optional HTTP/2 handler hooks
looked up by `@hasDecl` are public, especially `producedEnd` and `responseEnd` on
`Server.Connection`. A missed hook changes stream completion. The hot-path benchmark
also probes the public `Media.DiskCache`. The one project `@bitCast` in
`src/relay/adapter/body_parts.zig` reinterprets an integer byte as `i8`, which retains
its meaning. No project uses of the reordered `containsAtLeastScalar`, captured
`errdefer`, `void{}`, `i0`, runtime ZON parsing, or removed URI host getters turned up.
Recheck dependencies independently. [Language and standard library changes](https://ziglang.org/download/0.17.0/release-notes.html#Language-Changes)

## 4. Update the pin and release inputs together

- [x] Set `.zigversion` and `build.zig.zon.minimum_zig_version` to the selected and tested
  patch. In `packaging/linux/PKGBUILD.in`, change the compiler bounds to
  `zig>=0.17.1` and `zig<0.18` if adopting the proposed pin. Include the translator
  and its transitive packages in the preparation phase.
- [x] Update versioned Mac compiler discovery in `tools/update-relay.sh`,
  `packaging/macos/release.py`, `packaging/macos/remote.py` and `tests/mac_remote.py`.
  Derive the version from the revision being built where practical. Exercise both the
  default path and `ZIMBR_ZIG` override, including a detached release checkout.
- [x] Update optimization arguments in `release.sh`, the PKGBUILD, the Mac release builder
  and `tests/zrct/benchmarks.py`, including its recorded optimization label. Update
  active instructions, fixtures and contributor guidance in README, DESIGN, AGENTS,
  the development, Linux and Mac guides, the zrct README and the SDL vendor note.
  Search tracked files with `git grep -nE '0\.16|ReleaseSafe|ReleaseFast|ReleaseSmall|builtin\.mode'`.
  Keep dated validation results and benchmark measurements attributed to their original toolchain.
- [x] Exercise package fetching from an empty local package directory, then execute
  the Arch build and check phases with `--system zig-pkg`. In 0.17, plain `zig fetch`
  populates the global cache; `zig build` and saving a dependency can populate the local
  package directory. A warm developer checkout can mask an incomplete release archive.
  Verify production packaging works without a sibling zrct checkout, GUI tools or
  Apple-only dependencies on Linux. Check the conditional `ZrctBuild()` import against
  this case. A local sibling path worked far enough to compile zrct in the probe, but a
  URL-fetched package cannot depend on paths escaping its package root. If distributing
  the GUI-enabled graph as a dependency, use a pinned zrct package or an in-package path.

[Package management changes](https://ziglang.org/download/0.17.0/release-notes.html#Package-Management) ·
[Arch recipe](packaging/linux/PKGBUILD.in) · [Mac release builder](packaging/macos/release.py)

## 5. Verify the migration

Use fresh build and package caches for the first pass, then rerun with warm caches.
Set `OPENSSL_PREFIX` on each host to its **target** OpenSSL 3.5 static installation.
Before changing compilers, retain a 0.16 reference run for comparable rendering or
hot-path measurements. LLVM/Clang moves to 22.1.8 in 0.17.0 and Zig still disables LLVM
loop vectorization. Rebuild the C and Objective-C bridges with their existing warning flags.
[Toolchain changes](https://ziglang.org/download/0.17.0/release-notes.html#Toolchain)

**Linux x86-64** — build the headless and GUI paths separately so missing optional
dependencies and test-only compilation errors are visible.

```sh
zig version
zig fmt --check build.zig build.zig.zon build src
zig build --help
zig build client fake-relay client-probe test -Doptimize=safe -Dopenssl-prefix="$OPENSSL_PREFIX"
zig build client-desktop-probe gui-test-exe client-bench hotpath-bench render-bench -Doptimize=fast
python3 tests/integration.py
python3 tests/client_integration.py
python3 tests/relay_http2.py
zig build test-gui-isolated test-sdl-desktop -Ddesktop-tests=true -Dopenssl-prefix="$OPENSSL_PREFIX"
zig build test-zrct -Dautomation=true -Dopenssl-prefix="$OPENSSL_PREFIX" -- --filter send_unicode
zig build test-zrct-all -Dautomation=true -Dopenssl-prefix="$OPENSSL_PREFIX"
zig build test-ime -Dautomation=true -Dibus=true -Dopenssl-prefix="$OPENSSL_PREFIX"
```

Check both `-Dibus=false` and automatic detection on the production client. Exercise link
activation, clipboard, IME, file drops and focus loss through the real desktop tests.
Run the documented render workloads under matching compositor, driver, CPU target and
optimization settings. [GUI prerequisites and benchmark procedure](docs/development.md)

**Apple Silicon macOS** — use the selected Xcode SDK and the production release target.
Run native tests on the Mac even if a cross-build already passed.

```sh
zig build relay fake-relay test test-macos-enrichment -Dprofile=dev -Doptimize=safe -Dopenssl-prefix="$OPENSSL_PREFIX"
zig build macos-check -Dtarget=aarch64-macos.27.0 -Dcpu=apple_m1 -Dprofile=release \
  -Doptimize=safe -Dmacos-sdk="$(xcrun --sdk macosx --show-sdk-path)" -Dopenssl-prefix="$OPENSSL_PREFIX"
```

Verify static OpenSSL, nghttp2 and libPhoneNumber linkage, the image helper, Contacts
normalization and the signed menu-bar app under the existing deployment target. Use the
fixture relay for HTTP/2 and mutual TLS coverage. [Mac build and integration checks](docs/macos-relay.md) ·
[Menu-bar acceptance](docs/macos-menu-bar-validation.md)

**Release artifacts** — run `python3 tests/release.py`, `python3 tests/mac_release.py`
and `python3 tests/mac_remote.py`. Run `./release.sh <manifest-version> --check` on the
packaging host and build the Mac archive using the migrated builder. Inspect the packaged
client, app bundle, helpers and licenses, including any redistribution obligations from
the chosen translator. Record the compiler version, hosts and results with the migration.
[Linux packaging checks](docs/linux-packaging.md)
