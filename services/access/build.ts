const runtime = (
  await Bun.file(new URL("./.bun-version", import.meta.url)).text()
).trim();
if (Bun.version !== runtime) throw new Error(`Build requires Bun ${runtime}`);
const [version, commit, outfile] = Bun.argv.slice(2);
if (
  !version ||
  !/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(version) ||
  !commit ||
  !/^[0-9a-f]{40}$/.test(commit) ||
  !outfile
) {
  throw new Error(
    "Usage: bun build.ts <version> <40-character-commit> <outfile>",
  );
}
const result = await Bun.build({
  entrypoints: [new URL("./src/main.ts", import.meta.url).pathname],
  compile: { target: "bun-linux-x64", outfile },
  define: {
    ACCESS_VERSION: JSON.stringify(version),
    ACCESS_COMMIT: JSON.stringify(commit),
  },
});

if (!result.success)
  throw new AggregateError(result.logs, "Service build failed");
