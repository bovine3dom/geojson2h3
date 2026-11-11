# GeoJSON to H3

Convert GeoJSON polygons to H3 cells in an Arrow file. The output has the
selected feature property and an `h3` column of `UInt64` indexes.

## Setup

Run these commands from this repository. The tests use Julia 1.10.

```bash
juliaup add 1.10
julia +1.10 --project=. -e 'using Pkg; Pkg.instantiate(; allow_autoprecomp=false)'
cargo build --release --locked --manifest-path rust/Cargo.toml
```

## Usage

Convert a GeoJSON FeatureCollection or a single Feature:

```bash
julia +1.10 --project=. --threads=8 geojson2h3.jl \
  -r8 -kcategory input.geojson output.arrow
```

The default selects every cell that overlaps a polygon. Use
`--containment center` for the previous cell-centre rule. Use `--compact`
to produce mixed resolutions. Without this option, all cells have the
requested resolution.

Use `--keytype=UInt32` for numeric keys. The default converts keys to strings.
Features can share a key. The converter does not combine their rows or
calculate a maximum value per cell.

## Stream large inputs

The reader detects `.geojsonl`, `.geojsons`, `.jsonl`, and `.ndjson` files.
Use `--stream` for other file names. Use `-` for a sequence on standard input.
Each record must be one GeoJSON Feature on one line. An optional record
separator (`0x1e`) can precede each record.

For example, stream a GeoPackage layer through GDAL:

```bash
set -o pipefail
ogr2ogr -f GeoJSONSeq /vsistdout/ AT.gpkg \
  NoiseContours_majorRoadsIncludingAgglomeration_Lden \
  -t_srs EPSG:4326 -lco RS=NO \
  | julia +1.10 --project=. --threads=8 geojson2h3.jl \
      -r8 -kcategory --batch-size=512 - roads.arrow
```

The Rust helper processes up to 64 features per call. The default Arrow
batch size is 64 features. Use `--batch-size=512` with eight Julia threads
to process eight helper batches at once. This avoids one process launch
per feature. Reduce the batch size for large geometries. A regular GeoJSON
FeatureCollection still loads into memory.

The helper's `--stream` mode reads one GeoJSON object per line and writes
one comma-separated cell list per line. Empty coverage produces an empty
line. Add `--key PROPERTY` to prefix each line with the JSON-encoded
property value and a tab. This lets a consumer read keys and cells without
parsing geometry text. In this mode an empty cell list still has the key
prefix. Errors stop the helper and identify the input record and properties.
Use `--polygon-only` in the Rust helper to ignore lines, points, and empty
polygon components. For geometry collections, this option processes only
the polygon components. This is useful when geometry repair leaves
collapsed contours. Without this option, unsupported geometry is an error.
Rebuild the helper after an update to its command-line options.

Input coordinates must be WGS84 longitude/latitude in degrees. Reproject
other coordinate systems before conversion. See the
[GDAL GeoJSONSeq documentation](https://gdal.org/en/stable/drivers/vector/geojsonseq.html).

## Tests

```bash
cargo test --locked --manifest-path rust/Cargo.toml
julia +1.10 --project=. --threads=8 test/runtests.jl
```

Tests cover small polygons, separate components, holes, compaction,
coordinate errors, streaming, empty results, output preservation, and
threaded subprocess calls.
