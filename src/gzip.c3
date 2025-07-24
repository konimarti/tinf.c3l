<*

 Ported to C3 by Koni Marti <koni.marti@gmail.com>

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
module tinf::gzip;

import tinf::inflate;
import tinf::error;

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
	return ((uint) p[0]) | ((uint) p[1] << 8) | ((uint) p[2] << 16) | ((uint) p[3] << 24);
}

fn void? uncompress(char[] dst, char[] src)
{
	char *start;
	uint crc32;
	int dlen;
	char flg;

	// -- Check header --

	// Check room for at least 10 byte header and 8 byte trailer
	if (src.len < 18)
	{
		return error::DATA_ERROR?;
	}

	// Check id bytes
	if (src[0] != 0x1F || src[1] != 0x8B)
	{
		return error::DATA_ERROR?;
	}

	// Check method is deflate
	if (src[2] != 8)
	{
		return error::DATA_ERROR?;
	}

	// Get flag byte
	flg = src[3];

	// Check that reserved bits are zero
	if (flg & 0xE0)
	{
		return error::DATA_ERROR?;
	}

	// -- Find start of compressed data --

	// Skip base header of 10 bytes
	start = &src[10];

	// Skip extra data if present
	if (flg & FEXTRA)
	{
		uint xlen = read_le_16(start);

		if (xlen > src.len - 12)
		{
			return error::DATA_ERROR?;
		}

		start += (isz)xlen + 2;
	}

	// Skip file name if present
	if (flg & FNAME)
	{
		do {
			if (start - src.ptr >= src.len)
			{
				return error::DATA_ERROR?;
			}
		} while (*start++);
	}

	// Skip file comment if present
	if (flg & FCOMMENT)
	{
		do {
			if (start - src.ptr >= src.len)
			{
				return error::DATA_ERROR?;
			}
		} while (*start++);
	}

	// Check header crc if present
	if (flg & FHCRC)
	{
		uint hcrc;

		if (start - src.ptr > (long)src.len - 2)
		{
			return error::DATA_ERROR?;
		}

		hcrc = read_le_16(start);

		if (hcrc != (crc32::hash(src[:(start - src.ptr)]) & 0x0000FFFF))
		{
			return error::DATA_ERROR?;
		}

		start += 2;
	}

	// -- Get decompressed length --

	dlen = read_le_32(&src[src.len - 4]);

	if (dlen > dst.len)
	{
		return error::BUF_ERROR?;
	}

	// -- Get CRC32 checksum of original data --

	crc32 = read_le_32(&src[src.len - 8]);

	// -- Decompress data --

	if ((src.ptr + src.len) - start < 8)
	{
		return error::DATA_ERROR?;
	}

	inflate::uncompress(dst, start[:(uint)((src.ptr + src.len) - start - 8)])!;

	if (dst.len != dlen)
	{
		return error::DATA_ERROR?;
	}

	// -- Check CRC32 checksum --

	if (crc32 != crc32::hash(dst))
	{
		return error::DATA_ERROR?;
	}
}
