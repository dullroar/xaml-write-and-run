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
> same trick again, so the chain keeps extending itself?

Both answers are **yes**, demonstrated below. This is the generic shape of the classic `ObjectDataProvider`
XAML-deserialization gadget (the technique behind several real-world `.NET`/WPF insecure-deserialization
findings), stripped down to show its most consequential property on purpose: a trusted parser, fed
attacker-influenced or self-generated XAML, doesn't just build inert objects -- it can write new instructions
to disk and keep executing with changed behavior, indefinitely, using nothing but declarative markup.

## What's actually in the chain

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
not in code. There are two interchangeable hosts for the exact same `src/launcher.xaml` -- a compiled
`.NET` executable ([`src/Loader.cs`](src/Loader.cs)) and a PowerShell script
([`src/Launch.ps1`](src/Launch.ps1)) -- and both do the same three things: bootstrap a WPF `Application`,
clear `data/` at the start of a run, and optionally auto-exit after `XWR_AUTO_EXIT_MS` so an unattended run
terminates instead of waiting for someone to close three popped-up windows. Neither participates in the
write/sleep/load/show chain itself; that the exact same `.xaml` file runs unmodified under either host is
itself part of the point -- the program lives in the markup, not in whichever language happens to be
holding the parser.

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

## Why this generalizes to "forever"

Nothing about Stage 1 writing Stage 2 is special-cased -- it's the identical `ObjectDataProvider` pattern
Stage 0 used to write and run Stage 1. Stage 2 simply chose not to write a Stage 3. A XAML document that
*did* want to keep going could, at the same point where Stage 2 stops, write Stage 3, sleep, load it, and
show it -- and Stage 3 could do the same, and so on, for as long as each new generation keeps choosing to
write the next one. The chain's length is a decision encoded in the document, not a limitation of the
mechanism. That's the result this repo set out to check.

## Reading phase 1/2 from GitHub instead of local disk

A follow-on experiment: instead of an early object *writing* the next stage to local disk for a later
object to read, can a XAML document instead fetch the next stage live from a URL -- specifically, this
repo's own raw GitHub content -- and run that, with no local file read anywhere in the chain?

Yes, demonstrated in [`src/launcher-remote.xaml`](src/launcher-remote.xaml) and
[`templates/stage1-remote.xaml`](templates/stage1-remote.xaml): "Phase 1" is fetched over HTTPS from
`raw.githubusercontent.com` and run; Phase 1, once running, fetches "Phase 2" the same way. Phase 2 is
the *existing, completely unmodified* `templates/stage2.xaml` -- a terminal payload that neither reads
nor writes anything needs no changes at all to be loaded this way instead of from local disk.

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

**The fix needs no compiled code at all, and that matters: an earlier version of this file used a
four-line compiled C# bridge (`WebClient.DownloadString` + `XamlReader.Parse` in one call) to route around
the `MethodParameters` limitation above. That worked, but only from the `.NET` host -- a XAML file
referencing a type from the app's own compiled assembly can't be loaded by `src/Launch.ps1`, which has no
such assembly, undoing the entire point of that script existing.** The real fix reuses the same trick
`launcher.xaml` already uses for its local write-then-run chain: hand data between steps through the
*file system* instead of through a method parameter -- just with the "write" performed by an external
process instead of `File.WriteAllText`. `System.Diagnostics.Process` is built into .NET/.NET Framework
both, so it is invoked the exact same declarative way as everything else in this repo:

1. A `ProcessStartInfo` is constructed directly as a resource (`FileName="powershell.exe"`, a literal
   `Arguments` string running `Invoke-WebRequest -OutFile ...`) -- a plain resource, not a chained
   `ObjectDataProvider`, so it's a safe `MethodParameters` entry for the same reason a directly-constructed
   `FileStream` always has been.
2. `Process.Start(ProcessStartInfo)` launches it; `ObjectInstance="{StaticResource <the started process>}"
   MethodName="WaitForExit"` blocks this resource's construction -- and so blocks the parser from moving
   on to anything downstream -- until the download has actually finished.
3. The downloaded file is then opened with the exact same direct-resource `FileStream` +
   `XamlReader.Load` pattern the local chain already uses.

