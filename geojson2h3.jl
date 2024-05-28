using LazyJSON, DataFrames, ThreadsX
geojson = LazyJSON.value(read("data/Lower_layer_Super_Output_Areas_2021_EW_BGC_V3_-6823567593069184824.geojson", String));
# consider using LazyJSON.value(String(Mmap.mmap(open("filename","r"))))
H3_RES = 7

geojson["features"][1]["properties"]

# edit this for each geojson
featmeta(feat) = begin
    CODE_KEY = "LSOA21CD"
    NAME_KEY = "LSOA21NM"
    (name=feat["properties"][NAME_KEY], code=feat["properties"][CODE_KEY],)
end

hexdf = reduce(vcat, ThreadsX.map(feat -> begin
    pipe_in = IOBuffer(string(feat))
    hexstrarray = try
        read(pipeline(addenv(`deno run --allow-read --allow-env geojson2h3.js`, "DENO_H3_RES" => H3_RES), stdin=pipe_in), String)
    catch(e)
        ["0x0"]
    end
    map(x -> (featmeta(feat)..., hex=x,), parse.(UInt64, LazyJSON.value(hexstrarray), base=16))
end, geojson["features"])) |> DataFrame

using CSV, Statistics
CSV.write("lsoa_7.csv", hexdf)

df = leftjoin(hexdf, combine(groupby(hexdf, :code), x -> (value_t = rand(),)), on=:code)
df.index = string.(df.hex, base=16)
df.value = 1 .- (df.value_t .- quantile(df.value_t, 0.05)) ./ quantile(df.value_t, 0.95) # 0 is bad (red), cut off top and bottom 5%
CSV.write("$(homedir())/projects/H3-MON/www/data/h3_data.csv", df[!, [:index, :value]])

