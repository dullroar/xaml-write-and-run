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
not in C#. The only C# in the repo ([`src/Loader.cs`](src/Loader.cs)) bootstraps a WPF `Application`,
clears `data/` at the start of a run, and optionally auto-exits after `XWR_AUTO_EXIT_MS` so an unattended
run terminates instead of waiting for someone to close three popped-up windows. None of that participates
in the write/sleep/load/show chain itself.

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

## Running it

Requires the .NET 10 SDK with WPF support (Windows only -- `UseWPF` needs the desktop workload).

```powershell
cd src
dotnet run -c Release
```

Three windows will appear in quick succession (roughly 400ms apart, then another 400ms): the launcher,
Stage 1, and Stage 2. Close them (or let `XWR_AUTO_EXIT_MS` close them for you) to end the run. Then look
at the evidence it left behind:

```powershell
Get-Content data\run.log
Get-Content data\stage1.generated.xaml   # didn't exist before this run
Get-Content data\stage2.generated.xaml   # didn't exist before this run
```

For an unattended run (no one available to close the windows -- useful for CI or driving this from a
script/agent), set an auto-exit timer:

```powershell
$env:XWR_AUTO_EXIT_MS = "4000"
dotnet run -c Release
```

`data/` is recreated fresh (stale `run.log` / `*.generated.xaml` deleted) at the start of every run, so the
log and generated files always describe only the run you just made.

## Repo layout

```text
templates/                        human-edited sources (edit these, not src/launcher.xaml)
  stage2.xaml                      the terminal payload, standalone-valid XAML
  stage1.xaml.template             Stage 1, with a __STAGE2_ESCAPED__ placeholder
  launcher.xaml.template           Stage 0, with a __STAGE1_CDATA__ placeholder
  _generated-stage1-reference.xaml generated by tools/build-launcher.ps1, for human review only
tools/
  build-launcher.ps1               generator: templates/* -> src/launcher.xaml (dev-time only; not
                                    loaded or run by the program itself)
src/
  XamlWriteAndRun.csproj
  Loader.cs                        the only C#; see "What's actually in the chain" above
  launcher.xaml                    generated file; this is what Loader.cs actually hands to
                                    XamlReader.Load. Regenerate with tools/build-launcher.ps1 after
                                    editing templates/.
```

Stage 1 and Stage 2's final text are never hand-escaped: `tools/build-launcher.ps1` reads the
human-readable templates and performs the XML-entity escaping (and a CDATA-safety check) mechanically,
so the generated `src/launcher.xaml` is reproducible from the templates and not the product of
error-prone manual escaping of nested XML-inside-XML.

## Safety notes

- Everything stays local: no network access, no process execution, no shell invocation anywhere in the
  chain -- only `File`, `FileStream`, `Thread.Sleep`, and `XamlReader.Load`, all built into .NET/WPF.
- All generated files live under `src/data/` and are deleted and rewritten on every run; nothing outside
  that directory is touched.
- This is a controlled, bounded demonstration (the chain stops at Stage 2 on purpose) of a mechanism
  relevant to real `.NET`/WPF insecure-deserialization research (`ObjectDataProvider` gadgets via
  `XamlReader.Load`), built for understanding that mechanism -- not for use against a system you don't
  own or lack authorization to test.

## License

[MIT](LICENSE)
