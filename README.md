# ResumeGrabber

**Your resume.io resume → a crisp PNG, in a clean Windows app that leaves nothing behind.**

- **Portable.** Nothing is installed: no Docker, no Python, no admin rights, no shortcuts, no registry entries.
- **Leaves no trace.** The app runs from a temporary folder that is deleted the moment you close the window. Only your PNG stays.
- **Exact layout.** Uses resume.io's own renderer, so the PNG looks exactly like the editor — every page, your photo, the right fonts.

## Run it (Windows 10/11)

Open **PowerShell** and paste:

```powershell
irm https://raw.githubusercontent.com/Sacttt/ResumeGrabber/main/run.ps1 | iex
```

The app window opens. When you close it, the temporary folder is wiped and PowerShell prints
`Cleaned up. Nothing was left on your PC except your PNGs.`

## Get your PNG in 3 copies

1. Click **Open resume.io** (be signed in). On that page press **Ctrl+A**, then **Ctrl+C**.
2. Your resumes appear as cards in the app. Click the one you want — it opens in your browser.
3. Press **Ctrl+A**, **Ctrl+C** again. The PNG is created right away and saved to **Downloads** as
   `Your Name - Job Title - Resume.png`.

ResumeGrabber watches your clipboard while it is open, so there's nothing to paste. Firefox users: click **Raw Data**
before copying. Have the resume JSON as a file already? Click **Open file** or just drop it on the window.

## Features

| | |
|---|---|
| **Preview** | See the PNG in the app, then *Open*, *Show in folder*, *Save as…* or *Copy image* to paste anywhere |
| **Quality** | Standard 150 DPI, High 220 DPI (default), Print 300 DPI |
| **Multi-page** | One tall image, one PNG per page, or both |
| **Also PDF** | Optionally keep a vector PDF next to the PNG |
| **Language** | Override the resume's language for headings |
| **Drag & drop** | Drop a `.json` anywhere on the window |

Settings last for the session only — nothing is written to your PC.

## What happens behind the scenes

1. `run.ps1` downloads this repo into `%TEMP%\ResumeGrabber-xxxx` and opens the window.
2. The app fetches a portable Node.js (checksum-verified; skipped if you already have Node 18+) and resume.io's
   rendering worker into that same folder.
3. Your resume JSON is rendered by resume.io's worker inside a locked-down Node.js sandbox that can only talk to
   resume.io, giving a multi-page PDF.
4. Windows' built-in PDF renderer turns each page into a PNG.
5. On close, the whole `%TEMP%\ResumeGrabber-xxxx` folder is deleted. (If the PC is shut down mid-session, the next
   launch sweeps the leftovers.)

## Develop

```powershell
git clone https://github.com/Sacttt/ResumeGrabber; cd ResumeGrabber
.\run.ps1                    # runs your local copy, portable like the real thing
.\tests\Run-Tests.ps1        # self-tests (XAML, PDF->PNG, engine plumbing)
```

Credit: the rendering approach comes from [felipeall/resumeio-to-pdf](https://github.com/felipeall/resumeio-to-pdf) (MIT).

## Disclaimer

For personal use with your own resume. You are responsible for following resume.io's terms and applicable laws.
