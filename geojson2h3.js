import * as geojson2h3 from "geojson2h3"

const decoder = new TextDecoder()
const chunks = []
for await (const chunk of Bun.stdin.stream()) {
    const text = decoder.decode(chunk)
    chunks.push(text)
}
const feature = JSON.parse(chunks.reduce((l, r) => l+r, ""))

await Bun.write(Bun.stdout, new TextEncoder().encode(JSON.stringify(geojson2h3.featureToH3Set(feature, parseInt(Bun.env.DENO_H3_RES ?? "5")))))
