#!/usr/bin/env node
// Headless checks of the updater's live paths, on temp repositories and copies only (never the user's plugin or its
// data). Every window has an omp pane whose overlay sets a status every BEAT_MS (lib.mjs `demoStatus`): a headless
// window runs plugin timers only when something in it changes (never without an omp pane, about every 10 s with an
// idle one), and the updater waits on timers: Download Update's 1.5 s, the resume 0.5 s after a load, 2 s claims.
// 1. A linked clone's Download Update: the fast-forward is still running when Tern reloads the plugin, so its end
//    reaches the new VM as `process_exit`. Then a pending update the clone already has (pulled by hand) is dropped
//    at load (`merge-base`).
// 2. An installed copy's Download Update: the update's files land, plugin files the history deleted go (the old
//    `omp-usage/` folder, which copies installed before 0.8.0 have), and the copy's own files stay.
// 3. An installed copy whose update was cut off before it staged (the landing marker without a staging folder), with
//    three windows loading at once: one of them lands it, once, and one of them sets up the omp extension.
// 4. An installed copy whose update was cut off part-way through copying in (the marker, its staging folder, and the
//    omp extension's files already copied): the next load finishes it before the rest of the plugin loads, and says
//    so, with the restart omp sessions note.
// The installed copies set up the omp extension with a fake omp first on their PATH (built with the .NET Framework's
// csc.exe), which logs its calls.
// Usage: node tests/smoke/updater.mjs [OUT_DIR] [--only clone,install,resume,staged]. Writes OUT_DIR/updater.json and
// updater.md. Ports: SMOKE_UPDATER_PORT (default 47996) and the five after it.
import { execFileSync, spawn } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pluginLog, Profile, redact, REPO, Serve, sleep, TERN, waitFor } from "./lib.mjs";

const args = process.argv.slice(2);
const onlyAt = args.indexOf("--only");
const only = onlyAt >= 0 ? new Set(args[onlyAt + 1].split(",")) : null;
const outDir = args.find((a, i) => !a.startsWith("--") && !(onlyAt >= 0 && i === onlyAt + 1)) ?? join(tmpdir(), "ompu-updater");
rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });
const PORT = Number(process.env.SMOKE_UPDATER_PORT ?? 47996);
const BEAT_MS = 250;
// 0.7.10, the last release with the old `omp-usage/` folder
const OLD_FOLDER_AT = "24208a0";
const OLD_FOLDER = ["omp-usage/plugin.toml", "omp-usage/window.luau"];
const results = [];
function record(name, pass, seen) {
  const entry = { name, result: pass ? "PASS" : "FAIL", seen: redact(seen) };
  results.push(entry);
  console.log(`${entry.result.padEnd(5)} ${name}\n      ${entry.seen.replaceAll("\n", "\n      ")}`);
}

const git = (cwd, ...args) =>
  execFileSync("git", args, { cwd, encoding: "utf8", env: { ...process.env, GIT_TERMINAL_PROMPT: "0" }, stdio: ["ignore", "pipe", "pipe"] }).trim();
const secs = (ms) => `${(ms / 1000).toFixed(1)} s`;

// TEST FIXTURE ONLY, in the temp repo: each load of the plugin leaves a file in its data folder, which is how a check
// tells the VM a reload started from the one before it.
const LOAD_MARK =
  '\n-- TEST FIXTURE ONLY (tests/smoke/updater.mjs): each load leaves a file in the data folder\npcall(tern.fs.write, tern.plugin.data .. "/qa-load-" .. tostring(math.floor(tern.now())) .. "-" .. tostring(math.random(1, 1000000000)), "")\n';
const loadsOf = (profile) => readdirSync(profile.data).filter((name) => name.startsWith("qa-load-")).length;

