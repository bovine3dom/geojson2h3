using LazyJSON, DataFrames, ThreadsX
geojson = LazyJSON.value(read("data/nuts1.json", String));
# consider using LazyJSON.value(String(Mmap.mmap(open("filename","r"))))
H3_RES = 5

geojson["features"][1]["properties"]

# edit this for each geojson
featmeta(feat) = begin
    CODE_KEY = "NUTS112CD"
    NAME_KEY = "NUTS112NM"
    (name=feat["properties"][NAME_KEY], code=feat["properties"][CODE_KEY],)
end

reduce(vcat, ThreadsX.map(feat -> begin
    pipe_in = IOBuffer(string(feat))
    hexstrarray = try
        read(pipeline(addenv(`deno run --allow-read --allow-env geojson2h3.js`, "DENO_H3_RES" => H3_RES), stdin=pipe_in), String)
    catch(e)
        ["0x0"]
    end
    map(x -> (featmeta(feat)..., hex=x,), parse.(UInt64, LazyJSON.value(hexstrarray), base=16))
end, geojson["features"][1:2])) |> DataFrame
