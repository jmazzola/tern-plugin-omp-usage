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
  not placeholders; cropped to the surface with a little margin.
- **History:** squash a feature's local commits into one before pushing. Never rewrite commits already on GitHub:
  the plugin's updater only fast-forwards, so a rewrite strands everyone who already pulled.