// The temp upstream. C1 (9.0.0): the working tree's plugin, with the old `omp-usage/` folder as 0.7.10 had it. C2
// (9.1.0): changes the line drawing and the extension, and deletes that folder, as 0.8.0 does.
function buildUpstream(root) {
  const work = join(root, "upstream");
  mkdirSync(work, { recursive: true });
  git(work, "init", "-q", "-b", "main");
  git(work, "config", "user.email", "qa@example.invalid");
  git(work, "config", "user.name", "qa");
  git(work, "config", "core.autocrlf", "false");
  for (const name of readdirSync(REPO)) {
    if (name.endsWith(".luau") || ["plugin.toml", "bar.css", "README.md"].includes(name)) cpSync(join(REPO, name), join(work, name));
  }
  cpSync(join(REPO, "omp"), join(work, "omp"), { recursive: true });
  mkdirSync(join(work, "omp-usage"));
  for (const path of OLD_FOLDER) writeFileSync(join(work, path), execFileSync("git", ["-C", REPO, "show", `${OLD_FOLDER_AT}:${path}`]));
  const toml = (version) => readFileSync(join(REPO, "plugin.toml"), "utf8").replace(/^version = ".*"$/m, `version = "${version}"`);
  writeFileSync(join(work, "plugin.toml"), toml("9.0.0"));
  writeFileSync(join(work, "window.luau"), readFileSync(join(work, "window.luau"), "utf8") + LOAD_MARK);
  git(work, "add", "-A");
  git(work, "commit", "-q", "-m", "C1 9.0.0");
  const c1 = git(work, "rev-parse", "HEAD");
  writeFileSync(join(work, "plugin.toml"), toml("9.1.0"));
  writeFileSync(join(work, "render.luau"), readFileSync(join(work, "render.luau"), "utf8") + "\n-- C2 change\n");
  writeFileSync(join(work, "omp", "extensions", "usage-remaining.js"), readFileSync(join(work, "omp", "extensions", "usage-remaining.js"), "utf8") + "\n// C2 change\n");
  git(work, "rm", "-r", "-q", "omp-usage");
  git(work, "add", "-A");
  git(work, "commit", "-q", "-m", "9.1.0: C2 changes the line and the extension, and drops the old folder");
  const c2 = git(work, "rev-parse", "HEAD");
  return { work, c1, c2 };
}

// A bare remote of the upstream as it is now (C2), for one check: a check that pushes to its remote doesn't change
// what another's offers.
function remoteOf(root, up, name) {
  git(root, "clone", "-q", "--bare", up.work, name);
  return join(root, name);
}

// An installed copy of `sha`, as `tern plugin install` leaves one: the repo's files without `.git`, and an `upstream`
// file naming `remote`.
function installCopy(root, name, up, sha, remote) {
  const copy = join(root, name);
  mkdirSync(copy, { recursive: true });
  const tar = join(root, `${name}.tar`);
  execFileSync("git", ["-C", up.work, "archive", "-o", tar, sha]);
  execFileSync("tar", ["-xf", tar, "-C", copy]);
  writeFileSync(join(copy, "upstream"), `${remote.replaceAll("\\", "/")}\n`);
  return copy;
}

// Whether the copy's plugin files are `sha`'s, as an update lands them (the README isn't a plugin file); the files
// that differ otherwise.
function differing(copy, up, sha) {
  const paths = git(up.work, "ls-tree", "-r", "--name-only", sha).split("\n").filter((path) => path && path !== "README.md");
  return paths.filter((path) => {
    const want = execFileSync("git", ["-C", up.work, "show", `${sha}:${path}`]);
    return !existsSync(join(copy, path)) || !readFileSync(join(copy, path)).equals(want);
  });
}

// The old folder in a copy or clone: what's left of it.
function oldFolder(dir) {
  if (!existsSync(join(dir, "omp-usage"))) return "gone";
  const left = readdirSync(join(dir, "omp-usage"));
  return left.length ? `still there: ${left.join(", ")}` : "its files gone, the empty folder left";
}

// A stand-in for omp that the plugin's extension setup runs (`omp plugin list --json`, `omp plugin link DIR`): it
// answers as an omp without the plugin linked does, and logs each call to calls.log beside it.
const FAKE_OMP = String.raw`// Smoke tests only (tests/smoke/updater.mjs): a fake omp for the plugin's extension setup.
using System;
using System.IO;
using System.Threading;

static class FakeOmp
{
    static int Main(string[] args)
    {
        string line = string.Join(" ", args) + Environment.NewLine;
        for (int i = 0; i < 50; i++)
        {
            try { File.AppendAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "calls.log"), line); break; }
            catch (IOException) { Thread.Sleep(20); }
        }
        if (args.Length >= 2 && args[0] == "plugin" && args[1] == "list") { Console.WriteLine("{\"npm\":[],\"marketplace\":[]}"); return 0; }
        if (args.Length >= 2 && args[0] == "plugin" && args[1] == "link") { Console.WriteLine("Linked"); return 0; }
        Console.Error.WriteLine("unexpected: " + string.Join(" ", args));
        return 2;
    }
}
`;