One real cross-runtime bug found while verifying this under both hosts: `ProcessStartInfo.ArgumentList`
(the modern collection-of-strings property, which avoids manual command-line quoting) does not exist on
.NET Framework's `ProcessStartInfo`, so it loaded fine under the `.NET` host and threw `Cannot set unknown
member 'ArgumentList'` under the PowerShell 5.1 host. Switched to the older `Arguments` single-string
property, which exists under both, with the inner `-Command` string XML-escaped (`&quot;`) rather than
hand-quoted. Confirmed clean under both hosts afterward, not assumed.

Run it the same way as the local chain, pointed at the alternate entry file -- works unmodified from
either host (confirmed, not assumed):

```powershell
cd src
dotnet run -c Release -- launcher-remote.xaml
# or:
powershell.exe -File Launch.ps1 -Path launcher-remote.xaml
```

`src/launcher-remote.xaml` fetches `templates/stage1-remote.xaml` from `refs/heads/main` on GitHub, so
this only resolves once it has actually merged there -- before that, `Invoke-WebRequest` fails inside the
launched `powershell.exe` process, `data/phase1.downloaded.xaml` never gets created, and the subsequent
`FileStream` open throws a plain `FileNotFoundException`. That's the correct, expected pre-merge state,
not a bug. `templates/stage2.xaml` is fetched from `main` too, and already exists there, so that half of
the chain works regardless.

## Running it

Windows only (`UseWPF` needs the desktop workload). Two independent ways to run the exact same
`src/launcher.xaml`:

```powershell
# .NET host -- needs the .NET 10 SDK
cd src
dotnet run -c Release

# PowerShell host -- needs nothing but Windows PowerShell (or pwsh 7+ with -sta); no build step
powershell.exe -File src\Launch.ps1
```

Three windows will appear in quick succession (roughly 400ms apart, then another 400ms): the launcher,
Stage 1, and Stage 2. Close them (or let `XWR_AUTO_EXIT_MS` close them for you) to end the run. Then look
at the evidence it left behind:

```powershell
Get-Content src\data\run.log
Get-Content src\data\stage1.generated.xaml   # didn't exist before this run
Get-Content src\data\stage2.generated.xaml   # didn't exist before this run
```

For an unattended run (no one available to close the windows -- useful for CI or driving this from a
script/agent), set an auto-exit timer before either host:

```powershell
$env:XWR_AUTO_EXIT_MS = "4000"
dotnet run -c Release                 # or: powershell.exe -File src\Launch.ps1
```

`src/data/` is recreated fresh (stale `run.log` / `*.generated.xaml` deleted) at the start of every run, so
the log and generated files always describe only the run you just made.

`launcher.xaml`'s `sys`/`io`/`thr` XML namespaces deliberately point at `assembly=mscorlib` rather than the
modern `System.Runtime`/`System.Threading.Thread` facade names, specifically so this one file loads
unmodified under both runtimes: Windows PowerShell 5.1 runs on .NET Framework, where `File`/`Thread`/
`Random`/`String` live in `mscorlib` natively; the .NET 10 WPF host resolves the same `mscorlib` name
through its own compatibility forwarders. Confirmed empirically under both, not assumed.

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
  XamlWriteAndRun.csproj
  Loader.cs                        .NET host; see "What's actually in the chain" above
  Launch.ps1                       PowerShell host; loads the same launcher.xaml, no build step
  launcher.xaml                    generated file; this is what both hosts hand to
                                    XamlReader.Load. Regenerate with tools/build-launcher.ps1 after
                                    editing templates/.
  launcher-remote.xaml             alternate entry point: fetches Phase 1/2 from GitHub instead of
                                    writing/reading them locally. No compiled code of its own --
                                    see "Reading phase 1/2 from GitHub" above.
```

No file here is a compiled helper for the remote-source variant: it was tried (`src/XamlFetch.cs`, since
removed) and abandoned once it became clear it only worked from the `.NET` host, defeating the point of
`src/Launch.ps1` existing. See "Reading phase 1/2 from GitHub" above for what replaced it.

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
- All generated files live under `src/data/` and are deleted and rewritten on every run; nothing outside
  that directory is touched.
- This is a controlled, bounded demonstration (the chain stops at Stage 2 on purpose) of a mechanism
  relevant to real `.NET`/WPF insecure-deserialization research (`ObjectDataProvider` gadgets via
  `XamlReader.Load`), built for understanding that mechanism -- not for use against a system you don't
  own or lack authorization to test.

## License

[MIT](LICENSE)
