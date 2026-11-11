use clap::{Parser, ValueEnum};
use geo_types::Geometry;
use geojson::GeoJson;
use h3o::{
    geom::{ContainmentMode, TilerBuilder},
    CellIndex, Resolution,
};
use std::io::{self, Read};

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
}

fn cover(
    geometry: Geometry<f64>,
    resolution: Resolution,
    containment: Containment,
    compact: bool,
) -> Result<Vec<CellIndex>, Box<dyn std::error::Error>> {
    let polygons = match geometry {
        Geometry::Polygon(polygon) => vec![polygon],
        Geometry::MultiPolygon(polygons) if !polygons.0.is_empty() => polygons.0,
        _ => return Err("Expected a non-empty Polygon or MultiPolygon".into()),
    };
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

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let geometry = Geometry::<f64>::try_from(input.parse::<GeoJson>()?)?;
    let cells = cover(
        geometry,
        Resolution::try_from(args.resolution)?,
        args.containment,
        !args.nocompact,
    )?;
    if cells.is_empty() {
        eprintln!("Warning: No cells at resolution {}", args.resolution);
    }
    let cells: Vec<_> = cells.iter().map(|cell| format!("{cell:x}")).collect();
    print!("{}", cells.join(","));
    Ok(())
}
