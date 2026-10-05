# skills

Sylvain's Claude skills, grouped by category. Each skill is a directory with a `SKILL.md`
(YAML front matter with `name` and `description`, then the instructions) and whatever
scripts and templates it uses.

```
skills/
├── install.sh                  # links every skill into ~/.claude/skills
└── <category>/
    └── <skill>/
        ├── SKILL.md
        └── ...
```

## Skills

| Category | Skill | What it does |
|---|---|---|
| `loops` | [`long_running_loop`](loops/long_running_loop/SKILL.md) | Runs days-long work as a loop of fresh Claude Code rounds driven by `loop.sh`: PLAN / PROGRESS / PROMPT / INBOX files, detached runner, live and tmux views, waits on limits and API hiccups. |

## Install

Claude Code finds personal skills in `~/.claude/skills/<name>/SKILL.md`. `install.sh` links
each skill there under the `name` from its front matter, so a `git pull` here updates them:

```sh
./install.sh            # link every skill
./install.sh --dry-run  # show what it would do
```

Scripts can also be used directly, without installing, for example
`loops/long_running_loop/loop.sh -d .loop status`.

## Adding a skill

1. Pick or create a category directory (lowercase, one word or snake_case).
2. Create `<category>/<skill>/SKILL.md` with front matter:

   ```yaml
   ---
   name: my-skill            # lowercase, hyphens; unique across the repository
   description: What it does and when to use it, in one or two sentences.
   ---
   ```

3. Keep scripts next to it, executable, and document them in `SKILL.md`.
4. Add a row to the table above, then run `./install.sh`.
