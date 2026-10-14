// Build file chạy cho mọi nền tảng: bun scripts/build.ts
const targets = ["darwin-arm64", "darwin-x64", "linux-x64", "linux-arm64", "windows-x64"];
for (const t of targets) {
  const out = `dist/flygo-agent-${t}${t.startsWith("windows") ? ".exe" : ""}`;
  const p = Bun.spawnSync([process.execPath, "build", "src/cli.ts", "--compile", "--minify", `--target=bun-${t}`, ...(t.startsWith("windows") ? ["--windows-hide-console"] : []), "--outfile", out], { stdout: "pipe", stderr: "pipe" });
  if (p.exitCode !== 0) { console.error(`build ${t} lỗi:\n${p.stderr}`); process.exit(1); }
  console.log(`ok ${out}`);
}
// version.json cho app tự cập nhật (phát hành cùng các file chạy)
const { createHash } = await import("node:crypto");
const files: Record<string, { size: number; sha256: string }> = {};
for (const t of targets) {
  const f = `flygo-agent-${t}${t.startsWith("windows") ? ".exe" : ""}`;
  const b = new Uint8Array(await Bun.file(`dist/${f}`).arrayBuffer());
  files[f] = { size: b.length, sha256: createHash("sha256").update(b).digest("hex") };
}
const version = (await Bun.file("package.json").json()).version;
await Bun.write("dist/version.json", JSON.stringify({ version, built_at: new Date().toISOString(), files }, null, 2));
console.log(`ok dist/version.json (${version})`);
