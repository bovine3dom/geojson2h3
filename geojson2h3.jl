#!/bin/julia

# usage: ./geojson2h3.jl input.geojson output.arrow

using JSON, DataFrames, Statistics, Arrow, ThreadsX

infile = ARGS[1]
outfile = ARGS[2]

# infile = "data/PCON_MAY_2024_UK_BFE_1900571613665677527.geojson"

# readchomp(`h3 polygonToCells --help`) |> print

geo = JSON.parsefile(infile)
features = geo["features"]

pmp_only = filter(f->in(f["geometry"]["type"], ["Polygon", "MultiPolygon"]), features)
function featureToH3Redux(feature; res=10)
    try
        buffer = IOBuffer()
        open(`./rust/target/release/geojson_to_h3_rs -r$res --nocompact`, "w", buffer) do io
        # open(`./rust/target/release/geojson_to_h3_rs -r$res`, "w", buffer) do io
            println(io, JSON.json(feature)) # easter egg: polygonToCells will take a geojson fragment from Julia, but it's slower
        end
        return parse.(UInt64, split(String(take!(buffer)), ","), base=16)
    catch(e)
        return UInt64[] # fails sometimes when multithreaded :(((
    end
end

res = 9
a = ThreadsX.map(f -> featureToH3Redux(f, res=res), pmp_only)
for _ in 1:3 # one iteration is enough but why risk it
    Threads.@threads for (k, v) in collect(enumerate(a))
        if length(v) == 0
            a[k] = featureToH3Redux(pmp_only[k], res=res)
        end
    end
end

df = flatten(DataFrame(PCON24CD=map(f->f["properties"]["PCON24CD"], pmp_only), h3=a, value=rand(length(a))), :h3)
df.index = string.(df.h3, base=16)
# df.value = rand(size(df, 1))
using CSV
CSV.write("$(homedir())/projects/H3-MON/www/data/h3_data.csv", df[:, [:index, :value]])

function featureToH3(feature)
    buffer = IOBuffer()
    geoms = feature["geometry"]["coordinates"]
    geoms_rev = map(x -> reverse.(x), geoms) # easter egg: opposite to geojson
    open(`h3 polygonToCells -r 9 -i --`, "w", buffer) do io
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


h3s = Dict{String, Vector{Any}}()
# area_cutoff = quantile(map(f -> (bboxarea∘bbox)(f["geometry"]["coordinates"][1]), features), 0.99)
# length_cutoff = quantile(map(f -> length(f["geometry"]["coordinates"][1]), features),0.99)
for feature in features # multithreading doesn't work :(
    # (any(map(>(area_cutoff)∘bboxarea∘bbox, feature["geometry"]["coordinates"])) || any(map(>(length_cutoff)∘length, feature["geometry"]["coordinates"]))) && continue # skip big polygons
    try
        @info (feature["properties"]["PCON24CD"], feature["properties"]["PCON24NM"])
        h3s[feature["properties"]["PCON24CD"]] = featureToH3(feature)
        @info (feature["properties"]["PCON24CD"], "done")
    catch (e)
        @warn e
    end
end

df = flatten(DataFrame(:id_str => keys(h3s)|>collect, :h3_str => values(h3s)|>collect), :h3_str)
df.h3 = map(x -> parse(UInt64, x, base=16), df.h3_str)
df.INSPIREID = UInt32.(df.id_str)

Arrow.write(outfile, df[!, [:INSPIREID, :h3]]) # 73MB for IOW with big polygons excluded, approx 5mins to run
