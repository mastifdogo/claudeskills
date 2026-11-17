# Claude skills

Skills for [Claude](https://claude.ai). Each folder is one skill; the
`*-skill.zip` beside it is the same folder, ready to upload.

| Skill | What it is for |
|---|---|
| [`proxmox-lxc-template`](proxmox-lxc-template/) | Package an application as a ready-to-run Proxmox LXC container template: the build script, first-boot setup, publishing from GitHub Actions, and fixing a container that misbehaves. Written from getting a real one running, mistakes included. |
| [`ledger-module`](ledger-module/) | Build, change, check and release modules for [Ledger](https://github.com/mastifdogo/Bookeeping), the self-hosted bookkeeping app. |
| [`quickbooks-to-ledger`](quickbooks-to-ledger/) | Turn QuickBooks exports into a Ledger database dump that can be restored in Ledger. |

## Install

**Claude (claude.ai, desktop and mobile apps):** Settings → Capabilities:
turn on code execution, then under **Skills** upload the skill's zip. Menu
names may differ slightly between app versions.

**Claude Code:** copy the skill's folder into `.claude/skills/` in a
repository, or `~/.claude/skills/` for every project.

## proxmox-lxc-template

```
proxmox-lxc-template/
  SKILL.md                      what Claude follows
  references/pitfalls.md        what went wrong on a real server, and the fixes
  references/proxmox.md         the host-side commands
  scripts/build-lxc-template.sh starting point for a template build (mmdebstrap)
  scripts/check-template.py     looks inside a finished template for those mistakes
  assets/                       first-boot script and units, an app unit, release and
                                CI workflows, PostgreSQL source and small-container settings
```

`check-template.py` works on any template, whoever built it:

```sh
python3 proxmox-lxc-template/scripts/check-template.py debian-13-myapp_v1.2.3_amd64.tar.zst
```

## Changing a skill

Edit its folder, run `sh make-zip.sh`, commit both. The QuickBooks skill is
also kept in [ledger-import](https://github.com/mastifdogo/ledger-import);
copy changes across so they don't drift.
