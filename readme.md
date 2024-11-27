# rough script for converting geojson files to arrow files of h3 cells using the h3 CLI

requires h3 on the PATH
```
yay -S h3-git
h3 polygonToCells --help
./geojson2h3.jl input.geojson output.arrow
```


# example: inspire polygons

takes a while

```
mkdir out/
ls ~/projects/inspire/data/*.geojson | parallel -j12 --bar --eta 'julia --project=. geojson2h3.jl {} out/{/.}.arrow'
# {//} is the directory name, {/.} is the file name without extension, {} is the whole path
```

check for entirely missing ones

```fish
ls (comm -3 (ls ~/projects/inspire/data/*.geojson | xargs basename -s .geojson | sort | psub) (ls out/*.arrow | xargs basename -s .arrow | sort | psub) | sed 's,.*,/home/oliver/projects/inspire/data/&.geojson,') | parallel -j12 --bar --eta 'julia --project=. geojson2h3.jl {} out/{/.}.arrow'
``` 

todo: log failed IDs
