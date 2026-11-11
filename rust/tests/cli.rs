use geojson::{Geometry, Value};
use h3o::{CellIndex, LatLng, Resolution};
use std::{
    collections::BTreeSet,
    io::Write,
    process::{Command, Output, Stdio},
};

fn ring(x: f64, y: f64, half: f64) -> Vec<Vec<f64>> {
    vec![
        vec![x - half, y - half],
        vec![x + half, y - half],
        vec![x + half, y + half],
        vec![x - half, y + half],
        vec![x - half, y - half],
    ]
}

fn run(value: Value, options: &[&str]) -> Output {
    let input = Geometry::new(value).to_string().replace(",", " ,\n");
    let mut child = Command::new(env!("CARGO_BIN_EXE_geojson_to_h3_rs"))
        .args(["-r8"])
        .args(options)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn cells(value: Value, options: &[&str]) -> BTreeSet<CellIndex> {
    let output = run(value, options);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).unwrap();
    text.split(',')
        .filter(|cell| !cell.is_empty())
        .map(|cell| cell.parse().unwrap())
        .collect()
}

#[test]
fn small_polygon_is_covered_without_containing_a_cell_center() {
    let value = Value::Polygon(vec![ring(2.35, 48.85, 0.000001)]);
    let expected = LatLng::new(48.85, 2.35).unwrap().to_cell(Resolution::Eight);
    assert_eq!(
        cells(value.clone(), &["--nocompact"]),
        BTreeSet::from([expected])
    );
    assert!(cells(value, &["--nocompact", "--containment", "center"]).is_empty());
}

#[test]
fn separate_small_components_are_not_replaced_by_their_average_centroid() {
    let polygons = vec![
        vec![ring(2.35, 48.85, 0.000001)],
        vec![ring(13.405, 52.52, 0.000001)],
    ];
    let expected = polygons
        .iter()
        .flat_map(|rings| cells(Value::Polygon(rings.clone()), &["--nocompact"]))
        .collect();
    assert_eq!(
        cells(Value::MultiPolygon(polygons), &["--nocompact"]),
        expected
    );
}

#[test]
fn small_component_is_not_lost_next_to_a_large_component() {
    let large = vec![ring(2.35, 48.85, 0.02)];
    let small = vec![ring(13.405, 52.52, 0.000001)];
    let expected = cells(Value::Polygon(large.clone()), &["--nocompact"])
        .union(&cells(Value::Polygon(small.clone()), &["--nocompact"]))
        .copied()
        .collect();
    assert_eq!(
        cells(Value::MultiPolygon(vec![large, small]), &["--nocompact"]),
        expected
    );
}

#[test]
fn overlapping_components_are_deduplicated_before_compaction() {
    let polygon = vec![ring(2.35, 48.85, 0.02)];
    assert_eq!(
        cells(
            Value::MultiPolygon(vec![polygon.clone(), polygon.clone()]),
            &[]
        ),
        cells(Value::Polygon(polygon), &[])
    );
}

#[test]
fn holes_exclude_cells_fully_inside_them() {
    let center_cell = LatLng::new(48.85, 2.35).unwrap().to_cell(Resolution::Eight);
    let center = LatLng::from(center_cell);
    let outer = ring(center.lng(), center.lat(), 0.05);
    let mut hole = ring(center.lng(), center.lat(), 0.02);
    hole.reverse();
    let coverage = cells(Value::Polygon(vec![outer, hole]), &["--nocompact"]);
    assert!(!coverage.is_empty());
    assert!(!coverage.contains(&center_cell));
    assert!(coverage
        .iter()
        .all(|cell| cell.resolution() == Resolution::Eight));
}

#[test]
fn compaction_preserves_coverage() {
    let polygon = Value::Polygon(vec![ring(2.35, 48.85, 0.05)]);
    let compact = cells(polygon.clone(), &[]);
    let expanded: BTreeSet<_> = CellIndex::uncompact(compact, Resolution::Eight).collect();
    assert_eq!(expanded, cells(polygon, &["--nocompact"]));
}

#[test]
fn malformed_or_unsupported_geometry_fails_without_a_panic() {
    for value in [
        Value::Point(vec![2.35, 48.85]),
        Value::MultiPolygon(vec![]),
        Value::Polygon(vec![vec![]]),
        Value::Polygon(vec![ring(2.35, 100.0, 0.01)]),
    ] {
        let output = run(value, &[]);
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        assert!(!String::from_utf8_lossy(&output.stderr).contains("panicked"));
    }
}

#[test]
fn output_order_is_deterministic() {
    let polygon = Value::Polygon(vec![ring(2.35, 48.85, 0.02)]);
    let expected = run(polygon.clone(), &["--nocompact"]).stdout;
    for _ in 0..20 {
        assert_eq!(run(polygon.clone(), &["--nocompact"]).stdout, expected);
    }
}