function buildFakeOmp(root) {
  const csc = join(process.env.WINDIR ?? "C:\\Windows", "Microsoft.NET", "Framework64", "v4.0.30319", "csc.exe");
  if (!existsSync(csc)) throw new Error(`no ${csc} to build the fake omp with`);
  const dir = join(root, "fakeomp");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "fakeomp.cs"), FAKE_OMP);
  execFileSync(csc, ["/nologo", `/out:${join(dir, "omp.exe")}`, join(dir, "fakeomp.cs")], { stdio: "pipe" });
  return join(dir, "omp.exe");
}

// A folder with its own copy of the fake omp, so each check reads its own calls.
function fakeBin(root, name, fake) {
  const dir = join(root, name);
  mkdirSync(dir, { recursive: true });
  cpSync(fake, join(dir, "omp.exe"));
  return dir;
}

const callsOf = (bin) => (existsSync(join(bin, "calls.log")) ? readFileSync(join(bin, "calls.log"), "utf8").split(/\r?\n/).filter(Boolean) : []);

// A window of `profile` with Tern's logs in `local` and `bin` (the fake omp) first on PATH.
function windowOf(profile, port, label, bin, local = profile.local) {
  const own = Object.create(profile);
  own.local = local;
  own.env = () => {
    const env = { ...profile.env(), LOCALAPPDATA: local };
    for (const key of Object.keys(env)) if (/^path$/i.test(key)) delete env[key];
    env.PATH = `${bin};${process.env.PATH}`;
    return env;
  };
  return new Serve(own, port, label);
}

function runAsync(cmd, args) {
  return new Promise((done) => {
    const child = spawn(cmd, args, { stdio: "ignore", windowsHide: true });
    child.on("exit", done);
    child.on("error", done);
  });
}

function toastsOf(serve) {
  return serve.tree(".toast").map((n) => n.text ?? "");
}

// A window's toasts without blocking (the claim watch keeps running meanwhile).
function toastsAsync(serve) {
  return new Promise((done) => {
    const child = spawn(TERN, ["ctl", "--control", String(serve.port), "tree", ".toast"], { stdio: ["ignore", "pipe", "ignore"], windowsHide: true });
    let out = "";
    child.stdout.on("data", (chunk) => {
      out += chunk;
    });
    child.on("error", () => done([]));
    child.on("close", () => {
      try {
        done((JSON.parse(out).nodes ?? []).map((n) => n.text ?? ""));
      } catch {
        done([]);
      }
    });
  });
}

// The update card's button, once a check opened the card.
async function cardButton(s, text, timeout) {
  return waitFor(() => s.tree("button").find((n) => n.text === text) ?? null, timeout, 250);
}

function click(s, node) {
  const [x, y, w, h] = node.rect;
  s.ctl("click", Math.round(x + w / 2), Math.round(y + h / 2));
}

