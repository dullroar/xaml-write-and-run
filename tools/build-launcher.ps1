<#
.SYNOPSIS
  Dev-time generator. NOT part of the running program and not loaded by XamlReader at run time.

.DESCRIPTION
  Produces src/launcher.xaml (the file src/Launch.ps1 actually hands to XamlReader.Load) from the
  human-edited sources under templates/:

    templates/stage2.xaml              -- final, standalone-valid Stage 2 payload
    templates/stage1.xaml.template     -- Stage 1, with a __STAGE2_ESCAPED__ placeholder
    templates/launcher.xaml.template   -- Stage 0, with a __STAGE1_CDATA__ placeholder

  Stage 2's raw text is XML-entity-escaped (&, <, >) and substituted into Stage 1's template,
  producing Stage 1's final text. That final text is then substituted verbatim (no escaping --
  it goes inside a CDATA section already present in the launcher template) into the launcher
  template, producing src/launcher.xaml.

  This script exists so the embedded payloads are generated mechanically instead of hand-escaped,
  and so the pipeline is auditable/reproducible. Edit the templates, not src/launcher.xaml.

.NOTES
  Run from the repo root: pwsh -File tools/build-launcher.ps1
#>

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$stage2Path   = Join-Path $root 'templates/stage2.xaml'
$stage1TplPath = Join-Path $root 'templates/stage1.xaml.template'
$launcherTplPath = Join-Path $root 'templates/launcher.xaml.template'
$stage1RefOutPath = Join-Path $root 'templates/_generated-stage1-reference.xaml'
$launcherOutPath = Join-Path $root 'src/launcher.xaml'

function Escape-XmlText([string]$text) {
    # Order matters: & must be escaped first, or the entities just introduced would be re-escaped.
    return $text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

$stage2Raw = Get-Content -Raw -Path $stage2Path
$stage2Escaped = Escape-XmlText $stage2Raw

$stage1Tpl = Get-Content -Raw -Path $stage1TplPath
if ($stage1Tpl -notmatch [regex]::Escape('__STAGE2_ESCAPED__')) {
    throw "stage1.xaml.template is missing the __STAGE2_ESCAPED__ placeholder."
}
$stage1Final = $stage1Tpl.Replace('__STAGE2_ESCAPED__', $stage2Escaped)

# Stage 1's final text must never contain a literal "]]>" -- it is embedded in the launcher via a
# CDATA section, and that substring would prematurely close it. Entity-escaping Stage 2 (instead
# of also wrapping it in CDATA) guarantees this, but assert it rather than trust it.
if ($stage1Final.Contains(']]>')) {
    throw "Stage 1's generated text contains a literal ']]&gt;' sequence -- unsafe to embed via CDATA. " +
          "Check templates/stage2.xaml for an accidental CDATA close marker."
}

$launcherTpl = Get-Content -Raw -Path $launcherTplPath
if ($launcherTpl -notmatch [regex]::Escape('__STAGE1_CDATA__')) {
    throw "launcher.xaml.template is missing the __STAGE1_CDATA__ placeholder."
}
$launcherFinal = $launcherTpl.Replace('__STAGE1_CDATA__', $stage1Final)

Set-Content -Path $stage1RefOutPath -Value $stage1Final -NoNewline -Encoding utf8
Set-Content -Path $launcherOutPath -Value $launcherFinal -NoNewline -Encoding utf8

Write-Host "Wrote $launcherOutPath ($(($launcherFinal | Measure-Object -Character).Characters) chars)"
Write-Host "Wrote $stage1RefOutPath (reference copy of Stage 1's generated text, for human review only)"
