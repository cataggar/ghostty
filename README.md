<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty
</h1>
  <p align="center">
    Fast, native, feature-rich terminal emulator pushing modern features.
    <br />
    A native GUI or embeddable library via <code>libghostty</code>.
    <br />
    <a href="#about">About</a>
    ·
    <a href="https://ghostty.org/download">Download</a>
    ·
    <a href="https://ghostty.org/docs">Documentation</a>
    ·
    <a href="CONTRIBUTING.md">Contributing</a>
    ·
    <a href="HACKING.md">Developing</a>
  </p>
</p>

## About

Ghostty is a terminal emulator that differentiates itself by being
fast, feature-rich, and native. While there are many excellent terminal
emulators available, they all force you to choose between speed,
features, or native UIs. Ghostty provides all three.

**`libghostty`** is a cross-platform, zero-dependency C and Zig library
for building terminal emulators or utilizing terminal functionality
(such as style parsing). Anyone can use `libghostty` to build a terminal
emulator or embed a terminal into their own applications. See
[Ghostling](https://github.com/ghostty-org/ghostling) for a minimal complete project
example or the [`examples` directory](https://github.com/ghostty-org/ghostty/tree/main/example)
for smaller examples of using `libghostty` in C and Zig.

For more details, see [About Ghostty](https://ghostty.org/docs/about).

## Download

See the [download page](https://ghostty.org/download) on the Ghostty website.

## Documentation

See the [documentation](https://ghostty.org/docs) on the Ghostty website.

### Controlled launch preparation

macOS embedders can opt into `command-launch-policy = controlled` through the
existing configuration API, without a C ABI layout change. Select it on a fresh
configuration before finalization, require zero diagnostics and a successful
`ghostty_config_get` readback of `"controlled"`, then create a fresh app. A void
configuration update is not a supported way to enable this policy.

Controlled preparation requires `shell-integration = none`, an effective
nonempty direct command with an absolute executable, and an explicit absolute
working directory. The existing direct-command parser is unchanged. The C
surface working-directory option may supply the directory; invalid overrides
fail, and the C command option must be null because it represents shell input.
Arguments and paths cannot contain embedded NUL. The initial-command rule still
applies, but an invalid selected initial command never falls back to the base
command. Launch inputs, including `input` and the C `initial_input` replacement,
survive presentation replay and remain immutable for an existing subprocess.
Startup input is retained, not suppressed or deferred until a child
acknowledgment. Keep startup input empty when the host protocol requires an
acknowledgment before sending bytes.

Ghostty constructs `/usr/bin/login -q -flp USER COMMAND ARG...`, without its
passwd-home `.hushlogin` probe or launch-default fallback. Construction,
environment acquisition, identity, and checked child CWD/PTY setup failures
cannot authorize a fallback shell. Failed controlled preparation requires a
fresh config. Other platforms reject controlled mode. The default `normal`
policy retains its existing behavior.

This is a Ghostty preparation contract, not a sandbox or executable-format
attestation. System login/PAM and the explicit program remain trusted
components: login can retry authentication or choose a shell, and libc can
substitute a shell after ENOEXEC. Login can overwrite HOME/SHELL even with `-p`.
Embedders must qualify their system/helper assumptions and obtain a real child
acknowledgment before admitting input; successful surface creation is not one.
The detailed option contract is in [`Config.zig`](src/config/Config.zig).

#### Focused launch-policy tests

Use the dedicated artifact, not `test -Dtest-filter=...`: the compiler's
substring filter also admits unnamed tests, including native/OS tests in the
ordinary test graph.

```sh
zig build test-launch-policy-build -Dapp-runtime=none -Demit-lib-vt=false \
  -Demit-docs=false -Demit-macos-app=false -Demit-xcframework=false
zig build test-launch-policy -Dapp-runtime=none -Demit-lib-vt=false \
  -Demit-docs=false -Demit-macos-app=false -Demit-xcframework=false
```

`test-launch-policy-build` compiles `ghostty-launch-policy-test` without running
that artifact. Build-time generators, native dependencies, and macOS Metal
shader compilation still run as needed; it is not a no-process build.

`test-launch-policy` uses a fixed `launch policy pure` compile filter, then
validates an exact allowlist of **26 full names** before any test body runs:
23 launch-policy cases plus three memory-only selector regressions. Missing,
duplicate, or additional unreviewed focused names fail before execution.
Anonymous and unrelated tests are excluded. The complete inventory is in
[`launch_policy_test_selector.zig`](src/launch_policy_test_selector.zig);
new focused cases require review and an explicit inventory update.

The selector and allowlist have one named-module owner shared by the adapter
and regressions. The three regression declarations stay in
`launch_policy_test_selection.zig`, imported by the test root, so Zig collects
them with the other focused cases.

The small adapter delegates execution to the active Zig installation's
standard test runner, retaining its server protocol, allocation-leak and error
reporting, and fuzz entry point. It does not copy or reimplement that runner.
These dedicated steps do not change the ordinary `test` target, and a
user-supplied `-Dtest-filter` does not narrow or expand their fixed inventory.

## Contributing and Developing

If you have any ideas, issues, etc. regarding Ghostty, or would like to
contribute to Ghostty through pull requests, please check out our
["Contributing to Ghostty"](CONTRIBUTING.md) document. Those who would like
to get involved with Ghostty's development as well should also read the
["Developing Ghostty"](HACKING.md) document for more technical details.

## Roadmap and Status

Ghostty is stable and in use by millions of people and machines daily.

The high-level ambitious plan for the project, in order:

|  #  | Step                                                    | Status |
| :-: | ------------------------------------------------------- | :----: |
|  1  | Standards-compliant terminal emulation                  |   ✅   |
|  2  | Competitive performance                                 |   ✅   |
|  3  | Rich windowing features -- multi-window, tabbing, panes |   ✅   |
|  4  | Native Platform Experiences                             |   ✅   |
|  5  | Cross-platform `libghostty` for Embeddable Terminals    |   ✅   |
|  6  | Ghostty-only Terminal Control Sequences                 |   ❌   |

Additional details for each step in the big roadmap below:

#### Standards-Compliant Terminal Emulation

Ghostty implements all of the regularly used control sequences and
can run every mainstream terminal program without issue. For legacy sequences,
we've done a [comprehensive xterm audit](https://github.com/ghostty-org/ghostty/issues/632)
comparing Ghostty's behavior to xterm and building a set of conformance
test cases.

In addition to legacy sequences (what you'd call real "terminal" emulation),
Ghostty also supports more modern sequences than almost any other terminal
emulator. These features include things like the Kitty graphics protocol,
Kitty image protocol, clipboard sequences, synchronized rendering,
light/dark mode notifications, and many, many more.

We believe Ghostty is one of the most compliant and feature-rich terminal
emulators available.

Terminal behavior is partially a de jure standard
(i.e. [ECMA-48](https://ecma-international.org/publications-and-standards/standards/ecma-48/))
but mostly a de facto standard as defined by popular terminal emulators
worldwide. Ghostty takes the approach that our behavior is defined by
(1) standards, if available, (2) xterm, if the feature exists, (3)
other popular terminals, in that order. This defines what the Ghostty project
views as a "standard."

#### Competitive Performance

Ghostty is generally in the same performance category as the other highest
performing terminal emulators.

"The same performance category" means that Ghostty is much faster than
traditional or "slow" terminals and is within an unnoticeable margin of the
well-known "fast" terminals. For example, Ghostty and Alacritty are usually within
a few percentage points of each other on various benchmarks, but are both
something like 100x faster than Terminal.app and iTerm. However, Ghostty
is much more feature rich than Alacritty and has a much more native app
experience.

This performance is achieved through high-level architectural decisions and
low-level optimizations. At a high-level, Ghostty has a multi-threaded
architecture with a dedicated read thread, write thread, and render thread
per terminal. Our renderer uses OpenGL on Linux and Metal on macOS.
Our read thread has a heavily optimized terminal parser that leverages
CPU-specific SIMD instructions. Etc.

#### Rich Windowing Features

The Mac and Linux (build with GTK) apps support multi-window, tabbing, and
splits with additional features such as tab renaming, coloring, etc. These
features allow for a higher degree of organization and customization than
single-window terminals.

#### Native Platform Experiences

Ghostty is a cross-platform terminal emulator but we don't aim for a
least-common-denominator experience. There is a large, shared core written
in Zig but we do a lot of platform-native things:

- The macOS app is a true SwiftUI-based application with all the things you
  would expect such as real windowing, menu bars, a settings GUI, etc.
- macOS uses a true Metal renderer with CoreText for font discovery.
- macOS supports AppleScript, Apple Shortcuts (AppIntents), etc.
- The Linux app is built with GTK.
- The Linux app integrates deeply with systemd if available for things
  like always-on, new windows in a single instance, cgroup isolation, etc.

Our goal with Ghostty is for users of whatever platform they run Ghostty
on to think that Ghostty was built for their platform first and maybe even
exclusively. We want Ghostty to feel like a native app on every platform,
for the best definition of "native" on each platform.

#### Cross-platform `libghostty` for Embeddable Terminals

In addition to being a standalone terminal emulator, Ghostty is a
C-compatible library for embedding a fast, feature-rich terminal emulator
in any 3rd party project. This library is called `libghostty`.

Due to the scope of this project, we're breaking libghostty down into
separate libraries, starting with `libghostty-vt`. The goal of
this project is to focus on parsing terminal sequences and maintaining
terminal state. This is covered in more detail in this
[blog post](https://mitchellh.com/writing/libghostty-is-coming).

`libghostty-vt` is already available and usable today for Zig and C and
is compatible for macOS, Linux, Windows, and WebAssembly. The functionality
is extremely stable (since its been proven in Ghostty GUI for a long time),
but the API signatures are still in flux.

`libghostty` is already heavily in use. See [`examples`](https://github.com/ghostty-org/ghostty/tree/main/example)
for small examples of using `libghostty` in C and Zig or the
[Ghostling](https://github.com/ghostty-org/ghostling) project for a
complete example. See [awesome-libghostty](https://github.com/Uzaaft/awesome-libghostty)
for a list of projects and resources related to `libghostty`.

We haven't tagged libghostty with a version yet and we're still working
on a better docs experience, but our [Doxygen website](https://libghostty.tip.ghostty.org/)
is a good resource for the C API.

##### Embedded PTY input quiescence

Embedders can opt into a per-surface asynchronous input barrier using
`ghostty_surface_input_quiesce`, `ghostty_surface_input_status`,
`ghostty_surface_input_resume`, and `ghostty_surface_input_cancel`.
The surface, child, PTY output, rendering, and local copy/scroll remain live.
Input is discarded while gated, including delayed clipboard completions from
an older input epoch; no automatic input policy is enabled.

`READY` means that older library-owned input cannot arrive at the PTY later,
not that OS-accepted bytes have been consumed. Coordinate with the child:
stop forwarding input, request quiescence, wait for writer readiness, drain or
flush the child's PTY input and obtain its acknowledgement, then resume with
the same token before reopening input. Backpressure can keep a request pending
indefinitely. Cancellation leaves input closed; transport failures fail closed.
See [`include/ghostty.h`](include/ghostty.h) for the token, lifetime, threading,
clipboard, and failure contract.

Run the headless barrier and PTY shutdown regressions with
`zig build test -Dapp-runtime=none -Dtest-filter='input quiescence'`.
On Linux these explicitly exercise epoll and io_uring, including a real child,
registered process watcher, backpressured writes, and bounded writer shutdown.
To select only one Linux backend with the pinned development shell:

```sh
nix develop -c zig build test -Dapp-runtime=none -Dtest-filter='Linux epoll' --summary all
nix develop -c zig build test -Dapp-runtime=none -Dtest-filter='Linux io_uring' --summary all
```

Each selector runs three tests: barrier/backpressure and stale-generation
admission, partial-write teardown, and real-child/process-watcher teardown
(both ordinary and quiesced). These tests use libxev's `prefer` API before
creating any handles and restore the preceding backend after teardown.
An unavailable Linux backend fails explicitly rather than falling back or
skipping; non-Linux hosts skip these platform-specific cases. No application
backend configuration or new test-only selection API is needed.

#### Ghostty-only Terminal Control Sequences

We want and believe that terminal applications can and should be able
to do so much more. We've worked hard to support a wide variety of modern
sequences created by other terminal emulators towards this end, but we also
want to fill the gaps by creating our own sequences.

We've been hesitant to do this up until now because we don't want to create
more fragmentation in the terminal ecosystem by creating sequences that only
work in Ghostty. But, we do want to balance that with the desire to push the
terminal forward with stagnant standards and the slow pace of change in the
terminal ecosystem.

We haven't done any of this yet.

## Crash Reports

Ghostty has a built-in crash reporter that will generate and save crash
reports to disk. The crash reports are saved to the `$XDG_STATE_HOME/ghostty/crash`
directory. If `$XDG_STATE_HOME` is not set, the default is `~/.local/state`.
**Crash reports are _not_ automatically sent anywhere off your machine.**

Crash reports are only generated the next time Ghostty is started after a
crash. If Ghostty crashes and you want to generate a crash report, you must
restart Ghostty at least once. You should see a message in the log that a
crash report was generated.

> [!NOTE]
>
> Use the `ghostty +crash-report` CLI command to get a list of available crash
> reports. A future version of Ghostty will make the contents of the crash
> reports more easily viewable through the CLI and GUI.

Crash reports end in the `.ghosttycrash` extension. The crash reports are in
[Sentry envelope format](https://develop.sentry.dev/sdk/envelopes/). You can
upload these to your own Sentry account to view their contents, but the format
is also publicly documented so any other available tools can also be used.
The `ghostty +crash-report` CLI command can be used to list any crash reports.
A future version of Ghostty will show you the contents of the crash report
directly in the terminal.

To send the crash report to the Ghostty project, you can use the following
CLI command using the [Sentry CLI](https://docs.sentry.io/cli/installation/):

```shell-session
SENTRY_DSN=https://e914ee84fd895c4fe324afa3e53dac76@o4507352570920960.ingest.us.sentry.io/4507850923638784 sentry-cli send-envelope --raw <path to ghostty crash>
```

> [!WARNING]
>
> The crash report can contain sensitive information. The report doesn't
> purposely contain sensitive information, but it does contain the full
> stack memory of each thread at the time of the crash. This information
> is used to rebuild the stack trace but can also contain sensitive data
> depending on when the crash occurred.