async function cloneDownload(root, up) {
  const profile = new Profile(join(root, "clone-profile")).prepare({}, { beatMs: BEAT_MS });
  const remote = remoteOf(root, up, "clone-remote.git");
  const clone = join(root, "clone");
  git(root, "clone", "-q", "-c", "core.autocrlf=false", remote, "clone");
  git(clone, "reset", "-q", "--hard", up.c1);
  // The fast-forward holds its branch update for 12 s after it has written the files, as a slow disk or a virus scan
  // might: the plugin is reloaded meanwhile, so the merge's end can only reach the new VM.
  writeFileSync(
    join(clone, ".git", "hooks", "reference-transaction"),
    '#!/bin/sh\n[ "$1" = "prepared" ] || exit 0\nif grep -q " refs/heads/"; then sleep 12; fi\nexit 0\n'
  );
  writeFileSync(join(profile.fx, "crates", "plugins", "fixtures", "omp-usage.path"), clone);
  const s = await new Serve(profile, PORT, "clone").start();
  try {
    await s.openAgent();
    s.ctl("plugins", "run", "plugin.omp-usage.update");
    const button = await cardButton(s, "Download Update", 60_000);
    if (!button) {
      record("clone: Download Update reaches the new VM through process_exit", false, `no update card (kv: ${JSON.stringify(profile.readKv())}; toasts: ${JSON.stringify(toastsOf(s))})`);
      return;
    }
    const loadsBefore = loadsOf(profile);
    const t0 = Date.now();
    click(s, button);
    const toasts = new Set();
    const note = () => toastsOf(s).forEach((t) => toasts.add(t));
    // the files change while the branch update waits in the hook
    const filesAt = await waitFor(() => {
      note();
      return readFileSync(join(clone, "render.luau"), "utf8").includes("-- C2 change") ? Date.now() : null;
    }, 30_000, 100);
    const merging = profile.readKv()["omp-usage.update-merging"];
    const headDuring = git(clone, "rev-parse", "HEAD");
    s.ctl("plugins", "fixtures"); // Tern reloads the plugin: the VM that started the merge is gone
    const reloadAt = Date.now();
    const loadsAfter = loadsOf(profile);
    let headAt = null;
    let toastAt = null;
    const until = Date.now() + 40_000;
    while (Date.now() < until) {
      note();
      if (!headAt && git(clone, "rev-parse", "HEAD") === up.c2) headAt = Date.now();
      if (!toastAt && [...toasts].some((t) => t.includes("updated to 9.1.0"))) toastAt = Date.now();
      if (toastAt && Date.now() - toastAt > 5000) break;
      await sleep(250);
    }
    const kv = profile.readKv();
    const head = git(clone, "rev-parse", "HEAD");
    const updatedToasts = [...toasts].filter((t) => t.includes("updated to"));
    const log = pluginLog(profile);
    record(
      "clone: Download Update reaches the new VM through process_exit",
      Boolean(
        filesAt &&
          merging?.pid &&
          headDuring === up.c1 &&
          loadsAfter > loadsBefore &&
          head === up.c2 &&
          headAt &&
          toastAt &&
          toastAt - t0 >= 12_000 &&
          updatedToasts.length === 1 &&
          !kv["omp-usage.update-merging"] &&
          !kv["omp-usage.update-pending"] &&
          kv["omp-usage.update-outcome"]?.reason === "updated"
      ),
      [
        `click → files written after ${filesAt ? secs(filesAt - t0) : "never"}; HEAD then ${headDuring === up.c1 ? "still C1" : headDuring}; merge record ${merging ? `pid ${merging.pid}, window ${JSON.stringify(merging.window)}` : "missing"}`,
        `plugin reloaded ${secs(reloadAt - t0)} after the click (VM loads ${loadsBefore} → ${loadsAfter}); HEAD reached C2 ${headAt ? `${secs(headAt - t0)} after the click` : "never"} (the hook holds git 12 s); toast ${toastAt ? `${secs(toastAt - t0)} after the click` : "never"}`,
        `toasts: ${JSON.stringify([...toasts])}`,
        `HEAD now ${head === up.c2 ? "C2" : head}; kv merging ${JSON.stringify(kv["omp-usage.update-merging"] ?? null)}, pending ${JSON.stringify(kv["omp-usage.update-pending"] ?? null)}, outcome ${JSON.stringify(kv["omp-usage.update-outcome"] ?? null)}`,
        `the clone's old omp-usage folder: ${oldFolder(clone)}`,
        `plugin log lines: ${log.length ? log.slice(-5).join(" | ") : "none"}`,
      ].join("\n")
    );

    // 2. pulled by hand: a check finds C3, the user pulls it with git instead, and the next load drops it
    const scratch = join(root, "clone-c3");
    git(root, "clone", "-q", "-c", "core.autocrlf=false", remote, "clone-c3");
    git(scratch, "config", "user.email", "qa@example.invalid");
    git(scratch, "config", "user.name", "qa");
    writeFileSync(join(scratch, "README.md"), readFileSync(join(scratch, "README.md"), "utf8") + "\nC3\n");
    writeFileSync(join(scratch, "plugin.toml"), readFileSync(join(scratch, "plugin.toml"), "utf8").replace('version = "9.1.0"', 'version = "9.2.0"'));
    git(scratch, "commit", "-q", "-am", "9.2.0: C3");
    const c3 = git(scratch, "rev-parse", "HEAD");
    git(scratch, "push", "-q", "origin", "main");
    rmSync(join(clone, ".git", "hooks", "reference-transaction"));
    s.ctl("plugins", "run", "plugin.omp-usage.update");
    const later = await cardButton(s, "Not Now", 60_000);
    const pending = profile.readKv()["omp-usage.update-pending"];
    if (later) click(s, later);
    git(clone, "pull", "-q", "--ff-only");
    const loadsPulled = loadsOf(profile);
    s.ctl("plugins", "fixtures");
    const reloaded = Date.now();
    const cleared = await waitFor(() => (profile.readKv()["omp-usage.update-pending"] === undefined ? Date.now() : null), 30_000, 250);
    record(
      "clone: a pending update HEAD already has is dropped at load (merge-base)",
      Boolean(later && pending?.sha === c3 && cleared) && git(clone, "rev-parse", "HEAD") === c3 && loadsOf(profile) > loadsPulled,
      [
        `a check found C3: ${later ? "card opened" : "no card"}, kv pending ${pending?.sha === c3 ? "C3" : JSON.stringify(pending ?? null)}`,
        `pulled C3 by hand (HEAD ${git(clone, "rev-parse", "HEAD") === c3 ? "C3" : "not C3"}), plugin reloaded (VM loads ${loadsPulled} → ${loadsOf(profile)}): pending ${cleared ? `cleared ${secs(cleared - reloaded)} after the reload` : `still ${JSON.stringify(profile.readKv()["omp-usage.update-pending"])}`}`,
      ].join("\n")
    );
  } finally {
    await s.quit();
  }
}

