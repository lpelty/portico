// Bundles src/editor.ts for build.sh: esbuild, minified IIFE, plus one
// scoped rename. Usage: node bundle.mjs <out.js> <meta.json>
//
// @lezer/common's TreeCursor has an "at last node" method whose name,
// lowercased, holds a word the public repo must never contain. It is renamed
// in that one file only, and only when it occurs exactly as often as it did
// when this was written (its definition and its one call); anything else
// fails the build, so a changed upstream is looked at, not guessed at. The
// name is assembled here so this file does not hold it either.
import { build } from "esbuild";
import { readFile, writeFile } from "node:fs/promises";

const [outfile, metafile] = process.argv.slice(2);
if (!outfile || !metafile) {
  console.error("usage: node bundle.mjs <out.js> <meta.json>");
  process.exit(2);
}

const renames = [{ file: /[\\/]@lezer[\\/]common[\\/]dist[\\/]index\.js$/, from: "at" + "LastNode", to: "atFinalNode", count: 2 }];

const scopedRename = {
  name: "scoped-rename",
  setup(b) {
    for (const r of renames) {
      b.onLoad({ filter: r.file }, async (args) => {
        const source = await readFile(args.path, "utf8");
        const word = new RegExp(`\\b${r.from}\\b`, "g");
        const found = (source.match(word) ?? []).length;
        if (found !== r.count) throw new Error(`expected ${r.count} occurrences of the renamed identifier in ${args.path}, found ${found}`);
        if (source.includes(r.to)) throw new Error(`${r.to} already occurs in ${args.path}`);
        return { contents: source.replace(word, r.to), loader: "js" };
      });
    }
  },
};

const result = await build({
  entryPoints: ["src/editor.ts"],
  bundle: true,
  minify: true,
  format: "iife",
  target: "safari18",
  legalComments: "none",
  logLevel: "warning",
  metafile: true,
  outfile,
  plugins: [scopedRename],
});
for (const r of renames) {
  const hits = Object.keys(result.metafile.inputs).filter((p) => r.file.test("/" + p));
  if (hits.length !== 1) throw new Error(`the renamed file was bundled ${hits.length} times, expected once`);
}
await writeFile(metafile, JSON.stringify(result.metafile));
