# ResumeGrabber

**Turn your [resume.io](https://resume.io) resume into a pixel-perfect, multi-page, vector PDF — from a slick PowerShell app.**
No Docker. No Python. No admin rights. One line to install.

```
  ____                                ____           _     _
 |  _ \ ___  ___ _   _ _ __ ___   ___/ ___|_ __ __ _| |__ | |__   ___ _ __
 | |_) / _ \/ __| | | | '_ ` _ \ / _ \ |  _| '__/ _` | '_ \| '_ \ / _ \ '__|
 |  _ <  __/\__ \ |_| | | | | | |  __/ |_| | | | (_| | |_) | |_) |  __/ |
 |_| \_\___||___/\__,_|_| |_| |_|\___|\____|_|  \__,_|_.__/|_.__/ \___|_|
```

## Install (Windows 10/11)

Open **PowerShell** and paste:

```powershell
irm https://raw.githubusercontent.com/Sacttt/ResumeGrabber/main/install.ps1 | iex
```

That's it. You get:

- a **ResumeGrabber** shortcut on your Desktop and Start Menu
- a `resumegrabber` command in every new terminal
- **Right-click any `.json` → Convert with ResumeGrabber** in Explorer
- a portable Node.js (checksum-verified, kept inside `%LOCALAPPDATA%\ResumeGrabber`) — nothing is installed system-wide

## Use it

Launch **ResumeGrabber** and pick **Quick Grab**:

1. It opens your resume list on resume.io (be logged in). Press **Ctrl+A, Ctrl+C**.
2. Pick the resume from the menu. It opens that resume's page — **Ctrl+A, Ctrl+C** again.
3. Your PDF appears in `Documents\ResumeGrabber`, named like `Jane Doe - Product Designer - Resume.pdf`.

No saving files, no hunting for IDs. (Firefox: click **Raw Data** before copying.)

### Everything in the app

| | |
|---|---|
| **Quick Grab** | Guided browser + clipboard flow, 3 steps |
| **Convert JSON file(s)** | File picker, multi-select |
| **Convert from clipboard** | Already copied the JSON? One key. |
| **Batch convert** | Every resume JSON in a folder |
| **Watch mode** | Auto-converts any resume JSON you download or copy |
| **Recent PDFs** | Reopen anything you've made |
| **Settings** | Output folder, file-name template (`{name} {title} {doc} {date} {id}`), language override, auto-open |
| **Doctor** | Checks Node, engine cache, connectivity, permissions |
| **Update** | Self-updates the app and refreshes resume.io's engine |

### Command line

```powershell
resumegrabber                              # interactive app
resumegrabber resume.json                  # convert one file
resumegrabber a.json b.json -Out C:\CVs    # many files into a folder
resumegrabber .\folder                     # every JSON in a folder
resumegrabber -Clipboard -Open             # convert what you just copied, open it
resumegrabber -Watch                       # auto-convert downloads + clipboard
resumegrabber resume.json -Locale de       # force a language
resumegrabber -Doctor | -Update | -RefreshEngine | -Version
```

## How it works

resume.io stores your resume as JSON (`https://resume.io/api/app/resumes/<id>`) and draws the PDF in your browser
with a web worker. ResumeGrabber downloads that same worker (~4 MB, cached) and runs it in a locked-down Node.js
`vm` sandbox that may only talk to `resume.io`. The output is identical to the editor: every page, selectable
vector text, your photo.

## Compared with the original

Inspired by [felipeall/resumeio-to-pdf](https://github.com/felipeall/resumeio-to-pdf) (MIT).

| | resumeio-to-pdf | **ResumeGrabber** |
|---|---|---|
| Runtime | Python + uv + Node (or Docker) | **Nothing** — portable Node auto-installed |
| Install | `uv tool install …` | **one line**, shortcuts + PATH + right-click |
| Getting the JSON | save the page by hand | **clipboard wizard**, watch mode |
| Output name | `<renderingToken>.pdf` | `Name - Title - Resume.pdf`, templated |
| Many resumes | one at a time | multi-select, folders, watch mode |
| Offline re-render | — | cached engine + config, JSON backups |
| Extras | web UI | history, settings, doctor, self-update |

## Uninstall

```powershell
& "$env:LOCALAPPDATA\ResumeGrabber\app\uninstall.ps1"
```

Your PDFs in `Documents\ResumeGrabber` are left alone.

## Privacy

Your resume only ever goes to resume.io itself (to fetch fonts/images while rendering). Nothing else is contacted
except nodejs.org (one-time Node download) and GitHub (updates).

## Development

```powershell
git clone https://github.com/Sacttt/ResumeGrabber; cd ResumeGrabber
.\ResumeGrabber.ps1          # run from source
.\tests\Run-Tests.ps1        # offline self-tests
.\install.ps1                # install your local copy
```

## Disclaimer

For personal use with your own resume. You are responsible for following resume.io's terms and applicable laws.