async function installedDownload(root, up, fake) {
  const profile = new Profile(join(root, "install-profile")).prepare({}, { beatMs: BEAT_MS });
  const copy = installCopy(root, "install-copy", up, up.c1, remoteOf(root, up, "install-remote.git"));
  const notes = "the user's own file\n";
  writeFileSync(join(copy, "my-notes.txt"), notes);
  const upstreamFile = readFileSync(join(copy, "upstream"), "utf8");
  writeFileSync(join(profile.fx, "crates", "plugins", "fixtures", "omp-usage.path"), copy);
  const bin = fakeBin(root, "install-bin", fake);
  const s = windowOf(profile, PORT + 1, "install", bin);
  await s.start();
  try {
    await s.openAgent();
    const before = oldFolder(copy);
    // the first check clones the mirror and finds which commit the copy is from its version
    s.ctl("plugins", "run", "plugin.omp-usage.update");
    const button = await cardButton(s, "Download Update", 120_000);
    if (!button) {
      record("installed copy: Download Update lands the update", false, `no update card (kv: ${JSON.stringify(profile.readKv())}; toasts: ${JSON.stringify(toastsOf(s))})`);
      return;
    }
    const t0 = Date.now();
    click(s, button);
    const toasts = new Set();
    let toastAt = null;
    const until = Date.now() + 40_000;
    while (Date.now() < until) {
      toastsOf(s).forEach((t) => toasts.add(t));
      if (!toastAt && [...toasts].some((t) => t.includes("updated to 9.1.0"))) toastAt = Date.now();
      if (toastAt && Date.now() - toastAt > 8000) break; // past the reload Tern is asked for 5 s after
      await sleep(250);
    }
    const kv = profile.readKv();
    const off = differing(copy, up, up.c2);
    const after = oldFolder(copy);
    const staging = join(profile.data, "staging");
    const leftovers = existsSync(staging) ? readdirSync(staging) : [];
    const mine = existsSync(join(copy, "my-notes.txt")) && readFileSync(join(copy, "my-notes.txt"), "utf8") === notes;
    const upstreamKept = readFileSync(join(copy, "upstream"), "utf8") === upstreamFile;
    const updatedToasts = [...toasts].filter((t) => t.includes("updated to"));
    const log = pluginLog(s.profile);
    record(
      "installed copy: Download Update lands the update",
      off.length === 0 &&
        mine &&
        upstreamKept &&
        kv["omp-usage.installed"]?.sha === up.c2 &&
        !kv["omp-usage.update-pending"] &&
        !kv["omp-usage.update-landing"] &&
        kv["omp-usage.update-outcome"]?.reason === "updated" &&
        leftovers.length === 0 &&
        updatedToasts.length === 1,
      [
        `plugin files that aren't C2's: ${off.length ? JSON.stringify(off) : "none"}; the user's my-notes.txt kept: ${mine}; the upstream file kept: ${upstreamKept}`,
        `toast ${toastAt ? `${secs(toastAt - t0)} after the click` : "never"}; toasts: ${JSON.stringify([...toasts])}`,
        `kv installed ${JSON.stringify(kv["omp-usage.installed"] ?? null)}, pending ${JSON.stringify(kv["omp-usage.update-pending"] ?? null)}, landing ${JSON.stringify(kv["omp-usage.update-landing"] ?? null)}, outcome ${JSON.stringify(kv["omp-usage.update-outcome"] ?? null)}; staging leftovers ${JSON.stringify(leftovers)}`,
        `fake omp calls: ${JSON.stringify(callsOf(bin))}`,
        `plugin log lines: ${log.length ? log.slice(-5).join(" | ") : "none"}`,
      ].join("\n")
    );
    // the history deleted the folder's files (C2, as 0.8.0 does): the update deletes them, and the folder with them
    record("installed copy: the update drops the old omp-usage folder", off.length === 0 && after === "gone", `old omp-usage folder before the update: ${before}; after: ${after}`);
  } finally {
    await s.quit();
  }
}

