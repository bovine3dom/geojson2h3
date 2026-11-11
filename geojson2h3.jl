#!/usr/bin/env julia

using JSON, Arrow, ArgParse

function settings()
    s = ArgParseSettings()
    @add_arg_table! s begin
        "--res", "-r"
            help = "H3 resolution"
            arg_type = Int
            default = 10
            range_tester = x -> 0 <= x <= 15
        "--compact", "-c"
            help = "Compact cells to mixed resolutions"
            action = :store_true
        "--containment"
            help = "Cell selection: overlap or center"
            default = "overlap"
            range_tester = x -> x in ("overlap", "center")
        "--key", "-k"
            help = "Feature property to retain"
            arg_type = String
            required = true
        "--keytype"
            help = "Julia function or type for feature keys"
            default = "string"
        "--stream"
            help = "Read one GeoJSON feature per line"
            action = :store_true
        "--batch-size"
            help = "Maximum number of features per Arrow batch"
            arg_type = Int
            default = 64
            range_tester = x -> x > 0
        "input"
            help = "GeoJSON file, GeoJSONSeq file, or - for a sequence on stdin"
            required = true
        "output"
            help = "Output Arrow file"
            default = "out.arrow"
    end
    return s
end

function feature_to_h3(feature, cmd, key)
    properties = get(feature, "properties", nothing)
    label = properties isa AbstractDict ? get(properties, key, "<missing>") : "<missing>"
    try
        output = strip(read(pipeline(cmd; stdin=IOBuffer(JSON.json(feature))), String))
        return isempty(output) ? UInt64[] : parse.(UInt64, split(output, ','), base=16)
    catch e
        error("Conversion failed for $key=$(repr(label)): $(sprint(showerror, e))")
    end
end

function sequence_feature(line, number)
    try
        feature = JSON.parse(lstrip(strip(line), ['\x1e']))
        get(feature, "type", nothing) == "Feature" || error("Expected a GeoJSON Feature")
        return feature
    catch e
        error("Invalid GeoJSONSeq record at line $number: $(sprint(showerror, e))")
    end
end

function convert_features(features, writer, args, cmd, key_parser)
    key = args["key"]
    total_features = total_cells = empty_features = 0
    for batch in Iterators.partition(features, args["batch-size"])
        keys = map(enumerate(batch)) do (i, feature)
            get(feature, "type", nothing) == "Feature" || error("Expected a GeoJSON Feature")
            properties = get(feature, "properties", nothing)
            properties isa AbstractDict && haskey(properties, key) ||
                error("Feature $(total_features + i) has no property $(repr(key))")
            key_parser(properties[key])
        end
        cells = Vector{Vector{UInt64}}(undef, length(batch))
        Threads.@threads for i in eachindex(batch)
            cells[i] = feature_to_h3(batch[i], cmd, key)
        end
        output_keys = eltype(keys)[]
        output_cells = UInt64[]
        for (value, coverage) in zip(keys, cells)
            append!(output_keys, fill(value, length(coverage)))
            append!(output_cells, coverage)
            empty_features += isempty(coverage)
        end
        Arrow.write(writer, NamedTuple{(Symbol(key), :h3)}((output_keys, output_cells)))
        total_features += length(batch)
        total_cells += length(output_cells)
    end
    if total_features == 0
        key_type = key_parser isa Type ? key_parser : String
        Arrow.write(writer, NamedTuple{(Symbol(key), :h3)}((key_type[], UInt64[])))
    end
    return (; features=total_features, cells=total_cells, empty_features)
end

function main(argv=ARGS)
    args = parse_args(argv, settings())
    args["key"] == "h3" && error("The feature key must not be named h3")
    binary = joinpath(@__DIR__, "rust", "target", "release", "geojson_to_h3_rs")
    isfile(binary) || error("Build the converter first: cd $(@__DIR__)/rust && cargo build --release")
    options = ["-r$(args["res"])", "--containment", args["containment"]]
    args["compact"] || push!(options, "--nocompact")
    cmd = `$binary $options`
    key_parser = eval(Meta.parse(args["keytype"]))
    sequence = args["stream"] || args["input"] == "-" ||
        lowercase(splitext(args["input"])[2]) in (".geojsonl", ".geojsons", ".jsonl", ".ndjson")

    function convert_input(input)
        features = if sequence
            (sequence_feature(line, number) for (number, line) in enumerate(eachline(input))
             if !isempty(strip(line)))
        else
            geo = JSON.parse(read(input, String))
            get(geo, "type", nothing) == "FeatureCollection" ? geo["features"] : [geo]
        end
        mktempdir(dirname(abspath(args["output"]))) do directory
            partial = joinpath(directory, "output.arrow")
            counts = open(Arrow.Writer, partial; compress=:zstd, ntasks=1) do writer
                convert_features(features, writer, args, cmd, key_parser)
            end
            mv(partial, args["output"]; force=true)
            @info "Conversion complete" counts...
        end
    end

    if args["input"] == "-"
        convert_input(stdin)
    else
        open(convert_input, args["input"])
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && main()
