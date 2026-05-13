#include <stdint.h>

int gzip_compress(const uint8_t *input, int input_len, uint8_t **output, int *output_len);
int gzip_decompress(const uint8_t *input, int input_len, uint8_t **output, int *output_len);
