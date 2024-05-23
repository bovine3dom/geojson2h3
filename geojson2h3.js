//#!/bin/deno

import * as geojson2h3 from "npm:geojson2h3"

const decoder = new TextDecoder()
const chunks = []
for await (const chunk of Deno.stdin.readable) {
    const text = decoder.decode(chunk)
    chunks.push(text)
}
const feature = JSON.parse(chunks.reduce((l, r) => l+r, ""))

Deno.writeAll(Deno.stdout, new TextEncoder().encode(JSON.stringify(geojson2h3.featureToH3Set(feature, parseInt(Deno.env.get("DENO_H3_RES") ?? "5")))))
