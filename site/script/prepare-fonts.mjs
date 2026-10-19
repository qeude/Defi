import { mkdir, access, writeFile, rename } from 'node:fs/promises';

const directory = new URL('../public/fonts/', import.meta.url);
await mkdir(directory, { recursive: true });
const fonts = [
  [
    "CabinetGrotesk-500.woff2",
    "https://cdn.fontshare.com/wf/CKQBK2QBTCDREE7L3MXZ3PPW7LDNJCWU/OTOY7FQFSFOJVZKJWKO2EHUJLOGBDN4Q/4CO2ETY7NITKLUDKMYJ75RHJSPHOJ7XT.woff2"
  ]
];
for (const [name, source] of fonts) {
  const target = new URL(name, directory);
  try {
    await access(target);
    continue;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  const response = await fetch(source, { signal: AbortSignal.timeout(30000) });
  if (!response.ok) throw new Error(`Font download failed: ${name} (${response.status})`);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.subarray(0, 4).toString() !== 'wOF2') throw new Error(`Invalid WOFF2 font: ${name}`);
  // Rename into place so an interrupted write never leaves a truncated font that later runs would skip.
  const partial = new URL(`${name}.partial`, directory);
  await writeFile(partial, bytes);
  await rename(partial, target);
  console.log(`Prepared ${name}`);
}
