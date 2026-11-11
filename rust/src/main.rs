use clap::{Parser, ValueEnum};
use geo_types::Geometry;
use geojson::GeoJson;
use h3o::{
    geom::{ContainmentMode, TilerBuilder},
    CellIndex, Resolution,
};
use std::io::{self, BufRead, Read, Write};

#[derive(Clone, Copy, Debug, ValueEnum)]
enum Containment {
    Center,
    Overlap,
}

#[derive(Parser, Debug)]
#[command(author, version, about)]
struct Args {
    #[arg(short, long, default_value_t = 7)]
    resolution: u8,
    #[arg(short, long, help = "Do not compact cells to mixed resolutions")]
    nocompact: bool,
    #[arg(long, value_enum, default_value = "overlap")]
    containment: Containment,
    #[arg(
        long,
        help = "Read one GeoJSON object per line and write one cell list per line"
    )]
    stream: bool,
    #[arg(
        long,
        requires = "stream",
        help = "Prefix each cell list with the JSON property value and a tab"
    )]
    key: Option<String>,
    #[arg(
        long,
        help = "Ignore non-polygon geometry and empty polygon components"
    )]
    polygon_only: bool,
}

fn cover(
    geometry: Geometry<f64>,
    resolution: Resolution,
    containment: Containment,
    compact: bool,
    polygon_only: bool,
) -> Result<Vec<CellIndex>, Box<dyn std::error::Error>> {
    let mut pending = vec![geometry];
    let mut polygons = Vec::new();
    while let Some(geometry) = pending.pop() {
        match geometry {
            Geometry::Polygon(polygon) => polygons.push(polygon),
            Geometry::MultiPolygon(parts) if polygon_only || !parts.0.is_empty() => {
                polygons.extend(parts.0);
            }
            Geometry::GeometryCollection(parts) if polygon_only => pending.extend(parts.0),
            _ if polygon_only => {}
            _ => return Err("Expected a non-empty Polygon or MultiPolygon".into()),
        }
    }
    if polygon_only {
        polygons.retain(|polygon| !polygon.exterior().0.is_empty());
    }
    let mode = match containment {
        Containment::Center => ContainmentMode::ContainsCentroid,
        Containment::Overlap => ContainmentMode::Covers,
    };
    let mut cells = Vec::new();
    for polygon in polygons {
        if std::iter::once(polygon.exterior())
            .chain(polygon.interiors())
            .flat_map(|ring| &ring.0)
            .any(|coord| !(-180.0..=180.0).contains(&coord.x) || !(-90.0..=90.0).contains(&coord.y))
        {
            return Err("Expected WGS84 longitude/latitude coordinates in degrees".into());
        }
        // Covers uses a centroid fallback for a polygon contained in one cell.
        // Tile each component separately so that this fallback cannot lose islands.
        let mut tiler = TilerBuilder::new(resolution).containment_mode(mode).build();
        tiler.add(polygon)?;
        cells.extend(tiler.into_coverage());
    }
    cells.sort_unstable();
    cells.dedup();
    if compact {
        CellIndex::compact(&mut cells)?;
        cells.sort_unstable();
    }
    Ok(cells)
}

fn convert(
    input: &str,
    args: &Args,
) -> Result<(Vec<CellIndex>, Option<String>), Box<dyn std::error::Error>> {
    let mut json = input.parse::<GeoJson>()?;
    let properties = match &mut json {
        GeoJson::Feature(feature) => feature.properties.take(),
        _ => None,
    };
    let result: Result<_, Box<dyn std::error::Error>> = (|| {
        let key = args
            .key
            .as_ref()
            .map(|name| {
                properties
                    .as_ref()
                    .and_then(|values| values.get(name))
                    .map(ToString::to_string)
                    .ok_or_else(|| format!("Missing feature property {name}"))
            })
            .transpose()?;
        let cells = cover(
            Geometry::<f64>::try_from(json)?,
            Resolution::try_from(args.resolution)?,
            args.containment,
            !args.nocompact,
            args.polygon_only,
        )?;
        Ok((cells, key))
    })();
    result.map_err(|error| format!("{error}; properties: {properties:?}").into())
}

fn format_cells(cells: &[CellIndex]) -> String {
    let cells: Vec<_> = cells.iter().map(|cell| format!("{cell:x}")).collect();
    cells.join(",")
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    let mut output = io::BufWriter::new(io::stdout().lock());
    if args.stream {
        for (index, line) in io::stdin().lock().lines().enumerate() {
            let (cells, key) = convert(&line?, &args)
                .map_err(|error| format!("Input record {}: {error}", index + 1))?;
            if let Some(key) = key {
                write!(output, "{key}\t")?;
            }
            writeln!(output, "{}", format_cells(&cells))?;
        }
    } else {
        let mut input = String::new();
        io::stdin().read_to_string(&mut input)?;
        let (cells, _) = convert(&input, &args)?;
        if cells.is_empty() {
            eprintln!("Warning: No cells at resolution {}", args.resolution);
        }
        write!(output, "{}", format_cells(&cells))?;
    }
    output.flush()?;
    Ok(())
}
