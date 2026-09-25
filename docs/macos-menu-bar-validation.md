# macOS menu bar validation

The relay has a native AppKit menu bar interface and Settings window. Native
builds, signed installation, and basic installed UI checks passed on 2026-09-25.
Installed restart checks exposed an AppKit registration failure and a 30-second
LaunchAgent throttle. Both have fixes and native regression coverage described
below. The user confirmed that installed Save and Restart now works, the icon
returns promptly, and Settings opens afterward. Unchecked cases below
remain required for full acceptance; synthetic settings tests do not establish
every Settings interaction.

## Implemented behavior

- `serve --menu-bar` starts the interface and relay in one process. The packaged
  LaunchAgent selects this mode. Plain `serve`, diagnostics, and permission
  subprocesses remain headless.
- Opening the app with no arguments starts the menu and shows Settings. Reopening
  an existing menu instance asks it to reveal Settings. The relay lock prevents a
  second service for the same state directory.
- AppKit runs on the main thread. Startup, status reads, and configuration I/O run
  off that thread. Status refreshes every 250 milliseconds for the first five
  seconds, then every two seconds, including while tracking the menu, with at
  most one outstanding refresh. The icon does not wait for backend readiness.
- The menu icon is an 18-point vector template derived from the existing bridge
  mark. A monochrome exclamation mark indicates warnings. The app's full-color
  ICNS remains its Finder icon.
- Healthy status uses one summary row. The detail row appears only when it has
  additional information, such as startup progress or a permission error.
- Settings edits the listener, certificate identity, Contacts phone region, and
  credential/device-list paths. The GUI and `save-config` command share the same
  Zig validation and secure file replacement backend.
- Saving validates the proposed configuration and credentials before replacement,
  checks the original bytes for conflicting edits, writes a private temporary
  file, synchronizes it, and renames it over the destination. A failed directory
  sync is reported as saved with a durability warning, without automatic restart.
  The conflict check is optimistic; external editors do not participate in a lock.
- Save and Restart and Restart Relay start a fresh process. Installed services
  restart through `launchctl kickstart`, retaining LaunchAgent supervision with a
  one-second minimum launch interval. Manual
  launches preserve their original arguments and wait for the old process to
  exit before acquiring its lock. Existing journal recovery handles interrupted
  work; this is not a graceful drain of active requests.
- Startup errors keep the interface available. A failed listener does not appear
  healthy merely because ingestion threads are still running.
- Quit Relay sits below Restart Relay. Installed services use `launchctl bootout`
  to remove the current job, preventing an immediate `KeepAlive` relaunch while
  preserving the plist and login startup. Manual launches exit. A rejected stop
  leaves the app running with an error and re-enables its controls. Quit is
  disabled during settings I/O or restart.

Certificate issuance, enrollment, editing device-list entries, and a login-startup
switch are outside this version. An existing headless instance must be stopped
and relaunched with the menu option. Manual app launches
do not install a service. Installed services can also be stopped with the service
helper; its `start` command restores supervision after quitting.

## Completed on Linux

Validated using Zig 0.16.0 and the pinned OpenSSL 3.5 build:

| Check | Result |
| --- | --- |
| `zig build relay fake-relay test -Dopenssl-prefix=/absolute/openssl-3.5` | 101 tests passed, 1 skipped; native Objective-C is excluded on Linux |
| Native callback ABI and status tests in `Menu.zig` | Passed through the Zig suite; covers startup failure without a core, bounded output, readiness, stale ingestion, and expiry |
| `python3 tests/relay_settings.py` | 9 tests passed |
| `python3 tests/relay_tls.py` | 11 tests passed |
| `python3 tests/integration.py` | Passed, including journal persistence, recovery, idempotency, and reconnect |
| `python3 tests/mac_release.py` | 7 tests passed; packaging uses mocked Apple commands |
| Formatting, whitespace, and service-helper shell syntax | Passed |
| Monochrome SVG rendering | Inspected an enlarged raster preview; native template rendering remains pending |

The settings tests exercise the actual save backend through the fixture relay:
valid changes pass subsequent startup validation; invalid configuration or
credentials preserve the original bytes and inode; stale snapshots preserve
external edits; missing, malformed, and empty files can be repaired; unsafe
permissions, symlink paths, hard links, and non-regular destinations are rejected.
All certificates and databases in these tests are disposable synthetic fixtures.
The network suites require localhost sockets and normal filesystem ownership;
sandbox restrictions can prevent their fixtures from running.

## Native evidence (2026-09-25)