async function resumeThreeWindows(root, up, fake) {
  const profile = new Profile(join(root, "resume-profile")).prepare({}, { beatMs: BEAT_MS });
  const remote = remoteOf(root, up, "resume-remote.git");
  const copy = installCopy(root, "resume-copy", up, up.c1, remote);
  writeFileSync(join(profile.fx, "crates", "plugins", "fixtures", "omp-usage.path"), copy);
  const mirror = join(profile.data, "source");
  git(profile.data, "clone", "-q", "--bare", "--single-branch", remote, mirror);
  git(mirror, "fetch", "-q", "origin", "+HEAD:refs/upstream");
  // cut off before staging: the marker names the commit, and no staging folder
  profile.writeKv({
    "omp-usage.installed": { sha: up.c1, version: "9.0.0" },
    "omp-usage.update-landing": { sha: up.c2, name: "9.1.0", at: Math.floor(Date.now() / 1000) - 30 },
  });
  // three windows: one profile (shared plugin data and kv), a log folder each, the fake omp first on PATH
  const bin = fakeBin(root, "resume-bin", fake);
  const serves = [0, 1, 2].map((i) => windowOf(profile, PORT + 2 + i, `resume-${i}`, bin, join(root, `resume-local-${i}`)));
  await Promise.all(serves.map((s) => s.start()));
  try {
    await Promise.all(serves.map((s) => s.openAgent({ plugins: false })));
    const before = oldFolder(copy);
    // they load together; every claim one of them writes is caught (kv.json read every 25 ms)
    const claims = [];
    let watching = true;
    const watch = (async () => {
      while (watching) {
        const claim = profile.readKv()["omp-usage.update-land-claim"];
        if (claim && !claims.includes(claim)) claims.push(claim);
        await sleep(25);
      }
    })();
    const t0 = Date.now();
    await Promise.all(serves.map((s) => runAsync(TERN, ["ctl", "--control", String(s.port), "plugins", "fixtures"])));
    const loaded = Date.now();
    const toasts = serves.map(() => new Set());
    const until = Date.now() + 45_000;
    while (Date.now() < until) {
      const seen = await Promise.all(serves.map(toastsAsync));
      seen.forEach((list, i) => list.forEach((t) => toasts[i].add(t)));
      await sleep(300);
    }
    watching = false;
    await watch;
    const kv = profile.readKv();
    const off = differing(copy, up, up.c2);
    const after = oldFolder(copy);
    const staging = join(profile.data, "staging");
    const leftovers = existsSync(staging) ? readdirSync(staging) : [];
    const finished = toasts.map((set) => [...set].filter((t) => t.includes("finished updating to 9.1.0")).length);
    const unfinished = toasts.map((set) => [...set].filter((t) => t.includes("couldn't finish")).length);
    const calls = callsOf(bin);
    const lists = calls.filter((c) => c.startsWith("plugin list")).length;
    const links = calls.filter((c) => c.startsWith("plugin link")).length;
    const logs = serves.map((s) => pluginLog(s.profile));
    record(
      "installed copy: a land cut off before staging, three windows loading, lands once",
      off.length === 0 &&
        !kv["omp-usage.update-landing"] &&
        kv["omp-usage.installed"]?.sha === up.c2 &&
        leftovers.length === 0 &&
        finished.reduce((a, b) => a + b, 0) === 1 &&
        unfinished.reduce((a, b) => a + b, 0) === 0,
      [
        `the three windows loaded the plugin within ${secs(loaded - t0)}; VM loads: ${loadsOf(profile)}`,
        `plugin files that aren't C2's: ${off.length ? JSON.stringify(off) : "none"}; old omp-usage folder before: ${before}, after: ${after}`,
        `kv landing ${JSON.stringify(kv["omp-usage.update-landing"] ?? null)}, installed ${JSON.stringify(kv["omp-usage.installed"] ?? null)}, outcome ${JSON.stringify(kv["omp-usage.update-outcome"] ?? null)}`,
        `staging leftovers: ${JSON.stringify(leftovers)}; land claims written: ${claims.length} (…${claims.map((c) => String(c).slice(-10)).join(", …")}); standing at the end: …${String(kv["omp-usage.update-land-claim"] ?? "none").slice(-10)}`,
        `"finished updating" toasts per window: ${JSON.stringify(finished)}; "couldn't finish": ${JSON.stringify(unfinished)}`,
        `all toasts: ${JSON.stringify(toasts.map((set) => [...set]))}`,
        ...logs.map((lines, i) => `window ${i} plugin log: ${lines.length ? lines.slice(-4).join(" | ") : "none"}`),
      ].join("\n")
    );
    record(
      "installed copy: three windows loading together set up the omp extension once",
      lists === 1 && links === 1,
      `fake omp calls: ${JSON.stringify(calls)}; kv setup-at ${JSON.stringify(kv["omp-usage.setup-at"] ?? null)}`
    );
  } finally {
    await Promise.all(serves.map((s) => s.quit()));
  }
}

