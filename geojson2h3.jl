#!/bin/julia

# usage: ./geojson2h3.jl input.geojson output.arrow

using JSON, DataFrames, Statistics, Arrow

infile = ARGS[1]
outfile = ARGS[2]

# readchomp(`h3 polygonToCells --help`) |> print

geo = JSON.parsefile(infile)
features = geo["features"]

function featureToH3(feature)
    buffer = IOBuffer()
    geoms = feature["geometry"]["coordinates"]
    geoms_rev = map(x -> reverse.(x), geoms) # easter egg: opposite to geojson
    open(`h3 polygonToCells -r 15 -i --`, "w", buffer) do io
        println(io, geoms_rev) # easter egg: polygonToCells will take a geojson fragment from Julia, but it's slower
    end
    return take!(buffer) |> String |> JSON.parse
end

function bbox(coordinates)
    # coordinats are pairs of [[x, y], [x, y], ...]
    minx = minimum(map(x -> x[1], coordinates))
    maxx = maximum(map(x -> x[1], coordinates))
    miny = minimum(map(x -> x[2], coordinates))
    maxy = maximum(map(x -> x[2], coordinates))
    return [minx, miny, maxx, maxy]
end

function bboxarea(bbox)
    (bbox[3] - bbox[1]) * (bbox[4] - bbox[2])
end


h3s = Dict{Int, Vector{Any}}()
area_cutoff = quantile(map(f -> (bboxarea∘bbox)(f["geometry"]["coordinates"][1]), features), 0.99)
length_cutoff = quantile(map(f -> length(f["geometry"]["coordinates"][1]), features),0.99)
for feature in features # multithreading doesn't work :(
    (any(map(>(area_cutoff)∘bboxarea∘bbox, feature["geometry"]["coordinates"])) || any(map(>(length_cutoff)∘length, feature["geometry"]["coordinates"]))) && continue # skip big polygons
    try
        h3s[feature["properties"]["INSPIREID"]] = featureToH3(feature)
    catch (e)
        @warn e
    end
end

df = flatten(DataFrame(:id_str => keys(h3s)|>collect, :h3_str => values(h3s)|>collect), :h3_str)
df.h3 = map(x -> parse(UInt64, x, base=16), df.h3_str)
df.INSPIREID = UInt32.(df.id_str)

Arrow.write(outfile, df[!, [:INSPIREID, :h3]]) # 73MB for IOW with big polygons excluded, approx 5mins to run
