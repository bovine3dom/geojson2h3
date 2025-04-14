use h3o::{geom::{ContainmentMode, TilerBuilder}, Resolution, CellIndex};
use geo_types::{Geometry};
use geojson::{GeoJson};
use std::convert::TryFrom;
use std::str::FromStr;
use std::io::{self, BufRead};
use clap::Parser;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(short, long, default_value_t = 7)]
    resolution: u8,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();

    let mut geojson_str = String::new();
    let stdin = io::stdin();
    stdin.lock().read_line(&mut geojson_str).unwrap();

    let geojson = GeoJson::from_str(&geojson_str)?;
    let geom = Geometry::<f64>::try_from(geojson)?;

    let resolution = Resolution::try_from(args.resolution)?;
    let mut tiler = TilerBuilder::new(resolution)
        .containment_mode(ContainmentMode::ContainsCentroid)
        .build();

    match geom {
        Geometry::Polygon(poly) => {
            tiler.add(poly)?;
        }
        Geometry::MultiPolygon(multi_poly) => {
            for poly in multi_poly {
                tiler.add(poly)?;
            }
        }
        _ => {
            return Err(Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "not implemented u may only feed me polygons and mulipolygons",
            )));
        }
    }

    let mut cells = tiler.into_coverage().collect::<Vec<_>>();

    if !cells.is_empty() {
        CellIndex::compact(&mut cells)?;
    } else {
         eprintln!("Warning: No H3 cells generated for the input geometry at resolution {}.", args.resolution);
    }

    // rust can't infer that map to format is a string type :(
    let cell_strings: Vec<String> = cells.iter().map(|c| format!("{:x}", c)).collect();
    print!("{}", cell_strings.join(","));

    Ok(())
}
