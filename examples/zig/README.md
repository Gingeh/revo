# zig extensions in revo

run:

```sh
zig build && cp zig-out/lib/libzrevo.* ./zrevo.so
revo ./extension.rv
```

extensions can be made via any language with C api capabilities, which, ironically, is the least
complex way to make them in Zig. just transform the data back

this is wip, and they're not gonna look like this forever

`functions.zig` will act as moving documentation for how they could be written