Validated source `c7ae52a4c33efb1af21836ad5d794f349b156beb` plus the SDK
framework-path, AppKit restart, and startup corrections in this validation change.
Environment: Apple Silicon arm64,
macOS 27.0 (26A428), macOS SDK 27.0, Zig 0.16.0, static OpenSSL 3.5.8,
and Python with OpenSSL 3.5.8/TLS 1.3 and cryptography 46.0.7.
The installed build uses ReleaseSafe, `aarch64-macos.27.0`, and `apple_m1`.
Signing reused the existing persistent local identity; this was not a notarized
public release.

| Check | Observed result |
| --- | --- |
| Native Debug relay, fake relay, `test`, and `test-macos-enrichment` | Passed; 33 passed/1 skipped in the fixture suite and 34 passed in the native suite |
| Documented ReleaseFast `aarch64-macos`, `apple_m1` build | Failed before the framework-path correction; passed unchanged after it |
| ReleaseSafe `aarch64-macos.27.0`, `apple_m1` build and both Zig suites | Passed; 67 passed, 1 skipped |
| `tests/relay_settings.py` | 9 passed against the fixture executable; the same 9 passed with the suite's `BIN` set to the native ReleaseSafe executable |
| `tests/relay_tls.py`, `tests/integration.py` | 11 TLS tests passed; integration passed including restart, recovery, and idempotency |
| `tests/mac_release.py`, `tests/mac_acceptance_test.py` | 7 packaging tests and 5 acceptance-helper tests passed |
| `tests/mac_enrichment_packaging.py` | Native disposable staging/signature check passed |
| Persistent signing and validation archive | Original designated requirement preserved; app and helper verified; archive manifest and extracted deep/strict signature verified |
| Installed bundle and process | Build UUIDs and signed bytes match the staged build; running executable inode matches; exactly one listener |
| Installed state after upgrade | Server epoch, all pre-upgrade message IDs, and send associations preserved against the installer's journal backup |
| Installed readiness | Authenticated status reports reading, sending capability, Contacts, and media ready; no degraded reasons |
| Installed no-send doctor through Launch Services | Messages readable, Automation ready, Contacts authorized |
| Native restart regression | Original implementation fails with lost AppKit registration; corrected implementation passes two restarts each from direct, Launch Services, and isolated LaunchAgent launches, plus native parent-exit handoff checks |
| Restart latency regression | Installer-generated LaunchAgent reproduces the 30-second delay before correction; Restart Relay and Save and Restart pass after reducing the interval to one second |
| Startup status regression | Two-second polling fails the subsecond readiness update check; startup polling passes and returns to the lower steady cadence |
| Installed startup timing, three warm restarts | AppKit finished launching in 0.07–0.12 seconds; Messages reading ready in 0.28–0.29 seconds, sending capability in 0.42–0.65 seconds, Contacts reconciliation in 2.27–3.56 seconds; journal epoch preserved |
| Installed restart fix | Installed with the existing signing identity; AppKit again registers exactly one application with the supervised PID |
| Installed Save and Restart manual recheck | User confirmed the restart works, the icon returns promptly, and Settings opens afterward |
| Native Quit Relay checks | Direct and Launch Services launches exit; installer-configured disposable KeepAlive jobs unload and stay stopped beyond the restart interval; the same job can start again without changing its plist or enablement; stop rejection restores usable controls |
| Basic manual UI checks | User confirmed one bridge icon, no Dock icon, a single Settings window, edits preserved on reopening, and continued service after closing |
| Formatting and service-helper shell syntax | Passed |

The explicit-target build initially failed because the SDK framework directory
was added with `addFrameworkPath`. Apple header warnings became fatal under the
project's `-Werror`. Both the relay and image helper now use
`addSystemFrameworkPath`; warnings-as-errors remain enabled for project sources.
The exact previously failing build passed after that change.

The user reported that Restart Relay did not work. Although the old `execv`
implementation restored the HTTPS listener, AppKit reported its running-process
identifier as `-1`; backend recovery did not establish interface recovery. A disposable app using the
production restart method reproduced this without account data. The unchanged
regression fails against the original method and passes after the fix. Its
assertions check AppKit registration, a visible status item, an active refresh
timer, original arguments including spaces, and repeated restarts. A separate
synthetic native check verifies waiting for a live parent, handling an already
exited parent, and rejecting an invalid PID.

The fix deliberately changes the restart contract: the PID changes, while
LaunchAgent ownership, configuration, and journal identity persist. Installed
services request `launchctl kickstart -k`; manual replacements start in a new
session with old descriptors closed and wait for parent exit before startup.
Tests create and remove their own uniquely named LaunchAgent; they never use the
installed service or account data. Run them after building the native relay:

```sh
python3 tests/mac_menu_restart.py
# For a separate build prefix:
python3 tests/mac_menu_restart.py --relay /absolute/build/bin/relay
```