async function finishStaged(root, up, fake) {
  const profile = new Profile(join(root, "staged-profile")).prepare({}, { beatMs: BEAT_MS });
  const remote = remoteOf(root, up, "staged-remote.git");
  const copy = installCopy(root, "staged-copy", up, up.c1, remote);
  writeFileSync(join(profile.fx, "crates", "plugins", "fixtures", "omp-usage.path"), copy);
  const mirror = join(profile.data, "source");
  git(profile.data, "clone", "-q", "--bare", "--single-branch", remote, mirror);
  git(mirror, "fetch", "-q", "origin", "+HEAD:refs/upstream");
  // What `land` leaves when copying in stops part-way (a write that failed, Tern quitting): C2's plugin files staged,
  // the marker naming them and the files the history deleted, and the copy with the first of them in. copy_in goes
  // the updater first, then by name, so the omp extension's files are in before render.luau and plugin.toml.
  const stage = join(profile.data, "staging", `${Math.floor(Date.now() / 1000)}-qa`);
  const tree = join(stage, "tree");
  mkdirSync(tree, { recursive: true });
  const tar = join(root, "staged-c2.tar");
  execFileSync("git", ["-C", up.work, "archive", "-o", tar, up.c2]);
  execFileSync("tar", ["-xf", tar, "-C", tree]);
  rmSync(join(tree, "README.md"));
  const files = git(up.work, "ls-tree", "-r", "--name-only", up.c2).split("\n").filter((path) => path && path !== "README.md");
  const extensionFile = "omp/extensions/usage-remaining.js";
  cpSync(join(tree, extensionFile), join(copy, extensionFile));
  // `extension`: what `land` records before copying anything (C1 → C2 changes the extension)
  profile.writeKv({
    "omp-usage.installed": { sha: up.c1, version: "9.0.0" },
    "omp-usage.update-landing": { sha: up.c2, name: "9.1.0", at: Math.floor(Date.now() / 1000) - 30, stage, files, gone: OLD_FOLDER, extension: true },
  });
  const before = differing(copy, up, up.c2);
  const bin = fakeBin(root, "staged-bin", fake);
  const s = windowOf(profile, PORT + 5, "staged", bin);
  await s.start();
  try {
    // the next load, in a window whose timers already run (as a real window's do): the finishing toast is a timer's
    await s.openAgent({ plugins: false });
    s.ctl("plugins", "fixtures");
    const toasts = new Set();
    const until = Date.now() + 30_000;
    while (Date.now() < until) {
      toastsOf(s).forEach((t) => toasts.add(t));
      if ([...toasts].some((t) => t.includes("finished updating"))) break;
      await sleep(250);
    }
    await sleep(2000);
    toastsOf(s).forEach((t) => toasts.add(t));
    const kv = profile.readKv();
    const off = differing(copy, up, up.c2);
    const finished = [...toasts].filter((t) => t.includes("finished updating to 9.1.0"));
    const log = pluginLog(s.profile);
    record(
      "installed copy: an update cut off while copying in finishes at the next load",
      off.length === 0 &&
        !existsSync(stage) &&
        !kv["omp-usage.update-landing"] &&
        kv["omp-usage.installed"]?.sha === up.c2 &&
        kv["omp-usage.update-outcome"]?.reason === "updated" &&
        finished.length === 1,
      [
        `before the load: ${before.length} plugin files not yet C2's (${before.join(", ")}); the extension's already in`,
        `after the load (VM loads: ${loadsOf(profile)}): plugin files that aren't C2's: ${off.length ? JSON.stringify(off) : "none"}; staging folder ${existsSync(stage) ? "still there" : "removed"}; old omp-usage folder: ${oldFolder(copy)}`,
        `kv landing ${JSON.stringify(kv["omp-usage.update-landing"] ?? null)}, installed ${JSON.stringify(kv["omp-usage.installed"] ?? null)}, outcome ${JSON.stringify(kv["omp-usage.update-outcome"] ?? null)}`,
        `toasts: ${JSON.stringify([...toasts])}`,
        `plugin log lines: ${log.length ? log.slice(-5).join(" | ") : "none"}`,
      ].join("\n")
    );
    // the update changed the omp extension (C1 → C2), so running omp sessions need a restart, whichever load copied it
    record(
      "installed copy: finishing a cut-off update still says the omp extension changed",
      finished.length === 1 && finished[0].includes("restart omp sessions"),
      `C2 changes ${extensionFile}, which the cut-off load had already copied; the finishing toast: ${JSON.stringify(finished[0] ?? null)}`
    );
  } finally {
    await s.quit();
  }
}

