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

function skillFrontmatterKeys(source) {
  const frontmatter = source.match(/^---\r?\n([\s\S]*?)\r?\n---/)?.[1] ?? "";
  return [...frontmatter.matchAll(/^([a-z][a-z0-9_-]*):/gm)].map((match) => match[1]);
}

test("the runtime gate rejects Node 20 and a missing global WebSocket", async () => {
  const { assertSupportedRuntime } = await import("../scripts/runtime-compat.mjs");
  assert.throws(
    () => assertSupportedRuntime({ nodeVersion: "20.19.0", WebSocketClass: class {} }),
    /Node\.js 22/,
  );
  assert.throws(
    () => assertSupportedRuntime({ nodeVersion: "22.0.0", WebSocketClass: undefined }),
    /WebSocket/,
  );
  assert.doesNotThrow(() => assertSupportedRuntime({ nodeVersion: "22.0.0", WebSocketClass: class {} }));
});

test("every entry point gates Node before mutating installation state", async () => {
  for (const name of ["injector.mjs", "set-theme.mjs"]) {
    const source = await fs.readFile(path.join(repoRoot, "scripts", name), "utf8");
    assert.match(source, /import \{ assertSupportedRuntime \} from "\.\/runtime-compat\.mjs"/);
    assert.match(source, /assertSupportedRuntime\(\)/);
  }

  for (const name of ["install-dream-skin.ps1", "start-dream-skin.ps1"]) {
    const source = await fs.readFile(path.join(repoRoot, "scripts", name), "utf8");
    const gateIndex = source.indexOf("runtime-compat.mjs");
    const mutationIndex = Math.min(
      ...["New-Item -ItemType Directory", "Copy-FileAtomically", "Write-AtomicUtf8File", "Stop-CodexCompletely"]
        .map((marker) => source.indexOf(marker))
        .filter((index) => index >= 0),
    );
    assert.ok(gateIndex >= 0 && gateIndex < mutationIndex, `${name} must gate Node before state mutation`);
    assert.match(source.slice(gateIndex, mutationIndex), /\$LASTEXITCODE/);
  }
});