The initial restart test omitted the installed job's `KeepAlive` and
`ThrottleInterval` settings. Using the actual installer-generated configuration
reproduced a stalled restart. Two consecutive external installed restarts also
measured a 29-second wait, establishing that `kickstart` still observes the launch
throttle. Both installer paths now use one second instead of 30; regenerating
the LaunchAgent is required to apply this change. The regression exercises
Restart Relay followed by Settings' Save and Restart using disposable callbacks,
requires fresh registered processes within five seconds, and preserves the
earlier registration and argument checks. Configuration validation itself is
covered separately by the native settings suite.

The status regression first supplies a startup snapshot and then readiness. It
requires the menu to display the new status within 900 milliseconds and verifies
that polling slows after startup. Both latency regressions failed before their
corresponding fixes and passed afterward without changing the assertions.

Installed timing uses a ready AppKit observer before each restart and authenticated
read-only status requests. AppKit's finished-launch signal is not a visual timing
measurement of the menu bar. These are warm restarts of an existing journal, not
cold-login or first-import benchmarks. Reading and sending recover before optional
Contacts reconciliation completes. No credential or durability checks were removed.

Installation used the documented installer with the tested ReleaseSafe binaries
and existing credentials. The installer backed up the journal before replacing
the application. The local validation archive used the shared staged bundle and
release manifest validator, with a dirty-source revision marker; it was not
published or produced by the clean-checkout public-release command.

Permission attribution was checked through the running LaunchAgent and a fresh
`open -n -W -a /path/to/Zimbr\ Relay.app --args doctor --check-automation` launch.
Direct invocation from the validation terminal reported `DatabaseUnavailable`
and Contacts `not_determined`; that launch context does not establish the app's
permission state. The Launch Services invocation reported all three grants.
No validation command sent a real message or requested a new permission grant.

Private logs, build output, aggregate snapshots, and the validation archive are
kept outside this public record. Accessibility automation was unavailable and
the user chose manual UI checks. No screenshot, VoiceOver, appearance matrix,
permission-revocation, logout/reboot, or two-host delivery result is claimed.

## Native build and packaging gate

Use an Apple Silicon Mac with the supported macOS release, Zig 0.16.0, Apple's
Command Line Tools, target OpenSSL 3.5 static archives, and Python with TLS 1.3 and
the repository's TLS dependencies. Use generic local paths appropriate to the
machine; never commit deployed endpoints or credentials to this record.

```sh
zig build relay fake-relay test test-macos-enrichment \
  -Dopenssl-prefix=/absolute/openssl-3.5
python3 tests/relay_settings.py
python3 tests/relay_tls.py
python3 tests/integration.py
python3 tests/mac_release.py
python3 tests/mac_menu_restart.py
zig fmt --check build.zig src
```

- [x] Compile `src/relay/menu.m` with the build's warnings-as-errors flags. Resolve
  SDK selector, availability, ARC, and framework-link errors before installation.
