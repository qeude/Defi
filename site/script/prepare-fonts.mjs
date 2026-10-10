import { mkdir, access, writeFile } from 'node:fs/promises';

const directory = new URL('../public/fonts/', import.meta.url);
await mkdir(directory, { recursive: true });
const fonts = [
  [
    "CabinetGrotesk-500.woff2",
    "https://cdn.fontshare.com/wf/CKQBK2QBTCDREE7L3MXZ3PPW7LDNJCWU/OTOY7FQFSFOJVZKJWKO2EHUJLOGBDN4Q/4CO2ETY7NITKLUDKMYJ75RHJSPHOJ7XT.woff2"
  ],
  [
    "CabinetGrotesk-700.woff2",
    "https://cdn.fontshare.com/wf/XMXWOHABYLQDJ42L65EFRYNVRY37HQCB/B2O4O6V3JMFM2WDCYQI3A47L5U4THDUL/WN5274VQ3AUBDFP74GB4EC4XYJ3EKVNE.woff2"
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
  await writeFile(target, bytes);
  console.log(`Prepared ${name}`);
}
