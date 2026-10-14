// Build file chạy cho mọi nền tảng: bun scripts/build.ts
const targets = ["darwin-arm64", "darwin-x64", "linux-x64", "linux-arm64", "windows-x64"];
for (const t of targets) {
  const out = `dist/flygo-agent-${t}${t.startsWith("windows") ? ".exe" : ""}`;
  const p = Bun.spawnSync([process.execPath, "build", "src/cli.ts", "--compile", "--minify", `--target=bun-${t}`, ...(t.startsWith("windows") ? ["--windows-hide-console"] : []), "--outfile", out], { stdout: "pipe", stderr: "pipe" });
  if (p.exitCode !== 0) { console.error(`build ${t} lỗi:\n${p.stderr}`); process.exit(1); }
  console.log(`ok ${out}`);
}
