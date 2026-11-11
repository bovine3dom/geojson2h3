using Test, JSON, Arrow
include(joinpath(@__DIR__, "..", "geojson2h3.jl"))

const BINARY = joinpath(@__DIR__, "..", "rust", "target", "release", "geojson_to_h3_rs")

function feature(id; x=2.35, y=48.85, half=0.01)
    ring = [[x-half, y-half], [x+half, y-half], [x+half, y+half],
            [x-half, y+half], [x-half, y-half]]
    Dict("type" => "Feature", "properties" => Dict("id" => id),
         "geometry" => Dict("type" => "Polygon", "coordinates" => [ring]))
end

function rows(path)
    table = Arrow.Table(path)
    collect(zip(table.id, table.h3))
end

@testset "GeoJSON to Arrow" begin
    mktempdir() do directory
        features = [feature(i) for i in 1:8]
        collection = joinpath(directory, "input.geojson")
        sequence = joinpath(directory, "input.geojsonl")
        open(collection, "w") do io
            JSON.print(io, Dict("type" => "FeatureCollection", "features" => features), 2)
        end
        open(sequence, "w") do io
            println(io)
            for f in features
                println(io, '\x1e', JSON.json(f))
            end
        end
        output = joinpath(directory, "output.arrow")
        main(["-r8", "-kid", "--batch-size=3", collection, output])
        expected = rows(output)
        @test !isempty(expected)
        @test Set(first.(expected)) == Set(string.(1:8))
        main(["-r8", "-kid", "--batch-size=2", sequence, output])
        @test rows(output) == expected

        # Read stdin with a file-backed stream; main must not close it.
        open(sequence) do io
            redirect_stdin(io) do
                main(["-r8", "-kid", "-", output])
            end
            @test isopen(io)
        end
        @test rows(output) == expected

        explicit_stream = joinpath(directory, "records.txt")
        write(explicit_stream, read(sequence))
        main(["-r8", "-kid", "--stream", explicit_stream, output])
        @test rows(output) == expected

        single = joinpath(directory, "single.json")
        write(single, JSON.json(features[1]))
        main(["-r8", "-kid", single, output])
        @test rows(output) == filter(row -> first(row) == "1", expected)

        main(["-r8", "-kid", "--keytype=UInt32", sequence, output])
        @test eltype(Arrow.Table(output).id) == UInt32

        empty_input = joinpath(directory, "empty.geojsonl")
        write(empty_input, "")
        main(["-kid", empty_input, output])
        @test isempty(rows(output))
        @test eltype(Arrow.Table(output).h3) == UInt64

        tiny = feature(1; half=0.000001)
        tiny_file = joinpath(directory, "tiny.geojsonl")
        write(tiny_file, JSON.json(tiny) * "\n")
        main(["-r8", "-kid", "--containment=center", tiny_file, output])
        @test isempty(rows(output))
        main(["-r8", "-kid", tiny_file, output])
        @test length(rows(output)) == 1

        write(tiny_file, JSON.json(tiny) * "\n" * JSON.json(feature(2)) * "\n")
        main(["-r8", "-kid", "--containment=center", "--batch-size=1", tiny_file, output])
        @test Set(first.(rows(output))) == Set(["2"])

        # A failure after an Arrow batch must preserve any existing destination.
        original = read(output)
        for bad in ("not JSON", JSON.json(Dict("type" => "Feature", "properties" => Dict())),
                    JSON.json(merge(feature(2), Dict("geometry" => nothing))))
            write(sequence, JSON.json(features[1]) * "\n" * bad * "\n")
            @test_throws Exception main(["-kid", "--batch-size=1", sequence, output])
            @test read(output) == original
            @test !any(startswith(name, "jl_") for name in readdir(directory))
        end

        fail = `$(Base.julia_cmd()) --startup-file=no -e 'read(stdin); exit(1)'`
        @test_throws ErrorException feature_to_h3(features[1], fail, "id")
        @test_throws ErrorException sequence_feature("bad", 7)
        @test sequence_feature("\x1e" * JSON.json(features[1]), 1) == features[1]
    end
end

@testset "Threaded subprocess stress" begin
    features = [feature(i; half=0.05) for i in 1:256]
    command = `$BINARY -r10 --nocompact --containment overlap`
    expected = feature_to_h3(features[1], command, "id")
    results = Vector{Vector{UInt64}}(undef, length(features))
    Threads.@threads for i in eachindex(features)
        results[i] = feature_to_h3(features[i], command, "id")
    end
    @test all(==(expected), results)
    @test length(expected) * 16 > 64 * 1024
end
