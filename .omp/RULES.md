# Keep the README in step with the plugin

- **Features → README.** Any change that adds, changes or removes something a user can notice (a feature, a
  setting, a command, a default, a behavior) updates `README.md` in the same change: the feature list at the top,
  the section that covers it (Settings, Update, Troubleshooting, …) and every table that names it. Text about
  anything removed goes too.
- **UI/UX → pictures.** Any change to how something looks or is used (the line, the hover card, the settings panel,
  the update pill, card or toasts, pickers) adds, retakes or removes the matching pictures in `docs/images/`, with
  their README references and alt text. Delete pictures nothing references any more.
- **Take pictures like the existing ones:** Tern's dark Titanium theme; a headless `tern serve` session at 2× where
  it can show the surface (a real window, enlarged 2×, only where headless can't, e.g. the status line); real data,
  not placeholders; cropped to the surface with a little margin. In the README, show each at half its pixel width
  (`<img src="…" alt="…" width="…">`), so a 2× picture reads at its real size.
- **History:** squash a feature's local commits into one before pushing. Never rewrite commits already on GitHub:
  the plugin's updater only fast-forwards, so a rewrite strands everyone who already pulled.
- **Commit messages are release notes.** The update card shows users every commit that changes the plugin's folder
  or the omp extension, in full: the subject as a heading, the body as Markdown (hard wraps joined, lists and
  `code` kept). Write them for the person deciding whether to update:
  - **Subject:** what changes for them, in plain words, imperative, ≤72 characters, e.g. "Show every Fable reset
    again". A version bump leads it: `0.3.2: …`. No file, function or field names, no internal ids.
  - **Body:** what they saw before and what they'll see now, named as the UI names it (the line, the hover card,
    Fable resets, Ctrl+Alt+U). Anything they must do (restart omp sessions, change a setting) gets its own line.
    Short paragraphs or a `- ` list; wrap at 72.
  - **Why it broke,** when it helps (an omp or Tern update changed something), in one plain sentence. Leave out
    the code-level detail; it belongs in the diff and in code comments.
  - Commits that change only the README, pictures or these rules aren't shown, but still get a plain subject.
