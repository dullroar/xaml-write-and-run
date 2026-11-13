# xaml-write-and-run

A small, isolated research repo spun off from [dullroar/code-challenge](https://github.com/dullroar/code-challenge)'s
"pure runtime XAML" experiment (`src/xaml/strict.xaml` there). That experiment proved that `XamlReader.Load`,
fed nothing but a `.xaml` file and WPF's own built-in `ObjectDataProvider`/resource-dictionary machinery,
can act as a general-purpose declarative interpreter -- no code-behind, no compiled BAML -- and that its
resources are constructed **synchronously, in document order**, during parsing. The original demo used that
to drive a little simulated time-card workflow and end by writing an XML file to disk.

This repo asks a narrower, sharper question about that same mechanism:

> If an **early** object in a XAML document can write a brand-new `.xaml` file to disk, can a **later**
> object in that *same* document then load and run it? And if so, does the loaded document get to do the
> same trick again, so the chain keeps extending itself -- and can it keep going by reading its next
> instructions from the web instead of from local disk?

All three answers are **yes**, demonstrated below. This is the generic shape of the classic
`ObjectDataProvider` XAML-deserialization gadget (the technique behind several real-world `.NET`/WPF
insecure-deserialization findings), stripped down to show its most consequential property on purpose: a
trusted parser, fed attacker-influenced or self-generated XAML, doesn't just build inert objects -- it can
write new instructions to disk (or fetch them from a URL) and keep executing with changed behavior,
indefinitely, using nothing but declarative markup.

**Everything in this repo is a `.xaml` file or a `.ps1` script.** There is nothing to compile, no project
file, no build step. [`src/Launch.ps1`](src/Launch.ps1) is the only host, and it's about 50 lines of plain
PowerShell that do nothing but bootstrap WPF and call `XamlReader.Load` -- every behavior described below
lives in the `.xaml` files, readable top to bottom as plain text. (This wasn't the starting design -- see
["No compiled code: how this repo got here"](#no-compiled-code-how-this-repo-got-here) for why, and for two
real bugs that turned up while removing the last of it.)

## What's actually in the local chain

Three generations of `.xaml` "program," each one entirely written by the one before it:

1. **Stage 0 -- `src/launcher.xaml`.** The only file that exists before the program runs. While it is
   being parsed, it:
   - writes `data/stage1.generated.xaml` to disk (`File.WriteAllText`, synchronous -- the file is closed
     and durable before the next resource is constructed);
   - sleeps 400ms (`Thread.Sleep`) -- not required for correctness (`WriteAllText` already guaranteed the
     write landed), but an explicit, visible pause so the ordering is unmistakable in `data/run.log`;
   - opens that file and hands it to `System.Windows.Markup.XamlReader.Load` -- a **later object in the
     same document** successfully reading what an **earlier object in the same document** just wrote;
   - calls `.Show()` on the `Window` that `XamlReader.Load` just deserialized.
2. **Stage 1 -- generated at runtime, loaded from Stage 0.** Its own resource dictionary runs *inside*
   Stage 0's `XamlReader.Load` call, and it repeats exactly the same trick one link further down: it writes
   `data/stage2.generated.xaml`, sleeps, loads it, and shows it.
3. **Stage 2 -- generated at runtime, loaded from Stage 1.** A terminal popup. It writes nothing further.
   The chain stops here deliberately, not because anything ran out.

All of this is declared in XAML resource entries (`ObjectDataProvider`, `FileStream`, `sys:String`, ...),
not in code. `src/Launch.ps1` bootstraps a WPF `Application`, clears `data/` at the start of a run, and
optionally auto-exits after `XWR_AUTO_EXIT_MS` so an unattended run terminates instead of waiting for
someone to close three popped-up windows -- nothing it does participates in the write/sleep/load/show
chain itself.

Every step also appends a line to `data/run.log` (again via a declarative `File.AppendAllText`
`ObjectDataProvider`, not code), so the exact order of events is on disk afterward, independent of
whatever you saw on screen:

```text
stage0 (launcher): started
stage0: wrote data/stage1.generated.xaml
stage0: slept 400ms
stage1: started
stage1: wrote data/stage2.generated.xaml
stage1: slept 400ms
stage1: loaded stage2 via XamlReader.Load
stage1: called Show() on the loaded stage2 window
stage0: loaded stage1 via XamlReader.Load (this transitively wrote+loaded+showed stage2 too)
stage0: called Show() on the loaded stage1 window
```

Read bottom-up on the nesting: Stage 0's single `loadStage1` `ObjectDataProvider` call does not return
until Stage 1's *entire* resource dictionary -- write, sleep, load, show -- has finished, because that's
all nested inside the one `XamlReader.Load` invocation. One line of declarative markup in Stage 0 pulls in
two more full generations of self-written, self-run program underneath it.

### Why this generalizes to "forever"

Nothing about Stage 1 writing Stage 2 is special-cased -- it's the identical `ObjectDataProvider` pattern
Stage 0 used to write and run Stage 1. Stage 2 simply chose not to write a Stage 3. A XAML document that
*did* want to keep going could, at the same point where Stage 2 stops, write Stage 3, sleep, load it, and
show it -- and Stage 3 could do the same, and so on, for as long as each new generation keeps choosing to
write the next one. The chain's length is a decision encoded in the document, not a limitation of the
mechanism. That's the result this repo set out to check.

## Reading phase 1/2 from GitHub instead of local disk

A follow-on experiment: instead of an early object *writing* the next stage to local disk for a later
object to read, can a XAML document instead fetch the next stage live from a URL -- specifically, this
repo's own raw GitHub content, to multiple layers deep -- and run that, with no local file *read* anywhere
in the chain?

Yes, demonstrated in [`src/launcher-remote.xaml`](src/launcher-remote.xaml) and
[`templates/stage1-remote.xaml`](templates/stage1-remote.xaml): "Phase 1" is fetched over HTTPS from
`raw.githubusercontent.com` and run; Phase 1, once running, fetches "Phase 2" the same way. Phase 2 is the
*existing, completely unmodified* `templates/stage2.xaml` -- a terminal payload that neither reads nor
writes anything needs no changes at all to be loaded this way instead of from local disk. Nothing stops a
Phase 2 that wanted to keep going from fetching a Phase 3 the identical way, for exactly the "forever"
reason above.

**Getting there surfaced a genuine limit of the declarative mechanism this whole repo relies on, and two
dead ends worth recording precisely rather than silently working around:**

- `ObjectDataProvider.ObjectInstance` has special-case logic that unwraps a *chained* `ObjectDataProvider`
  to its `.Data` when you point it at one via `{StaticResource ...}`. That unwrap is what every multi-step
  chain in this repo depends on (`next` &rarr; `format` &rarr; `encode`, `write` &rarr; `sleep` &rarr;
  `load` &rarr; `show`, etc.) -- confirmed by inspecting `.Data` directly in an isolated probe.
- `ObjectDataProvider.MethodParameters` and `x:Arguments` have **no such unwrap**. A `{StaticResource}`
  pointing at another `ObjectDataProvider`, used as a method parameter or constructor argument, is passed
  through as the raw `ObjectDataProvider` object itself -- not its `.Data` -- regardless of whether the
  method being called is static or instance. Confirmed with four independent probes (a static call, an
  instance call, a constructor via `x:Arguments`, and a `{Binding}` attempt, which WPF rejects outright
  inside `MethodParameters`: "can only be set on a DependencyProperty of a DependencyObject"). This is why
  a naive `ObjectDataProvider` calling `WebClient.DownloadString(url)` feeding a second `ObjectDataProvider`
  calling `XamlReader.Parse` does not work: there is no way to hand the first step's result to the second
  as a parameter.
- WPF's native `ResourceDictionary.Source` -- which *can* fetch XAML from a URI with zero
  `ObjectDataProvider` involved -- was also tried, pointed at this repo's own raw GitHub URL. It failed
  too (`ResourceDictionary LoadFrom operation failed`), consistent with it expecting the fetched root
  element to itself be a `ResourceDictionary`, which `Window`-rooted payloads like ours aren't.
- XML's own standard remote-include mechanism, a DTD external general entity (`<!ENTITY remote SYSTEM
  "https://...">`, referenced in the document as `&remote;`), was tried too, and is flatly rejected:
  `XamlParseException: For security reasons DTD is prohibited in this XML document.` That is .NET's
  deliberate XXE hardening (default since .NET Framework 4.5.2 / all of .NET Core and later), and this
  repo isn't going to build a demo whose point is defeating it, so this path stops here as a documented
  negative result rather than a bypass.

**The fix needs no compiled code at all.** It reuses the same trick `launcher.xaml` already uses for its
local write-then-run chain: hand data between steps through the *file system* instead of through a method
parameter -- just with the "write" performed by an external process instead of `File.WriteAllText`.
`System.Diagnostics.Process` is built into .NET/.NET Framework both, so it is invoked the exact same
declarative way as everything else in this repo:

1. A `ProcessStartInfo` is constructed directly as a resource (`FileName="powershell.exe"`, a literal
   `Arguments` string running `Invoke-WebRequest -OutFile ...`) -- a plain resource, not a chained
   `ObjectDataProvider`, so it's a safe `MethodParameters` entry for the same reason a directly-constructed
   `FileStream` always has been.
2. `Process.Start(ProcessStartInfo)` launches it; `ObjectInstance="{StaticResource <the started process>}"
   MethodName="WaitForExit"` blocks this resource's construction -- and so blocks the parser from moving
   on to anything downstream -- until the download has actually finished.
3. The downloaded file is then opened with the exact same direct-resource `FileStream` +
   `XamlReader.Load` pattern the local chain already uses.

(An earlier version of this file used a four-line compiled C# bridge to route around the
`MethodParameters` limitation above instead. It worked, but it meant this one capability needed a
compiled assembly to exist -- see the next section for why that got removed, and a real cross-runtime
`ProcessStartInfo` bug found while removing it.)

Run it the same way as the local chain, pointed at the alternate entry file:

```powershell
powershell.exe -File src\Launch.ps1 -Path src\launcher-remote.xaml
```

`src/launcher-remote.xaml` fetches `templates/stage1-remote.xaml` from `refs/heads/main` on GitHub -- so
if you're testing this from an unmerged branch where that file doesn't exist on `main` yet,
`Invoke-WebRequest` fails inside the launched `powershell.exe` process, `data/phase1.downloaded.xaml`
never gets created, and the subsequent `FileStream` open throws a plain `FileNotFoundException`. That's
the correct, expected pre-merge state, not a bug.

## No compiled code: how this repo got here

This repo didn't start script-only. Roughly, in order:

1. **The write-then-run chain**, hosted by a tiny compiled `.NET` executable (`src/Loader.cs` + a
   `.csproj`) that did nothing but call `XamlReader.Load` and pump a WPF message loop -- something has to,
   and C# was the obvious first choice.
2. **A PowerShell host** (`src/Launch.ps1`), added specifically to test whether the chain was somehow
   dependent on being hosted by compiled code. It wasn't -- the *exact same* `launcher.xaml` ran unmodified
   under both -- but getting there took two real fixes: `launcher.xaml`'s `sys`/`io`/`thr` XML namespaces
   had to move from the modern `System.Runtime`/`System.Threading.Thread` facade assemblies to
   `assembly=mscorlib`, because Windows PowerShell 5.1 runs on .NET Framework, where those types live in
   `mscorlib` natively, not in the modern facades (confirmed `mscorlib` also resolves fine under the .NET
   host's compatibility forwarders, so one file served both); and `Launch.ps1` had to call
   `[System.IO.Directory]::SetCurrentDirectory()` explicitly, because `Push-Location` only updates
   PowerShell's own `$PWD`, not the process-wide directory .NET's `System.IO` APIs actually read, and the
   two were confirmed to drift apart specifically under `powershell.exe -File`.
3. **The GitHub-fetch variant**, which -- per the finding above -- needed a small compiled C# bridge
   method at first, because of the genuine `ObjectDataProvider.MethodParameters` limitation described in
   the section above. That method existed *only* from the `.NET` host: a XAML file referencing a type from
   the app's own compiled assembly can't be loaded by `Launch.ps1`, which has no such assembly. So the one
   remaining capability that needed compiled code also needed the compiled host to exist, just to support
   itself.
4. **The compiled bridge was replaced** with the `Process.Start`/`WaitForExit` approach described above,
   which needs no compiled code at all. At that point the compiled `.NET` host wasn't providing anything
   the PowerShell host didn't -- it was a second thing to keep in sync for no remaining capability -- so
   `src/Loader.cs` and the `.csproj` are gone. Confirming *that* was safe to do surfaced one more real
   bug: `ProcessStartInfo.ArgumentList` (the modern collection-of-strings property, which avoids manual
   command-line quoting) does not exist on .NET Framework's `ProcessStartInfo`, so the GitHub-fetch
   variant loaded fine under the (now-removed) `.NET` host and threw `Cannot set unknown member
   'ArgumentList'` under PowerShell 5.1. Switched to the older `Arguments` single-string property, which
   exists under both runtimes, with the inner `-Command` string XML-escaped (`&quot;`) rather than
   hand-quoted. Confirmed clean afterward, not assumed.

What's left is exactly as much as the research question needed: `.xaml` files carrying the actual program,
and one `.ps1` script just big enough to start a WPF message loop and get out of the way.

## Running it

Windows only (needs WPF, which ships with Windows; Windows PowerShell 5.1 is built in, no install needed).
No build step, no SDK:

```powershell
powershell.exe -File src\Launch.ps1                                      # the local write-then-run chain
powershell.exe -File src\Launch.ps1 -Path src\launcher-remote.xaml       # the GitHub-fetch chain
```

(PowerShell 7+ users: `pwsh -sta -File src\Launch.ps1` -- WPF needs an STA thread, which the default
Windows PowerShell console host already is, but `pwsh` needs `-sta` explicitly.)

Three windows will appear in quick succession (roughly 400ms apart for the local chain; a few seconds
apart for the GitHub-fetch chain, dominated by process-launch and download time): the launcher, Stage/Phase
1, and Stage/Phase 2. Close them (or let `XWR_AUTO_EXIT_MS` close them for you) to end the run. Then look
at the evidence it left behind:

```powershell
Get-Content src\data\run.log
Get-Content src\data\stage1.generated.xaml     # local chain: didn't exist before this run
Get-Content src\data\stage2.generated.xaml     # local chain: didn't exist before this run
Get-Content src\data\phase1.downloaded.xaml    # GitHub-fetch chain: didn't exist before this run
Get-Content src\data\phase2.downloaded.xaml    # GitHub-fetch chain: didn't exist before this run
```

For an unattended run (no one available to close the windows -- useful for CI or driving this from a
script/agent), set an auto-exit timer first:

```powershell
$env:XWR_AUTO_EXIT_MS = "4000"
powershell.exe -File src\Launch.ps1
```

`src/data/` is recreated fresh (stale `run.log` / `*.generated.xaml` / `*.downloaded.xaml` deleted) at the
start of every run, so the log and generated/downloaded files always describe only the run you just made.

## Repo layout

```text
templates/                        human-edited sources (edit these, not src/launcher.xaml)
  stage2.xaml                      the terminal payload, standalone-valid XAML; also "Phase 2" of
                                    the remote-source variant, unmodified
  stage1.xaml.template             Stage 1, with a __STAGE2_ESCAPED__ placeholder
  launcher.xaml.template           Stage 0, with a __STAGE1_CDATA__ placeholder
  _generated-stage1-reference.xaml generated by tools/build-launcher.ps1, for human review only
  stage1-remote.xaml               "Phase 1" of the remote-source variant: fetched from GitHub by
                                    src/launcher-remote.xaml, not read from local disk
tools/
  build-launcher.ps1               generator: templates/* -> src/launcher.xaml (dev-time only; not
                                    loaded or run by the program itself)
src/
  Launch.ps1                       the only host; see "No compiled code" above
  launcher.xaml                    generated file; this is what Launch.ps1 hands to XamlReader.Load
                                    by default. Regenerate with tools/build-launcher.ps1 after
                                    editing templates/.
  launcher-remote.xaml             alternate entry point: fetches Phase 1/2 from GitHub instead of
                                    writing/reading them locally
```

Stage 1 and Stage 2's final text are never hand-escaped: `tools/build-launcher.ps1` reads the
human-readable templates and performs the XML-entity escaping (and a CDATA-safety check) mechanically,
so the generated `src/launcher.xaml` is reproducible from the templates and not the product of
error-prone manual escaping of nested XML-inside-XML.

## Safety notes

- The local chain (`src/launcher.xaml`) stays entirely local: no network access, no process execution,
  no shell invocation anywhere in it -- only `File`, `FileStream`, `Thread.Sleep`, and `XamlReader.Load`,
  all built into .NET/WPF.
- The remote-source variant (`src/launcher-remote.xaml`) deliberately does make network calls and launch
  an external process: it runs `powershell.exe -Command "Invoke-WebRequest ..."` to perform a plain,
  unauthenticated HTTPS GET against `raw.githubusercontent.com`, read-only, fetching only this repo's own
  public files to a path under `data/`. No other host is ever contacted, nothing is ever sent beyond the
  GET itself, and the only process ever launched is that one copy of PowerShell running one fixed,
  hardcoded command -- never anything derived from fetched content or other runtime input.
- All generated/downloaded files live under `src/data/` and are deleted and rewritten on every run;
  nothing outside that directory is touched.
- This is a controlled, bounded demonstration (the chain stops at Stage/Phase 2 on purpose) of a mechanism
  relevant to real `.NET`/WPF insecure-deserialization research (`ObjectDataProvider` gadgets via
  `XamlReader.Load`), built for understanding that mechanism -- not for use against a system you don't
  own or lack authorization to test.

## License

[MIT](LICENSE)
