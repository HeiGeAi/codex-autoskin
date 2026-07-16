import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const injectorPath = path.join(repoRoot, "scripts", "injector.mjs");
const rendererPath = path.join(repoRoot, "assets", "renderer-inject.js");
const demoThemePath = path.join(repoRoot, "themes", "aurora-veil");

test("agent metadata invokes the skill name declared by SKILL.md", async () => {
  const skill = await fs.readFile(path.join(repoRoot, "SKILL.md"), "utf8");
  const metadata = await fs.readFile(path.join(repoRoot, "agents", "openai.yaml"), "utf8");
  const frontmatter = skill.match(/^---\n([\s\S]*?)\n---/)?.[1] ?? "";
  const frontmatterKeys = [...frontmatter.matchAll(/^([a-z][a-z0-9_-]*):/gm)].map((match) => match[1]);
  assert.deepEqual(frontmatterKeys, ["name", "description"]);
  const declaredName = skill.match(/^name:\s*([^\s]+)$/m)?.[1];
  assert.ok(declaredName, "SKILL.md must declare a skill name");
  assert.match(metadata, new RegExp(`\\$${declaredName}(?:\\s|$)`));
  assert.match(metadata, /display_name:\s*["']Codex AutoSkin["']/);
  const shortDescription = metadata.match(/short_description:\s*["']([^"']+)["']/)?.[1] ?? "";
  assert.ok(shortDescription.length >= 25 && shortDescription.length <= 64);
});

test("PowerShell config and state files are committed through the atomic writer", async () => {
  const helper = await fs.readFile(path.join(repoRoot, "scripts", "file-io.ps1"), "utf8");
  assert.match(helper, /\[System\.IO\.File\]::Replace\(/);
  assert.match(helper, /\[System\.IO\.File\]::Move\(/);
  const expectations = new Map([
    ["install-dream-skin.ps1", [/Write-AtomicUtf8File[^\n]+\$ConfigPath/, /Copy-FileAtomically[^\n]+\$BackupPath/]],
    ["start-dream-skin.ps1", [/Write-AtomicUtf8File[^\n]+\$StatePath/]],
    ["watch-dream-skin.ps1", [/Write-AtomicUtf8File[^\n]+\$WatcherStatePath/]],
    ["restore-dream-skin.ps1", [/Write-AtomicUtf8File[^\n]+\$config/]],
  ]);
  for (const [name, patterns] of expectations) {
    const source = await fs.readFile(path.join(repoRoot, "scripts", name), "utf8");
    assert.match(source, /\. \(Join-Path \$PSScriptRoot 'file-io\.ps1'\)/, `${name} must load the atomic writer`);
    for (const pattern of patterns) assert.match(source, pattern, `${name} must use ${pattern}`);
  }
});

test("restoring the base theme consumes the pre-install backup", async () => {
  const source = await fs.readFile(path.join(repoRoot, "scripts", "restore-dream-skin.ps1"), "utf8");
  const writeIndex = source.indexOf("Write-AtomicUtf8File -LiteralPath $config -Content $currentContent");
  const removeIndex = source.indexOf("Remove-Item -LiteralPath $backup", writeIndex);
  assert.ok(writeIndex >= 0, "the restored config must be committed atomically");
  assert.ok(removeIndex > writeIndex, "the consumed backup must be removed only after the config commit succeeds");
});

test("live restore uses recorded port state and reports a failed removal", async () => {
  const source = await fs.readFile(path.join(repoRoot, "scripts", "restore-dream-skin.ps1"), "utf8");
  assert.match(source, /\$EffectivePort = \$Port/);
  assert.match(source, /PSBoundParameters\.ContainsKey\('Port'\)[^\n]+\$state\.port/);
  assert.match(source, /\$removeExitCode = \$LASTEXITCODE/);
  assert.match(source, /if \(\$removeExitCode -ne 0 -and \$codexRunning\) \{[\s\S]*?throw "Failed to remove the live Dream Skin/);
});

test("recorded PIDs are acted on only when their command line belongs to AutoSkin", async () => {
  const helper = await fs.readFile(path.join(repoRoot, "scripts", "process-ownership.ps1"), "utf8");
  assert.match(helper, /Get-CimInstance[^\n]+Win32_Process/);
  assert.match(helper, /CommandLine\.IndexOf\(\$expectedPath, \[System\.StringComparison\]::OrdinalIgnoreCase\)/);
  for (const name of ["install-dream-skin.ps1", "start-dream-skin.ps1", "restore-dream-skin.ps1"]) {
    const source = await fs.readFile(path.join(repoRoot, "scripts", name), "utf8");
    assert.match(source, /\. \(Join-Path \$PSScriptRoot 'process-ownership\.ps1'\)/);
    assert.match(source, /Stop-RecordedProcess/);
  }
  const watcher = await fs.readFile(path.join(repoRoot, "scripts", "watch-dream-skin.ps1"), "utf8");
  assert.match(watcher, /Test-RecordedProcessOwnership[^\n]+\$Injector/);
});

test("process-stop failures are not swallowed by state-file parsing guards", async () => {
  const expectations = [
    ["install-dream-skin.ps1", "$watcherState = Get-Content"],
    ["start-dream-skin.ps1", "$old = Get-Content"],
    ["restore-dream-skin.ps1", "$watcherState = Get-Content"],
    ["restore-dream-skin.ps1", "$state = Get-Content"],
  ];
  for (const [name, readMarker] of expectations) {
    const source = await fs.readFile(path.join(repoRoot, "scripts", name), "utf8");
    const readIndex = source.indexOf(readMarker);
    const catchIndex = source.indexOf("catch", readIndex);
    const stopIndex = source.indexOf("Stop-RecordedProcess", readIndex);
    assert.ok(readIndex >= 0 && catchIndex > readIndex, `${name} must guard ${readMarker}`);
    assert.ok(
      stopIndex > catchIndex,
      `${name} must stop a recorded process after leaving the state-file parsing guard`,
    );
  }
});

test("the documented art-swap workflow uses the ownership-safe restore script", async () => {
  const source = await fs.readFile(path.join(repoRoot, "references", "scene-art-swap.md"), "utf8");
  assert.doesNotMatch(source, /watcher-state\.json[^\n]+Stop-Process/);
  assert.doesNotMatch(source, /injectorPid[^\n]+Stop-Process/);
  assert.match(source, /restore-dream-skin\.ps1/);
});

test("a failed launcher verification cleans up its daemon and state", async () => {
  const source = await fs.readFile(path.join(repoRoot, "scripts", "start-dream-skin.ps1"), "utf8");
  assert.match(
    source,
    /catch \{[\s\S]*?Stop-RecordedProcess[^\n]+\$daemon\.Id[^\n]+\$Injector[\s\S]*?Remove-Item -LiteralPath \$StatePath[\s\S]*?throw/,
  );
});

async function makeInjectorFixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codex-autoskin-test-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await fs.mkdir(path.join(root, "scripts"), { recursive: true });
  await fs.mkdir(path.join(root, "themes"), { recursive: true });
  await fs.copyFile(injectorPath, path.join(root, "scripts", "injector.mjs"));
  await fs.cp(demoThemePath, path.join(root, "themes", "aurora-veil"), { recursive: true });
  return root;
}

async function readDemoManifest(name) {
  const manifest = JSON.parse(await fs.readFile(path.join(demoThemePath, "theme.json"), "utf8"));
  manifest.name = name;
  return manifest;
}

function runThemes(root) {
  return spawnSync(process.execPath, [path.join(root, "scripts", "injector.mjs"), "--themes"], {
    cwd: root,
    encoding: "utf8",
  });
}

test("a non-object theme manifest is skipped without aborting valid themes", async (t) => {
  const root = await makeInjectorFixture(t);
  const invalidDir = path.join(root, "themes", "null-theme");
  await fs.mkdir(invalidDir);
  await fs.writeFile(path.join(invalidDir, "theme.json"), "null\n");

  const result = runThemes(root);

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stderr, /theme \"null-theme\" skipped: theme\.json must contain an object/);
  const report = JSON.parse(result.stdout);
  assert.deepEqual(report.themes.map((theme) => theme.name), ["aurora-veil"]);
});

test("an art symlink escaping the theme directory is rejected", async (t) => {
  const root = await makeInjectorFixture(t);
  const themeDir = path.join(root, "themes", "linked-art");
  const outsideArt = path.join(root, "outside.png");
  await fs.mkdir(themeDir);
  await fs.copyFile(path.join(demoThemePath, "art.png"), outsideArt);
  await fs.writeFile(
    path.join(themeDir, "theme.json"),
    `${JSON.stringify(await readDemoManifest("linked-art"), null, 2)}\n`,
  );
  await fs.symlink(outsideArt, path.join(themeDir, "art.png"));

  const result = runThemes(root);

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stderr, /theme \"linked-art\" skipped: art file must be a regular file inside the theme folder/);
  const report = JSON.parse(result.stdout);
  assert.deepEqual(report.themes.map((theme) => theme.name), ["aurora-veil"]);
});

test("an art file whose bytes do not match its image extension is rejected", async (t) => {
  const root = await makeInjectorFixture(t);
  const themeDir = path.join(root, "themes", "fake-image");
  await fs.mkdir(themeDir);
  await fs.writeFile(
    path.join(themeDir, "theme.json"),
    `${JSON.stringify(await readDemoManifest("fake-image"), null, 2)}\n`,
  );
  await fs.writeFile(path.join(themeDir, "art.png"), "this is not a PNG\n");

  const result = runThemes(root);

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stderr, /theme \"fake-image\" skipped: art file is not a valid PNG image/);
  const report = JSON.parse(result.stdout);
  assert.deepEqual(report.themes.map((theme) => theme.name), ["aurora-veil"]);
});

function makeRendererContext() {
  const nodes = new Map();
  let objectUrlCounter = 0;
  const classes = new Set();
  const properties = new Map();
  const makeClassList = () => ({
    add: (...names) => names.forEach((name) => classes.add(name)),
    remove: (...names) => names.forEach((name) => classes.delete(name)),
    contains: (name) => classes.has(name),
    toggle: (name, enabled) => enabled ? classes.add(name) : classes.delete(name),
    [Symbol.iterator]: () => classes[Symbol.iterator](),
  });
  const makeStyle = () => ({
    setProperty: (name, value) => properties.set(name, value),
    removeProperty: (name) => properties.delete(name),
  });
  const documentElement = { classList: makeClassList(), style: makeStyle() };
  const appendChild = (node) => {
    if (node.id) nodes.set(node.id, node);
    return node;
  };
  const document = {
    documentElement,
    body: { appendChild },
    head: { appendChild },
    createElement: () => ({ dataset: {}, style: makeStyle(), classList: makeClassList() }),
    getElementById: (id) => nodes.get(id) ?? null,
    querySelector: () => null,
    querySelectorAll: () => [],
  };
  const storage = new Map();
  const context = {
    atob,
    Blob,
    clearInterval: () => {},
    clearTimeout: () => {},
    console,
    document,
    localStorage: {
      getItem: (key) => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, String(value)),
    },
    MutationObserver: class {
      disconnect() {}
      observe() {}
    },
    setInterval: () => 1,
    setTimeout: () => 1,
    URL: {
      createObjectURL: () => `blob:test-${++objectUrlCounter}`,
      revokeObjectURL: () => {},
    },
  };
  context.window = context;
  return context;
}

function renderInjection(template, context, artDataUrl) {
  const manifest = {
    order: ["collision-test"],
    meta: {
      "collision-test": { button: "Test", brand: "Test", edition: "Test", signature: "Test" },
    },
    stickers: { "collision-test": null },
    defaultTheme: "collision-test",
    defaultLayout: "fullscreen",
  };
  const artAssets = { "collision-test": { home: artDataUrl, chat: artDataUrl } };
  const payload = template
    .replace("__DREAM_CSS_JSON__", JSON.stringify(""))
    .replace("__DREAM_ART_ASSETS_JSON__", JSON.stringify(artAssets))
    .replace("__DREAM_MANIFEST_JSON__", JSON.stringify(manifest));
  vm.runInNewContext(payload, context);
}

test("same-size art with the same file tail still refreshes its blob URL", async () => {
  const template = await fs.readFile(rendererPath, "utf8");
  const commonTail = Buffer.alloc(48, 0x7f);
  const first = Buffer.concat([Buffer.alloc(48, 0x11), commonTail]);
  const second = Buffer.concat([Buffer.alloc(48, 0x22), commonTail]);
  const firstUrl = `data:image/png;base64,${first.toString("base64")}`;
  const secondUrl = `data:image/png;base64,${second.toString("base64")}`;
  assert.equal(firstUrl.length, secondUrl.length);
  assert.equal(firstUrl.slice(-24), secondUrl.slice(-24));
  const context = makeRendererContext();

  renderInjection(template, context, firstUrl);
  const originalBlob = context.window.__CODEX_DREAM_SKIN_STATE__.artUrls["collision-test"].home;
  renderInjection(template, context, secondUrl);
  const refreshedBlob = context.window.__CODEX_DREAM_SKIN_STATE__.artUrls["collision-test"].home;

  assert.notEqual(refreshedBlob, originalBlob);
});

test("the demo-art generator runs with deprecations treated as errors", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codex-autoskin-art-test-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await fs.mkdir(path.join(root, "tools"), { recursive: true });
  await fs.mkdir(path.join(root, "themes", "aurora-veil"), { recursive: true });
  await fs.mkdir(path.join(root, "themes", "ember-bloom"), { recursive: true });
  await fs.copyFile(path.join(repoRoot, "tools", "generate-demo-art.py"), path.join(root, "tools", "generate-demo-art.py"));

  const result = spawnSync("python3", [path.join(root, "tools", "generate-demo-art.py")], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, PYTHONWARNINGS: "error::DeprecationWarning" },
  });

  assert.equal(result.status, 0, result.stderr);
  await fs.access(path.join(root, "themes", "aurora-veil", "art.png"));
  await fs.access(path.join(root, "themes", "ember-bloom", "art.png"));
});

test("a failed demo-art save leaves the previous image intact", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codex-autoskin-art-atomic-test-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await fs.mkdir(path.join(root, "tools"), { recursive: true });
  await fs.mkdir(path.join(root, "themes", "aurora-veil"), { recursive: true });
  await fs.mkdir(path.join(root, "themes", "ember-bloom"), { recursive: true });
  const generator = path.join(root, "tools", "generate-demo-art.py");
  const target = path.join(root, "themes", "aurora-veil", "art.png");
  await fs.copyFile(path.join(repoRoot, "tools", "generate-demo-art.py"), generator);
  await fs.writeFile(target, "previous-image");
  const probe = [
    "import importlib.util",
    `spec = importlib.util.spec_from_file_location('demo_art', ${JSON.stringify(generator)})`,
    "module = importlib.util.module_from_spec(spec)",
    "spec.loader.exec_module(module)",
    "class BrokenImage:",
    "    size = (1, 1)",
    "    def save(self, path, *args, **kwargs):",
    "        with open(path, 'wb') as handle:",
    "            handle.write(b'partial-image')",
    "        raise RuntimeError('simulated interrupted save')",
    "module.aurora_veil = BrokenImage",
    "try:",
    "    module.main()",
    "except RuntimeError:",
    "    pass",
    "else:",
    "    raise AssertionError('save unexpectedly succeeded')",
  ].join("\n");

  const result = spawnSync("python3", ["-c", probe], { cwd: root, encoding: "utf8" });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(await fs.readFile(target, "utf8"), "previous-image");
});