const root = join(outDir, "work");
mkdirSync(root, { recursive: true });
const up = buildUpstream(root);
const wanted = (name) => !only || only.has(name);
if (wanted("clone")) {
  try {
    await cloneDownload(root, up);
  } catch (err) {
    record("clone: Download Update", false, `error: ${err.stack ?? err}`);
  }
}
let fake = null;
if (wanted("install") || wanted("resume") || wanted("staged")) {
  try {
    fake = buildFakeOmp(root);
  } catch (err) {
    record("installed copy: the fake omp", false, `error: ${err.stack ?? err}`);
  }
}
if (fake) {
  const checks = [
    ["install", "installed copy: Download Update", installedDownload],
    ["resume", "installed copy: resume with three windows", resumeThreeWindows],
    ["staged", "installed copy: finish a cut-off copy at load", finishStaged],
  ];
  for (const [name, title, check] of checks) {
    if (!wanted(name)) continue;
    try {
      await check(root, up, fake);
    } catch (err) {
      record(title, false, `error: ${err.stack ?? err}`);
    }
  }
}
writeFileSync(join(outDir, "updater.json"), JSON.stringify(results, null, 1));
writeFileSync(join(outDir, "updater.md"), results.map((r) => `### ${r.result} ${r.name}\n\n\`\`\`\n${r.seen}\n\`\`\`\n`).join("\n"));