- [x] Repeat the native build with the deployed optimization/CPU options from
  [the relay guide](macos-relay.md#build-and-test).
- [x] Stage using the documented signing/install flow and provisioned synthetic
  credentials where possible. Verify the bundle signature and nested image helper.
- [x] Confirm `Contents/Resources/statusTemplate.pdf` is included in the signed
  bundle and a locally validated distribution-format archive, `LSUIElement`
  remains true, and the installer produces `serve --menu-bar` in
  `ProgramArguments`. The service helper contains the same arguments; its
  installed stop/start check remains below.
- [x] Run `tests/mac_enrichment_packaging.py` with its documented build/license
  prerequisites. The script stages an app and checks the PDF and bundle metadata;
  it does not establish installed permission attribution.
- [x] Preserve the installed signing identity and verify Full Disk Access,
  Automation, and Contacts attribution after upgrading.

## Appearance and interaction

- [x] Launch the installed service. Exactly one bridge icon appears without a
  Dock icon (manual confirmation).
- [ ] Confirm a fresh service launch does not open Settings unsolicited.
- [ ] Inspect light and dark appearances, a selected/open menu, light and dark
  wallpapers, and available display scales. The bridge and warning mark remain
  monochrome, legible, centered, and unclipped at their actual size.
- [ ] Trigger a warning using disposable configuration. Inspect the exclamation
  mark and tooltip. Verify the icon returns to normal when readiness recovers.
- [x] Open Settings repeatedly. Only one window appears and visible edits are
  preserved (manual confirmation); one relay listener was independently checked.
- [ ] Reopen through Finder and `open -n` to exercise Launch Services, the
  distributed reopen notification, and the single-service lock.
- [x] Close Settings and verify service continues (manual confirmation).
- [ ] Modify a disposable configuration externally while Settings is closed and
  verify reopening reloads the current file.
- [ ] Check field labels with VoiceOver, keyboard navigation, Return to save, and
  standard copy/paste/select-all/undo shortcuts. Check advanced-section layout,
  long paths, file-picker cancellation, and readable validation messages.
- [ ] Hold the menu open during a readiness change. Status must update, and the
  UI must stay responsive while history ingestion or validation is busy.
- [ ] Open Logs from an installed service and check the expected log opens.
  A manual Terminal launch must explain if no installed service log exists.

## Settings and startup recovery

Use a disposable profile for destructive error cases. Preserve the original
configuration and credentials before installed acceptance checks.

- [ ] Change the port to an available port and save. Confirm mode 0600, the old
  listener closes, the new listener opens, and clients reconnect after their
  endpoint configuration is updated. The server epoch and message history stay
  unchanged.
- [ ] Change only the Contacts phone region and save. Check that the running
  relay reports the new region after restart. Blank remains an explicit choice;
  no region is chosen automatically.
- [ ] Use the advanced file pickers with paths containing spaces. Verify the
  selected paths are stored correctly and credential files are never copied into
  the app bundle or rewritten by Settings.
- [ ] Reject a malformed IP, wildcard address, port outside 1–65535, unsupported
  phone region, mismatched key, expired certificate, and wrong server identity.
  The existing file and running relay must remain unchanged after rejection.
- [ ] Modify the configuration externally while Settings is open, then save.
  The app must report the conflict and preserve the external edit. Reload warns
  before discarding edits; after reloading, a valid save succeeds.
- [ ] Start with missing, malformed, and empty configuration. The menu stays
  present; Settings can supply a complete valid configuration and restart. With
  unsafe file/directory permissions, editing stays disabled until repaired and
  reloaded. No credentials are silently generated.
- [ ] Open a file with unsupported JSON entries. Confirm the notice that saving
  removes those entries, and verify the resulting configuration passes validation.
- [ ] Occupy the proposed port with another process. A valid save can still fail
  at listener startup: the UI must report the error, remain usable, and allow the
  previous port to be restored. There is no automatic configuration rollback.
- [ ] If practical, inject disk-full or synchronization failures on a disposable
  volume. Before rename, the original must survive. After a directory-sync
  failure, the app must say the file was saved and avoid claiming it was rejected.

## Permissions and lifecycle

- [ ] Check Permissions reports current Messages reading/sending readiness and
  Contacts authorization. Its System Settings action opens a usable privacy page.
  When all three are ready, it shows “Permissions are all set” with only **OK**;
  missing or unchecked access retains the setup actions.
- [ ] Request Contacts through the dialog. The prompt must belong to the installed
  signed app. Test allow and deny; closing the permission subprocess must not
  replace, stop, or create another relay. Contacts remains optional.
- [ ] Test missing Full Disk Access and Messages Automation, then grant access and
  restart. Status must distinguish unavailable reading from unavailable sending.
  Confirm no permission check sends a message.
- [x] Use Save and Restart in installed Settings; confirm the icon returns
  promptly and Settings opens afterward (manual confirmation).
- [ ] Complete repeated Restart Relay and Save and Restart lifecycle checks under
  LaunchAgent supervision.
  Verify a fresh supervised PID starts, the lock is reacquired, old network
  descriptors do not survive, and there is exactly one listener. Repeat several
  times, including with an active authenticated SSE stream.
- [ ] Repeat restart for a manual app launch and an explicit command-line
  `serve --menu-bar` with custom paths. Preserve the original arguments and do not
  accidentally register or start an additional LaunchAgent.
- [ ] Verify normal startup after logout/login and reboot/login; the settings
  window should stay closed for service launches. Check screen lock separately
  from logout, using the existing [Mac validation procedure](mac-validation.md).
- [ ] Stop via the service helper. Both the listener and icon disappear and stay
  stopped. Reinstall/update through the normal flow and verify menu startup again.
- [ ] Choose Quit Relay in the installed menu. Confirm the icon and listener
  disappear and stay stopped. Open the app to run it again manually, then quit
  and use the service helper to restore supervision. Check the next login still
  starts the installed service.
- [ ] Run the existing installed two-host acceptance checks, including one
  deliberately authorized send, reconnect, Contacts/media, and journal recovery.
  Never use a real conversation for an automatic fault-injection send.

## Recording acceptance

Replace pending checkboxes only after observing them on the installed build.
Record the commit/build identifier, macOS and SDK versions, architecture,
optimization mode, signing mode, relevant command results, and screenshots of
light/dark/selected/warning icons and Settings. Redact account information, paths,
endpoints, and credential material. Note every remaining failure or skipped case;
Linux success and a staged signature do not establish native UI acceptance.
