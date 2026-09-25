# macOS menu bar validation handoff

The relay now has a native AppKit menu bar interface and Settings window. This
record separates checks completed on Linux from work to pick up on a Mac.
**Native compilation and installed UI behavior have not been validated.**

## Implemented behavior

- `serve --menu-bar` starts the interface and relay in one process. The packaged
  LaunchAgent selects this mode. Plain `serve`, diagnostics, and permission
  subprocesses remain headless.
- Opening the app with no arguments starts the menu and shows Settings. Reopening
  an existing menu instance asks it to reveal Settings. The relay lock prevents a
  second service for the same state directory.
- AppKit runs on the main thread. Startup, status reads, and configuration I/O run
  off that thread. Status refreshes every two seconds, including while tracking
  the menu, with at most one outstanding refresh.
- The menu icon is an 18-point vector template derived from the existing bridge
  mark. A monochrome exclamation mark indicates warnings. The app's full-color
  ICNS remains its Finder icon.
- Settings edits the listener, certificate identity, Contacts phone region, and
  credential/device-list paths. The GUI and `save-config` command share the same
  Zig validation and secure file replacement backend.
- Saving validates the proposed configuration and credentials before replacement,
  checks the original bytes for conflicting edits, writes a private temporary
  file, synchronizes it, and renames it over the destination. A failed directory
  sync is reported as saved with a durability warning, without automatic restart.
  The conflict check is optimistic; external editors do not participate in a lock.
- Save and Restart and Restart Relay use `execv` with the existing arguments.
  LaunchAgent ownership remains with the same process. Existing journal recovery
  handles interrupted work; this is not a graceful drain of active requests.
- Startup errors keep the interface available. A failed listener does not appear
  healthy merely because ingestion threads are still running.

Certificate issuance, enrollment, editing device-list entries, a login-startup
switch, and a GUI Stop action are outside this version. An existing headless
instance must be stopped and relaunched with the menu option. Manual app launches
do not install a service. Installed services are stopped with the service helper.

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
zig fmt --check build.zig src
```

- [ ] Compile `src/relay/menu.m` with the build's warnings-as-errors flags. Resolve
  SDK selector, availability, ARC, and framework-link errors before installation.
- [ ] Repeat the native build with the deployed optimization/CPU options from
  [the relay guide](macos-relay.md#build-and-test).
- [ ] Stage using the documented signing/install flow and provisioned synthetic
  credentials where possible. Verify the bundle signature and nested image helper.
- [ ] Confirm `Contents/Resources/statusTemplate.pdf` is included in the signed
  bundle and public archive, `LSUIElement` remains true, and the installer and
  service helper both produce `serve --menu-bar` in `ProgramArguments`.
- [ ] Run `tests/mac_enrichment_packaging.py` with its documented build/license
  prerequisites. The script stages an app and checks the PDF and bundle metadata;
  it does not establish installed permission attribution.
- [ ] Preserve the installed signing identity and verify Full Disk Access,
  Automation, and Contacts attribution after upgrading.

## Appearance and interaction

- [ ] Launch the installed service. Exactly one bridge icon appears, without a
  Dock icon or an unsolicited Settings window.
- [ ] Inspect light and dark appearances, a selected/open menu, light and dark
  wallpapers, and available display scales. The bridge and warning mark remain
  monochrome, legible, centered, and unclipped at their actual size.
- [ ] Trigger a warning using disposable configuration. Inspect the exclamation
  mark and tooltip. Verify the icon returns to normal when readiness recovers.
- [ ] Open Settings repeatedly from the menu and by reopening the app in Finder.
  Only one window and one relay listener exist. Include `open -n` to exercise the
  distributed reopen notification and single-service lock.
- [ ] Close Settings and verify synchronization continues. Reopening reloads the
  current file. Clicking Settings while it is already visible preserves edits.
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
- [ ] Request Contacts through the dialog. The prompt must belong to the installed
  signed app. Test allow and deny; closing the permission subprocess must not
  replace, stop, or create another relay. Contacts remains optional.
- [ ] Test missing Full Disk Access and Messages Automation, then grant access and
  restart. Status must distinguish unavailable reading from unavailable sending.
  Confirm no permission check sends a message.
- [ ] Restart from the menu and after saving under LaunchAgent supervision.
  Verify the same supervised PID is replaced, the lock is reacquired, old network
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
