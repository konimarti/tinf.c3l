<*
 Ported to C3 by Koni Marti <koni.marti@gmail.com>

/*
 * tinfzlib - tiny zlib decompressor
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
module tinf::zlib;

import tinf::inflate;
import tinf::error;

import std::hash::adler32;

fn uint read_be_uint(char *p) @inline
{
	return (uint)p[0] << 24 | (uint)p[1] << 16 | (uint)p[2] << 8 | (uint)p[3];
}

fn void? uncompress(char[] dest, char[] source) //void *dest, int *dest.len, void *source, uint source.len)
{
	uint a32;
	char cmf, flg;

	// -- check header --

	// check room for at least 2 yte header and 4 byte trailer
	if (source.len < 6) return error::DATA_ERROR?;

	// get header bytes
	cmf = source[0];
	flg = source[1];

	// check checksum
	if ((256 * cmf + flg) % 31) return error::DATA_ERROR?;

	// check method is deflate
	if ((cmf & 0x0F) != 8) return error::DATA_ERROR?;

	// check window size is valid
	if ((cmf >> 4) > 7) return error::DATA_ERROR?;

	// Check there is no preset dictionary
	if (flg & 0x20) return error::DATA_ERROR?;

	// get Adler-32 checksum of original data

	a32 = read_be_uint(&source[source.len-4]);

	// decompress data

	inflate::uncompress(dest, source[2:source.len-6])!;

	// -- Check Adler-32 checksum --

	if (a32 != adler32::hash(dest)) {
		return error::DATA_ERROR?;
	}
}
