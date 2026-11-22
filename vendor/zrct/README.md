# Zrct for Zimbr

This is the SDL instrumentation and runner from the zrct 0.1.0 checkout previously
referenced as a sibling package. Zimbr carries this snapshot so a release archive
includes the same GUI harness as a development checkout. Changes for Zig 0.17
include translated SDL and POSIX bindings, make-time tool paths, and runner
argument forwarding. The Python dependency lock and native tool manifests pin
the test environment.

Use the [Zimbr GUI build steps](../../docs/development.md#gui-scenarios-with-zrct)
for end-to-end tests. The [skill](SKILL.md), [protocol](docs/protocol.md), and
[benchmark guide](docs/benchmarking.md) describe the runner. The standalone
`test`, `zrct`, `python`, and `desktop` build steps are also available from
this directory. Zimbr's own SDL build supplies the matching headers and library.
