#!/bin/julia

# usage: ./geojson2h3.jl --key INSPIREID input.geojson output.arrow

using JSON, DataFrames, Arrow, ArgParse, ProgressMeter
s = ArgParseSettings()
@add_arg_table! s begin
    "--res", "-r"
        help = "H3 resolution"
        arg_type = Int
        default = 10
    "--compact", "-c"
        help = "Compact H3 cells to varying resolutions, NB: for large features can make a huge difference to filesize"
        action = :store_true
    "--key", "-k"
        help = "Unique key per feature"
        arg_type = String
        required = true
        # default = "PCON24CD"
    "--keytype"
        help = "Julia function to parse string to key type e.g. UInt32"
        arg_type = String
        default = "string"
    "input"
        help = "Input geojson file"
        arg_type = String
        # default = "data/PCON_MAY_2024_UK_BFE_1900571613665677527.geojson"
        required = true
    "output"
        help = "Output arrow file"
        arg_type = String
        default = "out.arrow"
end
args = parse_args(ARGS, s)
res = args["res"]

key_parser = eval(Meta.parse(args["keytype"]))



infile = args["input"]

# readchomp(`h3 polygonToCells --help`) |> print

geo = JSON.parsefile(infile)
features = geo["features"]
key = args["key"]

pmp_only = filter(f->in(f["geometry"]["type"], ["Polygon", "MultiPolygon"]), features)
function featureToH3(feature; res=10)
    try
        buffer = IOBuffer()
        options = ["-r$res"]
        !args["compact"] && push!(options, "--nocompact") # what a nightmare
        open(`./rust/target/release/geojson_to_h3_rs $options`, "w", buffer) do io
            println(io, JSON.json(feature))
        end
        return parse.(UInt64, split(String(take!(buffer)), ","), base=16)
    catch(e)
        # @warn e
        return UInt64[] # fails sometimes when multithreaded :(((
    end
end

res = args["res"]
a = [[] for _ in 1:length(pmp_only)]
for i in 1:4 # one iteration is enough but why risk it
    @info("Iteration $i")
    @showprogress Threads.@threads for (k, v) in collect(enumerate(a))
        if length(v) == 0
            a[k] = featureToH3(pmp_only[k], res=res)
        end
    end
end

df = flatten(DataFrame(Symbol(key)=>map(f->key_parser(f["properties"][key]), pmp_only), :h3=>a), :h3)
Arrow.write(args["output"], df, compress=:zstd)
