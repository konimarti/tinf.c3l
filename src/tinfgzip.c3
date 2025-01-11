<*

 Ported to C3 from Koni Marti <koni.marti@gmail.com>

/*
 * tinfgzip - tiny gzip decompressor
 *
 * Copyright (c) 2003-2019 Joergen Ibsen
 *
 * This software is provided 'as-is', without any express or implied
 * warranty. In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 *   1. The origin of this software must not be misrepresented; you must
 *      not claim that you wrote the original software. If you use this
 *      software in a product, an acknowledgment in the product
 *      documentation would be appreciated but is not required.
 *
 *   2. Altered source versions must be plainly marked as such, and must
 *      not be misrepresented as being the original software.
 *
 *   3. This notice may not be removed or altered from any source
 *      distribution.
 */

*>
module tinf;

import std::hash::crc32;

const char FTEXT    = 1;
const char FHCRC    = 2;
const char FEXTRA   = 4;
const char FNAME    = 8;
const char FCOMMENT = 16;

fn uint read_le_16(char *p) @inline
{
	return ((uint) p[0]) | ((uint) p[1] << 8);
}

fn uint read_le_32(char *p) @inline
{
	return ((uint) p[0]) | ((uint) p[1] << 8) | ((uint) p[2] << 16) | ((uint) p[3] << 24); }

fn void! gzip_uncompress(void *dest, int *destLen, void *source, uint sourceLen)
{
	char *src = (char *) source;
	char *dst = (char *) dest;
	char *start;
	uint crc32;
	int dlen;
	char flg;

	// -- Check header --

	// Check room for at least 10 byte header and 8 byte trailer
	if (sourceLen < 18) return TinfError.DATA_ERROR?;

	// Check id bytes
	if (src[0] != 0x1F || src[1] != 0x8B) return TinfError.DATA_ERROR?;

	// Check method is deflate
	if (src[2] != 8) return TinfError.DATA_ERROR?;

	// Get flag byte
	flg = src[3];

	// Check that reserved bits are zero
	if (flg & 0xE0) {
		return TinfError.DATA_ERROR?;
	}

	// -- Find start of compressed data --

	// Skip base header of 10 bytes
	start = src + 10;

	// Skip extra data if present
	if (flg & FEXTRA) {
		uint xlen = read_le_16(start);

		if (xlen > sourceLen - 12) {
			return TinfError.DATA_ERROR?;
		}

		start += xlen + 2;
	}

	// Skip file name if present
	if (flg & FNAME) {
		do {
			if (start - src >= sourceLen) {
				return TinfError.DATA_ERROR?;
			}
		} while (*start++);
	}

	// Skip file comment if present
	if (flg & FCOMMENT) {
		do {
			if (start - src >= sourceLen) {
				return TinfError.DATA_ERROR?;
			}
		} while (*start++);
	}

	// Check header crc if present
	if (flg & FHCRC) {
		uint hcrc;

		if (start - src > (long)sourceLen - 2) {
			return TinfError.DATA_ERROR?;
		}

		hcrc = read_le_16(start);

		if (hcrc != (crc32::encode((String)src[:(start - src)]) & 0x0000FFFF)) {
			return TinfError.DATA_ERROR?;
		}

		start += 2;
	}

	// -- Get decompressed length --

	dlen = read_le_32(&src[sourceLen - 4]);

	if (dlen > *destLen) {
		return TinfError.BUF_ERROR?;
	}

	// -- Get CRC32 checksum of original data --

	crc32 = read_le_32(&src[sourceLen - 8]);

	// -- Decompress data --

	if ((src + sourceLen) - start < 8) {
		return TinfError.DATA_ERROR?;
	}

	tinf::uncompress(dst, destLen, start, (uint)((src + sourceLen) - start - 8))!;

	if (*destLen != dlen) {
		return TinfError.DATA_ERROR?;
	}

	// -- Check CRC32 checksum --

	if (crc32 != crc32::encode((String)dst[:dlen])) {
		return TinfError.DATA_ERROR?;
	}
}
