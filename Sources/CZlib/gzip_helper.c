#include <zlib.h>
#include <stdlib.h>
#include <string.h>

int gzip_compress(const uint8_t *input, int input_len, uint8_t **output, int *output_len) {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.zalloc = Z_NULL;
    stream.zfree = Z_NULL;
    stream.opaque = Z_NULL;

    int ret = deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                           15 + 16, 8, Z_DEFAULT_STRATEGY);
    if (ret != Z_OK) return ret;

    // Estimate output size (input + 0.1% + 12 bytes for headers)
    int bound = deflateBound(&stream, input_len);
    *output = malloc(bound);
    stream.next_in = (unsigned char *)input;
    stream.avail_in = input_len;
    stream.next_out = *output;
    stream.avail_out = bound;

    ret = deflate(&stream, Z_FINISH);
    if (ret != Z_STREAM_END) {
        free(*output);
        *output = NULL;
        deflateEnd(&stream);
        return ret == Z_OK ? Z_DATA_ERROR : ret;
    }

    *output_len = stream.total_out;
    deflateEnd(&stream);
    return Z_OK;
}

int gzip_decompress(const uint8_t *input, int input_len, uint8_t **output, int *output_len) {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.zalloc = Z_NULL;
    stream.zfree = Z_NULL;
    stream.opaque = Z_NULL;

    int ret = inflateInit2(&stream, 15 + 16);
    if (ret != Z_OK) return ret;

    // Start with 2x input size, grow as needed
    int capacity = input_len * 2;
    if (capacity < 4096) capacity = 4096;
    *output = malloc(capacity);
    stream.next_in = (unsigned char *)input;
    stream.avail_in = input_len;
    stream.next_out = *output;
    stream.avail_out = capacity;

    while (1) {
        ret = inflate(&stream, Z_FINISH);
        if (ret == Z_STREAM_END) break;
        if (ret != Z_OK && ret != Z_BUF_ERROR) {
            free(*output);
            *output = NULL;
            inflateEnd(&stream);
            return ret;
        }
        // Grow buffer
        int new_capacity = capacity * 2;
        *output = realloc(*output, new_capacity);
        stream.next_out = *output + stream.total_out;
        stream.avail_out = new_capacity - stream.total_out;
        capacity = new_capacity;
    }

    *output_len = stream.total_out;
    inflateEnd(&stream);
    return Z_OK;
}
