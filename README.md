<p align="center">
  <img src="assets/hero.png" alt="An amber planet surrounded by cyan and violet orbits carrying smaller skill satellites" width="960">
</p>

<h1 align="center">skills</h1>

<p align="center">
  Sylvain's skills for Claude Code: instructions, scripts and templates that Claude loads
  when a task calls for them.
</p>

---

## Catalog

### Loops

- [**long-running-loop**](loops/long-running-loop): runs days-long work as a loop of fresh,
  bounded Claude Code rounds driven by `loop.sh`, steered through an inbox and watched live.

## Install

Clone the repository and link every skill into `~/.claude/skills`:

```sh
git clone https://github.com/syl20bnr/skills.git
cd skills
./install.sh            # link every skill
./install.sh --dry-run  # show what it would do
```

On Windows, from PowerShell 7, `install.ps1` does the same with directory junctions (no
admin rights needed):

```powershell
git clone https://github.com/syl20bnr/skills.git
cd skills
.\install.ps1            # link every skill
.\install.ps1 -DryRun    # show what it would do
```

Each skill is linked under the `name` from its front matter, so a `git pull` updates them in
place. Run `./install.sh` again after adding, renaming or moving a skill. Set
`CLAUDE_SKILLS_DIR` to install somewhere other than `~/.claude/skills`.

## Usage

Claude Code picks a skill by itself when a request matches its description, for example
"set up a long-running loop to port this app". You can also name it: "use the
long-running-loop skill". Each skill's README explains what it does and how to use it.

Scripts work without installing too, for example
`loops/long-running-loop/loop.sh -d .loop status`.

## Layout

```
skills/
├── install.sh            # links every skill into ~/.claude/skills
├── install.ps1           # the same on Windows
├── assets/               # images for this README
└── <category>/
    └── <skill>/
        ├── SKILL.md      # what Claude reads: front matter, then instructions
        ├── README.md     # what people read
        └── ...           # scripts and templates
```

## Adding a skill

1. Pick or create a category directory (lowercase, one word or kebab-case).
2. Create `<category>/<skill>/SKILL.md` with front matter:

   ```yaml
   ---
   name: my-skill            # lowercase, hyphens; unique across the repository
   description: What it does and when to use it, in one or two sentences.
   ---
   ```

3. Keep scripts next to it, executable, and document them in `SKILL.md`.
4. Add a `README.md` for people, and a line to the catalog above.
5. Run `./install.sh`.
