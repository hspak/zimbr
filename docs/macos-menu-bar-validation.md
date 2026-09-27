# macOS menu bar validation

Repeat these checks on the installed build after changes to AppKit, settings,
packaging, or restart behavior. See [relay operation](macos-relay.md) for the
current UI contract and [setup](setup.md) for installation.

Use the checklist below for each build; keep results, screenshots, signing
identities and deployment details in private records.

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

- [ ] Compile `src/relay/menu.m` with the build's warnings-as-errors flags. Resolve
  SDK selector, availability, ARC, and framework-link errors before installation.
- [ ] Repeat the native build with the deployed optimization/CPU options from
  [the relay guide](macos-relay.md#build-and-test).
- [ ] Stage using the documented signing/install flow and provisioned synthetic
  credentials where possible. Verify the bundle signature and nested image helper.
- [ ] Confirm `Contents/Resources/statusTemplate.pdf` is included in the signed
  bundle and a locally validated distribution-format archive, `LSUIElement`
  remains true, and the installer produces `serve --menu-bar` in
  `ProgramArguments`. Verify the service helper uses the same arguments.
- [ ] Run `tests/mac_enrichment_packaging.py` with its documented build/license
  prerequisites. The script stages an app and checks the PDF and bundle metadata;
  it does not establish installed permission attribution.
- [ ] Preserve the installed signing identity and verify Full Disk Access,
  Automation, and Contacts attribution after upgrading.

## Appearance and interaction

- [ ] Launch the installed service. Exactly one bridge icon appears without a
  Dock icon.
- [ ] Confirm a fresh service launch does not open Settings unsolicited.
- [ ] Inspect light and dark appearances, a selected/open menu, light and dark
  wallpapers, and available display scales. The bridge and warning mark remain
  monochrome, legible, centered, and unclipped at their actual size.
- [ ] Trigger a warning using disposable configuration. Inspect the exclamation
  mark and tooltip. Verify the icon returns to normal when readiness recovers.
- [ ] Open Settings repeatedly. Only one window appears and visible edits are
  preserved. Verify there is exactly one relay listener.
- [ ] Reopen through Finder and `open -n` to exercise Launch Services, the
  distributed reopen notification, and the single-service lock.
- [ ] Close Settings and verify service continues.
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
- [ ] Use Save and Restart in installed Settings; confirm the icon returns
  promptly and Settings opens afterward.
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

In your private copy, mark cases complete only after observing the installed build.
Record the commit/build identifier, macOS and SDK versions, architecture,
optimization mode, signing mode, relevant command results, and screenshots of
light/dark/selected/warning icons and Settings. Redact account information, paths,
endpoints, and credential material. Note every remaining failure or skipped case;
Linux success and a staged signature do not establish native UI acceptance.
