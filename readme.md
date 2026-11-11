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
      -r8 -kcategory --batch-size=64 - roads.arrow
```

GeoJSONSeq processing uses batches of 64 features. Reduce `--batch-size`
for large geometries. A regular GeoJSON FeatureCollection still loads into
memory.

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
