# Links every skill of this repository (a directory holding a SKILL.md) into
# ~\.claude\skills\<name>, <name> being the `name:` of its front matter. The Windows
# counterpart of install.sh: links are directory junctions, which need no admin rights.
# Existing links are updated; a real directory with the same name is left alone.
#
# Usage: .\install.ps1 [-DryRun]
# Env: CLAUDE_SKILLS_DIR (default ~\.claude\skills)
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$dest = if ($env:CLAUDE_SKILLS_DIR) { $env:CLAUDE_SKILLS_DIR } else { Join-Path $HOME '.claude\skills' }
if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }

$skills = Get-ChildItem -LiteralPath $root -Directory | Where-Object Name -ne '.git' |
  ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory } |
  Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } |
  Sort-Object FullName

foreach ($dir in $skills) {
  $rel = [IO.Path]::GetRelativePath($root, $dir.FullName) -replace '\\', '/'
  $lines = @(Get-Content -LiteralPath (Join-Path $dir.FullName 'SKILL.md'))
  $name = $null
  for ($i = 1; $i -lt $lines.Count -and $lines[$i] -ne '---'; $i++) {
    if ($lines[$i] -match '^name:\s*([^\s#]+)') { $name = $Matches[1]; break }
  }
  if (-not $name) { "skipped ${rel}: no name in its front matter"; continue }
  $target = Join-Path $dest $name
  $existing = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
  if ($existing -and -not $existing.LinkType) { "skipped ${name}: $target exists and isn't a link"; continue }
  if ($DryRun) {
    "would: link $target -> $($dir.FullName)"
  } else {
    if ($existing) { $existing.Delete() }  # removes the link only, never its target
    New-Item -ItemType Junction -Path $target -Target $dir.FullName | Out-Null
  }
  "linked  $name -> $rel"
}
