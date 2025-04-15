# rough script for converting geojson files to arrow files of h3 cells using the h3 CLI

prep:

```
juliaup add 1.9.4
julia +1.9.4 --project=. -e 'using Pkg; Pkg.activate("."); Pkg.instantiate()'
cd rust
cargo build -j8 --release
cd ..
```


# usage 

e.g. fuas

```
julia +1.9.4 --project=. --threads auto geojson2h3.jl -r 12 -k'fuacode' --compact fuas_oecd_core.geojson fuas.arrow^
```

e.g. loads of geojsons

```
ls $HOME/projects/inspire/data/*.geojson | parallel -j3 --bar --eta 'julia +1.9.4 --threads=2 --project=. geojson2h3.jl -r15 --compact -k"INSPIREID" --keytype="UInt32" {} out/{/.}.arrow &> /dev/null'
```