test("VERSION is the renderer and documentation truth source", async () => {
  const version = (await fs.readFile(path.join(repoRoot, "VERSION"), "utf8")).trim();
  assert.match(version, /^\d+\.\d+\.\d+$/);
  const renderer = await fs.readFile(rendererPath, "utf8");
  const injector = await fs.readFile(injectorPath, "utf8");
  const readme = await fs.readFile(path.join(repoRoot, "README.md"), "utf8");
  assert.match(renderer, /__CODEX_AUTOSKIN_VERSION_JSON__/);
  assert.doesNotMatch(renderer, /version:\s*["']\d+\.\d+\.\d+/);
  assert.match(injector, /fs\.readFile\(path\.join\(root, "VERSION"\)/);
  assert.match(injector, /replace\("__CODEX_AUTOSKIN_VERSION_JSON__"/);
  assert.match(readme, /Node\.js\s*≥\s*22/);
  assert.match(readme, /\[VERSION\]\(VERSION\)/);
  assert.doesNotMatch(readme, /\*\*v2\.0\.0\*\*/);
});

test("agent metadata invokes the skill name declared by SKILL.md", async () => {
  const skill = await fs.readFile(path.join(repoRoot, "SKILL.md"), "utf8");
  const metadata = await fs.readFile(path.join(repoRoot, "agents", "openai.yaml"), "utf8");
  assert.deepEqual(skillFrontmatterKeys(skill), ["name", "description"]);
  assert.deepEqual(skillFrontmatterKeys(skill.replace(/\r?\n/g, "\r\n")), ["name", "description"]);
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
  assert.doesNotMatch(helper, /::Replace\(\$TempPath,\s*\$fullPath,\s*\$null\)/);
  assert.match(helper, /::Replace\(\$TempPath,\s*\$fullPath,\s*\$replaceBackupPath\)/);
  assert.match(helper, /::Delete\(\$replaceBackupPath\)/);
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
  assert.match(source, /PSBoundParameters\.ContainsKey\('Port'\)[^\n]+\$injectorState\.port/);
  assert.match(source, /\$removeExitCode = \$LASTEXITCODE/);
  assert.match(source, /if \(\$removeExitCode -ne 0\) \{[\s\S]*?Add-PhaseFailure -Phase 'live DOM removal'/);
  assert.doesNotMatch(source, /\$removeExitCode -ne 0 -and \$codexRunning/);
});

test("restore attempts requested local phases after live removal fails", async () => {
  const source = await fs.readFile(path.join(repoRoot, "scripts", "restore-dream-skin.ps1"), "utf8");
  const removeIndex = source.indexOf("$removeExitCode = $LASTEXITCODE");
  const uninstallIndex = source.indexOf("if ($Uninstall)", removeIndex);
  const restoreIndex = source.indexOf("if ($RestoreBaseTheme)", uninstallIndex);
  const finalFailureIndex = source.lastIndexOf("exit 1");
  assert.ok(removeIndex >= 0 && uninstallIndex > removeIndex);
  assert.ok(restoreIndex > uninstallIndex && finalFailureIndex > restoreIndex);
  assert.doesNotMatch(source.slice(removeIndex, uninstallIndex), /throw/);
  assert.ok(source.indexOf("Get-Command node") > source.indexOf("# Phase: live DOM removal"));
  assert.match(source, /Write-Output "Dream Skin restore completed with \$\(\$failures\.Count\) failed phase/);
});

test("recorded PIDs are acted on only when their command line belongs to AutoSkin", async () => {
  const helper = await fs.readFile(path.join(repoRoot, "scripts", "process-ownership.ps1"), "utf8");
  assert.match(helper, /Get-CimInstance[^\n]+Win32_Process/);
  assert.match(helper, /CommandLineToArgvW/);
  assert.match(helper, /ExecutablePath/);
  assert.doesNotMatch(helper, /CommandLine\.IndexOf/);
  for (const name of ["install-dream-skin.ps1", "start-dream-skin.ps1", "restore-dream-skin.ps1"]) {
    const source = await fs.readFile(path.join(repoRoot, "scripts", name), "utf8");
    assert.match(source, /\. \(Join-Path \$PSScriptRoot 'process-ownership\.ps1'\)/);
    assert.match(source, /Stop-RecordedProcess/);
  }
  const watcher = await fs.readFile(path.join(repoRoot, "scripts", "watch-dream-skin.ps1"), "utf8");
  assert.match(watcher, /Resolve-RecordedScriptPath[^\n]+injector\.mjs/);
  assert.match(watcher, /Get-RecordedProcessOwnership[^\n]+ExpectedExecutablePath/);
});

test("process ownership returns structured not-running, stopped, and failure states", async () => {
  const helper = await fs.readFile(path.join(repoRoot, "scripts", "process-ownership.ps1"), "utf8");
  assert.match(helper, /(?:Status\s*=\s*|-Status\s+)'not-running'/);
  assert.match(helper, /(?:Status\s*=\s*|-Status\s+)'stopped'/);
  assert.match(helper, /(?:Status\s*=\s*|-Status\s+)'ownership-failed'/);
  assert.match(helper, /(?:Status\s*=\s*|-Status\s+)'stop-failed'/);
  assert.match(helper, /(?:Status\s*=\s*|-Status\s+)'inspection-failed'/);
  assert.match(helper, /(?:Status\s*=\s*|-Status\s+)'invalid-state'/);
  assert.match(helper, /(?:Success\s*=\s*|-Success\s+)\$false/);
  assert.match(helper, /NodeEntryPoint/);
  assert.match(helper, /PowerShellFile/);
  assert.match(helper, /\$arguments\[1\]/);
  assert.match(helper, /-File/);
  assert.match(helper, /\.Process\.Kill\(\)/);
  assert.match(helper, /\.WaitForExit\(5000\)/);
  assert.doesNotMatch(helper, /Stop-Process -Id \$ProcessId/);
});

test("install and start fail closed on ownership errors and retain recorded paths", async () => {
  const expectations = new Map([
    ["install-dream-skin.ps1", [/Resolve-RecordedScriptPath -State \$watcherState/, /Resolve-RecordedExecutablePath -State \$watcherState/]],
    ["start-dream-skin.ps1", [/Resolve-RecordedScriptPath -State \$old/, /scriptPath\s*=\s*\$Injector/, /executablePath\s*=\s*\$node/]],
  ]);
  for (const [name, pathPatterns] of expectations) {
    const source = await fs.readFile(path.join(repoRoot, "scripts", name), "utf8");
    assert.match(source, /\$stopResult\s*=\s*Stop-RecordedProcess/);
    assert.match(source, /if \(-not \$stopResult\.Success\) \{[\s\S]*?throw/);
    for (const pattern of pathPatterns) assert.match(source, pattern);
    const failureIndex = source.indexOf("if (-not $stopResult.Success)");
    const stateRemovalIndex = source.indexOf("Remove-Item", failureIndex);
    assert.ok(failureIndex >= 0 && stateRemovalIndex > failureIndex, `${name} must retain state until stop succeeds`);
  }
});

test("every recorded-process caller supplies executable and argv-position contracts", async () => {
  for (const name of ["install-dream-skin.ps1", "start-dream-skin.ps1", "restore-dream-skin.ps1"]) {
    const source = await fs.readFile(path.join(repoRoot, "scripts", name), "utf8");
    for (const line of source.split("\n").filter((item) => item.includes("Stop-RecordedProcess"))) {
      assert.match(line, /-ExpectedExecutablePath/);
      assert.match(line, /-ScriptArgumentMode\s+'(?:NodeEntryPoint|PowerShellFile)'/);
    }
  }
});

test("old process reconciliation precedes destructive install and launch actions", async () => {
  const install = await fs.readFile(path.join(repoRoot, "scripts", "install-dream-skin.ps1"), "utf8");
  const installStop = install.indexOf("$stopResult = Stop-RecordedProcess");
  assert.ok(installStop >= 0 && installStop < install.indexOf("Copy-FileAtomically"));
  assert.ok(installStop < install.indexOf("$shortcut.Save()"));

  const start = await fs.readFile(path.join(repoRoot, "scripts", "start-dream-skin.ps1"), "utf8");
  const startStop = start.indexOf("$stopResult = Stop-RecordedProcess");
  assert.ok(startStop >= 0 && startStop < start.indexOf("$debugReady = Test-CodexDebugPort"));
  assert.ok(startStop < start.indexOf("while (-not (Test-CodexDebugPort $Port))"));
});

test("watcher distinguishes ownership failure from a missing injector", async () => {
  const source = await fs.readFile(path.join(repoRoot, "scripts", "watch-dream-skin.ps1"), "utf8");
  assert.match(source, /function Get-InjectorHealth/);
  assert.match(source, /Status 'ownership-failed'/);
  assert.match(source, /if \(\$injectorHealth\.Status -eq 'ownership-failed'\)/);
});

test("NoAutoRecover reconciles recorded watcher state and removes its Startup shortcut", async () => {
  const source = await fs.readFile(path.join(repoRoot, "scripts", "install-dream-skin.ps1"), "utf8");
  const noAutoIndex = source.indexOf("if ($NoAutoRecover)");
  const shortcutRemovalIndex = source.indexOf("Remove-Item -LiteralPath $watcherShortcutPath", noAutoIndex);
  const stateReadIndex = source.indexOf("$watcherState = Get-Content");
  const stopIndex = source.indexOf("$stopResult = Stop-RecordedProcess");
  assert.ok(noAutoIndex >= 0 && shortcutRemovalIndex > noAutoIndex && shortcutRemovalIndex < stateReadIndex);
  assert.ok(stopIndex > stateReadIndex && stopIndex < source.indexOf("Copy-FileAtomically"));
  assert.match(source, /Write-Output 'Codex Dream Skin installed\. Auto-recovery disabled/);
  assert.match(source, /Auto-recovery disabled; the recorded watcher was stopped and the Startup shortcut was removed/);
  assert.match(source, /Test-WatcherMutexPresent/);
  assert.match(source, /watcher mutex exists[\s\S]*current watcher may still be running/);
});

test("new lifecycle state records component, executable, script, and real process start time", async () => {
  for (const name of ["start-dream-skin.ps1", "watch-dream-skin.ps1"]) {
    const source = await fs.readFile(path.join(repoRoot, "scripts", name), "utf8");
    assert.match(source, /schemaVersion\s*=\s*2/);
    assert.match(source, /component\s*=\s*'(?:injector|watcher)'/);
    assert.match(source, /scriptPath\s*=/);
    assert.match(source, /executablePath\s*=/);
    assert.match(source, /processStartTimeUtc\s*=\s*[^\n]+\.StartTime\.ToUniversalTime\(\)\.ToString\('o'\)/);
  }
});

test("Windows PowerShell 5.1 CI exercises the real lifecycle contracts", async () => {
  const workflow = await fs.readFile(path.join(repoRoot, ".github", "workflows", "windows-powershell.yml"), "utf8");
  const selftest = await fs.readFile(path.join(repoRoot, "tests", "windows-powershell-selftest.ps1"), "utf8");
  assert.match(workflow, /runs-on:\s*windows-latest/);
  assert.match(workflow, /node-version:\s*['"]22['"]/);
  assert.match(workflow, /powershell\.exe[\s\S]*windows-powershell-selftest\.ps1/);
  for (const contract of [
    "ownership-failed",
    "inspection-failed",
    "invalid-state",
    "not-running",
    "stopped",
    "NodeEntryPoint",
    "PowerShellFile",
    "state was preserved",
    "NoAutoRecover",
    "RestoreBaseTheme",
    "Requested independent local phases were still attempted",
  ]) {
    assert.ok(selftest.includes(contract), "PowerShell selftest must cover " + contract);
  }
  assert.match(selftest, /Assert-Equal -Expected 1 -Actual \$restoreProcess\.ExitCode/);
  assert.match(selftest, /Assert-True -Condition \(Test-Path -LiteralPath \$statePath\)/);
});

test("process-stop failures are not swallowed by state-file parsing guards", async () => {
  const expectations = [
    ["install-dream-skin.ps1", "$watcherState = Get-Content"],
    ["start-dream-skin.ps1", "$old = Get-Content"],
    ["restore-dream-skin.ps1", "$watcherState = Get-Content"],
    ["restore-dream-skin.ps1", "$injectorState = Get-Content"],
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
  await fs.copyFile(path.join(repoRoot, "scripts", "image-validation.mjs"), path.join(root, "scripts", "image-validation.mjs"));
  await fs.copyFile(path.join(repoRoot, "scripts", "runtime-compat.mjs"), path.join(root, "scripts", "runtime-compat.mjs"));
  await fs.copyFile(path.join(repoRoot, "scripts", "verification-contract.mjs"), path.join(root, "scripts", "verification-contract.mjs"));
  await fs.copyFile(path.join(repoRoot, "VERSION"), path.join(root, "VERSION"));
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

function generateRealImage(source, destination, format) {
  const program = [
    "from PIL import Image",
    "import sys",
    "source, destination, image_format = sys.argv[1:]",
    "with Image.open(source) as image:",
    "    if image_format == 'JPEG':",
    "        image = image.convert('RGB')",
    "    image.save(destination, format=image_format)",
  ].join("\n");
  const result = spawnSync("python3", ["-c", program, source, destination, format], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
}

async function addThemeWithArt(root, name, fileName, bytes) {
  const themeDir = path.join(root, "themes", name);
  const manifest = await readDemoManifest(name);
  manifest.art = { home: fileName, chat: fileName };
  await fs.mkdir(themeDir);
  await fs.writeFile(path.join(themeDir, "theme.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  await fs.writeFile(path.join(themeDir, fileName), bytes);
}

function withoutPngChunks(buffer, omittedType) {
  const parts = [buffer.subarray(0, 8)];
  let offset = 8;
  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const end = offset + 12 + length;
    if (buffer.subarray(offset + 4, offset + 8).toString("ascii") !== omittedType) {
      parts.push(buffer.subarray(offset, end));
    }
    offset = end;
  }
  return Buffer.concat(parts);
}

function zeroJpegSofDimensions(buffer) {
  const result = Buffer.from(buffer);
  const sofMarkers = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]);
  for (let offset = 2; offset + 8 < result.length;) {
    assert.equal(result[offset], 0xff, "expected a JPEG marker");
    const marker = result[offset + 1];
    if (sofMarkers.has(marker)) {
      result.writeUInt16BE(0, offset + 5);
      return result;
    }
    if (marker === 0xda || marker === 0xd9) break;
    const length = result.readUInt16BE(offset + 2);
    offset += 2 + length;
  }
  assert.fail("generated JPEG did not contain a SOF marker");
}

function zeroWebpVp8Dimensions(buffer) {
  const result = Buffer.from(buffer);
  for (let offset = 12; offset + 8 <= result.length;) {
    const type = result.subarray(offset, offset + 4).toString("ascii");
    const length = result.readUInt32LE(offset + 4);
    if (type === "VP8 ") {
      result.writeUInt16LE(0, offset + 8 + 6);
      result.writeUInt16LE(0, offset + 8 + 8);
      return result;
    }
    offset += 8 + length + (length & 1);
  }
  assert.fail("generated WebP did not contain a VP8 chunk");
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

test("complete PNG, JPEG, and WebP art loads while a one-byte-truncated container is rejected", async (t) => {
  const root = await makeInjectorFixture(t);
  const source = path.join(demoThemePath, "art.png");
  const formats = [
    { extension: "png", format: "PNG", label: "PNG" },
    { extension: "jpg", format: "JPEG", label: "JPEG" },
    { extension: "webp", format: "WEBP", label: "WebP" },
  ];

  for (const { extension, format } of formats) {
    const generated = path.join(root, `real.${extension}`);
    generateRealImage(source, generated, format);
    const bytes = await fs.readFile(generated);
    await addThemeWithArt(root, `valid-${extension}`, `art.${extension}`, bytes);
    await addThemeWithArt(root, `truncated-${extension}`, `art.${extension}`, bytes.subarray(0, bytes.length - 1));
  }

  const result = runThemes(root);

  assert.equal(result.status, 0, result.stderr);
  for (const { extension, label } of formats) {
    assert.match(result.stderr, new RegExp(`theme "truncated-${extension}" skipped: art file is not a valid ${label} image`));
  }
  const report = JSON.parse(result.stdout);
  assert.deepEqual(
    report.themes.map((theme) => theme.name).sort(),
    ["aurora-veil", "valid-jpg", "valid-png", "valid-webp"],
  );
});

test("image wrappers without required PNG, JPEG, or WebP image structures are rejected", async (t) => {
  const root = await makeInjectorFixture(t);
  const png = await fs.readFile(path.join(demoThemePath, "art.png"));
  const emptyJpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x02, 0xff, 0xd9]);
  const emptyWebp = Buffer.from([
    0x52, 0x49, 0x46, 0x46, 0x0c, 0x00, 0x00, 0x00,
    0x57, 0x45, 0x42, 0x50,
    0x4a, 0x55, 0x4e, 0x4b, 0x00, 0x00, 0x00, 0x00,
  ]);
  await addThemeWithArt(root, "missing-idat-png", "art.png", withoutPngChunks(png, "IDAT"));
  await addThemeWithArt(root, "missing-scan-jpg", "art.jpg", emptyJpeg);
  await addThemeWithArt(root, "missing-frame-webp", "art.webp", emptyWebp);

  const result = runThemes(root);

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stderr, /theme "missing-idat-png" skipped: art file is not a valid PNG image/);
  assert.match(result.stderr, /theme "missing-scan-jpg" skipped: art file is not a valid JPEG image/);
  assert.match(result.stderr, /theme "missing-frame-webp" skipped: art file is not a valid WebP image/);
  assert.deepEqual(JSON.parse(result.stdout).themes.map((theme) => theme.name), ["aurora-veil"]);
});

test("header-only WebP frames and empty animation wrappers are rejected", async () => {
  const { validateImageContainer } = await import("../scripts/image-validation.mjs");
  const webp = (...chunks) => {
    const body = Buffer.concat(chunks.map(([type, payload]) => {
      const header = Buffer.alloc(8);
      header.write(type, 0, 4, "ascii");
      header.writeUInt32LE(payload.length, 4);
      return Buffer.concat([header, payload, payload.length & 1 ? Buffer.from([0]) : Buffer.alloc(0)]);
    }));
    const result = Buffer.alloc(12);
    result.write("RIFF", 0, 4, "ascii");
    result.writeUInt32LE(body.length + 4, 4);
    result.write("WEBP", 8, 4, "ascii");
    return Buffer.concat([result, body]);
  };
  const vp8Header = Buffer.from([0xe0, 0x00, 0x00, 0x9d, 0x01, 0x2a, 0x01, 0x00, 0x01, 0x00]);
  const vp8lHeader = Buffer.from([0x2f, 0x00, 0x00, 0x00, 0x00]);
  const vp8x = Buffer.from([0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  const anim = Buffer.alloc(6);
  const emptyFrame = Buffer.alloc(16);

  assert.equal(validateImageContainer(webp(["VP8 ", vp8Header]), ".webp"), false);
  assert.equal(validateImageContainer(webp(["VP8L", vp8lHeader]), ".webp"), false);
  assert.equal(validateImageContainer(webp(["VP8X", vp8x], ["ANIM", anim], ["ANMF", emptyFrame]), ".webp"), false);
});

test("corrupt image checksums, segment bounds, and encoded dimensions are rejected", async (t) => {
  const root = await makeInjectorFixture(t);
  const source = path.join(demoThemePath, "art.png");
  const png = Buffer.from(await fs.readFile(source));
  const jpegPath = path.join(root, "real.jpg");
  const webpPath = path.join(root, "real.webp");
  generateRealImage(source, jpegPath, "JPEG");
  generateRealImage(source, webpPath, "WEBP");
  const jpeg = await fs.readFile(jpegPath);
  const webp = await fs.readFile(webpPath);

  const badPngCrc = Buffer.from(png);
  badPngCrc[16] ^= 0x01;
  const badJpegBounds = Buffer.from(jpeg);
  badJpegBounds.writeUInt16BE(0xffff, 4);
  const badWebpBounds = Buffer.from(webp);
  badWebpBounds.writeUInt32LE(0xffffffff, 16);
  await addThemeWithArt(root, "bad-crc-png", "art.png", badPngCrc);
  await addThemeWithArt(root, "bad-bounds-jpg", "art.jpg", badJpegBounds);
  await addThemeWithArt(root, "zero-size-jpg", "art.jpg", zeroJpegSofDimensions(jpeg));
  await addThemeWithArt(root, "bad-bounds-webp", "art.webp", badWebpBounds);
  await addThemeWithArt(root, "zero-size-webp", "art.webp", zeroWebpVp8Dimensions(webp));

  const result = runThemes(root);

  assert.equal(result.status, 0, result.stderr);
  for (const name of ["bad-crc-png", "bad-bounds-jpg", "zero-size-jpg", "bad-bounds-webp", "zero-size-webp"]) {
    assert.match(result.stderr, new RegExp(`theme "${name}" skipped: art file is not a valid`));
  }
  assert.deepEqual(JSON.parse(result.stdout).themes.map((theme) => theme.name), ["aurora-veil"]);
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
    .replace("__CODEX_AUTOSKIN_VERSION_JSON__", JSON.stringify("2.2.0"))
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

test("main verification requires the complete active home composition", async () => {
  const { mainSnapshotPasses } = await import("../scripts/verification-contract.mjs");
  const complete = {
    installed: true,
    statePresent: true,
    stylePresent: true,
    chromePresent: true,
    legacyControlsPresent: false,
    theme: "aurora-veil",
    themes: ["aurora-veil", "ember-bloom"],
    themeClassActive: true,
    layout: "fullscreen",
    layoutClassActive: true,
    chromePointerEvents: "none",
    homePresent: true,
    suggestionsPresent: true,
    hero: { width: 600, height: 180 },
    cards: [{ width: 240 }, { width: 240 }],
    composer: { width: 640, height: 56 },
    sidebar: { width: 240, height: 800 },
  };

  assert.equal(mainSnapshotPasses(complete), true);
  assert.equal(mainSnapshotPasses({ ...complete, homePresent: false }), false);
  assert.equal(mainSnapshotPasses({ ...complete, hero: null }), false);
  assert.equal(mainSnapshotPasses({ ...complete, suggestionsPresent: false }), false);
  assert.equal(mainSnapshotPasses({ ...complete, cards: [{}] }), false);
  assert.equal(mainSnapshotPasses({ ...complete, cards: [{}, {}, {}, {}, {}] }), false);
  assert.equal(mainSnapshotPasses({ ...complete, composer: null }), false);
  assert.equal(mainSnapshotPasses({ ...complete, sidebar: null }), false);
  assert.equal(mainSnapshotPasses({ ...complete, themeClassActive: false }), false);
  assert.equal(mainSnapshotPasses({ ...complete, layoutClassActive: false }), false);
  assert.equal(mainSnapshotPasses({ ...complete, chromePointerEvents: "auto" }), false);
});

test("auxiliary verification requires a clean target with a transparent body", async () => {
  const { auxiliarySnapshotPasses } = await import("../scripts/verification-contract.mjs");
  const clean = {
    installed: false,
    themeClasses: [],
    layoutClasses: [],
    stylePresent: false,
    chromePresent: false,
    legacyControlsPresent: false,
    statePresent: false,
    disabledMarkerPresent: false,
    homeMarkerCount: 0,
    shellMarkerCount: 0,
    newTaskMarkerCount: 0,
    dreamInlineProperties: [],
    bodyBackgroundImage: "none",
    bodyBackgroundColor: "rgba(0, 0, 0, 0)",
  };

  assert.equal(auxiliarySnapshotPasses(clean), true);
  assert.equal(auxiliarySnapshotPasses({ ...clean, bodyBackgroundImage: 'url("art.png")' }), false);
  assert.equal(auxiliarySnapshotPasses({ ...clean, bodyBackgroundColor: "rgb(255, 255, 255)" }), false);
  assert.equal(auxiliarySnapshotPasses({ ...clean, bodyBackgroundColor: "transparent" }), true);
});

test("removal verification rejects every kind of residual skin state", async () => {
  const { removalSnapshotPasses } = await import("../scripts/verification-contract.mjs");
  const clean = {
    installed: false,
    themeClasses: [],
    layoutClasses: [],
    stylePresent: false,
    chromePresent: false,
    legacyControlsPresent: false,
    statePresent: false,
    disabledMarkerPresent: false,
    homeMarkerCount: 0,
    shellMarkerCount: 0,
    newTaskMarkerCount: 0,
    dreamInlineProperties: [],
  };
  const residuals = [
    { installed: true },
    { themeClasses: ["dream-theme-stale"] },
    { layoutClasses: ["dream-layout-stale"] },
    { stylePresent: true },
    { chromePresent: true },
    { legacyControlsPresent: true },
    { statePresent: true },
    { disabledMarkerPresent: true },
    { homeMarkerCount: 1 },
    { shellMarkerCount: 1 },
    { newTaskMarkerCount: 1 },
    { dreamInlineProperties: ["--dream-stale"] },
  ];

  assert.equal(removalSnapshotPasses(clean), true);
  for (const residual of residuals) {
    assert.equal(removalSnapshotPasses({ ...clean, ...residual }), false, JSON.stringify(residual));
  }
});

function makeCleanupRendererContext() {
  const nodesById = new Map();
  const allNodes = [];
  let objectUrlCounter = 0;

  const makeStyle = () => {
    const properties = new Map();
    return {
      get length() { return properties.size; },
      item: (index) => [...properties.keys()][index] ?? "",
      setProperty: (name, value) => properties.set(name, String(value)),
      removeProperty: (name) => properties.delete(name),
      getPropertyValue: (name) => properties.get(name) ?? "",
      names: () => [...properties.keys()],
    };
  };
  const makeClassList = () => {
    const classes = new Set();
    return {
      add: (...names) => names.forEach((name) => classes.add(name)),
      remove: (...names) => names.forEach((name) => classes.delete(name)),
      contains: (name) => classes.has(name),
      toggle: (name, enabled) => enabled ? classes.add(name) : classes.delete(name),
      [Symbol.iterator]: () => classes[Symbol.iterator](),
    };
  };
  const createNode = () => {
    const node = {
      dataset: {},
      style: makeStyle(),
      classList: makeClassList(),
      remove() {
        if (node.id) nodesById.delete(node.id);
        const index = allNodes.indexOf(node);
        if (index >= 0) allNodes.splice(index, 1);
      },
    };
    allNodes.push(node);
    return node;
  };
  const appendChild = (node) => {
    if (node.id) nodesById.set(node.id, node);
    return node;
  };
  const documentElement = createNode();
  const body = createNode();
  body.appendChild = appendChild;
  const head = createNode();
  head.appendChild = appendChild;
  const document = {
    documentElement,
    body,
    head,
    createElement: createNode,
    getElementById: (id) => nodesById.get(id) ?? null,
    querySelector: () => null,
    querySelectorAll: (selector) => {
      if (selector === "[style]") return allNodes.filter((node) => node.style.length > 0);
      if (selector.startsWith(".")) {
        const className = selector.slice(1);
        return allNodes.filter((node) => node.classList.contains(className));
      }
      return [];
    },
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
      createObjectURL: () => `blob:cleanup-${++objectUrlCounter}`,
      revokeObjectURL: () => {},
    },
  };
  context.window = context;
  return { context, createNode, nodesById, allNodes };
}

test("renderer cleanup removes stale classes, DOM markers, inline tokens, and window markers", async () => {
  const template = await fs.readFile(rendererPath, "utf8");
  const { removalSnapshotPasses } = await import("../scripts/verification-contract.mjs");
  const { context, createNode, nodesById, allNodes } = makeCleanupRendererContext();
  const art = `data:image/png;base64,${Buffer.alloc(32, 0x42).toString("base64")}`;
  renderInjection(template, context, art);

  context.document.documentElement.classList.add("dream-theme-stale", "dream-layout-stale");
  context.document.documentElement.style.setProperty("--dream-stale-root", "1");
  for (const [id, className] of [
    ["codex-dream-skin-chrome", "dream-home-shell"],
    ["codex-dream-skin-controls", "dream-new-task"],
    ["marker-only", "dream-home"],
  ]) {
    const node = createNode();
    node.id = id;
    node.classList.add(className);
    node.style.setProperty("--dream-stale-node", "1");
    nodesById.set(id, node);
  }

  context.window.__CODEX_DREAM_SKIN_STATE__.cleanup();

  const rootClasses = [...context.document.documentElement.classList];
  const inlineProperties = allNodes.flatMap((node) => node.style.names()).filter((name) => name.startsWith("--dream-"));
  const snapshot = {
    installed: rootClasses.includes("codex-dream-skin"),
    themeClasses: rootClasses.filter((name) => name.startsWith("dream-theme-")),
    layoutClasses: rootClasses.filter((name) => name.startsWith("dream-layout-")),
    stylePresent: nodesById.has("codex-dream-skin-style"),
    chromePresent: nodesById.has("codex-dream-skin-chrome"),
    legacyControlsPresent: nodesById.has("codex-dream-skin-controls"),
    statePresent: Object.hasOwn(context.window, "__CODEX_DREAM_SKIN_STATE__"),
    disabledMarkerPresent: Object.hasOwn(context.window, "__CODEX_DREAM_SKIN_DISABLED__"),
    homeMarkerCount: allNodes.filter((node) => node.classList.contains("dream-home")).length,
    shellMarkerCount: allNodes.filter((node) => node.classList.contains("dream-home-shell")).length,
    newTaskMarkerCount: allNodes.filter((node) => node.classList.contains("dream-new-task")).length,
    dreamInlineProperties: inlineProperties,
  };
  assert.equal(removalSnapshotPasses(snapshot), true, JSON.stringify(snapshot));
});

test("injector verifies complete removal and makes remove failures nonzero", async () => {
  const source = await fs.readFile(injectorPath, "utf8");
  assert.match(source, /import \{[\s\S]*?removalSnapshotPasses[\s\S]*?\} from "\.\/verification-contract\.mjs"/);
  assert.match(source, /removalSnapshotPasses\(result\)/);
  assert.match(source, /\["verify", "remove"\]\.includes\(options\.mode\)/);
  assert.doesNotMatch(source, /options\.mode === "remove"[\s\S]{0,160}!document\.documentElement\.classList\.contains/);
});
