## C3 Inflate library (inflate, gzip, zlib)

Implementation of the decompression algorithm for the deflate compressed data
format (called 'inflate'). Ported from [tinf](https://github.com/jibsen/tinf).

API overview:
```cpp
import tinf;

// inflate
fn void! uncompress(void *dest, int *destLen, void *source, uint sourceLen)

// gzip
fn void! gzip_uncompress(void *dest, int *destLen, void *source, uint sourceLen)

// zlib
fn void! zlib_uncompress(void *dest, int *destLen, void *source, uint sourceLen)
```

Run the unit tests with `c3c test` from the project root.

### Example

Example will follow.

### Installation

Clone the repository with
```git clone http://github.com/konimarti/tinf.c3l```
to the `./lib` folder of your C3 project and add the following to
`project.json`:

```json
{
    "dependency-search-paths": [ "lib" ],
    "dependencies": [ "tinf" ]
}
```

If you didn't clone it into the `lib` folder, adjust your
`dependency-search-paths` accordingly.
